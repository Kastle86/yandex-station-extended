#!/bin/bash
# Install persistent ADB init script on a rooted Yandex Station.
# Requires: adb access to <ip>:5555 (first-time needs eQuasar unlock).
#
# Usage: sh install-s97adb.sh <station-ip>
set -e
IP="${1:-<STATION_IP>}"
SER="$IP:5555"
cd "$(dirname "$0")"

[ -f S97adb ] || { echo "S97adb not found"; exit 1; }

echo "[*] Installing S97adb on station $SER..."
adb -s "$SER" shell "mount -o remount,rw /"
adb -s "$SER" push S97adb /etc/init.d/S97adb >/dev/null
adb -s "$SER" shell "sync; mount -o remount,ro /; chmod 755 /etc/init.d/S97adb; echo INSTALLED"
echo "[*] Rebooting station..."
adb -s "$SER" shell "sleep 1; reboot" 2>/dev/null || true
sleep 60
echo "[*] Checking port 5555..."
if (exec 3<>/dev/tcp/$IP/5555) 2>/dev/null; then
    echo "[+] ADB is alive after reboot. Now S97adb survives without eQuasar server."
else
    echo "[-] Port not open yet, wait a bit or rerun: adb connect $SER"
fi
