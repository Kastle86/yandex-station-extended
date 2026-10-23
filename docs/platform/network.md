# Сеть, порты и протокол glagol

Сетевая архитектура Яндекс Станции, локальные сервисы, протокол mDNS-обнаружения и прямое локальное управление через `glagol`.

---

## 📡 Сетевые интерфейсы

| Интерфейс | Назначение | Особенности |
|---|---|---|
| **`wlan0`** | Основное Wi-Fi подключение | Клиент домашней сети, получает IP по DHCP от роутера. |
| **`p2p0`** | Wi-Fi Direct | Подсеть `169.254.0.0/16` для прямого взаимодействия с устройствами. |
| **`wlan1`** | Режим точки доступа (SoftAP) | Поднимается со статикой `10.10.10.254` во время первичной настройки. |

На большинстве компактных Станций (Лайт, Мини, Мини 2) радиочасть построена на комбо-чипе **Unisoc UWE5621** (Wi-Fi 802.11ac + Bluetooth 5.0 по шине SDIO). Физический Ethernet на платах отсутствует.

---

## 🗺️ Карта портов и сервисов

| Порт / Протокол | Процесс | Назначение |
|---|---|---|
| **`tcp 0.0.0.0:1961`** | `maind` | **glagol** — локальный управляющий WebSocket API (TLS). |
| **`udp 0.0.0.0:5353`** | `maind` | **mDNS** — широковещательное объявление сервиса `_yandexio._tcp`. |
| **`tcp/udp 0.0.0.0:7447`**| `maind` | **Zenoh** — шина данных для экосистемы умного дома и Matter. |
| **`tcp 0.0.0.0:5081`** | `maind` | Внутренний сервисный RPC-эндпоинт прошивки. |
| **`tcp 127.0.0.1:53`** | `unbound`| Локальный кэширующий DNS-резолвер. |
| **`udp 11124 / 11125`**| `maind` | **netclock** — собственный протокол точной синхронизации времени. |
| **`tcp 0.0.0.0:5555`** | `adbd` | Сетевой ADB-сервер (если активирован маркерами). |
| **`tcp 0.0.0.0:2222`** | `dropbear`| Автономный SSH-сервер (после ручной настройки). |

---

## 🔍 Обнаружение в сети (mDNS)

Каждая включенная колонка в локальной сети анонсирует себя по протоколу ZeroConf/mDNS как сервис `_yandexio._tcp`.

### Как найти колонки с ПК:

В Linux (пакет `avahi-utils`):

```sh
avahi-browse -rt _yandexio._tcp
```

Пример ответа:

```text
+   wlan0 IPv4 Yandex-Station-Mini-2-M10FHG010WKX1K  _yandexio._tcp       local
=   wlan0 IPv4 Yandex-Station-Mini-2-M10FHG010WKX1K  _yandexio._tcp       local
   hostname = [yandexmini_2-M10FHG010WKX1K.local]
   address = [192.168.1.120]
   port = [1961]
   txt = ["platform=yandexmini_2" "deviceId=M10FHG010WKX1K"]
```

Из TXT-записи можно сразу извлечь:
* **IP-адрес** и порт подключения (`1961`);
* **Платформу** (`yandexmini_2`, `plum`, `cucumber` и т.д.);
* **Уникальный deviceId** колонки.

---

## 🎙️ Протокол glagol: локальное управление { #glagol }

`glagol` — это встроенный в прошивку WebSocket-сервер с шифрованием TLS на порту **1961**. Он позволяет посылать голосовые команды, менять громкость и управлять медиаплеером **напрямую по локальной сети без облачных задержек**.

### Принцип авторизации:

1. Клиент подключается по `wss://<IP_колонки>:1961/`.
2. Используется самоподписанный TLS-сертификат (проверку валидности сертификата в клиенте отключают).
3. Для авторизации отправляется токен сессии (`conversationToken`), который запрашивается у облака Яндекса по OAuth-токену аккаунта:
   ```http
   GET https://quasar.yandex.net/glagol/token?device_id=<DEVICE_ID>
   Authorization: OAuth <YANDEX_OAUTH_TOKEN>
   ```

### Пример управления на Python:

```python
import asyncio
import json
import ssl
import websockets

DEVICE_IP = "192.168.1.120"
PORT = 1961
TOKEN = "YOUR_GLAGOL_CONVERSATION_TOKEN"

ssl_context = ssl.create_default_context()
ssl_context.check_hostname = False
ssl_context.verify_mode = ssl.CERT_NONE

async def send_command():
    uri = f"wss://{DEVICE_IP}:{PORT}/"
    async with websockets.connect(uri, ssl=ssl_context) as ws:
        # 1. Рукопожатие и авторизация
        auth_msg = {
            "conversationToken": TOKEN,
            "id": "req-1"
        }
        await ws.send(json.dumps(auth_msg))
        resp = await ws.recv()
        print("Auth response:", resp)

        # 2. Отправка голосовой команды (эмуляция фразы)
        command = {
            "vins": {
                "application": {
                    "app_id": "ru.yandex.quasar.app"
                },
                "payload": {
                    "command": {
                        "type": "server_action",
                        "name": "send_text_to_dialog",
                        "payload": {
                            "text": "Алиса, сколько сейчас времени?"
                        }
                    }
                }
            }
        }
        await ws.send(json.dumps(command))
        print("Команда успешно отправлена!")

asyncio.run(send_command())
```

### Доступные локальные действия:

* **Регулировка громкости:** payload `{"type": "set_volume", "volume": 0.5}`.
* **Пауза / Возобновление:** payload `{"type": "player_pause"}` / `{"type": "player_play"}`.
* **Произношение любого текста (TTS):** команда воспроизведения синтезированной речи.

---

## 🔒 Локальный DNS-резолвер `unbound`

В прошивке работает демон `unbound`, привязанный к `127.0.0.1:53`.

Конфигурация форвардинга:
```text
forward-zone:
    name: "."
    forward-addr: 77.88.8.8    # Яндекс DNS (основной)
    forward-addr: 77.88.8.1    # Яндекс DNS (вторичный)
```

**Важное следствие для взлома и изоляции:**  
Даже если роутер раздаёт через DHCP свой DNS, некоторые демоны прошивки могут обращаться напрямую к внешним IP Яндекса `77.88.8.8:53`. Именно поэтому при настройке перехвата на продвинутых роутерах (OpenWrt, MikroTik, iptables) рекомендуется заворачивать весь исходящий трафик с колонки на 53 порт через **DNAT**.
