# Режим USB Host (OTG) и подключение периферии

Практическое руководство по переводу порта Type-C Яндекс Станций в режим **USB Host (OTG)**, подключению внешней периферии (USB-аудиокарт, сетевых адаптеров Ethernet, флешек) через активный разветвитель питания и загрузке необходимых модулей ядра.

Все скомпилированные модули ядра (`.ko`) уже подготовлены и доступны для загрузки в папке репозитория:  
👉 **[Каталог модулей `contrib/modules/`](https://github.com/Marker284/yandex-station-extended/tree/main/contrib/modules)**

---

## ⚡ Аппаратные особенности и требования к подключению

1. **Разъём Type-C — это вход питания (Sink / UFP):**
   * На системной плате Станции Лайт нет повышающего преобразователя питания (Boost). Колонка **не умеет выдавать 5V** на разъём Type-C.
   * Если просто воткнуть обычный пассивный OTG-переходник, колонка мгновенно обесточится и выключится.
2. **Как правильно подключать (Обязательное условие):**
   * Для подключения любых USB-устройств требуется **активный USB-C OTG Y-кабель** или **USB-C хаб с поддержкой сквозного питания (Pass-Through Power)**.
   * Блок питания 5V вставляется во вход питания хаба, а сам хаб подключается в порт Type-C Станции. Питание получают и колонка, и периферия, а линии данных D+/D- идут в USB-устройства.

---

## 📦 Скомпилированные модули ядра (Linux 4.9.68 `aarch64`)

В штатном ядре Яндекса драйверы внешних USB-устройств выключены. Мы собрали статические модули с совпадающим вермаджиком (`vermagic=4.9.y SMP preempt mod_unload aarch64`):

### 1. Накопители и флешки (Mass Storage):
* [📥 `usb-storage.ko`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/usb-storage.ko) — драйвер обычных USB-флешек и жестких дисков.
* [📥 `uas.ko`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/uas.ko) — быстрый протокол USB Attached SCSI.

### 2. Внешние звуковые карты и ЦАП:
* [📥 `snd-usb-audio.ko`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/snd-usb-audio.ko) — основной драйвер USB Audio Class 1.0 / 2.0.
* [📥 `snd-hwdep.ko`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/snd-hwdep.ko) — зависимость подсистемы ALSA.
* [📥 `snd-rawmidi.ko`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/snd-rawmidi.ko) / [📥 `snd-usbmidi-lib.ko`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/snd-usbmidi-lib.ko) — поддержка MIDI-устройств.

### 3. Проводные сетевые адаптеры (Ethernet):
* [📥 `usbnet.ko`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/usbnet.ko) + [📥 `mii.ko`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/mii.ko) — базовый сетевой стек USB.
* [📥 `r8152.ko`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/r8152.ko) — адаптеры Realtek RTL8152 / RTL8153 (самые распространенные в USB-хабах).
* [📥 `asix.ko`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/asix.ko) — чипы Asix AX8817x (100 Мбит/с).
* [📥 `ax88179_178a.ko`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/ax88179_178a.ko) — гигабитные чипы Asix AX88179.
* [📥 `cdc_ether.ko`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/cdc_ether.ko) / [📥 `cdc_ncm.ko`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/cdc_ncm.ko) — стандартные CDC-адаптеры и модемы.

---

## 🚀 Установка модулей и переключение режима

### Шаг 1. Переключение контроллера в режим Host (U-Boot)

По умолчанию в загрузчике зашит параметр `otg_device=1`, который принудительно удерживает USB-контроллер в режиме клиента (Slave/Device).

Чтобы разрешить режим Хоста, измените переменную окружения `initargs` в U-Boot:

```sh
# 1. Сделайте бэкап окружения
/usr/bin/fw_printenv > /data/uboot_env_backup.txt

# 2. Выставите otg_device=0
NEW_ARGS="ubi.mtd=system root=ubi0:rootfs rootfstype=ubifs ubi.mtd=bkupgrade otg_device=0 console=ttyS0,115200 no_console_suspend printk_no_block ramoops.pstore_en=1 ramoops.record_size=0x8000 ramoops.console_size=0x4000"
/usr/bin/fw_setenv initargs "$NEW_ARGS"

# 3. Проверьте результат
/usr/bin/fw_printenv initargs
```

### Шаг 2. Загрузка модулей на колонку

Скачайте скомпилированные модули из репозитория и положите их в каталог `/data/modules/`:

```sh
mkdir -p /data/modules
# Скопируйте .ko файлы в /data/modules/
```

### Шаг 3. Настройка автозагрузки модулей при старте

Создайте исполняемый скрипт `/etc/init.d/S98usb_modules` (сделав предварительно `mount -o remount,rw /`):

```sh
cat << 'EOF' > /etc/init.d/S98usb_modules
#!/bin/sh
MOD_DIR="/data/modules"
if [ -d "$MOD_DIR" ]; then
    # Накопители
    insmod $MOD_DIR/usb-storage.ko 2>/dev/null
    insmod $MOD_DIR/uas.ko 2>/dev/null

    # Звук (ALSA USB Audio)
    insmod $MOD_DIR/snd-hwdep.ko 2>/dev/null
    insmod $MOD_DIR/snd-rawmidi.ko 2>/dev/null
    insmod $MOD_DIR/snd-usbmidi-lib.ko 2>/dev/null
    insmod $MOD_DIR/snd-usb-audio.ko 2>/dev/null

    # Сеть (Ethernet)
    insmod $MOD_DIR/mii.ko 2>/dev/null
    insmod $MOD_DIR/usbnet.ko 2>/dev/null
    insmod $MOD_DIR/cdc_ether.ko 2>/dev/null
    insmod $MOD_DIR/r8152.ko 2>/dev/null
    insmod $MOD_DIR/asix.ko 2>/dev/null
    insmod $MOD_DIR/ax88179_178a.ko 2>/dev/null
fi
exit 0
EOF
chmod +x /etc/init.d/S98usb_modules
```

---

## 🎯 Проверка работы периферии

После перезагрузки или ручной загрузки модулей (`/etc/init.d/S98usb_modules`):

* **Проверка флешки:**
  ```sh
  cat /proc/partitions
  # Появится устройство sda / sda1
  mkdir -p /mnt/usb
  mount /dev/sda1 /mnt/usb
  ```
* **Проверка аудиокарты:**
  ```sh
  cat /proc/asound/cards
  # Появится card 1 [USB Audio]: USB-Audio ...
  ```
* **Проверка проводного интернета (Ethernet):**
  ```sh
  ip link
  # Появится интерфейс eth0
  udhcpc -i eth0
  ```
