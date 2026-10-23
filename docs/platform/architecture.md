# Архитектура прошивки (quasar)

`quasar` — прошивочный стек Яндекса, общий для Amlogic-станций. Описание ниже
проверено на [Станции Лайт](../devices/station-lite.md); на других моделях цепочка
та же, но версии и пути могут отличаться — дополняйте.

## Загрузка и init

BusyBox init (`/sbin/init` → busybox), `/etc/inittab`:

- `sysinit` → mount proc/pts/shm, `mount -a`, hostname, затем `/etc/init.d/rcS`;
- `console::respawn:/sbin/getty_rabbit_hole` — getty на serial (см.
  [Доступ → serial](access.md#serial));
- `rcS` прогоняет по порядку все `/etc/init.d/S??*`.

Порядок `S`-скриптов (Лайт):

```
S00hostname  S01rw-dirs  S01syslogd  S01watchdog  S02klogd  S02sysctl
S10mdev  S20urandom  S30dbus  S39w1_wifi_ant_config  S40dhcpcd-db  S40net.lo
S40wifi  S41dhcpcd  S45tas58xx  S49chrony  S49teeinit  S50hci0  S51bluetoothd
S52bluealsa  S53bluealsa-aplay  S54default-bluez-agent  S60touch_buttons_settings
S70unbound  S98pstore-clear  S99quasar
```

`S99quasar` → `/system/vendor/quasar/onboot.sh start`:

- `echo 1 > /proc/sys/vm/overcommit_memory`;
- чистит старые OTA-артефакты (`/bkupgrade/update_*`, `/bkupgrade/ota/*`, `uImage*`);
- экспортит `LD_LIBRARY_PATH=…/quasar/libs`, `GST_PLUGIN_PATH`, `PATH`;
- `yio_iptables_init.sh` (firewall-каркас), `set_monotonic_time.sh`;
- **`activate_adb.sh check`** — включает adbd по файлам-маркерам (см.
  [Доступ → ADB](access.md#adb));
- `route delete default gateway 10.10.10.254 wlan1` — чистит маршрут setup-режима
  (10.10.10.x — softAP первичной настройки);
- `run.sh` → `quasar_launcher2 launch.json`.

`run.sh`: `ulimit -n 10240`, `ulimit -s 1024` (стек 1 МБ — у quasar >100 потоков),
запускает `quasar_launcher2`, который по `launch.json` стартует демоны `maind`.

## Стек quasar

Всё в одном бинарнике **`maind`** (~21 МБ на Лайте), запускается многократно под
разными ролями (`quasar_launcher2` по `launch.json`). Симлинки на `maind`:
`keymaster_proxy_app`, `led_util`, `metrics_collector`, `quasar_client`,
`tcp_alsa_writer`.

**Демоны (роли maind):** `--platformd` (главный: glagol, облако, IoT), `--mediad`
(воспроизведение), `--telemetry`, `--fluent-bitd` (логи), `--updatesd` (OTA — см.
[отключение](access.md#ota)).

**Tools-режимы `maind`** (`--help`):

```
--build-timestamp  --cli  --device-id  --device-localization  --full-info
--getprop  --glagol-connections  --gst-launch  --nettest
--set-dev-backend-flag  --remove-dev-backend-flag  --save-last-monotonic-time
--version  --wifi-info
```

### `--gst-launch` { #gst-launch }

Встроенный `gst-launch` поверх родного GStreamer Яндекса:

```
--gst-launch [--clock <host:port>] <PIPELINE> [--next <PIPELINE> ...]
```

- поддерживает несколько конвейеров подряд (`--next`);
- **`--clock`** — синхрочасы для мультирум/стерео-пары;
- доступны `souphttpsrc`, `decodebin`, opus/aac/mp3, `alsasink`, `scaletempo`, EQ,
  `spectrum` и кастомные элементы Яндекса.

Пример (проверено, что пайплайн инициализируется):

```sh
cd /system/vendor/quasar
LD_LIBRARY_PATH=libs ./maind --gst-launch \
  "souphttpsrc location=<URL> ! decodebin ! audioconvert ! audioresample ! alsasink"
```

!!! tip
    Это правильный путь, чтобы играть произвольный звук **без** своего ffmpeg/aplay —
    родным трактом с EQ и ресемплом.

### Хелпер `q`

`/system/vendor/quasar/q` оборачивает tools-режимы:

```
q {start|stop|restart|version|device-id|wifi-info|glagol-connections|
   full-info|backend-dev|backend-prod|cli|save-last-monotonic-time|getprop}
```

- `q cli` → интерактивная консоль `maind --cli`;
- `q backend-dev` → `maind --set-dev-backend-flag` (переключение на **dev-backend**
  Яндекса) + restart; `q backend-prod` — обратно;
- `begemot` — локальный NLU-движок, останавливается вместе с maind.

### Библиотеки (`/system/vendor/quasar/libs`)

| Библиотека | Назначение |
|---|---|
| `libquasar_gstreamer.so` | монолитный GStreamer (плагины встроены, реестр отключён) |
| `libyandex_evil.so` | внутренний слой (обфускация / anti-tamper / крипто) |
| `libtflite.so` | TensorFlow Lite (споттер wake-word, VQE) |
| `libglib.so`, `libavahi-*` | GLib, mDNS (glagol discovery) |
| `libiconv.so` | перекодировка |

### Модели и ресурсы

- `spotter_models/` — wake-word (activation/command/vad/counteractivation);
- `vqe_models/` — эхоподавление / beamforming;
- `bio_lingware/` — TTS / биометрия голоса;
- `sounds/` — системные звуки;
- `matter/paa/` — сертификаты Matter PAA (Google / TP-Link / CommScope / …);
- `quasar.cfg` — конфиг медиа-пайплайнов; `zstd.dict` — словарь сжатия логов.

!!! info "Умный дом"
    В конфиге включены провайдеры **Matter** и **Zenoh** — колонка работает как
    Matter-контроллер/хаб.
