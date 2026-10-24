#!/bin/sh
# Установка USB Host (OTG) на Станцию Лайт (Yandex Station Micro, Amlogic AXG, ядро 4.9.68).
#
# Запуск на колонке из каталога, куда скопированы contrib/otg и contrib/modules
# (например: scp -r contrib/otg contrib/modules root@<ip>:/data/otg-src/):
#   sh /data/otg-src/otg/install.sh
#
# Что делает:
#   /data/otg/otg-host.sh      — переключение Type-C в host + загрузка драйверов
#   /data/otg/usb-mount.sh     — монтирование разделов в /tmp/usb/<метка>
#   /data/otg/modules/*.ko     — модули, собранные под ядро Яндекса
#   /etc/init.d/S97otg-host    — автозапуск с защитой от бутлупа
# Старый /etc/init.d/S98usb_modules (битые модули из ранней версии гайда) удаляется.
set -e
SRC=$(cd "$(dirname "$0")/.." && pwd)
D=/data/otg

grep -q "yandex,station-micro" /proc/device-tree/compatible 2>/dev/null \
	|| { echo "Это не Станция Лайт (yandex,station-micro) — регистры PHY другие, выходим."; exit 1; }
[ "$(uname -r)" = "4.9.68" ] || { echo "Ядро $(uname -r), модули собраны под 4.9.68 — выходим."; exit 1; }
command -v devmem >/dev/null || { echo "Нет devmem в busybox — выходим."; exit 1; }

mkdir -p $D/modules
cp "$SRC/otg/otg-host.sh" "$SRC/otg/usb-mount.sh" $D/
cp "$SRC"/modules/*.ko $D/modules/
chmod +x $D/otg-host.sh $D/usb-mount.sh
( cd "$SRC/modules" && sha256sum -c SHA256SUMS >/dev/null ) || { echo "Контрольные суммы модулей не сошлись."; exit 1; }

mount -o remount,rw /
if [ -f /etc/init.d/S98usb_modules ]; then
	cp -p /etc/init.d/S98usb_modules $D/S98usb_modules.bak
	rm /etc/init.d/S98usb_modules
	echo "Старый S98usb_modules убран (копия: $D/S98usb_modules.bak)"
fi
cp "$SRC/otg/S97otg-host" /etc/init.d/S97otg-host
chmod +x /etc/init.d/S97otg-host
sync
mount -o remount,ro / || true

echo "Готово. Для exFAT/NTFS: yse install exfat-fuse ntfs-3g"
echo "Перезагрузите колонку; лог первого запуска — $D/last.log"
