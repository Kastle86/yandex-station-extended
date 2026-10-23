# Пакетный менеджер `yse`

`yse` — лёгкий пакетный менеджер проекта Yandex Station Extended: тонкая обёртка над
**[Entware](https://github.com/Entware/Entware/wiki/Home)** (opkg). Ставит софт в
`/data/opt` (rootfs только для чтения). Сам клиент — один шелл-скрипт **~5 КБ**, без
зависимостей.

```sh
yse bootstrap            # развернуть Entware (один раз)
yse install htop         # поставить пакет
```

## Публичный репозиторий: Entware

Чтобы не собирать пакеты вручную, `yse` опирается на **Entware** — зрелый репозиторий
opkg под embedded ARM (~тысячи пакетов: htop, tmux, nano, mc, python, git…). Он
self-contained: ставится в `/opt`, тащит свой `ld`/glibc/TLS-`wget`, поэтому не зависит
от нашего armhf-userspace.

| Модель | Арка Entware | Доступность |
|---|---|---|
| Лайт, Мини 2, Станция 2, Миди | `aarch64-k3.10` | ✅ (64-бит ядро гоняет self-contained aarch64) |
| Станция Стрит (A1) | `armv7sf-k3.2` | ✅ (32-бит) |
| Станция Макс, gen1 (Android) | — | ❌ (нет root, закрытая загрузка) |

`yse bootstrap` делает:

1. `/opt → /data/opt/entware` (симлинк; rootfs временно `remount,rw` — durable-правка);
2. качает и запускает официальный установщик Entware для нужной арки;
3. `opkg update`.

!!! warning "Нюансы"
    - **Место:** на Лайте в `/data` свободно немного (~15–20 МБ) — следи за объёмом;
      база Entware небольшая, но пакеты копятся.
    - **TLS при bootstrap:** busybox `wget` без TLS. `bin.entware.net` отдаёт установщик
      по http — проверено, работает. После установки сам Entware использует свой
      TLS-`wget`, так что `opkg update/install` по https работают. Если где-то редирект
      на https — задай http-зеркало через `YSE_ENT_MIRROR` или поставь Entware с хоста.
    - **Только root-модели:** на закрытых Android-моделях (Макс/gen1) не применимо.
    - **HOME и shells:** `bootstrap`/установщик задают писабельный `HOME=/data/opt/home`
      (у root домашний каталог на RO-rootfs) и делают `/opt/etc/shells` реальным файлом
      (он симлинкован на RO `/etc/shells`) — иначе интерактивные шеллы (fish/bash/zsh) и
      их postinst-скрипты падают с «Read-only».

## Команды

```sh
yse bootstrap              # развернуть Entware (один раз)
yse update                 # обновить индекс пакетов
yse install <pkg>...       # установить
yse remove  <pkg>...       # удалить
yse list [-a]              # установленные / -a: все доступные
yse search <строка>
yse info <pkg>
yse upgrade                # обновить установленные
yse env                    # строки окружения для текущей сессии
```

Арку можно переопределить через `YSE_ARCH`, зеркало — через `YSE_ENT_MIRROR`.

!!! tip "PATH в текущей сессии (без переподключения)"
    PATH меняется персистентно (`/etc/profile.d/yse.sh`), поэтому новые сессии видят
    `yse` и пакеты автоматически. Дочерний процесс не может изменить окружение текущего
    шелла (ограничение Unix — как `nvm`/`pyenv`/`brew`), поэтому для **текущей** сессии
    без реконнекта:
    ```sh
    eval "$(/data/opt/bin/yse env)"     # как `brew shellenv` / `pyenv init`
    # или одноразово:  . /etc/profile
    ```

## Установка клиента на устройство

Клиент — один шелл-скрипт **~5 КБ**. Проще всего установщиком с ПК (сам зальёт `yse`
по ADB):

```sh
sh install-yse.sh 192.168.1.50        # IP колонки
```

Или вручную:

```sh
adb connect <IP>:5555
adb push yse /data/opt/bin/yse && adb shell chmod +x /data/opt/bin/yse
```

Установщик (и `yse bootstrap`) прописывают **PATH** через `/etc/profile.d/yse.sh`
(rootfs rw), поэтому после установки нужно **зайти по SSH заново** (или `. /etc/profile`)
— и `yse`, и пакеты Entware из `/opt/bin` зовутся без полного пути. Дальше:
`yse bootstrap` → `yse install <pkg>`.

## Удалить

```sh
rm -rf /data/opt/bin/yse /data/opt/entware    # + симлинк /opt (rootfs rw)
```

## Статус

- ✅ клиент v0.3 (bootstrap/update/install/remove/list/search/info/upgrade),
  Entware-бэкенд, проверено на busybox колонки;
- ✅ установщик с ПК (`install-yse.sh`) + архив для раздачи (`yse-install.zip`);
- ⏳ в планах: on-device bootstrap Entware на Лайте, станце-специфичные пакеты.
