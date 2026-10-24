#!/bin/sh
# Mount every USB disk partition under /tmp/usb/<label|name>.
# exFAT and NTFS go through FUSE from Entware (yse install exfat-fuse ntfs-3g):
# the stock kernel has no exFAT/NTFS and in-kernel modules cannot be built safely for it.
# ext2/3/4 go through fuse2fs (static, /data/otg/bin/fuse2fs) — the only option with real
# owners, permissions, symlinks and FIFOs, so it can hold Entware.
#
# Entware on USB: if a mounted volume has entware/.yse-usb, that tree is bind-mounted over
# /data/opt/entware (= /opt) and its services (/opt/etc/init.d/S*) are started. Without the
# disk the built-in Entware on /data is used as before. Make one: docs/recipes/print-server.md.
#   usb-mount.sh          mount all
#   usb-mount.sh -u       unmount all
export PATH=/opt/bin:/opt/sbin:$PATH LD_LIBRARY_PATH=/opt/lib
BASE=/tmp/usb
ENT=/data/opt/entware
FUSE2FS=/data/otg/bin/fuse2fs
if [ "${1:-}" = "-u" ]; then
	if grep -q " $ENT fuse" /proc/mounts; then
		[ -x /opt/etc/init.d/rc.unslung ] && /opt/etc/init.d/rc.unslung stop
		umount $ENT && echo "umount $ENT (USB Entware)"
	fi
	for d in $BASE/*; do mountpoint -q "$d" && umount "$d" && rmdir "$d" && echo "umount $d"; done
	exit 0
fi
for dev in /dev/sd[a-z][0-9]*; do
	[ -b "$dev" ] || continue
	grep -q "^$dev " /proc/mounts && continue
	label=$(blkid "$dev" | sed -n "s/.*LABEL=\"\([^\"]*\)\".*/\1/p" | tr " /" "__")
	dir=$BASE/${label:-$(basename $dev)}
	magic=$(dd if=$dev bs=1 skip=3 count=8 2>/dev/null)
	ext=$(dd if=$dev bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' ')   # 0xEF53
	mkdir -p "$dir"
	case "$magic" in
	EXFAT*) mount.exfat-fuse "$dev" "$dir" ;;
	NTFS*)  ntfs-3g "$dev" "$dir" ;;
	*)      if [ "$ext" = 53ef ]; then $FUSE2FS -o allow_other "$dev" "$dir"
	        else mount -t vfat -o utf8 "$dev" "$dir" 2>/dev/null; fi ;;
	esac && echo "mount $dev -> $dir" || { rmdir "$dir"; echo "skip $dev (unknown fs)"; }
done

# Entware from USB: bind over the built-in one (once), then start its services
grep -q " $ENT fuse" /proc/mounts && exit 0
for f in $BASE/*/entware/.yse-usb; do
	[ -f "$f" ] || continue
	src=${f%/.yse-usb}
	mount -o bind "$src" $ENT && echo "Entware -> $src" || continue
	[ -x /data/otg/zram-swap.sh ] && /data/otg/zram-swap.sh
	[ -x /opt/etc/init.d/rc.unslung ] && /opt/etc/init.d/rc.unslung start
	break
done
