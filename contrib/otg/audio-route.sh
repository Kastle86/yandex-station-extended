#!/bin/sh
# Route all speaker playback to a USB sound card (or back to the built-in amplifier).
# Every player on the Station (Alice TTS, music, sounds, AirPlay/Bluetooth) uses ALSA "default":
#   default -> softvol "Master" -> dmix_spk -> hw:0,0 (NTP8910A amp)
# Only dmix_spk(_plug) is swapped, so the Master volume (buttons, "Алиса, громче") keeps working.
# Alice's volume scale is tuned for the built-in amp; a USB DAC drives headphones at full line
# level, so on USB the plug stage also applies a fixed attenuation (default -20 dB).
#   audio-route.sh usb        to the first USB-Audio card
#   audio-route.sh speaker    back to the built-in speaker
#   audio-route.sh auto       usb if a USB card is present, else speaker (boot / mdev hotplug)
#   audio-route.sh gain [dB]  show / set the USB attenuation, e.g. "gain -25" (0 = none)
#   audio-route.sh off        speaker now and stay there, even with a USB card plugged in
#   audio-route.sh on         undo "off": back to automatic switching (USB card if present)
#   audio-route.sh status
# install.sh links this script as /usr/bin/usb-audio, so "usb-audio off" works from any shell.
# "off" is the file /data/otg/audio-no-usb: it makes "auto" always choose the speaker and survives reboots.
D=/data/otg
CONF=/etc/asound.conf
ORIG=$D/asound.conf.orig
GAINF=$D/audio-usb-gain-db
NOUSB=$D/audio-no-usb

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

blocks(){ sed -n '/^pcm.dmix_spk_plug {/,/^}/p; /^pcm.dmix_spk {/,/^}/p' "$1"; }

write_conf(){  # $1 = dmix_spk_plug + dmix_spk blocks
	[ -f $ORIG ] || cp -p $CONF $ORIG
	tmp=/tmp/asound.conf.$$
	# softvol creates its control on the card of its slave unless told otherwise; with a USB slave
	# that would be a separate "Master" on the USB card, while Alice and the buttons drive card 0.
	{ sed '/^pcm.dmix_spk_plug {/,/^}/d; /^pcm.dmix_spk {/,/^}/d
	       /^pcm.soft_volume {/,/^}/{/name "Master Playback Volume"/a\    card 0
	       }' $ORIG; printf '%s\n' "$1"; } > $tmp
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
	[ -f $ORIG ] || cp -p $CONF $ORIG
	write_conf "$(blocks $ORIG)"
	echo "audio -> speaker (hw:0,0)"
}

to_usb(){
	id=$(usb_card) || { echo "no USB sound card"; return 1; }
	set -- $(usb_params "$id")
	fmt=${1:-S16_LE}; ch=${2:-2}; rate=${3:-48000}
	db=$(cat $GAINF 2>/dev/null || echo -20)
	# 10^(dB/20) without libm (busybox awk has no exp/log): whole dB, 1 dB = x1.12202
	g=$(awk -v d="$db" 'BEGIN{d=int(d<0?d-0.5:d+0.5); g=1; for(i=0;i<(d<0?-d:d);i++) g=(d<0)?g/1.122018454:g*1.122018454; printf "%.4f", g}')
	[ -n "$g" ] || { echo "cannot compute gain for '$db' dB, route unchanged"; return 1; }
	if [ "$ch" = 1 ]; then
		tt="  ttable.0.0 $(awk -v g=$g 'BEGIN{print g/2}')
  ttable.1.0 $(awk -v g=$g 'BEGIN{print g/2}')"
	else
		tt="  ttable.0.0 $g
  ttable.1.1 $g"
	fi
	# ipc_key differs from the speaker dmix (1024), so a stream still open on the old route cannot clash.
	write_conf "pcm.dmix_spk_plug {
  type plug
  slave.pcm \"dmix_spk\"
$tt
}
pcm.dmix_spk {
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
	echo "audio -> USB card $id ($fmt, ${ch}ch, ${rate} Hz, ${db} dB)"
}

case "${1:-status}" in
	usb)     to_usb ;;
	speaker) to_speaker ;;
	auto)    [ "${ACTION:-}" = remove ] && sleep 1   # mdev: let the card leave /proc/asound first
	         if [ ! -e $NOUSB ] && usb_card >/dev/null; then to_usb; else to_speaker; fi ;;
	off)     touch $NOUSB; to_speaker; echo "USB audio off (back on: usb-audio on)" ;;
	on)      rm -f $NOUSB; if usb_card >/dev/null; then to_usb; else to_speaker; fi ;;
	gain)    if [ -n "${2:-}" ]; then
	         	echo "$2" | grep -qE '^-?[0-9]+$' || { echo "gain: whole number of dB, e.g. -20"; exit 1; }
	         	echo "$2" > $GAINF
	         	case "$(current)" in hw:CARD=*) to_usb ;; esac
	         fi
	         echo "usb gain: $(cat $GAINF 2>/dev/null || echo -20) dB" ;;
	status)  echo "route: $(current)"; echo "usb card: $(usb_card || echo none)"
	         echo "usb audio: $([ -e $NOUSB ] && echo off || echo auto)"; echo "usb gain: $(cat $GAINF 2>/dev/null || echo -20) dB" ;;
	*)       echo "usage: $0 on|off|usb|speaker|auto|gain [dB]|status"; exit 1 ;;
esac
