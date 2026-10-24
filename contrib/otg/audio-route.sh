#!/bin/sh
# Route all speaker playback to a USB sound card (or back to the built-in amplifier).
# Every player on the Station (Alice TTS, music, sounds, AirPlay/Bluetooth) uses ALSA "default":
#   default -> softvol "Master" -> dmix_spk -> hw:0,0 (NTP8910A amp)
# Only the dmix_spk slave is swapped, so the Master volume (buttons, "Алиса, громче") keeps working.
#   audio-route.sh usb       to the first USB-Audio card
#   audio-route.sh speaker   back to the built-in speaker
#   audio-route.sh auto      usb if a USB card is present, else speaker (boot / mdev hotplug)
#   audio-route.sh status
# touch /data/otg/audio-no-usb  makes "auto" always choose the speaker.
D=/data/otg
CONF=/etc/asound.conf
ORIG=$D/asound.conf.orig

usb_card(){
	for c in /proc/asound/card[0-9]*; do
		[ -e "$c/usbid" ] && [ -e "$c/stream0" ] && grep -q "Playback:" "$c/stream0" && { cat "$c/id"; return 0; }
	done
	return 1
}

# First playback format/rate/channels of the card (USB Audio: /proc/asound/cardN/stream0).
usb_params(){
	awk '/^Playback:/{p=1} /^Capture:/{p=0}
	     p && /Format:/   && !f {f=$2}
	     p && /Channels:/ && !c {c=$2}
	     p && /Rates:/    && !r {r=$2; sub(",","",r)}
	     END{print f, c, r}' "/proc/asound/card$(grep -l "^$1\$" /proc/asound/card*/id | sed 's|.*/card\([0-9]*\)/id|\1|')/stream0"
}

current(){ grep -o 'pcm "hw:[^"]*"' $CONF | tail -1 | cut -d'"' -f2; }

write_conf(){  # $1 = dmix_spk block
	[ -f $ORIG ] || cp -p $CONF $ORIG
	tmp=/tmp/asound.conf.$$
	{ sed '/^pcm.dmix_spk {/,/^}/d' $ORIG; printf '%s\n' "$1"; } > $tmp
	cmp -s $tmp $CONF && { rm -f $tmp; return 0; }
	rw=0; awk '$2=="/"{print $4}' /proc/mounts | grep -q '^ro' && { mount -o remount,rw / && rw=1; }
	cp $tmp $CONF.new && mv $CONF.new $CONF
	# Running players (maind --mediad) only reload when the top-level alsa.conf changes:
	# alsa-lib does not track /etc/asound.conf, which alsa.conf pulls in through a hook.
	touch /usr/share/alsa/alsa.conf
	rm -f $tmp; sync
	[ $rw = 1 ] && mount -o remount,ro / 2>/dev/null
	return 0
}

to_speaker(){
	write_conf "$(sed -n '/^pcm.dmix_spk {/,/^}/p' $ORIG 2>/dev/null || sed -n '/^pcm.dmix_spk {/,/^}/p' $CONF)"
	echo "audio -> speaker (hw:0,0)"
}

to_usb(){
	id=$(usb_card) || { echo "no USB sound card"; return 1; }
	set -- $(usb_params "$id")
	fmt=${1:-S16_LE}; ch=${2:-2}; rate=${3:-48000}
	# ipc_key differs from the speaker dmix (1024), so a stream still open on the old route cannot clash.
	write_conf "pcm.dmix_spk {
  type dmix
  ipc_key 1025
  ipc_key_add_uid false
  ipc_perm 0666
  slave {
    pcm \"hw:CARD=$id,DEV=0\"
    format $fmt
    channels $ch
    rate $rate
    buffer_size 7680
    period_size 960
  }
}"
	echo "audio -> USB card $id ($fmt, ${ch}ch, ${rate} Hz)"
}

case "${1:-status}" in
	usb)     to_usb ;;
	speaker) to_speaker ;;
	auto)    [ "${ACTION:-}" = remove ] && sleep 1   # mdev: let the card leave /proc/asound first
	         if [ ! -e $D/audio-no-usb ] && usb_card >/dev/null; then to_usb; else to_speaker; fi ;;
	status)  echo "route: $(current)"; echo "usb card: $(usb_card || echo none)" ;;
	*)       echo "usage: $0 usb|speaker|auto|status"; exit 1 ;;
esac
