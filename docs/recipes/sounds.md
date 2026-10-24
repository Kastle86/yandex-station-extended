# Свои звуки

В прошивке есть GStreamer: через `maind --gst-launch` колонка проигрывает файлы и
интернет-потоки без дополнительного софта.

## Проиграть файл или поток

```sh
cd /system/vendor/quasar
LD_LIBRARY_PATH=/system/vendor/quasar:libs ./maind --gst-launch \
  "filesrc location=/data/sounds/my.mp3 ! decodebin ! audioconvert ! audioresample ! alsasink"
```

Поток: замените `filesrc location=…` на `souphttpsrc location=http://…`.
Звук идёт в ALSA `default`, то есть туда же, куда и Алиса, и регулируется её громкостью.

## Звук при включении (Mac Chime)

Файл в репозитории: [`contrib/packages/mac-startup-chime-t2.mp3`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/packages/mac-startup-chime-t2.mp3).

```sh
adb shell mkdir -p /data/sounds
adb push contrib/packages/mac-startup-chime-t2.mp3 /data/sounds/chime.mp3
adb shell
mount -o remount,rw /
cat > /etc/init.d/S98chime <<'EOF'
#!/bin/sh
[ "$1" = start ] || exit 0
cd /system/vendor/quasar
LD_LIBRARY_PATH=/system/vendor/quasar:libs ./maind --gst-launch \
  "filesrc location=/data/sounds/chime.mp3 ! decodebin ! audioconvert ! audioresample ! alsasink" \
  >/dev/null 2>&1 &
EOF
chmod +x /etc/init.d/S98chime
sync; mount -o remount,ro /
```

Удалить: `rm /etc/init.d/S98chime` (rootfs в `rw`).

## Системные звуки

Лежат в `/system/vendor/quasar/sounds/`: `common/` (общие: `spotter_start.opus`,
`spotter_cancel.opus`, `volume_sound.opus`, `notification_sound.opus`, `timer.opus`,
`calls_*`…) и `ru-RU/` (фразы). Формат — Ogg Opus.

Конвертировать свой файл:

```sh
ffmpeg -i my.mp3 -c:a libopus -ar 48000 -ac 1 -b:a 64k my.opus
```

Заменить системный звук можно в rootfs (`mount -o remount,rw /`), **сохранив оригинал**.
Подхватывает ли его Алиса без перезагрузки — не проверяли.
