# Сборка своего софта под Станцию

Руководство по кросс-компиляции и сборке статических бинарников для процессоров Amlogic и Allwinner в умных колонках Яндекс.

---

## 💡 Архитектурный парадокс прошивки

На большинстве современных Станций (Лайт, Мини 2, Станция 2, Миди):

* **Ядро Linux — 64-битное (`aarch64`, ARMv8-A).**
* **Системное окружение (Userspace) — 32-битное (`armhf`, glibc 2.30).**

### Что из этого следует:

1. **Статическая сборка под `aarch64-linux-musl` — лучший путь:**
   Поскольку ядро поддерживает 64-битный режим, полностью статические бинарники `aarch64` исполняются ядром напрямую и на 100% независимы от старых системных библиотек в `/lib` и `/usr/lib`.
2. **Динамическая сборка под `armhf` (32-бит):**
   Если программе обязательно нужны системные библиотеки прошивки (например, GStreamer, ALSA, D-Bus), её необходимо компилировать 32-битным тулчейном с привязкой к **glibc не новее 2.30**.
   *(Именно поэтому готовый Node.js 18.20.5 запускается штатно, а Node.js 20+ падает с ошибкой `version GLIBC_2.31 not found`)*.

---

## 🛠️ Сборка через Zig (рекомендуемый инструмент)

[Zig](https://ziglang.org/) содержит встроенные кросс-компиляторы под все архитектуры и готовую библиотеку `musl`. Это позволяет собирать программы под ARM без установки гигабайтных кросс-тулчейнов.

### 1. Настройка псевдо-компиляторов

Создайте скрипты-обёртки на вашем компьютере (например, в каталоге `~/zbin`):

```sh
mkdir -p ~/zbin

# ~/zbin/aarch64-cc
cat << 'EOF' > ~/zbin/aarch64-cc
#!/bin/sh
exec zig cc -target aarch64-linux-musl "$@"
EOF

# ~/zbin/aarch64-cxx
cat << 'EOF' > ~/zbin/aarch64-cxx
#!/bin/sh
exec zig c++ -target aarch64-linux-musl "$@"
EOF

chmod +x ~/zbin/aarch64-cc ~/zbin/aarch64-cxx
export PATH="$HOME/zbin:$PATH"
```

Для 32-битной Станции Стрит (SoC Amlogic A1 / Mango) используйте таргет:
```text
-target arm-linux-musleabihf
```

---

### 2. Кросс-компиляция проектов на CMake

Создайте файл описания тулчейна `toolchain-aarch64.cmake`:

```cmake
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(CMAKE_C_COMPILER zig;cc;-target;aarch64-linux-musl)
set(CMAKE_CXX_COMPILER zig;c++;-target;aarch64-linux-musl)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
```

Пример сборки любого проекта:

```sh
cmake -B build -DCMAKE_TOOLCHAIN_FILE=toolchain-aarch64.cmake -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
```

После компиляции уменьшите размер бинарника утилитой strip:
```sh
zig objcopy --strip-all build/my_program
```

---

## 📦 Уже проверенные и работающие утилиты

| Программа | Архитектура | Способ сборки | Примечания |
|---|---|---|---|
| **Fastfetch** | `aarch64` | `zig cc` + CMake | Отключены Vulkan, Wayland, X11. Работает быстро, выводит ASCII-лого. |
| **Dropbear (SSH)** | `aarch64` | `zig cc` + configure | Патч на пустой пароль, статика ~400 КБ. |
| **FFmpeg (lite)** | `aarch64` | `musl-cross-make` | Минимальная статика под аудио (MP3/AAC/OGG/Opus). |
| **Node.js** | `armv7l` (32-bit) | Официальный тарбол | Версия **18.20.5** (последняя под glibc 2.30). |
| **htop / tmux / nano** | `aarch64` / `armv7` | Установка через `yse` | Ставятся из репозитория Entware в `/data/opt/bin`. |

---

## 🚀 Заливка и запуск на колонке

Все собранные бинарники и библиотеки должны размещаться в доступном для записи разделе `/data`:

```sh
# 1. Загрузка файла по ADB
adb connect <IP_колонки>:5555
adb push my_program /data/opt/bin/
adb shell chmod +x /data/opt/bin/my_program

# 2. Проверка запуска
adb shell /data/opt/bin/my_program
```

Если утилите требуются собственные конфиги или базы данных, создавайте их в `/data/opt/etc/` или `/data/opt/home/`.
