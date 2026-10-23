# Как дополнять вики

Вики наполняется материалом сообщества. Можно просто прислать Markdown — он будет
разложен по нужным разделам.

## Куда что идёт

| Тип материала | Раздел |
|---|---|
| Железо конкретной модели (SoC, флеш, I2C, LED, звук) | `docs/devices/<модель>.md` |
| Общее по прошивке (quasar, maind, boot, gst-launch) | `docs/platform/architecture.md` |
| Способы доступа (ADB, SSH, serial, OTA, durable) | `docs/platform/access.md` |
| Сеть, порты, glagol, Bluetooth | `docs/platform/network.md` |
| Кросс-сборка бинарников | `docs/platform/toolchain.md` |
| Готовый приём/проект/скрипт | `docs/projects.md` |

Правило: **одинаковое для всех Amlogic-станций → в «Платформу»; специфичное для
модели → в «Устройства»**.

## Формат присылаемого Markdown

Не нужно оформлять идеально — важнее факты и как они получены. Минимум:

- какая модель и версия прошивки (`/system/vendor/quasar/VERSION`,
  `cat /proc/device-tree/model`);
- команды, которыми снято (чтобы можно было воспроизвести);
- вывод как есть (dmesg-строки, `/proc/mtd`, список i2c и т.п.) — отформатирую сам.

Пример заголовка материала:

```markdown
## Станция Мини 3 — карта флеша
Модель: <model>, quasar <версия>
Снято: `cat /proc/mtd`
<вывод>
```

## Что НЕ публикуем

- приватные ключи (`/data/quasar/devices.json`: `server_private_key`, `secret`);
- MAC-адреса, серийные номера, `device-id`, OAuth-токены;
- координаты/адрес, SSID и хеши Wi-Fi, e-mail аккаунта.

Если в выводе команды есть такие данные — замазывайте перед отправкой (или скажите,
и я вычищу при вёрстке).

## Минимальный набор для новой модели

```sh
uname -a
cat /proc/device-tree/model
cat /proc/cpuinfo | grep -E 'processor|part|Hardware'
cat /proc/meminfo | head -1
cat /proc/mtd
cat /proc/mounts
ls /sys/bus/i2c/devices/
cat /system/vendor/quasar/VERSION
ls /sys/class/leds/
cat /proc/asound/cards
```

Этого хватит, чтобы завести страницу устройства и строку в
[матрице поддержки](devices/index.md#support-matrix).

## Локально посмотреть правки

```sh
cd ~/yandex-wiki
./venv/bin/mkdocs serve -a 127.0.0.1:8000     # live-reload
```

Структура навигации — в `mkdocs.yml` (`nav:`). Деплой на прод — см. `DEPLOY.md`.
