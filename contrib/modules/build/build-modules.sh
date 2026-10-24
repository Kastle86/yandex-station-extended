#!/bin/sh
# Воспроизводимая сборка модулей USB Host для Станции Лайт (ядро Яндекса 4.9.68, vermagic 4.9.y).
#
# Требования (Ubuntu/Debian): gcc-aarch64-linux-gnu bc flex bison libssl-dev make git curl xz-utils
#   ./build-modules.sh <config-station>      # config-station = zcat /proc/config.gz с колонки
# Результат: ./out/*.ko
#
# Почему так сложно: исходников ядра Яндекса нет. Ближайшая база — Amlogic buildroot-aml-4.9
# (4.9.40) + stable-разница 4.9.40→4.9.68 для заголовков и нужных драйверов + yandex-axg.patch
# (раскладка struct page под AMLOGIC_PAGE_TRACE, WIRELESS_EXT в net_device, vermagic 4.9.y).
# struct task_struct у Яндекса всё равно отличается, поэтому собираются только драйверы,
# которые не лезут в current->… (проверено дизассемблером). ext4/jbd2/exfat — НЕ собирать.
set -e
CFG=$(readlink -f "${1:?usage: $0 <config-station>}")
HERE=$(cd "$(dirname "$0")" && pwd)
W=${WORK:-$HERE/work}
mkdir -p "$W" "$HERE/out"
cd "$W"

[ -d aml-4.9 ] || git clone --depth 1 -b buildroot-aml-4.9 https://github.com/khadas/linux aml-4.9
git -C aml-4.9 checkout -q 656a3fa29d2b03eefe6e61278ed694344f76a18a 2>/dev/null || true
for v in 4.9.40 4.9.68; do
	[ -d linux-$v ] || curl -fsSL https://cdn.kernel.org/pub/linux/kernel/v4.x/linux-$v.tar.xz | tar -xJ
done

if [ ! -f aml-4.9/.yandex-patched ]; then
	P="include arch/arm64/include drivers/usb/storage drivers/net/usb drivers/net/mii.c sound/usb sound/core
	   drivers/scsi/sd.c drivers/scsi/sd.h drivers/scsi/sd_dif.c drivers/usb/core"
	for p in $P; do diff -urN linux-4.9.40/$p linux-4.9.68/$p || true; done \
		| sed 's|^--- linux-4.9.40/|--- a/|; s|^+++ linux-4.9.68/|+++ b/|' > stable-40-68.diff
	(cd aml-4.9 && patch -p1 -N -s < ../stable-40-68.diff && patch -p1 -N < "$HERE/yandex-axg.patch")
	: > aml-4.9/.scmversion
	touch aml-4.9/.yandex-patched
fi

cd aml-4.9
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
cp "$CFG" .config && cat "$HERE/config.fragment" >> .config
make olddefconfig >/dev/null
make -j"$(nproc)" HOSTCFLAGS=-fcommon modules_prepare >/dev/null
grep -q '"4.9.y"' include/generated/utsrelease.h || { echo "vermagic не 4.9.y"; exit 1; }

K="-Wno-error -fno-stack-protector -Wno-address-of-packed-member -Wno-array-bounds -Wno-stringop-overflow -Wno-format-truncation"
for d in drivers/scsi drivers/net drivers/usb/storage drivers/usb/class sound/core sound/usb; do
	make -j"$(nproc)" HOSTCFLAGS=-fcommon KCFLAGS="$K" M=$d modules >/dev/null
done
for m in drivers/scsi/sd_mod drivers/usb/storage/usb-storage drivers/usb/storage/uas \
         drivers/net/mii drivers/net/usb/usbnet drivers/net/usb/cdc_ether drivers/net/usb/cdc_ncm \
         drivers/net/usb/r8152 drivers/net/usb/ax88179_178a drivers/net/usb/asix drivers/usb/class/usblp \
         sound/core/snd-hwdep sound/core/snd-rawmidi sound/usb/snd-usbmidi-lib sound/usb/snd-usb-audio; do
	aarch64-linux-gnu-strip --strip-debug -o "$HERE/out/$(basename $m).ko" $m.ko
done
ls -la "$HERE/out"
