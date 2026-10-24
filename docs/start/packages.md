# Шаг 3. Пакеты: `yse`

`yse` — маленький шелл-скрипт поверх [Entware](https://github.com/Entware/Entware/wiki/Home)
(opkg): тысячи готовых пакетов для ARM — `htop`, `tmux`, `nano`, `mc`, `python`, `git`,
`exfat-fuse`, `usbutils`… Всё ставится в `/data/opt`, системные файлы не трогаются.

## Установка

С компьютера, из клона репозитория:

```sh
adb push contrib/bin/yse /data/opt/bin/yse
adb shell chmod +x /data/opt/bin/yse
adb shell /data/opt/bin/yse bootstrap
```

`bootstrap` делается один раз: он связывает `/opt` с `/data/opt/entware`, ставит Entware и
прописывает `PATH` в `/etc/profile.d/yse.sh`. Затем **переподключитесь по SSH** — `yse` и
пакеты будут вызываться без полного пути.

```sh
yse install htop
```

## Команды

```sh
yse bootstrap            # развернуть Entware (один раз)
yse update               # обновить список пакетов
yse install <pkg>...     # установить
yse remove  <pkg>...     # удалить
yse search  <строка>     # найти
yse info    <pkg>
yse list [-a]            # установленные / все доступные
yse upgrade              # обновить установленные
eval "$(yse env)"        # PATH для текущей сессии без переподключения
```

Переопределить архитектуру: `YSE_ARCH`, зеркало: `YSE_ENT_MIRROR`.

## Модели

| Модель | Архитектура Entware |
|---|---|
| Лайт, Мини 2, Станция 2, Миди | `aarch64-k3.10` (проверено на Лайт) |
| Стрит | `armv7sf-k3.2` |
| Макс, Станция 1-го поколения | не подходит (Android, нет root) |

!!! note "Место"
    На Лайт под `/data` весь раздел `bkupgrade` — ~87 МБ, из них половина свободна после
    Entware и нескольких пакетов. Смотрите `df -h /data` перед установкой больших пакетов.

## Удалить { #uninstall }

```sh
rm -rf /data/opt/bin/yse /data/opt/entware
mount -o remount,rw / && rm /opt && mkdir /opt && sync && mount -o remount,ro /
```

---

## Как это устроено

- Busybox `wget` на колонке не умеет TLS, поэтому установщик Entware качается по `http`
  с `bin.entware.net`. Дальше Entware пользуется своим `wget` с TLS.
- Entware самодостаточен (свой загрузчик и glibc в `/opt`), поэтому 64-битные пакеты работают,
  хотя системный userspace колонки 32-битный.
- `bootstrap` задаёт записываемый `HOME=/data/opt/home` (домашний каталог root лежит на
  read-only разделе) и превращает `/opt/etc/shells` в обычный файл — иначе установка
  шеллов (`fish`, `bash`, `zsh`) падает с «Read-only file system».

Дальше: **[если что-то сломалось](recovery.md)** · **[рецепты](../recipes/index.md)**.
