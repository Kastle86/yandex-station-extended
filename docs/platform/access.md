# Получение доступа

Как получить root-доступ к станции и сделать его устойчивым. Проверено на
[Станции Лайт](../devices/station-lite.md); на других Amlogic-моделях механизмы те же.

## ADB — как включается { #adb }

`activate_adb.sh` + `adb_options.inc`. Логика по **файлам-маркерам** в `/data/quasar`:

```
activate_adb_sound        # включён «звуковой» командой
activate_adb_quasmodrom   # включён через quasmodrom-конфиг (серверно)
activate_adb_glagol       # включён по glagol
activate_network_adb      # adbd по СЕТИ (иначе только USB)
```

`onboot.sh` → `activate_adb.sh check`: если есть любой из первых трёх маркеров —
поднимает adbd; если есть ещё и `activate_network_adb` — adbd по TCP (bare `adbd` =
порт **5555**), иначе USB-gadget (`adb.sh start`).

- Сетевой adbd = `start-stop-daemon -S -b -x adbd` → слушает `0.0.0.0:5555`.
- USB-adb: `adb.sh` конфигурит USB-gadget через **configfs**
  (`/sys/kernel/config/usb_gadget/g1`, VID `0x18d1` Google, PID `0x4e40`,
  функция `ffs.adb`). Через configfs можно добавить другие gadget-функции
  (serial / RNDIS-ethernet / mass-storage).
- root-shell по adb **без авторизации** (сборка `user`, но adbd даёт uid 0).

```sh
adb connect <IP>:5555 && adb shell
```

Включение ADB «с нуля» (когда ещё есть доступ): маркеры ставит серверный
quasmodrom-конфиг, либо их можно создать вручную и поднять adbd, если доступ уже
есть другим путём.

## SSH (dropbear) { #ssh }

ADB зависит от маркеров, которыми управляет облако. Независимый канал — свой
SSH-сервер.

- Собрать статический **dropbear** (aarch64/musl, см.
  [Сборка софта](toolchain.md)), положить в `/data/opt/bin`.
- Патч `svr-authpasswd.c` разрешает вход в аккаунт с пустым паролем (у `root` пароль
  пустой), либо завести ключи.
- Автозапуск — свой `/etc/init.d/S99z…` (после `remount rw`), демонизирует dropbear
  и всегда `exit 0`. Имя `S99z*` → стартует **после** `S99quasar`, так что при сбое
  скрипта adb остаётся как запасной канал.

```sh
ssh -p 2222 root@<IP>        # с пустым паролем — просто Enter
```

!!! tip "Пустой пароль через sshpass"
    `sshpass -p '' ssh -p 2222 root@<IP>`. **Не** `-p ""` через `eval` — туда уйдёт
    литерал `""` как пароль, и аутентификация поведёт себя странно.

## Serial-консоль и `rh_unlock` { #serial }

Getty на UART обёрнут в `getty_rabbit_hole`:

```sh
grep -qwF 'androidboot.rh_unlock=1' /proc/cmdline && exec /sbin/getty "$@" \
  || exec sleep infinity
```

При `rh_unlock=0` (штатно) serial-getty уходит в `sleep infinity` — «кроличья нора».
Чтобы получить root-консоль на UART, нужно `rh_unlock=1` в cmdline (ставится
загрузчиком / unlock-состоянием) — это **официальный dev-unlock** Яндекса. Варианты:

- правка bootargs в U-Boot env (если доступен);
- проще и без риска — свой getty-враппер в rootfs (RW) на нужном tty.

## Отключение OTA { #ota }

Чтобы правки rootfs не откатывались обновлением. Цепочка OTA:

```
maind --updatesd → quasar.yandex.net/check_updates → загрузка с quasar.s3.yandex.net
→ проверка подписи ota_script.pub (RSA PKCS#1) → распаковка → update_script.sh
→ apply_packed_ota → reboot
```

Глушится тремя правками rootfs (после `mount -o remount,rw /`):

1. убрать задачу `updatesd` из `launch.json` (апдейтер не стартует);
2. подменить `ota_script.pub` на чужой ключ (любой OTA провалит подпись — «ремень»);
3. застабить `device_ota_update.sh`.

Делайте это скриптом с бэкапом и возможностью отката (`disable | status | restore`).
Проверено на Лайте: после ребута `--updatesd` не стартует.

## Устойчивый доступ { #durable }

1. **rootfs RW без verity.** `mount -o remount,rw /` → правки `/etc`, `/system`
   переживают ребут (при отключённом OTA).
2. **Фиксация ADB-маркеров.** `chattr +i` на маркеры (ubifs поддерживает) — облако не
   удалит, adbd встаёт каждый boot. (Облако умеет гасить `remoteActivation`.)
3. **Два независимых канала.** SSH (свой, облаку невидим) + ADB (по маркерам). Снесут
   один — остаётся другой.
4. **firewall — каркас, но не фильтрует.** `yio_iptables_init.sh` создаёт цепочки
   `yio_*`, но листовые пустые, policy `ACCEPT` → входящие по факту открыты.

## Инструменты на борту

`devmem` (`CONFIG_DEVMEM=y`, `CONFIG_DEVKMEM=y`), `insmod`/`modprobe` (OOT-модули
грузятся, `tainted=4096`), i2c-tools, `crond`, `wget`, `telnet`, `tftp`.

!!! danger "Чего НЕ трогаем"
    TEE/keymaster (`/dev/tee0`, `/tee` nv) хранит ключи устройства; glagol-ключи — в
    `devices.json`. Их компрометация = потеря доверия устройства в облаке.
