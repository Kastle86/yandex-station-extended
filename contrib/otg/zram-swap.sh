#!/bin/sh
# Compressed swap in RAM (zram is built into the stock kernel). Gives Ghostscript and other
# memory-hungry jobs headroom on a 256 MB box; low swappiness keeps Alice's processes in RAM
# until memory is really short. Started by usb-mount.sh together with the USB Entware.
#   zram-swap.sh [size]     default 128M (real RAM use is ~1/3 of that, lzo compression)
#   zram-swap.sh off
Z=/sys/block/zram0
[ -d $Z ] || { echo "no zram in this kernel"; exit 0; }
if [ "${1:-}" = off ]; then
	swapoff /dev/zram0 2>/dev/null; echo 1 > $Z/reset; echo "zram swap off"; exit 0
fi
grep -q '^/dev/zram0 ' /proc/swaps && exit 0
grep -q '^/dev/zram0 ' /proc/mounts && { echo "zram0 is in use, skipping"; exit 0; }
echo 1 > $Z/reset 2>/dev/null
echo lzo > $Z/comp_algorithm 2>/dev/null
echo "${1:-128M}" > $Z/disksize && mkswap /dev/zram0 >/dev/null && swapon /dev/zram0 || exit 1
echo 10 > /proc/sys/vm/swappiness
echo "zram swap ${1:-128M}"
