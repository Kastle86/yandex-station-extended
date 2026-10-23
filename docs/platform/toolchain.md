# Сборка своего софта

Как кросс-компилировать бинарники под станцию.

## Ключевой факт

Ядро **64-битное** (aarch64), а userspace — **32-битный armhf** (glibc 2.30).
Поэтому:

- **статические aarch64-бинарники работают** (запускаются прямо на 64-битном ядре),
  даже несмотря на 32-битный userspace — самый надёжный путь;
- либо собирать под armhf glibc 2.30 (динамика под родной userspace).

## Рецепт: zig как кросс-компилятор

На x86_64-хосте ставим **zig** (standalone, например 0.13.0) и делаем обёртки:

```sh
# zbin/cc, zbin/cxx, zbin/ar, zbin/ranlib
exec zig cc  -target aarch64-linux-musl "$@"     # cc
exec zig c++ -target aarch64-linux-musl "$@"     # cxx
```

musl-статика не тянет зависимостей от хостовой glibc. Для стрипа —
`zig objcopy --strip-all`.

### CMake

Toolchain-файл с:

```cmake
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
# и PKG_CONFIG=/bin/false в окружении,
# чтобы не затянулись хостовые заголовки/библиотеки
```

## Что уже собрано и работает

| Софт | Как |
|---|---|
| `fastfetch` | из git, cmake + zig-toolchain, отключены GPU/Vulkan/Wayland и т.п. |
| `dropbear` (ssh) | из исходников, патч blank-password, статик aarch64/musl |
| `ffmpeg` (минимальный) | статик aarch64/musl, нужные демуксеры/декодеры |
| Node.js | официальный бинарник **armv7l glibc 18.20.5** (Node 20+ требует glibc 2.31 — не пойдёт) |

!!! tip
    Готовые бинарники кладём в `/data/opt/bin` (раздел RW). Запуск через свой
    `S99z…`-скрипт или вручную.
