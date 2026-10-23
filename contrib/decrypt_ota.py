#!/usr/bin/env python3
import argparse
import gzip
import hashlib
import io
import lz4.block
import os
import struct
import sys
import zipfile
import zlib
from datetime import datetime, timedelta
from math import gcd

from Crypto.Cipher import AES

RSA_KEYS = {
    'mini2': int(
        '8021a52c47fa3d2afb8c8a397b737c2ea7d1975ef71fa357c4cc686d6ae529a1'
        'cbd87ace3d575527f83af377ae56acc792cd9652dd97cedf1eab3331f142ae95'
        'eeff08a41043375f9783a8fda1f582ce07ded1f81f58d8cbbadbc0046d236fc'
        '8a394550fabb224ae824dc774a14e947a42689a648ec27f69ddf9cc6c83b6358b', 16),
    'station2': int(
        '99a5d94c611ef6c1877163afec0976d25de437d69b617edc20507c12f0fb505e'
        '6507fa25b6515dd7594a699bc072c4018c70584e6fbc88198bef19fb06f9f2ba'
        '3611b74758cc8e75b39b12708de7fe24db06ba5d9eb66183cec610519251cbc1'
        '9f7cd65166053ce815121911c4ee52aea12a68c2af4106a67964a6f9d5aeb977', 16),
    'lite': int(
        '9dc2abe3fef6adf3904be0897a7ba903f14aa822f1acf9dacfe9e9f6298b219'
        'dd41dbcc6d111a74c969d0a1ac5d7617461e6426695b0bfc43ccc4b040c43e03'
        'bfdcb261d9e0f15a5c3c39a7729faa19e0ea1e5dcd9f59236419d339beec0ff'
        '9e59a2ed08f3fc9faa5e82b183f943631212fe5f5144b48d961c89009ccd3a97db', 16),
}
UUIDS = {
    '9766fd3d89bee849ae5d78a140608213': 'bl30_scp',
    '47d4086d4cfe98469b952950cbbd5a00': 'bl31_monitor',
    '05d0e18953dc13478d2b500a4b7a3e38': 'bl32_arm32',
    'd6d0eea7fcead54b97829934f234b6e4': 'bl33_uboot_lz4',
}


def ok(msg):
    print(f'[+] {msg}')


def warn(msg):
    print(f'[!] {msg}')


def info(msg):
    print(f'    {msg}')


def parse_cpio_newc(data):
    out = {}
    pos = 0
    while pos + 110 <= len(data):
        if data[pos:pos + 6] not in (b'070701', b'070702'):
            break
        fields = [int(data[pos + 6 + 8 * i:pos + 14 + 8 * i], 16) for i in range(13)]
        filesize, namesize = fields[6], fields[11]
        npos = pos + 110
        name = data[npos:npos + namesize - 1].decode('utf-8', 'replace')
        dpos = (npos + namesize + 3) & ~3
        if name == 'TRAILER!!!':
            break
        out[name] = data[dpos:dpos + filesize]
        pos = (dpos + filesize + 3) & ~3
    return out


def load_package(path):
    if os.path.isdir(path):
        ok(f'using directory {path}')
        return {f: open(os.path.join(path, f), 'rb').read()
                for f in os.listdir(path) if os.path.isfile(os.path.join(path, f))}
    raw = open(path, 'rb').read()
    try:
        zf = zipfile.ZipFile(io.BytesIO(raw))
    except zipfile.BadZipFile:
        zf = None
    if zf is not None:
        files = {}
        for zn in zf.namelist():
            blob = zf.read(zn)
            if blob[:6] in (b'070701', b'070702'):
                ok(f'parsing cpio member {zn}')
                files.update(parse_cpio_newc(blob))
            else:
                files[os.path.basename(zn)] = blob
        return files
    if raw[:6] in (b'070701', b'070702'):
        ok(f'parsing cpio archive {path}')
        return parse_cpio_newc(raw)
    if raw[:5] == b'\xfd7zXZ':
        import lzma
        warn('xz container, inflating')
        inner = lzma.decompress(raw)
        return load_package_bytes(inner, path)
    warn(f'unknown container, treating as single image')
    return {os.path.basename(path): raw}


def load_package_bytes(raw, path):
    if raw[:6] in (b'070701', b'070702'):
        ok(f'parsing cpio archive {path}')
        return parse_cpio_newc(raw)
    try:
        zf = zipfile.ZipFile(io.BytesIO(raw))
    except zipfile.BadZipFile:
        zf = None
    if zf is not None:
        files = {}
        for zn in zf.namelist():
            blob = zf.read(zn)
            if blob[:6] in (b'070701', b'070702'):
                files.update(parse_cpio_newc(blob))
            else:
                files[os.path.basename(zn)] = blob
        return files
    if raw[:257] == b'\x00' * 257 or raw[257:262] == b'ustar':
        ok(f'parsing tar archive {path}')
        import tarfile
        files = {}
        with tarfile.open(fileobj=io.BytesIO(raw)) as tf:
            for m in tf.getmembers():
                if m.isfile() and m.name.endswith(('.swu', '.zip')):
                    files.update(load_package_bytes(tf.extractfile(m).read(), m.name))
                elif m.isfile():
                    files[os.path.basename(m.name)] = tf.extractfile(m).read()
        return files
    return {os.path.basename(path): raw}


def rsa_header(n, e, data, off):
    nb = 128
    out = b''
    for ci in range(0, 0x200, nb):
        c = int.from_bytes(data[off + ci:off + ci + nb], 'big')
        out += pow(c, e, n).to_bytes(nb, 'big')
    return out


def amlsecu_region(n, e, data, rs):
    hdr = rsa_header(n, e, data, rs)
    if hdr[0x0c:0x10] != b'AMLC' or hdr[0xfc:0x100] != b'AMLC':
        raise ValueError('no AMLC magic')
    dsz = struct.unpack_from('<I', hdr, 0x18)[0]
    km = hdr[0x40:0x88]
    stream = data[rs + dsz:rs + dsz + 0x200] + data[rs + 0x200:rs + dsz]
    if hashlib.sha256(stream).digest() != hdr[0x20:0x40]:
        raise ValueError('stream hash mismatch')
    return AES.new(km[:32], AES.MODE_CBC, km[32:48]).decrypt(stream), dsz


def inflate(pt):
    if pt[:2] == b'\x1f\x8b':
        out = b''
        while pt[:2] == b'\x1f\x8b':
            d = zlib.decompressobj(16 + zlib.MAX_WBITS)
            out += d.decompress(pt)
            pt = d.unused_data
            if not d.eof:
                break
        return out
    if pt[:6] == b'\xfd7zXZ\x00':
        import lzma
        return lzma.LZMADecompressor(format=lzma.FORMAT_XZ).decompress(pt)
    return pt


def split_multidtb(c):
    if c[:4] != b'AML_':
        return []
    cnt = struct.unpack_from('<I', c, 8)[0]
    dts = []
    for i in range(cnt):
        base = 0xc + i * 0x38
        idstr = c[base:base + 48].decode('ascii', 'replace').split()
        tail = idstr[-1] if idstr else str(i)
        off = struct.unpack_from('<I', c, base + 48)[0]
        tsz = struct.unpack_from('>I', c, off + 4)[0]
        dts.append((tail, c[off:off + tsz]))
    return dts


def extract_ikconfig(kernel):
    i = kernel.find(b'IKCFG_ST')
    if i < 0:
        return None
    end = kernel.find(b'IKCFG_ED', i)
    try:
        return gzip.decompress(kernel[i + 8:end])
    except Exception:
        return None


def fip_components(fip):
    comps = []
    pos = 0x20
    while pos + 0x28 <= len(fip):
        ent = fip[pos:pos + 0x28]
        if ent == b'\x00' * 0x28:
            break
        uuid = ent[:16].hex()
        off, sz, _ = struct.unpack_from('<QQQ', ent, 16)
        name = UUIDS.get(uuid)
        if name and sz:
            comps.append((name, off, sz))
        pos += 0x28
    return comps


def is_boot_image(b):
    return b[:8] == b'ANDROID!' and b[0x400:0x408] == b'AMLSECU!'


def block1_candidates(d):
    desc = d[0x410:0x420].decode('ascii', 'ignore')
    if not desc[:14].isdigit():
        return []
    base = datetime.strptime(desc[:14], '%Y%m%d%H%M%S')
    c = int.from_bytes(d[0x880:0x900], 'big')
    out = []
    for k in range(0, 16):
        ts = (base - timedelta(seconds=k)).strftime('%Y/%m/%d %H:%M:%S')
        m = (b'\x00' * 8 + b'AES-CBC' + ts.encode()
             + b'\x00' * 88 + b'\x00\x02' + b'AMLC')
        out.append((c, int.from_bytes(m, 'big')))
    return out


def verify_key(n, boot_images):
    for d in boot_images:
        try:
            amlsecu_region(n, 3, d, 0x800)
            return True
        except Exception:
            continue
    return False


def derive_rsa_key(boot_images):
    cands = [block1_candidates(d) for d in boot_images]
    cands = [c for c in cands if c]
    if len(cands) < 2:
        return None
    for i in range(len(cands)):
        for j in range(i + 1, len(cands)):
            ci_set = {c for c, _ in cands[i]}
            cj_set = {c for c, _ in cands[j]}
            if ci_set & cj_set:
                continue
            for c1, m1 in cands[i]:
                a = c1 ** 3 - m1
                for c2, m2 in cands[j]:
                    g = gcd(a, c2 ** 3 - m2)
                    if g.bit_length() < 1000:
                        continue
                    for cand in (g, g // 3, g // 5, g // 15):
                        if cand.bit_length() == 1024 and verify_key(cand, boot_images):
                            return cand
    return None


def decrypt_boot(n, data, out, subdir=None):
    nreg = struct.unpack_from('<I', data, 0x40c)[0]
    page = struct.unpack_from('<I', data, 0x24)[0] or 0x800
    outdir = os.path.join(out, 'mtd2_boot', subdir) if subdir else os.path.join(out, 'mtd2_boot')
    os.makedirs(outdir, exist_ok=True)
    ts = data[0x410:0x41e].decode('ascii', 'replace')
    rs = page
    for i in range(nreg):
        pt, dsz = amlsecu_region(n, 3, data, rs)
        inner = inflate(pt)
        fn = 'kernel.bin' if (i == 0 and inner[0x38:0x3c] == b'ARMd') else f'region{i}'
        open(os.path.join(outdir, fn), 'wb').write(inner)
        info(f'region{i} @0x{rs:x}: {dsz} -> {len(inner)} bytes md5={hashlib.md5(inner).hexdigest()}')
        if i == 0:
            cfg = extract_ikconfig(inner)
            if cfg:
                open(os.path.join(outdir, 'kernel_config'), 'wb').write(cfg)
                info(f'kernel_config {len(cfg.splitlines())} lines')
        rs = (rs + dsz + 0x200 + page - 1) & ~(page - 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('packages', nargs='+')
    ap.add_argument('--out', default=None)
    ap.add_argument('--bootchain-key', default=None, metavar='HEX',
                    help='AES-256 bootchain key (bl2/tpl), 64 hex chars')
    args = ap.parse_args()

    name = os.path.splitext(os.path.basename(args.packages[0]))[0]
    out = args.out or f'{name}-decrypted'
    for d in ('mtd0_bootloader', 'mtd1_tpl/fip', 'mtd2_boot', 'dtb', 'rootfs'):
        os.makedirs(os.path.join(out, d), exist_ok=True)

    files = {}
    for pkg in args.packages:
        ok(f'decrypting ota: {pkg}')
        for fn, blob in load_package(pkg).items():
            if fn in files and files[fn] != blob:
                k = 1
                while f'{fn}~{k}' in files:
                    k += 1
                fn = f'{fn}~{k}'
            files[fn] = blob
    ok(f'package contents: {", ".join(sorted(files))}')

    for fn in ('sw-description', 'sw-description.sig', 'flash-nand-copies.sh'):
        if fn in files:
            open(os.path.join(out, fn), 'wb').write(files[fn])
    ok('metadata copied')

    bootchain_key = bytes.fromhex(args.bootchain_key) if args.bootchain_key else None
    for fn in sorted(files):
        if 'bl2' in fn and bootchain_key:
            enc = files[fn]
            bl2 = AES.new(bootchain_key, AES.MODE_CBC, b'\x00' * 16).decrypt(enc)
            if bl2[0x10:0x14] != b'@AML':
                warn('bl2 @AML missing, bootchain key not valid for this device')
            else:
                ok('decrypting mtd0 bootloader (bl2)...')
                open(os.path.join(out, 'mtd0_bootloader/bl2.encrypt'), 'wb').write(enc)
                open(os.path.join(out, 'mtd0_bootloader/bl2.bin'), 'wb').write(bl2)
                info(f'bl2.bin {len(bl2)} bytes md5={hashlib.md5(bl2).hexdigest()}')
        elif ('tpl' in fn) and bootchain_key:
            enc = files[fn]
            tpl = AES.new(bootchain_key, AES.MODE_CBC, b'\x00' * 16).decrypt(enc)
            if struct.unpack_from('<I', tpl, 0x10)[0] != 0xAA640001:
                warn('FIP magic missing, bootchain key not valid for this device')
            else:
                ok('decrypting mtd1 tpl (FIP)...')
                open(os.path.join(out, 'mtd1_tpl/tpl.encrypt'), 'wb').write(enc)
                open(os.path.join(out, 'mtd1_tpl/tpl_fip.bin'), 'wb').write(tpl)
                info(f'tpl_fip.bin {len(tpl)} bytes FIP magic ok')
                for cname, off, sz in fip_components(tpl):
                    comp = tpl[off:off + sz]
                    if comp[0x10:0x14] != b'@AML':
                        warn(f'{cname}: no @AML header')
                        continue
                    psz = struct.unpack_from('<Q', comp, 0x20)[0]
                    payload = comp[0x290:0x290 + psz]
                    open(os.path.join(out, 'mtd1_tpl/fip', f'{cname}.bin'), 'wb').write(payload)
                    info(f'{cname}.bin {len(payload)} bytes md5={hashlib.md5(payload).hexdigest()}')
                    if cname == 'bl33_uboot_lz4' and payload[:4] == b'LZ4C':
                        ub = lz4.block.decompress(
                            payload[0x80:0x80 + struct.unpack_from('<I', payload, 12)[0]],
                            uncompressed_size=struct.unpack_from('<I', payload, 8)[0])
                        open(os.path.join(out, 'mtd1_tpl/fip/uboot_bl33.bin'), 'wb').write(ub)
                        ver = ub[ub.find(b'U-Boot'):].split(b'\x00')[0].decode('ascii', 'replace')
                        info(f'uboot_bl33.bin {len(ub)} bytes — {ver}')

    if any('bl2' in fn or 'tpl' in fn for fn in files) and not bootchain_key:
        warn('bl2/tpl found, but no --bootchain-key given: skipping bootloader decryption')

    boot_images = [b for b in files.values() if is_boot_image(b)]
    dt_names = [fn for fn in files if 'dt' in fn.lower() and not is_boot_image(files[fn])]
    if not boot_images and not dt_names:
        sys.exit('[!] no AMLSECU images found')

    key = None
    family = None
    if boot_images:
        for name, k in RSA_KEYS.items():
            if verify_key(k, boot_images):
                key, family = k, name
                break
        if key is not None:
            ok(f'RSA key: {family} (embedded)')
        else:
            warn('no embedded RSA key matches, deriving key from images...')
            key = derive_rsa_key(boot_images)
            if key is None:
                sys.exit('[!] key derivation failed: need >=2 different-build images of this device family')
            family = 'derived'
            ok(f'RSA key derived from images: n={format(key, "x")[:32]}..')
    elif dt_names:
        for name, k in RSA_KEYS.items():
            try:
                amlsecu_region(k, 3, files[dt_names[0]], 0x20)
                key, family = k, name
                break
            except Exception:
                continue
        if key is None:
            sys.exit('[!] no boot image to derive RSA key from and no embedded key matches')
        ok(f'RSA key: {family} (embedded)')

    if boot_images:
        ok('decrypting boot image (AMLSECU)...')
        for i, b in enumerate(boot_images):
            decrypt_boot(key, b, out, subdir=None if i == 0 else b[0x410:0x41e].decode('ascii', 'replace'))
        ok('boot image done')

    for fn in dt_names:
        ok(f'decrypting {fn} (AMLSECU)...')
        data = files[fn]
        pt, dsz = amlsecu_region(key, 3, data, 0x20)
        inner = inflate(pt)
        base = fn.replace('.img.encrypt', '')
        tag = '' if base == 'dt' else f'_{base}'
        open(os.path.join(out, f'dtb/dt{tag}_multidtb.img'), 'wb').write(inner)
        info(f'dt{tag}_multidtb.img {len(inner)} bytes md5={hashlib.md5(inner).hexdigest()}')
        for tail, dtb in split_multidtb(inner):
            open(os.path.join(out, f'dtb/dtb{tag}_{tail}.dtb'), 'wb').write(dtb)
        ok(f'{base} done ({len(split_multidtb(inner))} variants)')

    if 'rootfs.ubifs' in files:
        ok('saving rootfs.ubifs (plaintext, as shipped)...')
        open(os.path.join(out, 'rootfs/rootfs.ubifs'), 'wb').write(files['rootfs.ubifs'])
        info(f'rootfs.ubifs {len(files["rootfs.ubifs"])} bytes md5={hashlib.md5(files["rootfs.ubifs"]).hexdigest()}')

    ok(f'done -> {out}')


if __name__ == '__main__':
    main()
