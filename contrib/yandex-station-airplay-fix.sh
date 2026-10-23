#!/usr/bin/env bash
#
# yandex-station-airplay-fix.sh
# Фикс звука AirPlay на Яндекс.Станции (shairport-sync + airplayd + Алиса/quasar)
#
# Какие проблемы лечит:
#   1. AirPlay подключается, но звука нет / звук появляется только после
#      переключения трека. Причина: airplayd падает/зависает в функции часов
#      (time()/localtime_r), перестаёт читать /tmp/sps.fifo, и shairport
#      блокируется на записи в этот fifo.
#   2. Пауза на колонке запускает Яндекс.Музыку. Причина: /dev/input/event1
#      читают одновременно airplayd и quasar (maind --platformd), поэтому
#      кнопка уходит в оба демона.
#
# Что делает скрипт:
#   - патчит airplayd по смещению 7344 (4 байта), убирая вызов time()/localtime_r
#     в функции обновления часов;
#   - ставит хуки shairport: на старте воспроизведения гасит quasar (Алису),
#     на паузе/остановке поднимает обратно. Так кнопки не двоятся, а звук
#     AirPlay не конфликтует с Яндекс.Музыкой;
#   - перезапускает /data/shairport/airplay.sh restart.
#
# Побочный эффект патча airplayd: обновление часов на дисплее может не работать
# (патч убирает чтение времени в функции часов). Если часы важны — запусти
# скрипт с --no-patch, но тогда останется риск зависания airplayd.
#
# Пока играет AirPlay, Алиса выключена (голосовые команды не работают);
# после паузы/остановки она возвращается примерно через 2 секунды.
#
# Известное ограничение: если после возврата Алисы нажать play кнопкой на
# колонке, кнопку могут увидеть оба демона. Надёжнее запускать с телефона.
#
# Проверено на: Я.Станция Мини 3 (bergamot), VERSION 1.0
# (shairport-sync 4.3.7 AirPlay 2 + nqptp 1.2.4).
# На других моделях пути те же; патч airplayd применяется только если байты
# по смещению 7344 совпадают с ожидаемыми.
#
# После переустановки/обновления AirPlay-пакета (airplay.sh setup) конфиг
# создаётся заново без хуков — просто запусти этот скрипт ещё раз.
#
# Требования:
#   - root-доступ по adb;
#   - установленный /data/shairport (airplay.sh, airplayd, ap2/shairport-sync-ap2);
#   - один подключённый adb-девайс либо IP:PORT первым аргументом.
#
# Использование:
#   ./yandex-station-airplay-fix.sh 192.168.1.50:5555
#   ./yandex-station-airplay-fix.sh --status 192.168.1.50:5555
#   ./yandex-station-airplay-fix.sh --uninstall 192.168.1.50:5555
#   ./yandex-station-airplay-fix.sh --with-autostart 192.168.1.50:5555
#   ./yandex-station-airplay-fix.sh --no-patch 192.168.1.50:5555
#   ./yandex-station-airplay-fix.sh --force 192.168.1.50:5555
#
# Флаги:
#   --status         — только показать состояние, ничего не менять;
#   --uninstall      — убрать хуки, вернуть оригинальный airplayd;
#   --with-autostart — прописать автозапуск в /etc/init.d/S99zairplay;
#   --no-patch       — не трогать airplayd, поставить только хуки;
#   --force          — патчить даже при несовпадении байтов (опасно).
#
set -euo pipefail

D=/data/shairport
A=$D/ap2
PATCH_OFFSET=7344
PATCH_WANT=3ce000bf          # "\x3c\xe0\x00\xbf"
PATCH_OLD=3846fef7           # "\x38\x46\xfe\xf7" — оригинал

ADB_BIN=${ADB_BIN:-adb}
SERIAL=""
MODE=install
WITH_AUTOSTART=0
FORCE=0
NO_PATCH=0

usage() {
  # печатаем шапку скрипта до первой строки кода
  awk 'NR == 1 { next }
       /^#/ { sub(/^# ?/, ""); if (NR > 2) print; next }
       { exit }' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --status)          MODE=status ;;
    --uninstall)       MODE=uninstall ;;
    --with-autostart)  WITH_AUTOSTART=1 ;;
    --no-patch)        NO_PATCH=1 ;;
    --force)           FORCE=1 ;;
    -h|--help)         usage; exit 0 ;;
    -*)                echo "Неизвестный параметр: $1" >&2; usage; exit 1 ;;
    *)                 SERIAL=$1 ;;
  esac
  shift
done

adb_() {
  if [ -n "$SERIAL" ]; then
    "$ADB_BIN" -s "$SERIAL" "$@"
  else
    "$ADB_BIN" "$@"
  fi
}

if [ -n "$SERIAL" ] && [[ "$SERIAL" == *:* ]]; then
  "$ADB_BIN" connect "$SERIAL" >/dev/null 2>&1 || true
fi

if [ -z "$SERIAL" ]; then
  COUNT=$("$ADB_BIN" devices | awk 'NR > 1 && $2 == "device" { n++ } END { print n + 0 }')
  if [ "$COUNT" -ne 1 ]; then
    echo "ОШИБКА: найдено adb-устройств: $COUNT. Укажи IP:PORT первым аргументом," >&2
    echo "        например: $0 192.168.1.50:5555" >&2
    exit 1
  fi
fi

echo "==> ждём устройство"
adb_ wait-for-device

if ! adb_ shell id 2>/dev/null | grep -q 'uid=0'; then
  echo "ОШИБКА: нужен root-доступ по adb (adb root)." >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --------------------------------------------------------------- helpers

remote_yes() {
  # Некоторые adbd не пробрасывают код возврата `adb shell`, поэтому
  # проверяем не статус, а вывод удалённой команды.
  [ "$(adb_ shell "if $1; then echo yes; else echo no; fi" 2>/dev/null | tr -d ' \r\n')" = "yes" ]
}

remote_read4() {
  local f=${1:-$D/airplayd}
  local out
  out=$(adb_ shell "dd if=$f bs=1 skip=$PATCH_OFFSET count=4 2>/dev/null | xxd -p" 2>/dev/null | tr -d ' \r\n')
  if [ -z "$out" ]; then
    out=$(adb_ shell "dd if=$f bs=1 skip=$PATCH_OFFSET count=4 2>/dev/null | od -An -tx1" 2>/dev/null | tr -d ' \r\n')
  fi
  if [ -z "$out" ]; then
    out=$(adb_ shell "dd if=$f bs=1 skip=$PATCH_OFFSET count=4 2>/dev/null | hexdump -C" 2>/dev/null | awk 'NR==1 {print $2$3$4$5}')
  fi
  printf '%s' "$out" | tr 'A-F' 'a-f'
}

strip_sessioncontrol() {
  # Убирает блок sessioncontrol = { ... }; (однострочный или многострочный).
  awk '
    {
      if (!skip && $0 ~ /^[[:space:]]*sessioncontrol[[:space:]]*=/) {
        line=$0; d=0
        for (i=1; i<=length(line); i++) {
          c=substr(line,i,1)
          if (c=="{") d++
          else if (c=="}") d--
        }
        if (d > 0) { skip=1; depth=d }
        next
      }
      if (skip) {
        for (i=1; i<=length($0); i++) {
          c=substr($0,i,1)
          if (c=="{") depth++
          else if (c=="}") depth--
        }
        if (depth <= 0) skip=0
        next
      }
      print
    }
  ' "$1" > "$2"
}

write_sessioncontrol() {
  local allow=$1 file=$2
  {
    echo 'sessioncontrol = {'
    echo "  allow_session_interruption = \"$allow\";"
    if [ "$MODE" = "install" ]; then
      echo '  wait_for_completion = "yes";'
      echo "  run_this_before_play_begins = \"$A/on_play.sh\";"
      echo "  run_this_after_play_ends = \"$A/on_stop.sh\";"
    fi
    echo '};'
  } >> "$file"
}

patch_airplayd() {
  if [ "$NO_PATCH" -eq 1 ]; then
    echo "==> патч airplayd пропущен (--no-patch)"
    return
  fi

  echo "==> патч airplayd (offset $PATCH_OFFSET)"
  local cur
  cur=$(remote_read4)

  if [ -z "$cur" ]; then
    echo "    ВНИМАНИЕ: не удалось прочитать байты, патч пропущен."
    return
  fi
  if [ "$cur" = "$PATCH_WANT" ]; then
    # На случай, если патч ставили вручную: сохраним оригинал для --uninstall.
    if ! remote_yes "[ -f $D/airplayd.orig ]"; then
      if remote_yes "[ -f $D/airplayd.bak ]" && [ "$(remote_read4 "$D/airplayd.bak")" = "$PATCH_OLD" ]; then
        adb_ shell "cp $D/airplayd.bak $D/airplayd.orig"
        echo "    создан airplayd.orig из airplayd.bak"
      fi
    fi
    echo "    уже пропатчен, пропускаем"
    return
  fi
  if [ "$cur" != "$PATCH_OLD" ] && [ "$FORCE" -ne 1 ]; then
    echo "    ВНИМАНИЕ: неизвестные байты ($cur) — похоже, другая версия airplayd."
    echo "    Патч пропущен, чтобы не сломать бинарь. Хуки всё равно поставим."
    return
  fi

  if ! remote_yes "[ -f $D/airplayd.orig ]"; then
    adb_ shell "cp $D/airplayd $D/airplayd.orig"
  fi
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  adb_ shell "cp $D/airplayd $D/airplayd.bak.$ts"
  echo "    бэкап: $D/airplayd.bak.$ts"

  # Нельзя писать в работающий бинарь (Text file busy) — останавливаем стек.
  # В конце install скрипт всё равно делает airplay.sh restart.
  echo "    останавливаем AirPlay для патча"
  adb_ shell "$D/airplay.sh stop" || true
  adb_ shell "printf '\\x3c\\xe0\\x00\\xbf' | dd of=$D/airplayd bs=1 seek=$PATCH_OFFSET count=4 conv=notrunc"

  cur=$(remote_read4)
  if [ "$cur" = "$PATCH_WANT" ]; then
    echo "    пропатчен"
  else
    echo "ОШИБКА: патч не применился (получили '$cur')." >&2
    adb_ shell "$D/airplay.sh start" >/dev/null 2>&1 || true
    exit 1
  fi
}

install_helpers() {
  cat > "$TMP/quasar_stop.sh" <<'EOS'
#!/bin/sh
# Fast stop of Alice (quasar): launcher first so nothing respawns, then the rest.
for p in $(ps | grep "[q]uasar_launcher2" | awk '{print $1}'); do
  kill "$p" 2>/dev/null
done
for p in $(ps | grep "[s]ystem/vendor/quasar" | awk '{print $1}'); do
  kill "$p" 2>/dev/null
done
sleep 0.3
for p in $(ps | grep "[s]ystem/vendor/quasar" | awk '{print $1}'); do
  kill -9 "$p" 2>/dev/null
done
EOS

  cat > "$TMP/quasar_start.sh" <<'EOS'
#!/bin/sh
# Restart the Yandex Station stack (Alice) if it is not running.
if ps w | grep -q "[q]uasar_launcher2"; then
  exit 0
fi

echo 1 > /proc/sys/vm/overcommit_memory
ulimit -n 10240
ulimit -s 1024

export LD_LIBRARY_PATH=/system/vendor/quasar:/system/vendor/quasar/libs:$LD_LIBRARY_PATH
export GST_PLUGIN_PATH=/system/vendor/quasar/libs
export PATH=/system/vendor/quasar:$PATH
export CA_CERTIFICATES=/system/vendor/quasar/ca-certificates.crt

cd /data/quasar || exit 1
nohup /system/vendor/quasar/quasar_launcher2 /system/vendor/quasar/launch.json \
  > launcher2.out 2>&1 &
EOS

  cat > "$TMP/on_play.sh" <<'EOS'
#!/bin/sh
# AirPlay playback started: Alice must not see the buttons or touch the mixer.
touch /tmp/sps-airplay-playing
/data/shairport/ap2/quasar_stop.sh
EOS

  cat > "$TMP/on_stop.sh" <<'EOS'
#!/bin/sh
# AirPlay playback stopped/paused: bring Alice back after a short grace period.
rm -f /tmp/sps-airplay-playing
( sleep 2; [ -f /tmp/sps-airplay-playing ] || /data/shairport/ap2/quasar_start.sh ) >/dev/null 2>&1 &
EOS

  echo "==> заливаем helper-скрипты"
  adb_ push "$TMP/quasar_stop.sh"  "$A/quasar_stop.sh"  >/dev/null
  adb_ push "$TMP/quasar_start.sh" "$A/quasar_start.sh" >/dev/null
  adb_ push "$TMP/on_play.sh"      "$A/on_play.sh"      >/dev/null
  adb_ push "$TMP/on_stop.sh"      "$A/on_stop.sh"      >/dev/null
  adb_ shell "chmod 755 $A/quasar_stop.sh $A/quasar_start.sh $A/on_play.sh $A/on_stop.sh"
}

update_config() {
  echo "==> обновляем shairport.conf"
  if ! remote_yes "[ -f $A/shairport.conf ]"; then
    echo "    конфига нет — создаём через airplay.sh setup"
    adb_ shell "$D/airplay.sh setup"
  fi
  adb_ pull "$A/shairport.conf" "$TMP/shairport.conf" >/dev/null

  local allow
  allow=$(sed -n 's/.*allow_session_interruption *= *"\([^"]*\)".*/\1/p' "$TMP/shairport.conf" | head -n1)
  [ -z "$allow" ] && allow=yes

  strip_sessioncontrol "$TMP/shairport.conf" "$TMP/shairport.conf.new"
  write_sessioncontrol "$allow" "$TMP/shairport.conf.new"

  local backup="$A/shairport.conf.bak.$(date +%Y%m%d-%H%M%S)"
  adb_ shell "cp $A/shairport.conf $backup 2>/dev/null || true"
  adb_ push "$TMP/shairport.conf.new" "$A/shairport.conf" >/dev/null
  echo "    бэкап: $backup"
}

install_autostart() {
  echo "==> ставим автозапуск /etc/init.d/S99zairplay"
  adb_ shell "mount -o remount,rw /"
  cat > "$TMP/S99zairplay" <<EOF
#!/bin/sh
case "\$1" in
  start) $D/airplay.sh start ;;
  stop)  $D/airplay.sh stop ;;
esac
EOF
  adb_ push "$TMP/S99zairplay" /etc/init.d/S99zairplay >/dev/null
  adb_ shell "chmod +x /etc/init.d/S99zairplay; mount -o remount,ro /"
}

remove_autostart() {
  echo "==> убираем /etc/init.d/S99zairplay"
  adb_ shell "mount -o remount,rw /"
  adb_ shell "rm -f /etc/init.d/S99zairplay"
  adb_ shell "mount -o remount,ro /"
}

restart_airplay() {
  echo "==> перезапуск AirPlay"
  adb_ shell "rm -f /tmp/sps-airplay-playing"
  adb_ shell "$D/airplay.sh restart"
}

ensure_quasar() {
  adb_ shell "[ -f /tmp/sps-airplay-playing ] || $A/quasar_start.sh"
}

show_status() {
  echo
  adb_ shell "$D/airplay.sh status" || true
  echo
  echo "--- airplayd patch:"
  local cur
  cur=$(remote_read4)
  if [ "$cur" = "$PATCH_WANT" ]; then
    echo "    patched ($cur)"
  elif [ "$cur" = "$PATCH_OLD" ]; then
    echo "    original ($cur)"
  else
    echo "    unknown/empty ($cur)"
  fi
  echo "--- shairport hooks:"
  adb_ shell "grep -E 'run_this_before_play_begins|run_this_after_play_ends' $A/shairport.conf 2>/dev/null || echo '    not installed'"
  echo "--- sps.fifo readers:"
  adb_ shell "for p in /proc/[0-9]*; do ls -l \$p/fd 2>/dev/null | grep -q '/tmp/sps.fifo' && echo \"    pid \${p#/proc/} \$(cat \$p/comm 2>/dev/null)\"; done"
}

# --------------------------------------------------------------- checks

if [ "$MODE" != "status" ]; then
  if ! remote_yes "[ -x $D/airplay.sh ] && [ -f $D/airplayd ] && [ -x $A/shairport-sync-ap2 ] && [ -d $A ]"; then
    echo "ОШИБКА: не найден установленный shairport в $D." >&2
    echo "Сначала установи AirPlay-пакет для Яндекс.Станции." >&2
    exit 1
  fi
fi

# --------------------------------------------------------------- main

case "$MODE" in
  status)
    show_status
    ;;

  install)
    echo "==> версия: $(adb_ shell "cat $D/VERSION 2>/dev/null" | tr -d '\r')"
    install_helpers
    update_config
    [ "$WITH_AUTOSTART" -eq 1 ] && install_autostart
    # Патч делаем последним: он останавливает AirPlay, а следующий шаг его поднимет.
    patch_airplayd
    restart_airplay
    ensure_quasar
    show_status
    ;;

  uninstall)
    echo "==> удаляем хуки и helper-скрипты"

    if remote_yes "[ -f $A/shairport.conf ]"; then
      adb_ pull "$A/shairport.conf" "$TMP/shairport.conf" >/dev/null
      local_allow=$(sed -n 's/.*allow_session_interruption *= *"\([^"]*\)".*/\1/p' "$TMP/shairport.conf" | head -n1)
      [ -z "$local_allow" ] && local_allow=yes
      strip_sessioncontrol "$TMP/shairport.conf" "$TMP/shairport.conf.new"
      write_sessioncontrol "$local_allow" "$TMP/shairport.conf.new"
      adb_ shell "cp $A/shairport.conf $A/shairport.conf.bak.$(date +%Y%m%d-%H%M%S) 2>/dev/null || true"
      adb_ push "$TMP/shairport.conf.new" "$A/shairport.conf" >/dev/null
    else
      echo "    shairport.conf нет — пропускаем"
    fi

    # Вернуть оригинальный airplayd, если он сохранён
    cur=$(remote_read4)
    restore_src=""
    if remote_yes "[ -f $D/airplayd.orig ]"; then
      restore_src=$D/airplayd.orig
    elif remote_yes "[ -f $D/airplayd.bak ]" && [ "$(remote_read4 "$D/airplayd.bak")" = "$PATCH_OLD" ]; then
      restore_src=$D/airplayd.bak
    fi
    if [ "$cur" = "$PATCH_WANT" ] && [ -n "$restore_src" ]; then
      adb_ shell "cp $restore_src $D/airplayd"
      echo "    airplayd восстановлен из $restore_src"
    fi

    restart_airplay

    # Алиса должна подняться, пока quasar_start.sh ещё на месте
    adb_ shell "[ -f /tmp/sps-airplay-playing ] || $A/quasar_start.sh" || true

    adb_ shell "rm -f $A/on_play.sh $A/on_stop.sh $A/quasar_stop.sh $A/quasar_start.sh"
    [ "$WITH_AUTOSTART" -eq 1 ] && remove_autostart
    adb_ shell "$D/airplay.sh status" || true
    ;;

  *)
    echo "Неизвестный режим: $MODE" >&2
    exit 1
    ;;
esac

echo
echo "Готово."
