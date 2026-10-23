# Рецепты и полезные проекты

Практические рецепты настройки, кастомизации и расширения возможностей отрутованной Яндекс Станции.

---

## 🎨 1. Fastfetch с логотипом Алисы и мониторингом { #fastfetch }

Установка современного системного информера `fastfetch` с цветным ASCII-логотипом Алисы, фирменным неоновым фиолетовым цветом (`#7A55FF`) и датчиками температуры процессора.

### Установка бинарника:

Для Amlogic (Лайт, Мини, Мини 2, Миди) используется статическая сборка под `aarch64`:

```sh
mkdir -p /data/opt/bin
# Скопируйте fastfetch с ПК или через wget/curl:
# adb push fastfetch /data/opt/bin/fastfetch
chmod +x /data/opt/bin/fastfetch
```

### Конфигурация (`/data/opt/home/.config/fastfetch/config.jsonc`):

```jsonc
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": {
    "source": "/data/opt/home/.config/fastfetch/alice.txt",
    "type": "file",
    "color": {
      "1": "38;2;122;85;255" // Неоновый фиолетовый Алисы (#7A55FF)
    },
    "padding": {
      "top": 1,
      "right": 3
    }
  },
  "modules": [
    "title",
    "separator",
    "host",
    "os",
    "kernel",
    "uptime",
    "shell",
    {
      "type": "cpu",
      "temp": true
    },
    "memory",
    {
      "type": "disk",
      "folders": ["/", "/data"]
    },
    "localip"
  ]
}
```

### Файл логотипа (`alice.txt`):

Сохраните в `/data/opt/home/.config/fastfetch/alice.txt`:

```text
         @@@@@@@@@@         
       @@@@@@@@@@@@@@       
     @@@@@@@    @@@@@@@     
    @@@@@@        @@@@@@    
   @@@@@@           @@@@@   
  @@@@@              @@@@@  
 @@@@@                @@@@@ 
@@@@@                  @@@@@
@@@@                    @@@@
@@@@                    @@@@
@@@@                    @@@@
@@@@@@@@@          @@@@@@@@@
  @@@@@@@@@@@@@@@@@@@@@@@@@ 
     @@@@@@@@@@@@@@@@@@     
```

### Запуск при входе в терминал:

Чтобы Fastfetch красиво встречал вас при каждом SSH-подключении, добавьте вызов в `/etc/profile`:

```sh
echo '/data/opt/bin/fastfetch' >> /etc/profile
```

---

## 🔑 2. Автономный SSH-сервер (Dropbear) { #dropbear }

Сетевой ADB удобен для первичной настройки, но для постоянной работы лучше использовать полнофункциональный SSH.

### Установка и настройка:

1. Скачайте статический `dropbear` под `aarch64` (или установите через пакетный менеджер `yse install dropbear`).
2. Положите бинарники в `/data/opt/bin/`.
3. Создайте скрипт автозагрузки `/etc/init.d/S99z_dropbear`:

```sh
cat << 'EOF' > /etc/init.d/S99z_dropbear
#!/bin/sh
mount -o remount,rw /

# Создаем каталог для ключей хоста, если его нет
mkdir -p /etc/dropbear

# Генерируем ключи хоста при первом запуске
if [ ! -f /etc/dropbear/dropbear_ed25519_host_key ]; then
    /data/opt/bin/dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key
fi

# Запуск демона на порту 2222 в фоновом режиме с разрешением пустого пароля
/data/opt/bin/dropbear -p 2222 -B -R
exit 0
EOF
chmod +x /etc/init.d/S99z_dropbear
```

### Вход по SSH-ключам (без паролей):

Чтобы входить безопасно и без ввода пароля со своего ПК:

```sh
mkdir -p /data/opt/home/.ssh
# Скопируйте ваш публичный ключ с компьютера:
cat ~/.ssh/id_ed25519.pub >> /data/opt/home/.ssh/authorized_keys
chmod 600 /data/opt/home/.ssh/authorized_keys
```

---

## 🎵 3. Собственное аудио через `gst-launch` { #gst-launch }

В прошивке Яндекс Станции уже встроен полнофункциональный **GStreamer**, управляемый демоном `maind`. Вам не нужно собирать сторонние плееры вроде `ffmpeg` или `mpg123`.

### Воспроизведение интернет-потока (радио):

```sh
maind --gst-launch "souphttpsrc location=http://stream.radiorecord.ru/rr_sync ! decodebin ! audioconvert ! audioresample ! alsasink"
```

### Локальный звуковой файл (WAV / MP3 / OGG):

```sh
maind --gst-launch "filesrc location=/data/sounds/alert.mp3 ! decodebin ! audioconvert ! audioresample ! alsasink"
```

### Синхронный звук между колонками (Мультирум):

Используя родной сетевой клок GStreamer, можно связать воспроизведение на нескольких колонках в одной Wi-Fi сети с точностью до миллисекунд:

```sh
maind --gst-launch --clock 192.168.1.50:8554 ... alsasink
```

---

## 💡 4. Управление кольцевой LED-индикацией { #led-recipes #led }

Формат `.led`-файлов прошивки полностью расшифрован. Колонки используют аппаратные драйверы светодиодов (например, на Станции Лайт — 4 адресных RGB-диода, на Станции 2 и Миди — светодиодные матрицы).

### Прямое управление через sysfs:

Яркостью и отдельными каналами диодов можно управлять напрямую через ядро:

```sh
# Список доступных диодов
ls /sys/class/leds/

# Включить максимальную яркость канала
echo 255 > /sys/class/leds/led1:red/brightness
echo 0 > /sys/class/leds/led1:green/brightness
```

### Проигрывание системных анимаций:

```sh
# Запуск готового светового паттерна
maind --led-pattern /system/vendor/quasar/led/boot.led
```

---

## 🧹 5. Очистка и освобождение места во флеш-памяти { #clean-disk }

На моделях с UBIFS/NAND (например, Станция Лайт) раздел `/data` имеет скромный объём (всего ~20-30 МБ свободно). Чтобы освободить место под установку пакетов Entware и свои скрипты:

```sh
# 1. Очистка логов демонов Яндекса
rm -rf /data/quasar/logs/*
rm -rf /data/logs/*

# 2. Удаление временных бэкапов и крэш-дампов
rm -rf /data/core* /data/tombstones/*

# 3. Проверка остатка свободного места
df -h /data
```

---

## 🌐 6. Подключение Станции к Tailscale / WireGuard { #vpn }

Станция — это компактный маломощный компьютер с постоянным питанием, который идеально подходит на роль **Subnet Router** (шлюза для удаленного доступа в домашнюю сеть).

Собрав легковесный статический `tailscaled` (или установив через `yse install tailscale`):

```sh
tailscaled --state=/data/tailscale.state &
tailscale up --advertise-routes=192.168.1.0/24 --accept-dns=false
```

После этого вы сможете подключаться к своей домашней сети из любой точки мира через Станцию без белого IP и проброса портов на роутере.
