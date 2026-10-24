# Станция (1-е поколение)

Розничное имя — **Яндекс Станция** (большая, первое поколение, 2018). Это **другая
аппаратная платформа**, не как у минислушателей: **Allwinner R18** + **Android 6.0.1**
(а не Amlogic + Buildroot). Полноценный медиацентр с **HDMI-выходом**.

!!! info "Две платформы в семействе"
    Станции делятся как минимум на два мира:

    - **Amlogic AXG + Buildroot + quasar/maind** — [Лайт](station-lite.md),
      [Мини 2](station-mini2.md), [Мини](station-mini.md);
    - **Allwinner + Android + quasar как APK** — эта модель (и другие ТВ-ориентированные).

    Многие приёмы из раздела [«Как это устроено»](../internals/architecture.md) (maind-демоны,
    `gst-launch`, init.d) к Android-платформе **не применимы** напрямую — там Android
    и APK. Общее — протокол **glagol** (`:1961`).

## Платформа в двух словах

| | |
|---|---|
| SoC | **Allwinner R18** (`sun50iw1`), board `tulip-d1` |
| ОС | **Android 6.0.1** (SDK 23), ABI `arm64-v8a` |
| CPU | 4× Cortex-A53 (`0xd03`), до **1.344 ГГц** (480…1344 МГц) |
| ОЗУ | **~980 МБ** (1002756 kB) |
| Видео | **HDMI 1920×1080** (медиацентр) |
| ЦАП / усилитель | **2× TAS5751M** (I2S, стерео) |
| PMIC | AXP81x |
| Прошивка quasar | 3.21, как Android-APK `ru.yandex.quasar.app` |
| Безопасность | **dm-verity** (`verity_block`), SELinux `permissive` |
| Кодовое имя | `tulip-d1` / platform `yandexstation` |

## Чем принципиально отличается

- **SoC Allwinner R18** (ARM+Android), а не Amlogic+Buildroot. Соответственно — всё
  дерево `sunxi_*` драйверов (`sunxi_daudio`, `sunxi_sndhdmi`, `sunxi-ths` и т.д.).
- **Полный Android 6** со своим init, SELinux, `/system/priv-app`, и **quasar — это
  APK** (`ru.yandex.quasar.app`, `/system/priv-app/Quasar-Webmusic`), а не нативный
  `maind`-стек (хотя нативные роли `--platformd/--mediad` тоже присутствуют).
- **HDMI-выход** и звук по HDMI (`sndhdmi`) — модель задумана как ТВ-приставка-колонка.
- **Стерео** на двух усилителях **TAS5751M** (`1-0x2a`, `1-0x2b`).
- **dm-verity включён** (`verity_block`) — rootfs подписан; durable-правки системного
  раздела сложнее, чем на Buildroot-моделях без verity.

## Разметка (Android-партиции)

```
bootloader, env, boot, system, verity_block, misc, recovery, cache, metadata,
private, frp, rescue, tinaos, rback, secret, alog, lback, rboot, media_data, UDISK(/data)
```

`verity_block` — dm-verity для `system`; `tinaos` — Allwinner Tina (recovery-мир);
`frp` — factory reset protection; `UDISK` → `/data`.

## I2C / звук

| Шина:адрес | Чип | Назначение |
|---|---|---|
| `1-0x2a` | **TAS5751M** | Class-D усилитель (канал 1) |
| `1-0x2b` | **TAS5751M** | Class-D усилитель (канал 2) |

ALSA-карты: `audiocodec`, `snddaudio1 (TAS5751)`, `snddaudio0`, `sndhdmi`,
`Loopback`. Входы: `axp81x-supplyer` (PMIC), `audiocodec sunxi Audio Jack`,
`sunxi-ths` (термодатчик).

## Доступ

- **ADB** — обычный Android adb (`:5555`); root — по-андроидному (зависит от сборки,
  SELinux `permissive` помогает).
- **glagol** — тот же локальный API на `:1961` (WebSocket/TLS), как на всех Станциях.
- Энтузиасты ставят свои бинарники в `/data/local/bin` (Android-путь) — например,
  `zsh`, `fastfetch`; можно поднять свой dropbear-SSH.

## Что ещё проверить

- Способ получить root и влияние SELinux-политики.
- Обход/отключение OTA на Android-платформе (механизм иной, чем `maind --updatesd`).
- Полная карта разделов и формат прошивки Allwinner (Tina/`tinaos`).
