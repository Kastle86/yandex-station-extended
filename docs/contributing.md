# Как дополнять вики

Вики проекта **Yandex Station Extended** полностью открыта для сообщества. Если вы исследовали свою колонку, сняли дампы или написали полезный скрипт — вы можете легко добавить свой материал.

---

## 🚀 Самый простой способ (прямо в браузере за 1 минуту)

На сайте настроена прямая интеграция с GitHub:

1. Откройте любую статью на сайте **[hackalice.me](https://hackalice.me)**.
2. Вверху справа (под заголовком) нажмите иконку **✏️ (карандаш) — «Редактировать страницу»**.
3. Вас перенаправит в веб-редактор GitHub прямо к нужному `.md`-файлу.
4. Внесите изменения или дополнения.
5. Внизу страницы нажмите **«Propose changes»** (Создать Pull Request).
6. Мы проверим правки, нажмём **Merge**, и сайт автоматически обновится за 15 секунд через GitHub Actions!

---

## Куда добавлять материалы

| Тип материала | Каталог в репозитории |
|---|---|
| Железо конкретной модели (SoC, флеш, I2C, LED, звук) | `docs/devices/<модель>.md` |
| Новая неизученная модель | Создать новый файл в `docs/devices/` и добавить в `mkdocs.yml` |
| Общее по прошивке (quasar, maind, boot, gst-launch) | `docs/platform/architecture.md` |
| Методы доступа (ADB, эксплойты, DNS-подмена, serial) | `docs/platform/access.md` |
| Сеть, порты, glagol, Bluetooth | `docs/platform/network.md` |
| Кросс-компиляция софта под ARM | `docs/platform/toolchain.md` |
| Готовые рецепты, проекты, скрипты | `docs/projects.md` |
| Пакетный менеджер `yse` | `docs/packages.md` |

> **Золотое правило:** Всё, что одинаково для всех Станций на Amlogic, пишется в раздел **«Платформа»**; специфика конкретного корпуса/платы — в **«Устройства»**.

---

## Минимальный набор данных для новой модели

Если у вас на руках модель, которой ещё нет в матрице (например, *Станция Мини 3*, *Станция Дуо Макс*, *Станция Про*):

Подключитесь по `adb shell` и снимите диагностику одной командой:

```sh
echo "=== MODEL & KERNEL ==="
cat /proc/device-tree/model
uname -a
echo "=== CPU ==="
cat /proc/cpuinfo | grep -E 'processor|part|Hardware|model name'
echo "=== MEMORY & STORAGE ==="
cat /proc/meminfo | head -2
cat /proc/mtd
df -h
echo "=== I2C & PERIPHERY ==="
ls /sys/bus/i2c/devices/
ls /sys/class/leds/
cat /proc/asound/cards
echo "=== QUASAR VERSION ==="
cat /system/vendor/quasar/VERSION 2>/dev/null
```

Откройте [Issue в репозитории](https://github.com/Marker284/yandex-station-extended/issues) или создайте Pull Request — мы оформим эти данные в красивую страницу устройства!

---

## 🔒 Что категорически НЕ публикуется:

В целях безопасности и приватности авторов в статьях **запрещено** указывать:
* Приватные ключи устройства (`/data/quasar/devices.json`: `server_private_key`, `secret`);
* Реальные MAC-адреса, серийные номера и персональные `device-id`;
* OAuth-токены аккаунтов Яндекса;
* Пароли, Wi-Fi SSID и домашние координаты.

*(Заменяйте серийники и токены на `<DEVICE_ID>` / `<REDACTED>`)*.

---

## 💻 Локальный запуск (для разработчиков документации)

Если вы хотите клонировать репозиторий и просматривать правки локально:

```sh
git clone https://github.com/Marker284/yandex-station-extended.git
cd yandex-station-extended
python3 -m venv venv
./venv/bin/pip install -r requirements.txt
./venv/bin/mkdocs serve
```
Сайт с live-reload откроется на `http://127.0.0.1:8000`.
