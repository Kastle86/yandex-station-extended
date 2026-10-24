#!/bin/sh
# fastfetch helper: N-th line (1-based) of the USB OTG disk summary, exit 1 if there is none
# (fastfetch hides failed "command" modules, so unused slots just disappear).
#   ff-usb.sh 1  ->  Burst Elite 240G · 223.6 GiB · USB 480 Mbit/s
#   ff-usb.sh 2  ->  ├ Ventoy  12.3 GiB / 100.0 GiB (12%) · exfat
n=${1:-1}
hum(){ awk -v k="$1" 'BEGIN{ if (k >= 1048576) printf "%.1f GiB", k/1048576; else printf "%.0f MiB", k/1024 }'; }

lines(){
	for b in /sys/block/sd*; do
		[ -e "$b" ] || continue
		d=${b##*/}
		model=$(sed 's/ *$//' $b/device/model 2>/dev/null)
		port=$(readlink -f $b | tr / '\n' | grep -E '^[0-9]+-[0-9.]+$' | tail -1)
		spd=$(cat /sys/bus/usb/devices/$port/speed 2>/dev/null)
		echo "${model:-$d} · $(hum $(( $(cat $b/size) / 2 ))) · USB ${spd:-?} Mbit/s"
		parts=$(grep "^/dev/$d[0-9]" /proc/mounts | awk '{print $1":"$2}')
		last=$(echo "$parts" | tail -1)
		for pm in $parts; do
			dev=${pm%%:*}; mnt=${pm#*:}
			case "$(dd if=$dev bs=1 skip=3 count=8 2>/dev/null)" in
				EXFAT*) fs=exfat ;; NTFS*) fs=ntfs ;; *) fs=$(awk -v m="$mnt" '$2==m{print $3}' /proc/mounts) ;;
			esac
			set -- $(df -k "$mnt" | awk 'NR==2{print $2, $3}')
			[ "$pm" = "$last" ] && t='└' || t='├'
			echo "$t ${mnt##*/}  $(hum $2) / $(hum $1) ($(( $1 ? $2 * 100 / $1 : 0 ))%) · $fs"
		done
	done
}

l=$(lines | sed -n "${n}p")
[ -n "$l" ] || exit 1
echo "$l"
