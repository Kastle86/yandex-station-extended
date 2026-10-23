#!/bin/sh
# ring.sh - RGB ring control for Yandex Station Lite (yandexmicro)
# nodes: /sys/class/leds/micro:{red,green,blue}:ring{1,2,3}  brightness 0-255
LEDS=/sys/class/leds
SEGS="1 2 3"
COLS="red green blue"

raw(){ echo "$3" > "$LEDS/micro:$1:ring$2/brightness" 2>/dev/null; }
grab(){ for c in $COLS; do for n in $SEGS; do echo none > "$LEDS/micro:$c:ring$n/trigger" 2>/dev/null; done; done; }
off(){ for c in $COLS; do for n in $SEGS; do raw "$c" "$n" 0; done; done; }
release(){ off; for c in $COLS; do for n in $SEGS; do echo led_ring_fb > "$LEDS/micro:$c:ring$n/trigger" 2>/dev/null; done; done; }
seg(){ raw red "$1" "$2"; raw green "$1" "$3"; raw blue "$1" "$4"; }
fill(){ for n in $SEGS; do seg "$n" "$1" "$2" "$3"; done; }

cmd="$1"; [ $# -ge 1 ] && shift
case "$cmd" in
  grab)    grab ;;
  release) release ;;
  off)     off ;;
  fill)    grab; fill "${1:-0}" "${2:-0}" "${3:-0}" ;;
  seg)     grab; seg "${1:-1}" "${2:-0}" "${3:-0}" "${4:-0}" ;;
  rainbow)
    grab; cnt="${1:-10}"; i=0
    while [ "$i" -lt "$cnt" ]; do
      fill 255 0   0;   sleep 0.15
      fill 255 160 0;   sleep 0.15
      fill 0   255 0;   sleep 0.15
      fill 0   180 255; sleep 0.15
      fill 80  0   255; sleep 0.15
      i=$((i+1))
    done; off ;;
  chase)
    grab; cnt="${1:-20}"; i=0
    while [ "$i" -lt "$cnt" ]; do
      for n in $SEGS; do off; seg "$n" 0 180 255; sleep 0.12; done
      i=$((i+1))
    done; off ;;
  blink)
    grab; r="${1:-255}"; g="${2:-0}"; b="${3:-0}"; ms="${4:-250}"; cnt="${5:-10}"
    d=$(awk "BEGIN{print $ms/1000}"); i=0
    while [ "$i" -lt "$cnt" ]; do fill "$r" "$g" "$b"; sleep "$d"; off; sleep "$d"; i=$((i+1)); done ;;
  breathe)
    grab; r="${1:-0}"; g="${2:-180}"; b="${3:-255}"; cnt="${4:-5}"; i=0
    while [ "$i" -lt "$cnt" ]; do
      v=0;   while [ "$v" -le 255 ]; do fill $((r*v/255)) $((g*v/255)) $((b*v/255)); sleep 0.02; v=$((v+17)); done
      v=255; while [ "$v" -ge 0   ]; do fill $((r*v/255)) $((g*v/255)) $((b*v/255)); sleep 0.02; v=$((v-17)); done
      i=$((i+1))
    done; off ;;
  hwblink)
    if [ "$1" = "off" ]; then grab; off; else
      ms="${1:-200}"
      for c in $COLS; do for n in $SEGS; do
        echo timer > "$LEDS/micro:$c:ring$n/trigger"
        echo "$ms" > "$LEDS/micro:$c:ring$n/delay_on"
        echo "$ms" > "$LEDS/micro:$c:ring$n/delay_off"
      done; done
    fi ;;
  *)
    echo "ring.sh - RGB ring control (yandexmicro)"
    echo "  ring.sh fill R G B         whole ring to color (0-255)"
    echo "  ring.sh seg N R G B        one segment (N=1..3)"
    echo "  ring.sh off                all off"
    echo "  ring.sh rainbow [cycles]   color cycle"
    echo "  ring.sh chase [cycles]     running dot"
    echo "  ring.sh breathe R G B [c]  smooth fade in/out"
    echo "  ring.sh blink R G B [ms] [count]"
    echo "  ring.sh hwblink <ms> | hwblink off   kernel timer blink"
    echo "  ring.sh grab | release     take / give back ring from firmware"
    ;;
esac
