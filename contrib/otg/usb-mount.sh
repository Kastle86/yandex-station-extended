#!/bin/sh
# Mount every USB disk partition under /tmp/usb/<label|name>.
# exFAT and NTFS go through FUSE from Entware (yse install exfat-fuse ntfs-3g):
# the stock kernel has no exFAT/NTFS and in-kernel modules cannot be built safely for it.
#   usb-mount.sh          mount all
#   usb-mount.sh -u       unmount all
export PATH=/opt/bin:/opt/sbin:$PATH LD_LIBRARY_PATH=/opt/lib
BASE=/tmp/usb
if [ "${1:-}" = "-u" ]; then
	for d in $BASE/*; do mountpoint -q "$d" && umount "$d" && rmdir "$d" && echo "umount $d"; done
	exit 0
fi
for dev in /dev/sd[a-z][0-9]*; do
	[ -b "$dev" ] || continue
	grep -q "^$dev " /proc/mounts && continue
	label=$(blkid "$dev" | sed -n "s/.*LABEL=\"\([^\"]*\)\".*/\1/p" | tr " /" "__")
	dir=$BASE/${label:-$(basename $dev)}
	magic=$(dd if=$dev bs=1 skip=3 count=8 2>/dev/null)
	mkdir -p "$dir"
	case "$magic" in
	EXFAT*) mount.exfat-fuse "$dev" "$dir" ;;
	NTFS*)  ntfs-3g "$dev" "$dir" ;;
	*)      mount -t vfat -o utf8 "$dev" "$dir" 2>/dev/null ;;
	esac && echo "mount $dev -> $dir" || { rmdir "$dir"; echo "skip $dev (unknown fs)"; }
done
