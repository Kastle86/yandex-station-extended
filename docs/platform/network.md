# Сеть и glagol

Сетевые сервисы станции и локальный API `glagol`. Данные с
[Станции Лайт](../devices/station-lite.md); на других моделях состав сервисов
аналогичный.

## Интерфейсы

- `wlan0` — DHCP от роутера (основная сеть).
- `p2p0` (169.254/16) — Wi-Fi Direct (setup / совмещённый режим).
- `wlan1` / `10.10.10.254` — softAP первичной настройки (маршрут чистится на boot).

На Лайте радио — **Unisoc UWE5621** (`vlsicomm` + `aml_sdio` + `sdio_bt`), Wi-Fi + BT
combo по SDIO. Ethernet отсутствует.

## Сетевые демоны

- `wpa_supplicant -Dnl80211 -iwlan0 -c …/wpa_supplicant.conf`, ctrl-сокет
  `/var/run/wpa_supplicant/wlan0` → управление через `wpa_cli`.
- `dhcpcd`.
- **`unbound`** — `127.0.0.1:53`, форвард на Яндекс-DNS `77.88.8.1/2/8/88` (роутер
  запасной).
- **`chronyd`** — NTP (+ свой netclock Яндекса).

## Bluetooth

`hciattach ttyS1 aml` + `bluetoothd` + **`bluealsa`** (`a2dp-sink`, `a2dp-source`,
`hfp-ag`) + `bluealsa-aplay` + `just-works` agent → колонку можно использовать как
BT-аудиоприёмник/источник. Утилиты: `bt-adapter`, `bt-agent`, `bt-device`,
`bt-network` (PAN), `bt-obex`, `btmon`.

## Карта слушающих портов

| Порт | Кто | Назначение |
|---|---|---|
| `tcp 127.0.0.1:53`, `udp 53` | unbound | локальный DNS-резолвер |
| `tcp [::]:1961` | maind / platformd | **glagol** — локальный API (TLS, mutual-auth) |
| `tcp 0.0.0.0:5081` | maind / platformd | локальный сервис maind (не HTTP) |
| `tcp/udp 0.0.0.0:7447` | maind / platformd | локальный сервис (вероятно **Zenoh**) |
| `udp 0.0.0.0:5353` | maind | mDNS (`_yandexio._tcp` discovery) |
| `udp 11124/11125` | maind | netclock (синхронизация времени Яндекса) |
| `tcp 127.0.0.1:98xx` (много) | maind | внутренний IPC между ролями |
| `udp 323` | chronyd | NTP control (localhost) |
| `tcp 5555` | adbd | ADB по сети (если включён) |

!!! note "Порты 7447 и 5081"
    `7447` совпадает с дефолтом **Zenoh** (в конфиге `iot.providers.Zenoh=true`) —
    вероятно, транспорт умного дома. `5081` — ещё один локальный сервис maind (на
    plain-HTTP не отвечает). Оба — поле для дальнейшего ресёрча.

## glagol — локальное управление { #glagol }

Штатный путь управления колонкой из скриптов, без облака:

- discovery по mDNS `_yandexio._tcp`;
- TLS на `:1961`, авторизация токеном из облака + сертификат/ключ устройства из
  `devices.json`;
- протокол — JSON-команды поверх WebSocket/TLS (play / pause / volume / ping / TTS).
