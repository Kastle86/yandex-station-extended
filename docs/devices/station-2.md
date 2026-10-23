# Станция 2

Розничное имя — **Яндекс Станция 2** (флагман 2-го поколения). SoC — **Amlogic AXG**
(как у [Лайта](station-lite.md)), ядро 4.9, но это «старшая» AXG-модель: вдвое больше
ОЗУ (~490 МБ), 512 МБ NAND, сенсорная панель, Wi-Fi Marvell и USB-C PD.

!!! warning "Путаница кодовых имён"
    В device-tree эта модель называется **`yandex,station-midi`** (model
    «Yandex Station Midi», hostname `…gen2`). Это **не** розничная
    [«Станция Миди»](station-midi.md) — та имеет кодовое имя **Cucumber** на SoC A5.
    То есть внутреннее имя «Midi» принадлежит розничной **Станции 2**, а розничная
    «Станция Миди» — это «Cucumber». Ориентируйтесь на SoC и ОЗУ, а не на слово «Midi».
    И не путайте с [**Станцией Макс**](station-max.md), у которой Android-идентификатор
    `ro.product.device=yandexstation_2` (другое устройство, Android 9).

## Платформа в двух словах

| | |
|---|---|
| SoC | **Amlogic AXG** (`amlogic, axg`) |
| CPU | 4× Cortex-A53 (`0xd03`), до **1.2 ГГц** |
| ОЗУ | **~490 МБ** (MemTotal 501664 kB) — вдвое больше минислушателей |
| Флеш | **NAND Micron 512 МБ SLC** (ID `0x2c 0xdc`, page 4096, erase 256 КБ), UBI |
| Ядро | Linux **4.9.68** aarch64 (сборка 20261013) |
| Userspace | Buildroot **2020.02.1** |
| ЦАП-АЦП мик. | **TLV320ADC3101** (TI, АЦП для микрофонов) |
| Усилитель | **SY6045S** (как у Мини 2) |
| Индикация | LED-дисплей через **Gowin** (`gowin_led_device`) — FPGA/CPLD-контроллер |
| Сенсор касания | `midi_touch` |
| Питание | **USB-C Power Delivery** (`husb238_pd`) |
| Датчик света | **LTR-308** (`0-0x53`) |
| Радио | **Marvell/NXP** (`mlan` + `moal`), BT через `hci_uart` |
| quasar | 3.21 (`0.369.1.46.4778263334.20261013`) |

## Чем отличается от AXG-минислушателей

- **Другой Wi-Fi:** Marvell/NXP (`mlan` + `moal`) — на Лайте/Мини 2 Unisoc, на Мини 1
  Broadcom. BT — через `hci_uart`.
- **Больше ресурсов:** ~490 МБ ОЗУ и **512 МБ NAND Micron** (у минислушателей —
  256 МБ Toshiba).
- **LED-дисплей на Gowin** (`gowin_led_device`) — отдельный FPGA/CPLD-контроллер
  индикации (у Станции 2 — текстово-пиксельная «шторка»), а не прямые sysfs-leds
  (список `/sys/class/leds` пуст).
- **Сенсорная панель** (`midi_touch`).
- **USB-C PD** (`husb238`) и отдельный аудио-**АЦП TLV320ADC3101** для микрофонного
  тракта.

## Карта флеша (MTD)

```
mtd0 "bootloader" 4 MB    mtd1 "tpl" 6 MB     mtd2 "boot" 20 MB
mtd3 "system" 176 MB -> ubi0:rootfs (ubifs, RO)
mtd4 "nv" 1 MB -> /tee (vfat, RO)
mtd5 "bkupgrade" 233 MB -> ubi1 (RW) = /bkupgrade
mtd6 "recovery" 60 MB
```

NAND — **Micron 512 МБ SLC**, page 4096, OOB 128, erase 256 КБ. Разделы заметно
крупнее, чем у минислушателей.

## Шина I2C и периферия

| Шина:адрес | Чип | Назначение |
|---|---|---|
| `0-0x08` | **HUSB238** (husb238_pd) | USB-C Power Delivery |
| `0-0x53` | **LTR-308** | датчик освещённости |
| `0-0x51/0x54/0x55`, `1-0x50` | 24C02 | EEPROM |
| `1-0x18` | **TLV320ADC3101** | аудио-АЦП (микрофоны) |
| `1-0x2a` | **SY6045S** | Class-D усилитель |

## Звук

- ALSA card0 `AML-AUGESOUND`: `TDM-B-sy6045s-hifi` (усилитель),
  `TDM-C-tlv320adc3101-adc` (АЦП микрофонов), `PDM` (микрофоны).

## Вход

- `gpio-keys` — физические кнопки.
- `midi_touch` — сенсорная панель.

## Что ещё проверить

- Протокол **Gowin LED** (`gowin_led_device`) — как выводится на дисплей-«шторку».
- Marvell/NXP Wi-Fi (`mlan`/`moal`) — чип и возможности (monitor/AP).
- Карта регистров TLV320ADC3101 (микрофонный тракт).
- USB-C PD-профили (`husb238`).

---

*Данные для этой страницы собрал **@sharazhniy** — спасибо за вклад! 🙌*
