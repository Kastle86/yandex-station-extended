#!/bin/sh
# spoof_alice_pro_led.sh — переключение LED-подсветки Алисы в стиль «Алиса Про» (бирюзово-фиолетовый градиент)
# с возможностью безопасного отката (restore) в исходное состояние.
#
# Использование:
#   sh spoof_alice_pro_led.sh          # включить анимации Алисы Про
#   sh spoof_alice_pro_led.sh enable   # включить анимации Алисы Про
#   sh spoof_alice_pro_led.sh restore  # вернуть заводские фиолетовые анимации
#   sh spoof_alice_pro_led.sh status   # проверить текущее состояние

set -u

PDIR="/system/vendor/quasar/ledpatterns"
BDIR="/data/opt/backup/ledpatterns"

say() { echo "[*] $*"; }
err() { echo "[!] $*" >&2; }
need_root() { [ "$(id -u)" = 0 ] || { err "Требуются права root"; exit 1; }; }
rw() { mount -o remount,rw / 2>/dev/null || { err "Не удалось перемонтировать / в rw"; exit 1; }; }
ro() { sync; mount -o remount,ro / 2>/dev/null; }

restart_maind() {
  say "Перезапуск maind для применения новых паттернов..."
  killall -HUP maind 2>/dev/null || killall maind 2>/dev/null || true
  sleep 2
  say "Готово! maind перезапущен."
}

do_status() {
  echo "=== Состояние LED-анимаций Алисы ==="
  if [ ! -f "$PDIR/alice_listening.led" ] || [ ! -f "$PDIR/alice_pro_listening.led" ]; then
    err "Файлы анимаций не найдены в $PDIR"
    return 1
  fi

  if cmp -s "$PDIR/alice_listening.led" "$PDIR/alice_pro_listening.led"; then
    echo "  Текущий режим : [АЛИСА ПРО] (бирюзово-фиолетовый градиент)"
    echo "  Спуф          : АКТИВЕН"
  else
    echo "  Текущий режим : [СТАНДАРТНАЯ АЛИСА] (монохромный фиолетовый)"
    echo "  Спуф          : ВЫКЛЮЧЕН"
  fi

  if [ -d "$BDIR" ] && [ -f "$BDIR/alice_listening.led.orig" ]; then
    echo "  Бэкап         : ЕСТЬ ($BDIR)"
  else
    echo "  Бэкап         : ЕЩЁ НЕ СОЗДАВАН"
  fi
}

do_enable() {
  need_root
  mkdir -p "$BDIR" || { err "Не удалось создать папку бэкапа $BDIR"; exit 1; }

  # Создаем бэкап оригиналов только если файлы еще не подменены
  if ! cmp -s "$PDIR/alice_listening.led" "$PDIR/alice_pro_listening.led"; then
    say "Создание резервной копии оригинальных паттернов в $BDIR..."
    cp "$PDIR/alice_listening.led" "$BDIR/alice_listening.led.orig"
    cp "$PDIR/alice_speaking.led"  "$BDIR/alice_speaking.led.orig"
    cp "$PDIR/alice_thinking.led"  "$BDIR/alice_thinking.led.orig"
  else
    say "Файлы уже подменены, существующий бэкап сохранён."
  fi

  rw
  say "Подмена анимаций на стиль «Алиса Про»..."
  cp -f "$PDIR/alice_pro_listening.led" "$PDIR/alice_listening.led"
  cp -f "$PDIR/alice_pro_speaking.led"  "$PDIR/alice_speaking.led"
  cp -f "$PDIR/alice_pro_thinking.led"  "$PDIR/alice_thinking.led"
  ro

  restart_maind
  echo
  say "Спуф успешно включен! Теперь колонка светится стилем Алисы Про."
}

do_restore() {
  need_root
  if [ ! -f "$BDIR/alice_listening.led.orig" ]; then
    err "Файлы бэкапа не найдены в $BDIR!"
    exit 1
  fi

  rw
  say "Восстановление оригинальных паттернов из бэкапа..."
  cp -f "$BDIR/alice_listening.led.orig" "$PDIR/alice_listening.led"
  cp -f "$BDIR/alice_speaking.led.orig"  "$PDIR/alice_speaking.led"
  cp -f "$BDIR/alice_thinking.led.orig"  "$PDIR/alice_thinking.led"
  ro

  restart_maind
  echo
  say "Откат завершен! Восстановлена стандартная фиолетовая подсветка."
}

case "${1:-enable}" in
  enable|on)
    do_enable
    ;;
  restore|disable|off)
    do_restore
    ;;
  status)
    do_status
    ;;
  *)
    echo "Использование: $0 [enable|restore|status]"
    exit 1
    ;;
esac
