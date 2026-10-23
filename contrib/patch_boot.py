#!/usr/bin/env python3
"""Склейка патча в существующий boot.img без mkbootimg.

Не пересобирает kernel. Меняет только gzip-ramdisk (newc cpio) и поле
размера ramdisk в заголовке (offset 16). Хвост раздела после конца
«официального» образа не трогает, если передан --blob-at.
"""

from __future__ import annotations

import argparse
import gzip
import io
import os
import struct
import sys


def align(value: int, page: int) -> int:
    return (value + page - 1) // page * page


def parse_header(data: bytes) -> dict:
    if data[:8] != b"ANDROID!":
        raise SystemExit("нет magic ANDROID!")
    kernel_size = struct.unpack_from("<I", data, 8)[0]
    ramdisk_size = struct.unpack_from("<I", data, 16)[0]
    page_size = struct.unpack_from("<I", data, 36)[0]
    if page_size not in (2048, 4096):
        raise SystemExit(f"странный page_size={page_size}")
    kernel_off = page_size
    ramdisk_off = align(kernel_off + kernel_size, page_size)
    return {
        "kernel_size": kernel_size,
        "ramdisk_size": ramdisk_size,
        "page_size": page_size,
        "kernel_off": kernel_off,
        "ramdisk_off": ramdisk_off,
    }


def gunzip(data: bytes) -> bytes:
    return gzip.decompress(data)


def gzip_unix(data: bytes) -> bytes:
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=9, mtime=0) as gz:
        gz.write(data)
    out = bytearray(buf.getvalue())
    # OS = Unix (как у Яндекса)
    if len(out) > 9:
        out[9] = 3
    return bytes(out)


def cpio_replace(cpio: bytes, name: str, new_body: bytes) -> bytes:
    """Заменить содержимое файла name в newc cpio. Размер в заголовке обновляется."""
    marker = b"070701"
    i = 0
    out = bytearray()
    found = False
    while i < len(cpio):
        if cpio[i : i + 6] != marker:
            raise SystemExit(f"битый cpio около offset {i}")
        hdr = cpio[i : i + 110]
        namesize = int(hdr[94:102], 16)
        filesize = int(hdr[54:62], 16)
        name_start = i + 110
        name_end = name_start + namesize
        raw_name = cpio[name_start:name_end]
        path = raw_name.split(b"\0", 1)[0].decode("ascii", "replace")
        data_off = align(name_end, 4)
        data_end = data_off + filesize
        next_off = align(data_end, 4)

        if path == name:
            found = True
            new_filesize = len(new_body)
            new_hdr = bytearray(hdr)
            new_hdr[54:62] = f"{new_filesize:08x}".encode("ascii")
            out += new_hdr
            out += raw_name
            while len(out) % 4:
                out += b"\0"
            out += new_body
            while len(out) % 4:
                out += b"\0"
        else:
            out += cpio[i:next_off]

        if path == "TRAILER!!!":
            # дописать хвост как есть после TRAILER, если есть
            out += cpio[next_off:]
            break
        i = next_off
    if not found:
        raise SystemExit(f"в cpio нет файла {name}")
    return bytes(out)


def cpio_get(cpio: bytes, name: str) -> bytes:
    marker = b"070701"
    i = 0
    while i < len(cpio):
        hdr = cpio[i : i + 110]
        if hdr[:6] != marker:
            raise SystemExit(f"битый cpio около {i}")
        namesize = int(hdr[94:102], 16)
        filesize = int(hdr[54:62], 16)
        name_start = i + 110
        name_end = name_start + namesize
        path = cpio[name_start:name_end].split(b"\0", 1)[0].decode("ascii", "replace")
        data_off = align(name_end, 4)
        data_end = data_off + filesize
        next_off = align(data_end, 4)
        if path == name:
            return cpio[data_off:data_end]
        if path == "TRAILER!!!":
            break
        i = next_off
    raise SystemExit(f"в cpio нет файла {name}")


def patch_default_prop(text: str) -> str:
    lines = text.splitlines(keepends=True)
    out = []
    seen_debug = False
    seen_tcp = False
    for line in lines:
        if line.startswith("ro.debuggable="):
            out.append("ro.debuggable=1\n")
            seen_debug = True
            continue
        if line.startswith("service.adb.tcp.port="):
            out.append("service.adb.tcp.port=5555\n")
            seen_tcp = True
            continue
        if line.startswith("persist.sys.usb.config="):
            out.append("persist.sys.usb.config=adb\n")
            continue
        out.append(line if line.endswith("\n") else line + "\n")
    if not seen_debug:
        out.append("ro.debuggable=1\n")
    if not seen_tcp:
        # сразу после debuggable удобнее читать глазами
        tmp = []
        inserted = False
        for line in out:
            tmp.append(line)
            if (not inserted) and line.startswith("ro.debuggable="):
                tmp.append("service.adb.tcp.port=5555\n")
                inserted = True
        out = tmp if inserted else out + ["service.adb.tcp.port=5555\n"]
    return "".join(out)


def patch_init_rc(text: str) -> str:
    needle = "    seclabel u:r:adbd:s0\n"
    block = (
        "    seclabel u:r:adbd:s0\n"
        "\n"
        "service rootshell /system/bin/busybox-smp telnetd -l /system/bin/sh -p 2323 -F\n"
        "    class core\n"
    )
    if "service rootshell " in text:
        return text
    if needle not in text:
        # запасной якорь — конец файла сервиса adbd часто другой
        alt = "service adbd /sbin/adbd\n"
        if "busybox-smp telnetd" in text:
            return text
        raise SystemExit(
            "в init.rc не найден якорь 'seclabel u:r:adbd:s0'. "
            "Вставь блок rootshell вручную рядом с service adbd."
        )
    # вставить ПОСЛЕ первой строки seclabel у adbd
    return text.replace(needle, block, 1)


def splice(orig: bytes, new_ramdisk: bytes, blob_at: int | None) -> bytes:
    h = parse_header(orig)
    roff = h["ramdisk_off"]
    page = h["page_size"]
    end = align(roff + len(new_ramdisk), page)

    if blob_at is None:
        # если хвоста нет — просто пишем до конца файла
        blob_at = len(orig)

    if end > blob_at:
        raise SystemExit(
            f"новый ramdisk не влезает: end={end} > blob_at={blob_at} "
            f"(лимит {blob_at - roff} байт gzip)"
        )

    out = bytearray(orig)
    struct.pack_into("<I", out, 16, len(new_ramdisk))
    # меняется только uint32 размера ramdisk (байты 16..19)
    if out[:16] != orig[:16] or out[20:roff] != orig[20:roff]:
        raise SystemExit("внутренний контроль: повредили header/kernel")
    out[roff:end] = new_ramdisk + b"\0" * (end - roff - len(new_ramdisk))
    # дырку до хвоста занулить, хвост не трогать
    if end < blob_at:
        out[end:blob_at] = b"\0" * (blob_at - end)
    return bytes(out)


def find_blob_at(data: bytes, ramdisk_off: int, ramdisk_size: int, page: int) -> int:
    """Конец выровненного ramdisk — дальше часто мусор раздела."""
    return align(ramdisk_off + ramdisk_size, page)


def cmd_info(path: str) -> None:
    data = open(path, "rb").read()
    h = parse_header(data)
    blob = find_blob_at(data, h["ramdisk_off"], h["ramdisk_size"], h["page_size"])
    print(f"size          {len(data)}")
    print(f"page_size     {h['page_size']}")
    print(f"kernel_size   {h['kernel_size']}")
    print(f"ramdisk_size  {h['ramdisk_size']}")
    print(f"kernel_off    {h['kernel_off']}")
    print(f"ramdisk_off   {h['ramdisk_off']}")
    print(f"aligned_end   {blob}")
    if blob < len(data):
        print(f"tail_hex      {data[blob:blob+8].hex()}")
        print(f"tail_nonzero  {any(data[blob:])}")


def cmd_extract(path: str, outdir: str) -> None:
    data = open(path, "rb").read()
    h = parse_header(data)
    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, "kernel"), "wb").write(
        data[h["kernel_off"] : h["kernel_off"] + h["kernel_size"]]
    )
    gz = data[h["ramdisk_off"] : h["ramdisk_off"] + h["ramdisk_size"]]
    open(os.path.join(outdir, "ramdisk.img"), "wb").write(gz)
    cpio = gunzip(gz)
    open(os.path.join(outdir, "ramdisk.cpio"), "wb").write(cpio)
    for name in ("default.prop", "init.rc"):
        try:
            body = cpio_get(cpio, name)
        except SystemExit:
            continue
        open(os.path.join(outdir, name.replace("/", "_")), "wb").write(body)
    meta = find_blob_at(data, h["ramdisk_off"], h["ramdisk_size"], h["page_size"])
    open(os.path.join(outdir, "meta.txt"), "w").write(
        f"blob_at={meta}\npage_size={h['page_size']}\nramdisk_off={h['ramdisk_off']}\n"
    )
    print(f"ok -> {outdir}")


def cmd_patch(path: str, out: str, blob_at: int | None, no_telnet: bool) -> None:
    orig = open(path, "rb").read()
    h = parse_header(orig)
    if blob_at is None:
        blob_at = find_blob_at(orig, h["ramdisk_off"], h["ramdisk_size"], h["page_size"])
    gz = orig[h["ramdisk_off"] : h["ramdisk_off"] + h["ramdisk_size"]]
    cpio = gunzip(gz)

    prop = cpio_get(cpio, "default.prop").decode("utf-8", "replace")
    prop = patch_default_prop(prop)
    cpio = cpio_replace(cpio, "default.prop", prop.encode("utf-8"))

    if not no_telnet:
        init = cpio_get(cpio, "init.rc").decode("utf-8", "replace")
        init = patch_init_rc(init)
        cpio = cpio_replace(cpio, "init.rc", init.encode("utf-8"))

    new_gz = gzip_unix(cpio)
    image = splice(orig, new_gz, blob_at)
    open(out, "wb").write(image)
    print(f"wrote {out}")
    print(f"old_ramdisk {h['ramdisk_size']} -> new_ramdisk {len(new_gz)}")
    print(f"blob_at {blob_at} slack {blob_at - align(h['ramdisk_off'] + len(new_gz), h['page_size'])}")


def main() -> None:
    ap = argparse.ArgumentParser(description="Патч boot.img Яндекс.Станции (splice)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("info", help="показать заголовок")
    p.add_argument("boot")

    p = sub.add_parser("extract", help="достать kernel/ramdisk/prop")
    p.add_argument("boot")
    p.add_argument("-o", "--out", default="boot-extract")

    p = sub.add_parser("patch", help="собрать boot с ADB:5555 и telnet:2323")
    p.add_argument("boot")
    p.add_argument("-o", "--out", required=True)
    p.add_argument("--blob-at", type=int, default=None, help="offset хвоста раздела (не трогать)")
    p.add_argument("--no-telnet", action="store_true", help="только default.prop, без rootshell")

    args = ap.parse_args()
    if args.cmd == "info":
        cmd_info(args.boot)
    elif args.cmd == "extract":
        cmd_extract(args.boot, args.out)
    elif args.cmd == "patch":
        cmd_patch(args.boot, args.out, args.blob_at, args.no_telnet)


if __name__ == "__main__":
    main()
