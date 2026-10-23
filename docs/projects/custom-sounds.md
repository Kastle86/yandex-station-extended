# Кастомные системные звуки и звук включения (Mac Chime)

Руководство по замене системных звуков отклика Алисы, сигналов успешной настройки и добавлению легендарного звука запуска Mac при старте Станции.

Все необходимые аудиофайлы уже подготовлены и доступны в репозитории:
* 🍎 **[mac-startup-chime-t2.mp3](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/packages/mac-startup-chime-t2.mp3)** — оригинальный звук включения Apple Mac (чип T2).

---

## 📁 Где хранятся системные звуки

В прошивке `quasar` все встроенные сигналы находятся по пути:
```text
/system/vendor/quasar/sounds/
```

### Ключевые системные файлы:

| Имя файла | Назначение |
|---|---|
| **`seam_activation_feedback_*.opus`** | Звуковой сигнал активации («дзынь» при обращении к Алисе). Нумерация от `1` до `9`. |
| **`configure_success_update.wav`** | Звуковой сигнал успешного завершения настройки или обновления. |
| **`bluetooth_turning_blocked_by_subscription.opus`** | Фраза-предупреждение при блокировке по подписке Яндекс Плюс. |
| **`mute_mic.opus`** / **`unmute_mic.opus`** | Звуки нажатия кнопки отключения микрофонов. |

---

## 🎵 Формат аудиофайлов и конвертация

Система использует контейнер **Ogg Opus** (`.opus`) с фиксированной частотой дискретизации **48 000 Гц**:

```sh
# Конвертация любого MP3 или WAV в формат прошивки:
ffmpeg -i your_sound.mp3 -c:a libopus -ar 48000 -ac 1 -b:a 64k custom_feedback.opus
```

---

## 🍎 Рецепт: Звук запуска Mac при включении Станции

Чтобы колонка при каждой загрузке питания приветствовала вас сочным аккордом Apple Mac Chime:

### 1. Загрузка файла на колонку
Загрузите подготовленный MP3-файл через ADB:

```sh
adb connect <IP_колонки>:5555
adb shell "mkdir -p /data/sounds"
adb push contrib/packages/mac-startup-chime-t2.mp3 /data/sounds/chime.mp3
```

### 2. Встраивание в скрипт автозагрузки
Отредактируйте скрипт запуска Quasar (перемонтировав rootfs в RW):

```sh
adb shell
mount -o remount,rw /

# Добавляем воспроизведение звука в самое начало /system/vendor/quasar/onboot.sh:
sed -i '2i /system/vendor/quasar/maind --gst-launch "filesrc location=/data/sounds/chime.mp3 ! decodebin ! audioconvert ! audioresample ! alsasink" &' /system/vendor/quasar/onboot.sh
```

Теперь при каждой подаче питания Станция будет воспроизводить узнаваемый звук запуска Mac еще до полной загрузки голосового ассистента!

---

## 🔇 Замена звуков отклика Алисы

Если вам надоел стандартный «колокольчик» при вызове Алисы:

1. Перемонтируйте раздел: `mount -o remount,rw /`.
2. Замените файлы активации вашим подготовленным `.opus` файлом:
   ```sh
   for i in $(seq 1 9); do
       cp /data/sounds/custom_feedback.opus /system/vendor/quasar/sounds/seam_activation_feedback_${i}.opus
   done
   ```
3. Изменения вступают в силу мгновенно без перезагрузки колонки.
