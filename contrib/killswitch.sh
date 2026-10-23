#!/bin/sh
# ==============================================================================
# Yandex Station Lite 1 — Kill Switch / Bunker Mode (Quasar Lockdown)
# Использование:
#   sh killswitch.sh on     <- Включить бункер (отрубить Алису и внешний интернет)
#   sh killswitch.sh off    <- Выключить бункер (воскресить Алису)
#   sh killswitch.sh status <- Проверить текущий статус
# ==============================================================================

LAUNCH_JSON="/system/vendor/quasar/launch.json"
BACKUP_JSON="/data/quasar/launch.json.backup"
FIREWALL_SCRIPT="/etc/init.d/S41firewall_lockdown"

status() {
    if ps | grep -E 'maind|platformd' | grep -v grep >/dev/null 2>&1; then
        echo "[STATUS] Штатный режим: Quasar активен, Алиса подключена к облаку."
    else
        echo "[STATUS] РЕЖИМ БУНКЕРА: Quasar выключен, колонка изолирована от серверов Яндекса."
    fi
}

enable_bunker() {
    echo "[*] Активация Режима Бункера (Kill Switch)..."
    mount -o remount,rw / || { echo "Ошибка remount rw!"; exit 1; }

    # 1. Бэкапим рабочий launch.json, если бэкапа ещё нет
    mkdir -p /data/quasar
    if [ ! -f "$BACKUP_JSON" ] && [ -f "$LAUNCH_JSON" ]; then
        cp -f "$LAUNCH_JSON" "$BACKUP_JSON"
        echo "[+] Бэкап launch.json сохранён в $BACKUP_JSON"
    fi

    # 2. Подменяем launch.json на пустой список задач
    # (quasar_launcher2 остаётся жить для watchdog, но демоны maind/platformd не стартуют)
    cat << 'EOF' > "$LAUNCH_JSON"
{
  "nodes": [
    {
      "name": "main",
      "root": ".",
      "tasks": []
    }
  ]
}
EOF

    # 3. Создаём и включаем аппаратный сетевой экран (WAN Lockdown)
    cat << 'EOF' > "$FIREWALL_SCRIPT"
#!/bin/sh
case "$1" in
  start)
    # Безопасная громкость по умолчанию (35%)
    amixer -c0 set 'Master' 35% >/dev/null 2>&1

    # Разрешаем Loopback и локальные подсети (LAN)
    iptables -I OUTPUT 1 -d 127.0.0.0/8 -j ACCEPT
    iptables -I OUTPUT 2 -d 192.168.0.0/16 -j ACCEPT
    iptables -I OUTPUT 3 -d 10.0.0.0/8 -j ACCEPT
    iptables -I OUTPUT 4 -d 172.16.0.0/12 -j ACCEPT
    # AirPlay / mDNS Bonjour / Broadcast
    iptables -I OUTPUT 5 -d 224.0.0.0/4 -j ACCEPT
    iptables -I OUTPUT 6 -d 255.255.255.255 -j ACCEPT
    # Дропаем весь исходящий интернет (WAN / Яндекс)
    iptables -I OUTPUT 7 -j DROP

    # Входящий трафик (только локалка)
    iptables -I INPUT 1 -s 127.0.0.0/8 -j ACCEPT
    iptables -I INPUT 2 -s 192.168.0.0/16 -j ACCEPT
    iptables -I INPUT 3 -s 10.0.0.0/8 -j ACCEPT
    iptables -I INPUT 4 -s 172.16.0.0/12 -j ACCEPT
    iptables -I INPUT 5 -d 224.0.0.0/4 -j ACCEPT
    iptables -I INPUT 6 -d 255.255.255.255 -j ACCEPT
    iptables -I INPUT 7 -j DROP
    iptables -I FORWARD 1 -j DROP
    ;;
  stop)
    iptables -F
    ;;
esac
EOF
    chmod +x "$FIREWALL_SCRIPT"

    mount -o remount,ro /
    echo "[OK] Режим бункера установлен! Колонка перезагружается в режим изоляции..."
    sync
    reboot
}

disable_bunker() {
    echo "[*] Отключение Режима Бункера и воскрешение Алисы..."
    mount -o remount,rw / || { echo "Ошибка remount rw!"; exit 1; }

    # 1. Восстанавливаем оригинальный launch.json
    if [ -f "$BACKUP_JSON" ]; then
        cp -f "$BACKUP_JSON" "$LAUNCH_JSON"
        echo "[+] Рабочий launch.json восстановлен из бэкапа."
    else
        echo "[!] Предупреждение: Бэкап не найден, используем дефолтный шаблон."
    fi

    # 2. Удаляем файрвол изоляции
    rm -f "$FIREWALL_SCRIPT"
    iptables -F

    mount -o remount,ro /
    echo "[OK] Алиса включена! Колонка перезагружается в штатный режим..."
    sync
    reboot
}

case "$1" in
    on|enable)
        enable_bunker
        ;;
    off|disable)
        disable_bunker
        ;;
    status)
        status
        ;;
    *)
        echo "Использование: sh $0 {on|off|status}"
        exit 1
        ;;
esac