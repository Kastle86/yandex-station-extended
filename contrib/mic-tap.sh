#!/usr/bin/env bash
#
# One-file mic tap for the Yandex Mini. Decodes a prebuilt LD_PRELOAD shim
# (embedded below, built once on a Linux host - don't try to rebuild it on
# the fly, cross-compiling 32-bit ARM glibc from a Darwin host is currently
# broken in nixpkgs), pushes it, patches it into platformd's env in
# launch.json, restarts the quasar stack so platformd picks it up, then
# sits there while the tap's live on port 17771 (no auth on it, so don't
# leave this running longer than you need).
#
# Ctrl-C (or just letting it exit any other way, or a hard 10-minute
# timeout if the signal gets lost somehow) puts launch.json back and
# restarts the stack clean again. Nothing persists after that.
#
# If a session ever gets SIGKILL'd outright (flaky terminal, laptop
# losing network mid-restart) the trap above can't run - nothing can trap
# that. Recover with:
#   ./mic-tap.sh clean
# which forces the revert unconditionally, independent of any session
# state. Safe to run any time, including when nothing's wrong.
#
# Needs: adb reachable at $DEVICE, jq. No compiler, no nix, nothing else -
# the shim binary is baked in below.
#
# The mic hardware (quasar.cfg's "dmicarray" device) is an 8-slot TDM
# frame: 4 real mic channels + 4 fixed/unused slots (0x7fff, then 0,0).
# An earlier build assumed 4 channels and got a comb-filter/ringing
# artifact from landing on the fixed slots every other sample. This one
# extracts channel 0 of 8 correctly -- verified against a raw hex dump
# and confirmed as real bipolar, zero-centered audio (not a known-good
# listening test from a human yet, so if it's still off, try channels
# 1-3 before anything else).

set -uo pipefail

if [ -n "${ADB:-}" ]; then
  :
elif command -v adb >/dev/null 2>&1; then
  ADB="$(command -v adb)"
else
  echo "adb not found on PATH. Install it (nix: nix shell nixpkgs#android-tools, or brew install android-platform-tools) or set \$ADB." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found on PATH. Install it (brew install jq / nix shell nixpkgs#jq)." >&2
  exit 1
fi

DEVICE="${MINI_ADB_TARGET:-192.168.3.96:5555}"
PORT=17771
LJ=/system/vendor/quasar/launch.json
MAX_SESSION_SECONDS="${MAX_SESSION_SECONDS:-600}"

WORK="$(mktemp -d /tmp/mic-tap.XXXXXX)"
cleanup_local() { rm -rf "$WORK"; }

adbsh() { "$ADB" -s "$DEVICE" shell "$@"; }

# launch.json may or may not already be immutable (chattr +i) depending on
# whatever else has been done to this device (e.g. separate OTA-blocking
# setups do this independently of anything here). Detect that ONCE before
# touching it at all, so we leave it exactly as found either way - never
# adding immutability that wasn't already there, never stripping it if it
# was.
WAS_IMMUTABLE=0
if adbsh "lsattr $LJ 2>/dev/null" | awk '{print $1}' | grep -q i; then
  WAS_IMMUTABLE=1
fi
restore_immutable() {
  [ "$WAS_IMMUTABLE" = 1 ] && adbsh "chattr +i $LJ"
}

# ---- 0. the shim, prebuilt ---------------------------------------------
#
# ARM32 (armv7l), hooks snd_pcm_readi, calls through to the real one so
# capture behaves normally, then best-effort/non-blocking forwards a copy
# to any TCP client on $PORT. Symbol versions pinned to GLIBC_2.4 (checked
# against the device's actual libc/libdl, which is glibc 2.23) so it loads
# cleanly on platformd despite being built with a much newer toolchain.
# Source is in the project notes if this ever needs rebuilding - do that
# on a Linux host, then re-embed with: base64 < miccap.so

MICCAP_SO_B64='
f0VMRgEBAQAAAAAAAAAAAAMAKAABAAAAAAAAADQAAABQGgAAAAQABTQAIAAFACgAGgAZAAEAAAAA
AAAAAAAAAAAAAABkDAAAZAwAAAUAAAAAEAAAAQAAAPwOAAD8HgAA/B4AAGgBAABwIQAABgAAAAAQ
AAACAAAACA8AAAgfAAAIHwAA+AAAAPgAAAAGAAAABAAAAFHldGQAAAAAAAAAAAAAAAAAAAAAAAAA
AAYAAAAQAAAAUuV0ZPwOAAD8HgAA/B4AAAQBAAAEAQAABAAAAAEAAAARAAAAFQAAAAwAAAAUAAAA
EQAAABMAAAAAAAAAAAAAAAAAAAAPAAAABgAAAAAAAAAOAAAAAAAAAAQAAAAFAAAADQAAAAoAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAAAAAAAAAAAAAAAAAAAsA
AAAJAAAAAAAAAAAAAAAHAAAAEAAAABIAAAADAAAAAgAAABQAAAABAAAABQAAAAAoAAAAAAAAFAAA
AG0NtrUAAAAAAAAAAAAAAAAAAAAAAAAAAKAFAAAAAAAAAwAJAAAAAABYIAAAAAAAAAMAEwBGAAAA
AAAAAAAAAAAiAAAAEAAAAAAAAAAAAAAAIAAAAGgAAAAAAAAAAAAAABIAAAC6AAAAAAAAAAAAAAAS
AAAAlAAAAAAAAAAAAAAAEQAAAIcAAAAAAAAAAAAAABIAAABVAAAAAAAAAAAAAAASAAAAAQAAAAAA
AAAAAAAAIAAAAH8AAAAAAAAAAAAAABIAAACpAAAAAAAAAAAAAAASAAAAcwAAAAAAAAAAAAAAEgAA
AIgAAAAAAAAAAAAAABIAAAB4AAAAAAAAAAAAAAASAAAAWwAAAAAAAAAAAAAAEgAAAGEAAAAAAAAA
AAAAABIAAAAsAAAAAAAAAAAAAAAgAAAAjgAAAAAAAAAAAAAAEgAAAJsAAADgCAAAqAEAABIACwAA
X19nbW9uX3N0YXJ0X18AX0lUTV9kZXJlZ2lzdGVyVE1DbG9uZVRhYmxlAF9JVE1fcmVnaXN0ZXJU
TUNsb25lVGFibGUAX19jeGFfZmluYWxpemUAZGxzeW0AZmNudGwAc29ja2V0AHNldHNvY2tvcHQA
YmluZABsaXN0ZW4AZnByaW50ZgBmd3JpdGUAY2xvc2UAc3RkZXJyAHNuZF9wY21fcmVhZGkAX19l
cnJub19sb2NhdGlvbgBhY2NlcHQAbGliZGwuc28uMgBsaWJjLnNvLjYAR0xJQkNfMi40AC9uaXgv
c3RvcmUvNDYxdzFxd2x5dmJobmQwa2tjZnBmZmR4aHFqc2k0ejgtZ2xpYmMtYXJtdjdsLXVua25v
d24tbGludXgtZ251ZWFiaWhmLTIuNDQtMjUvbGliOi9uaXgvc3RvcmUvbm15NGR6N2Q5MnNoMGww
M3FsNWR2enJma2YxNng2MXgtYXJtdjdsLXVua25vd24tbGludXgtZ251ZWFiaWhmLWdjYy0xNi4y
LjAtbGliL2FybXY3bC11bmtub3duLWxpbnV4LWdudWVhYmloZi9saWIAAAAAAAAAAgAAAAIAAgAC
AAIAAgAAAAIAAgACAAIAAgACAAIAAAACAAEAAQABAMwAAAAQAAAAAAAAABRpaQ0AAAIA1gAAAAAA
AAD8HgAAFwAAAAAfAAAXAAAABB8AABcAAABYIAAAFwAAAEQgAAAVAwAASCAAABUEAABMIAAAFQcA
AFAgAAAVCgAAVCAAABUSAAAMIAAAFgMAABAgAAAWBQAAFCAAABYGAAAYIAAAFggAABwgAAAWCQAA
ICAAABYKAAAkIAAAFgsAACggAAAWDAAALCAAABYNAAAwIAAAFg4AADQgAAAWDwAAOCAAABYQAAA8
IAAAFhEAAEAgAAAWEwAACEAt6YQAAOsIgL3oBOAt5QTgn+UO4I/gCPC+5UQaAAAAxo/iAcqM4kT6
vOUAxo/iAcqM4jz6vOUAxo/iAcqM4jT6vOUAxo/iAcqM4iz6vOUAxo/iAcqM4iT6vOUAxo/iAcqM
4hz6vOUAxo/iAcqM4hT6vOUAxo/iAcqM4gz6vOUAxo/iAcqM4gT6vOUAxo/iAcqM4vz5vOUAxo/i
AcqM4vT5vOUAxo/iAcqM4uz5vOUAxo/iAcqM4uT5vOUAxo/iAcqM4tz5vOXwSS3pAADg4ygRn+UY
sI3iJNBN4gEQj+Da///rGDGf5Rhhn+UAIKDjAzCP4BBxn+UGYI/gARCg4wdwj+AAAIPlAgCg4+f/
/+sAQFDiAECG5SkAALoBgKDjBDCg4wIgoOMAMI3lCBCg4TAwS+IwgAvlAFCg47r//+sQIKDjLBBL
4gQAoOECMKDjRTtG4yhQC+UkUAvlIFAL5SwwC+XF///rAABQ4xYAALoIEKDhBACg4cb//+sFIKDh
AxCg4wQAoOHF///rBBCg4wIrgOMAAJblwf//62wAn+VsEJ/lCMCg4wUwoOFrJQTjARCP4AAAl+cA
wI3lAACQ5aj//+sY0Evi8Im96Dwwn+UaIKDjPACf5QgQoOEAAI/gAzCX5wAwk+WV///rAACW5bH/
/+sAMODjADCG5fD//+qcBAAA0BkAALwZAABYGQAATAAAAPQDAACsAwAAFDCf5RQgn+UDMI/gAiCT
5wAAUuMe/y8BiP//6jQYAABQAAAALACf5Swwn+UAAI/gKCCf5QMwj+AAAFPhAiCP4B7/LwEYMJ/l
AzCS5wAAU+Me/y8BE/8v4XQYAABsGAAAABgAAEgAAAA4AJ/lODCf5QAAj+A0IJ/lAzCP4AAwQ+AC
II/gox+g4UMRgeDBELDhHv8vARgwn+UDMJLnAABT4x7/LwET/y/hMBgAACgYAAC8FwAAVAAAAEww
n+VMIJ/lAzCP4AIgj+AAMNPlAABT4x7/LxE4MJ/lEEAt6QMwkucAAFPjAgAACigwn+UDAJ/nQ///
68r//+scMJ/lASCg4wMwj+AAIMPlEIC96OAXAAB4FwAARAAAAKgXAACgFwAA0P//6ngxn+XwSC3p
AWCg4QMwj+BswZ/lFLCN4gjQTeIMwI/gADCT5QxwoOEz/y/hAEBQ4hkAANpMMZ/lAzCP4AAQk+UA
AFHjFAAAugQAk+UAAFDjKQAAugEKVOMsMZ/lBCCgsQEqoKMDMI/gBhCg4QIwQ+IC4obgsMHR4LLA
4+EOAFHh+///GgQRn+WCIKDhARCP4C3//+sAAFDjAgAAugQAoOEU0Evi8Ii96CH//+sAMJDlCwBT
4/j//wrUIJ/lAiCP4BggC+UEAJLlK///6xggG+XAMJ/lABDg47wAn+UEEILlIiCg4wEQoOMAAI/g
AzCX5wAwk+UC///r5///6gAgoOMBAKDhAhCg4RgwC+X5/v/rACBQ4gJQoOEQAAC6ACCg4wMQoOMO
///rBBCg4wIrgOMFAKDhCv//6xgwG+VcAJ/lHyCg4wEQoOMEUIPlAACP4EAwn+UDMJfnADCT5ej+
/+s8MJ/lAzCP4AQAk+UAAFDjt///qgQAoOEU0Evi8Ii96HQXAAD8FgAAPBcAACAXAAD4FgAAuBYA
AEwAAADcAQAAWAEAABAWAAAIQC3pCIC96D4AAAAIAAAALwAAAAgAAAAEAAAACAAAAAsAAAAIAAAA
PQAAAAgAAAA2AAAACAAAABYAAAAIAAAALgAAAAgAAAAQAAAACAAAADIAAAAIAAAAFAAAAAgAAAAR
AAAACAAAAB4AAAAIAAAANQAAAAgAAAAPAAAACAAAACMAAAAIAAAAKQAAAAgAAAAAAAAAAAAAAHNu
ZF9wY21fcmVhZGkAAABbbWljY2FwLXNoaW1dIGJpbmQgZmFpbGVkCgAAW21pY2NhcC1zaGltXSBs
b2FkZWQsIGxpc3RlbmluZyBvbiA6JWQgKGV4dHJhY3RpbmcgY2glZCBvZiAlZCkKAFttaWNjYXAt
c2hpbV0gY2xpZW50IGNvbm5lY3RlZAoAW21pY2NhcC1zaGltXSBjbGllbnQgZGlzY29ubmVjdGVk
CgAAPgAAAAgAAAAvAAAACAAAAAQAAAAIAAAACwAAAAgAAAA9AAAACAAAADYAAAAIAAAAFgAAAAgA
AAAuAAAACAAAABAAAAAIAAAAMgAAAAgAAAAUAAAACAAAABEAAAAIAAAAHgAAAAgAAAA1AAAACAAA
AA8AAAAIAAAAIwAAAAgAAAApAAAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
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
AAAAAAEA8f9AAQAAZCAAAAAAAAABABMATAEAAAAgAAAAAAAAAQDx/y8AAACgBQAAAAAAAAIACQAI
AAAArAUAAAAAAAAAAAoAGAAAALwFAAAAAAAAAAAKAAgAAADABQAAAAAAAAAACgBiAQAAAAAAAAAA
AAAiAAAAewEAAAAAAAAAAAAAIAAAAJcBAAAAAAAAAAAAABIAAACsAQAAAAAAAAAAAAASAAAAvQEA
AAAAAAAAAAAAEQAAAM4BAAAAAAAAAAAAABIAAADfAQAAAAAAAAAAAAASAAAA7wEAAAAAAAAAAAAA
IAAAAP4BAAAAAAAAAAAAABIAAAAQAgAAAAAAAAAAAAASAAAAKwIAAAAAAAAAAAAAEgAAAM8BAAAA
AAAAAAAAABIAAAA6AgAAAAAAAAAAAAASAAAASwIAAAAAAAAAAAAAEgAAAFsCAAAAAAAAAAAAABIA
AABsAgAAAAAAAAAAAAAgAAAAVwAAAOAIAACoAQAAEgALAIYCAAAAAAAAAAAAABIAAAAAY3J0aS5v
ACRhAGNhbGxfd2Vha19mbgAkZABjcnRuLm8AbWljY2FwLmMAc2hpbV9pbml0AG91dGJ1Zi4wAGxp
c3Rlbl9mZABjbGllbnRfZmQAcmVhbF9zbmRfcGNtX3JlYWRpAGNydGJlZ2luUy5vAGFsbF9pbXBs
aWVkX2ZiaXRzAGRlcmVnaXN0ZXJfdG1fY2xvbmVzAF9fZG9fZ2xvYmFsX2R0b3JzX2F1eABjb21w
bGV0ZWQuMABfX2RvX2dsb2JhbF9kdG9yc19hdXhfZmluaV9hcnJheV9lbnRyeQBmcmFtZV9kdW1t
eQBfX2ZyYW1lX2R1bW15X2luaXRfYXJyYXlfZW50cnkAY3J0ZW5kUy5vAF9fRlJBTUVfRU5EX18A
X2ZpbmkAX19kc29faGFuZGxlAF9EWU5BTUlDAF9fVE1DX0VORF9fAF9HTE9CQUxfT0ZGU0VUX1RB
QkxFXwBfX2N4YV9maW5hbGl6ZUBHTElCQ18yLjQAX0lUTV9kZXJlZ2lzdGVyVE1DbG9uZVRhYmxl
AHNldHNvY2tvcHRAR0xJQkNfMi40AGFjY2VwdEBHTElCQ18yLjQAc3RkZXJyQEdMSUJDXzIuNABm
d3JpdGVAR0xJQkNfMi40AGRsc3ltQEdMSUJDXzIuNABfX2dtb25fc3RhcnRfXwBmcHJpbnRmQEdM
SUJDXzIuNABfX2Vycm5vX2xvY2F0aW9uQEdMSUJDXzIuNABiaW5kQEdMSUJDXzIuNABsaXN0ZW5A
R0xJQkNfMi40AGZjbnRsQEdMSUJDXzIuNABzb2NrZXRAR0xJQkNfMi40AF9JVE1fcmVnaXN0ZXJU
TUNsb25lVGFibGUAY2xvc2VAR0xJQkNfMi40AAAuc3ltdGFiAC5zdHJ0YWIALnNoc3RydGFiAC5n
bnUuaGFzaAAuZHluc3ltAC5keW5zdHIALmdudS52ZXJzaW9uAC5nbnUudmVyc2lvbl9yAC5yZWwu
ZHluAC5yZWwucGx0AC5pbml0AC50ZXh0AC5maW5pAC5yb2RhdGEALmVoX2ZyYW1lAC5pbml0X2Fy
cmF5AC5maW5pX2FycmF5AC5keW5hbWljAC5nb3QALmRhdGEALmJzcwAuY29tbWVudAAuQVJNLmF0
dHJpYnV0ZXMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAfAAAABQAA
AAIAAADUAAAA1AAAAKAAAAADAAAAAAAAAAQAAAAEAAAAGwAAAPb//28CAAAAdAEAAHQBAAAgAAAA
AwAAAAAAAAAEAAAABAAAACUAAAALAAAAAgAAAJQBAACUAQAAUAEAAAQAAAADAAAABAAAABAAAAAt
AAAAAwAAAAIAAADkAgAA5AIAALoBAAAAAAAAAAAAAAEAAAAAAAAANQAAAP///28CAAAAngQAAJ4E
AAAqAAAAAwAAAAAAAAACAAAAAgAAAEIAAAD+//9vAgAAAMgEAADIBAAAIAAAAAQAAAABAAAABAAA
AAAAAABRAAAACQAAAAIAAADoBAAA6AQAAEgAAAADAAAAAAAAAAQAAAAIAAAAWgAAAAkAAABCAAAA
MAUAADAFAABwAAAAAwAAABIAAAAEAAAACAAAAGMAAAABAAAABgAAAKAFAACgBQAADAAAAAAAAAAA
AAAABAAAAAAAAABeAAAAAQAAAAYAAACsBQAArAUAALwAAAAAAAAAAAAAAAQAAAAEAAAAaQAAAAEA
AAAGAAAAaAYAAGgGAAAgBAAAAAAAAAAAAAAEAAAAAAAAAG8AAAABAAAABgAAAIgKAACICgAACAAA
AAAAAAAAAAAABAAAAAAAAAB1AAAAAQAAAAIAAACQCgAAkAoAANABAAAAAAAAAAAAAAQAAAAAAAAA
fQAAAAEAAAACAAAAYAwAAGAMAAAEAAAAAAAAAAAAAAAEAAAAAAAAAIcAAAAOAAAAAwAAAPweAAD8
DgAACAAAAAAAAAAAAAAABAAAAAQAAACTAAAADwAAAAMAAAAEHwAABA8AAAQAAAAAAAAAAAAAAAQA
AAAEAAAAnwAAAAYAAAADAAAACB8AAAgPAAD4AAAABAAAAAAAAAAEAAAACAAAAKgAAAABAAAAAwAA
AAAgAAAAEAAAWAAAAAAAAAAAAAAABAAAAAQAAACtAAAAAQAAAAMAAABYIAAAWBAAAAwAAAAAAAAA
AAAAAAQAAAAAAAAAswAAAAgAAAADAAAAZCAAAGQQAAAIIAAAAAAAAAAAAAAEAAAAAAAAALgAAAAB
AAAAMAAAAAAAAABkEAAAEgAAAAAAAAAAAAAAAQAAAAEAAADBAAAAAwAAcAAAAAAAAAAAdhAAADEA
AAAAAAAAAAAAAAEAAAAAAAAAAQAAAAIAAAAAAAAAAAAAAKgQAABABgAAGAAAAFIAAAAEAAAAEAAA
AAkAAAADAAAAAAAAAAAAAADoFgAAlgIAAAAAAAAAAAAAAQAAAAAAAAARAAAAAwAAAAAAAAAAAAAA
fhkAANEAAAAAAAAAAAAAAAEAAAAAAAAA
'

# ---- 1. restart helper, used both to bring the tap up and to revert ---

full_restart() {
  adbsh 'pkill -9 quasar_launcher2 2>/dev/null; pkill -9 -f "maind --" 2>/dev/null'
  sleep 1
  adbsh 'rm -f /tmp/loop_capture_pcm
mkfifo /tmp/loop_capture_pcm
cd /data/quasar
rm -f daemons_logs/*.log.* 2>/dev/null
rm -f /data/quasar/_* 2>/dev/null
export CA_CERTIFICATES=/system/vendor/quasar/ca-certificates.crt
export LD_LIBRARY_PATH=/system/vendor/quasar/libs
ulimit -n 10240
ulimit -s 1024
nohup /system/vendor/quasar/quasar_launcher2 /system/vendor/quasar/launch.json > launcher2.out 2>&1 &
sleep 1'
  for _ in $(seq 1 10); do
    sleep 1
    [ "$(adbsh 'ps | grep -- "maind --" | grep -v grep | wc -l' | tr -d '\r')" = "4" ] && return 0
  done
  return 1
}

# ---- 2. revert on exit, no matter how we leave -------------------------
#
# This trap is bulletproof against Ctrl-C, errors, and the timeout below -
# but NOT against this script getting SIGKILL'd outright (flaky terminal,
# laptop's network dying mid-restart, whatever). Nothing running on the
# Mac can trap that, and a device-side watchdog doesn't help either - it
# hits the exact same "doesn't survive the adb shell session closing"
# problem quasar_launcher2 itself has, proven not to work here.
#
# So instead: if a session ever does get orphaned, just run
#   ./mic-tap.sh clean
# which forces the revert unconditionally, independent of any session
# state. That's the actual safety net - on demand, not automatic.

REVERTED=0
revert_and_restart() {
  [ "$REVERTED" = 1 ] && return
  REVERTED=1
  echo "[mic-tap] reverting launch.json and restarting clean..." >&2
  adbsh "chattr -i $LJ 2>/dev/null; cp $LJ.mictap.bak $LJ"
  restore_immutable
  full_restart || echo "[mic-tap] WARNING: didn't reach 4/4 tasks after revert, check manually." >&2
  adbsh 'ps | grep -E "maind|launcher2" | grep -v grep' >&2
  adbsh "netstat -tln | grep $PORT || echo '[mic-tap] confirmed: $PORT closed'" >&2
  cleanup_local
}

if [ "${1:-}" = "clean" ]; then
  echo "[mic-tap] clean: forcing launch.json back to its backed-up state and restarting, regardless of session state..." >&2
  adbsh "chattr -i $LJ 2>/dev/null"
  if adbsh "[ -f $LJ.mictap.bak ]"; then
    adbsh "cp $LJ.mictap.bak $LJ"
  else
    echo "[mic-tap] no backup file found on device - launch.json left as-is, just restarting the stack." >&2
  fi
  restore_immutable
  full_restart || echo "[mic-tap] WARNING: didn't reach 4/4 tasks, check manually." >&2
  adbsh 'ps | grep -E "maind|launcher2" | grep -v grep'
  adbsh "netstat -tln | grep $PORT || echo '[mic-tap] confirmed: $PORT closed'"
  cleanup_local
  exit 0
fi

trap revert_and_restart EXIT INT TERM

# ---- 3. decode shim, push it, patch launch.json, restart with it ------

echo "$MICCAP_SO_B64" | base64 -d > "$WORK/miccap.so" 2>"$WORK/b64.err"
if [ ! -s "$WORK/miccap.so" ]; then
  echo "[mic-tap] ABORT: failed to decode embedded shim." >&2
  cat "$WORK/b64.err" >&2
  exit 1
fi

if ! "$ADB" -s "$DEVICE" push "$WORK/miccap.so" /tmp/miccap.so; then
  echo "[mic-tap] ABORT: push of miccap.so to device failed." >&2
  exit 1
fi
# confirm it's actually there and the right size before trusting it
REMOTE_SIZE="$(adbsh 'wc -c < /tmp/miccap.so' | tr -d '\r ')"
LOCAL_SIZE="$(wc -c < "$WORK/miccap.so" | tr -d ' ')"
if [ "$REMOTE_SIZE" != "$LOCAL_SIZE" ]; then
  echo "[mic-tap] ABORT: pushed shim size mismatch (local=$LOCAL_SIZE remote=$REMOTE_SIZE)." >&2
  exit 1
fi

echo "[mic-tap] backing up and patching launch.json..." >&2
adbsh "cp $LJ $LJ.mictap.bak"
adbsh "chattr -i $LJ"
"$ADB" -s "$DEVICE" pull "$LJ" "$WORK/launch_live.json" >/dev/null

awk '
  /--platformd/ { inblock=1 }
  inblock && /"MALLOC_ARENA_MAX=2"/ && !done {
    print $0
    print "                        \"LD_PRELOAD=/tmp/miccap.so\","
    done=1
    next
  }
  { print }
' "$WORK/launch_live.json" > "$WORK/launch_patched.json"

if ! jq empty "$WORK/launch_patched.json" 2>"$WORK/jq.err"; then
  echo "[mic-tap] ABORT: patched launch.json isn't valid JSON, not pushing it." >&2
  cat "$WORK/jq.err" >&2
  restore_immutable
  exit 1
fi

"$ADB" -s "$DEVICE" push "$WORK/launch_patched.json" "$LJ" >/dev/null
restore_immutable

echo "[mic-tap] restarting stack with the shim loaded..." >&2
if ! full_restart; then
  echo "[mic-tap] didn't reach 4/4 tasks - reverting now." >&2
  exit 1
fi

PFPID="$(adbsh "ps | grep -- '--platformd' | grep -v grep | awk '{print \$1}'" | tr -d '\r')"
HAS_PRELOAD="$(adbsh "cat /proc/$PFPID/environ 2>/dev/null | tr '\\0' '\\n' | grep -c LD_PRELOAD")"
echo "[mic-tap] platformd pid $PFPID, LD_PRELOAD set: $HAS_PRELOAD" >&2

# the real proof it's working: is the shim's listener actually up, not just
# the env var string being present (a missing/bad preload is a soft
# failure in glibc, not a hard one - the env var can be set and true while
# nothing is actually listening).
sleep 1
if adbsh "netstat -tln | grep -q $PORT"; then
  echo "[mic-tap] confirmed: shim is actually listening on :$PORT" >&2
else
  echo "[mic-tap] ABORT: LD_PRELOAD is set but nothing is listening on :$PORT - the shim did not actually load. Reverting." >&2
  exit 1
fi

echo >&2
echo "[mic-tap] live - connect to ${DEVICE%:*}:$PORT for raw S16_LE/48kHz/mono PCM." >&2
echo "[mic-tap] Ctrl-C when done, or it auto-reverts on its own after ${MAX_SESSION_SECONDS}s regardless." >&2
echo "[mic-tap] If this session ever gets killed and leaves things stuck: ./mic-tap.sh clean" >&2
sleep "$MAX_SESSION_SECONDS"
echo "[mic-tap] max session time hit, reverting automatically." >&2
