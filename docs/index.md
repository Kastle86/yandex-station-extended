# Yandex Station Extended

<p align="center">
  <img src="assets/images/logo.png" alt="YSE Alice Logo" width="160" style="border-radius: 18px; box-shadow: 0 8px 24px rgba(122, 85, 255, 0.4);">
</p>

**Yandex Station Extended (YSE)** — открытая community-база знаний по исследованию, разблокировке и модификации умных колонок Яндекса (семейство «Станций»).

Здесь собраны проверенные практические инструкции: как получить root-доступ без разборки корпуса, отключить принудительные автообновления, настроить автономный SSH, свой звук, LED-индикацию и использовать колонку как домашний сервер.

---

!!! tip "⚡ Быстрый старт: Разблокировка и получение Root по сети"
    Недавно стал доступен универсальный публичный способ получения постоянного ADB через подмену DNS на роутере. Не требует пайки, вскрытия и разборки.  
    👉 **[Пошаговый гайд разблокировки (quasar-unlock)](platform/access.md#dns-unlock)**

---

## 📚 Разделы документации

<div class="grid cards" markdown>

-   :material-speaker: **[Каталог устройств](devices/index.md)**

    Разбор моделей: SoC (Amlogic A113 / A5 / A1), флеш-память (NAND / eMMC), I2C-периферия, драйверы LED и усилителей звука. Матрица поддержки.

-   :material-key: **[Получение доступа](platform/access.md)**

    Разблокировка по сети через DNS, ADB-маркеры, автономный Dropbear SSH, UART-консоль и полное отключение OTA Яндекса.

-   :material-package-variant: **[Пакетный менеджер yse](packages.md)**

    Установка готового софта поверх Entware: `htop`, `tmux`, `python`, `nano`, `git` в `/data/opt` без риска повредить систему.

-   :material-lightbulb-on: **[Рецепты и проекты](projects.md)**

    Свой звук через GStreamer, красивый Fastfetch с логотипом Алисы, LED-нотификаторы, Tailscale-нода, освобождение диска.

-   :material-cog: **[Платформа quasar](platform/architecture.md)**

    Внутреннее устройство прошивки: бинарник `maind`, системные демоны, запуск звукового тракта, библиотеки.

-   :material-hammer-wrench: **[Сборка софта](platform/toolchain.md)**

    Кросс-компиляция статических бинарников под ARM64 (`aarch64-linux-musl`) и ARM32 (`armv7l`).

</div>

---

## 📊 Матрица моделей

| Модель | Кодовое имя | Процессор (SoC) | Платформа | Root / ADB |
|---|---|---|---|:---:|
| **Станция Лайт** | `Micro v1.2` | Amlogic AXG (A113X) | Buildroot / maind | ✅ Доступен |
| **Станция Мини 2** | `station-mini2` | Amlogic AXG (A113X) | Buildroot / maind | ✅ Доступен |
| **Станция Мини (1 пок)** | `yandexmini` | Amlogic AXG | Buildroot / maind | ✅ Доступен |
| **Станция Миди** | `cucumber` | Amlogic A5 (A55) | Buildroot / maind | ✅ Доступен |
| **Станция 2** | `station-midi` *(DT)* | Amlogic AXG | Buildroot / maind | ✅ Доступен |
| **Станция Стрит** | `mango` | Amlogic A1 (A35, 32-bit) | Buildroot / maind | ✅ Доступен |
| **Станция Макс** | `yandexstation_2` | Amlogic (TV-серия) | Android 9 / APK | ⚠️ В исследовании |
| **Станция 1 пок.** | `tulip-d1` | Allwinner R18 | Android / APK | ⚠️ В исследовании |
| **Умный хаб (Saturn)** | `saturn` | Amlogic AXG | Buildroot / maind | ✅ Доступен |

---

## 🤝 Как внести свой вклад

Нашли новую модель, сняли дамп регистров или написали полезный скрипт? Добавить материал можно прямо в браузере за 1 минуту:
на любой странице нажмите кнопку **✏️ (карандаш)** вверху справа и отправьте Pull Request.

Подробнее читайте в разделе **[Как дополнять вики](contributing.md)**.
Репозиторий проекта на GitHub: **[Marker284/yandex-station-extended](https://github.com/Marker284/yandex-station-extended)**.

---

!!! warning "Предупреждение о безопасности"
    Все материалы предназначены исключительно для исследования и модификации **собственных** устройств. Модификация системных разделов может привести к неработоспособности устройства. Персональные данные (приватные ключи из `devices.json`, MAC-адреса, серийные номера и токены) в вики строго запрещены к публикации.
