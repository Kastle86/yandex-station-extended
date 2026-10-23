#!/bin/sh
# qsdmn.sh — управление quasar-стеком на Yandex Station Mini 2 (нужен root)
#
# Команды:
#   stop     — аккуратно остановить quasar: сначала quasar_launcher2
#              (supervisor, который перезапускает maind), затем сами maind.
#              SIGTERM -> ожидание -> SIGKILL только если не вышли.
#   start    — запустить quasar заново (эквивалент /system/vendor/quasar/run.sh
#              с окружением живого лаунчера).
#   restart  — stop + start.
#   reboot   — перезагрузка колонки.
#   status   — показать состояние (только чтение).
#
# Индикация: во время stop и start все светодиоды часов плавно загораются,
# а светодиодное кольцо крутится "кометой" (тёплый белый). По завершении
# всё плавно гаснет; после start часы отдаются platformd (покажет время).
#
# Цепочка запуска (после загрузки лаунчер НИКТО не перезапускает):
#   init -> /etc/init.d/rcS -> S99quasar -> onboot.sh -> run.sh
#        -> quasar_launcher2 /system/vendor/quasar/launch.json
#           -> maind --telemetry / --fluent-bitd / --platformd / --mediad
#              (их лаунчер перезапускает по launch.json)
#
# Пока quasar остановлен: Алиса/микрофон/звуки не отвечают, adbd и Wi-Fi живы.
# Восстановление: qsdmn.sh start (или reboot в худшем случае).

LAUNCHER=/system/vendor/quasar/quasar_launcher2
LAUNCH_CFG=/system/vendor/quasar/launch.json
QDIR=/data/quasar
LOG=$QDIR/launcher2.out
TERM_WAIT=8      # секунд ждём выхода по SIGTERM
KILL_WAIT=4      # секунд ждём выхода после SIGKILL
START_WAIT=40    # секунд ждём появления сервисов после start

# --- Индикация: часы + кольцо ---
LEDB=/sys/class/leds/mini2
CLOCK_MAX=170    # max_brightness часовых каналов
CLOCK_LEDS="A1 A2 A3 A4 B1 B2 B3 B4 C1 C2 C3 C4 D1 D2 D3 D4 E1 E2 E3 E4 \
F1 F2 F3 F4 G1 G2 G3 G4 MINUS DEGREE PLUS1 PLUS2 PLUS3 PLUS4"
SPIN_PID=

led_spin() {
    (
    trap 'exit 0' TERM INT HUP
    for n in 1 2 3 4 5 6; do
        for c in red green blue; do
            echo none > $LEDB:$c:ring$n/trigger 2>/dev/null
        done
    done
    for l in $CLOCK_LEDS; do
        echo none > $LEDB:white:clock$l/trigger 2>/dev/null
    done
    # Часы плавно разгораются (~0.4 c, квадратичное ease-in)
    s=1
    while [ $s -le 8 ]; do
        v=$((CLOCK_MAX * s * s / 64))
        for l in $CLOCK_LEDS; do
            echo $v > $LEDB:white:clock$l/brightness 2>/dev/null
        done
        usleep 45000
        s=$((s + 1))
    done
    # Кольцо: "комета" из 3 LED, полный оборот ~1.7 c, 8 подшагов на LED
    t8=0
    while :; do
        i=0
        while [ $i -lt 6 ]; do
            w=$(( (t8 - i * 8 + 48) % 48 ))
            if [ $w -lt 24 ]; then b=$((255 - w * 255 / 24)); else b=0; fi
            n=$((i + 1))
            echo $b > $LEDB:red:ring$n/brightness 2>/dev/null
            echo $((b * 7 / 8)) > $LEDB:green:ring$n/brightness 2>/dev/null
            echo $((b * 2 / 3)) > $LEDB:blue:ring$n/brightness 2>/dev/null
            i=$((i + 1))
        done
        usleep 35000
        t8=$(( (t8 + 1) % 48 ))
    done
    ) &
    SPIN_PID=$!
}

led_halt() { # led_halt dark|release
    if [ -n "$SPIN_PID" ]; then
        kill $SPIN_PID 2>/dev/null
        wait $SPIN_PID 2>/dev/null
        SPIN_PID=
    fi
    for n in 1 2 3 4 5 6; do
        for c in red green blue; do
            echo 0 > $LEDB:$c:ring$n/brightness 2>/dev/null
        done
    done
    # dark: колонка остаётся без quasar — гасим и часы, плавно.
    # release: quasar поднялся — часы отданы platformd, не трогаем.
    if [ "$1" = dark ]; then
        s=8
        while [ $s -ge 1 ]; do
            v=$((CLOCK_MAX * s * s / 64))
            for l in $CLOCK_LEDS; do
                echo $v > $LEDB:white:clock$l/brightness 2>/dev/null
            done
            usleep 45000
            s=$((s - 1))
        done
        for l in $CLOCK_LEDS; do
            echo 0 > $LEDB:white:clock$l/brightness 2>/dev/null
        done
    fi
}

# PIDs по подстроке в cmdline. Паттерн собирается из двух частей, чтобы
# awk не находил сам себя в выводе ps.
pids_by() {
    ps | awk -v p1="$1" -v p2="$2" -v me="$$" 'index($0, p1 p2) && $1 != me {print $1}'
}

launcher_pids() { pids_by quasar_ launcher2; }
maind_pids()    { pids_by /system/vendor/quasar/ma ind; }

alive() { # alive PID -> 0 если процесс существует
    kill -0 "$1" 2>/dev/null
}

kill_list() { # kill_list TERM|KILL "pid..." — сигнал и ожидание
    sig=$1; shift
    for p in $*; do kill -$sig $p 2>/dev/null; done
    i=0
    while [ $i -lt $KILL_WAIT ]; do
        left=""
        for p in $*; do alive $p && left="$left $p"; done
        [ -z "$left" ] && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

wait_gone() { # wait_gone "pid..." TERM_WAIT
    timeout=$2; i=0
    while [ $i -lt $timeout ]; do
        left=""
        for p in $*; do alive $p && left="$left $p"; done
        [ -z "$left" ] && return 0
        sleep 1
        i=$((i + 1))
    done
    left=""
    for p in $*; do alive $p && left="$left $p"; done
    [ -z "$left" ] && return 0
    return 1
}

# Pid-ы конкретного maind-сервиса; аргумент сервиса тоже разрезан на две
# части, чтобы awk не находил собственную командную строку в выводе ps.
svc_pid() { # svc_pid <часть1> <часть2>, например: svc_pid --plat formd
    ps | awk -v b1="/system/vendor/quasar/ma" -v b2="ind" -v a1="$1" -v a2="$2" \
        'index($0, b1 b2) && index($0, a1 a2) {print $1}'
}

svc_status() {
    for pair in "--tele metry" "--fluent- bitd" "--plat formd" "--me diad"; do
        label=${pair% *}${pair#* }
        p=$(svc_pid ${pair% *} ${pair#* })
        if [ -n "$p" ]; then
            echo "  maind $label  pid $p  [запущен]"
        else
            echo "  maind $label  [НЕ запущен]"
        fi
    done
}

do_status() {
    lp=$(launcher_pids)
    if [ -n "$lp" ]; then
        echo "quasar_launcher2: pid $lp [запущен]"
        svc_status
    else
        echo "quasar_launcher2: [НЕ запущен]"
        mp=$(maind_pids)
        [ -z "$mp" ] && echo "maind: [нет процессов]" || echo "maind остались (осиротели): $mp"
    fi
}

do_stop() {
    led_spin
    # 1) Сначала supervisor — иначе он перезапустит убитых maind.
    lp=$(launcher_pids)
    if [ -z "$lp" ]; then
        echo "quasar_launcher2 не запущен"
    else
        echo "Останавливаю quasar_launcher2 (pid $lp) — SIGTERM"
        kill -TERM $lp 2>/dev/null
        if wait_gone "$lp" $TERM_WAIT; then
            echo "quasar_launcher2 остановлен"
        else
            echo "Не вышли по TERM, добиваю SIGKILL: $lp"
            kill -KILL $lp 2>/dev/null
            kill_list KILL $lp || { echo "ОШИБКА: не удалось убить лаунчер"; led_halt dark; exit 1; }
            echo "quasar_launcher2 убит по SIGKILL"
        fi
    fi

    # 2) Теперь maind-сервисы — их уже некому перезапустить.
    mp=$(maind_pids)
    if [ -z "$mp" ]; then
        echo "maind-процессов нет"
    else
        echo "Останавливаю maind (pid $mp) — SIGTERM"
        kill -TERM $mp 2>/dev/null
        if wait_gone "$mp" $TERM_WAIT; then
            echo "maind остановлен"
        else
            echo "Не все вышли по TERM, добиваю SIGKILL"
            kill -KILL $mp 2>/dev/null
            kill_list KILL $mp || { echo "ОШИБКА: maind не умирает"; led_halt dark; exit 1; }
            echo "maind убит по SIGKILL"
        fi
    fi

    # 3) Контроль.
    lp=$(launcher_pids); mp=$(maind_pids)
    if [ -z "$lp$mp" ]; then
        echo "OK: quasar полностью остановлен. Алиса/микрофон не отвечают."
        led_halt dark
    else
        echo "ВНИМАНИЕ: остались процессы: $lp $mp"
        led_halt dark
        exit 1
    fi
}

do_start() {
    lp=$(launcher_pids)
    if [ -n "$lp" ]; then
        echo "quasar_launcher2 уже запущен (pid $lp)"
        svc_status
        return 0
    fi
    [ -x "$LAUNCHER" ] || { echo "ОШИБКА: нет $LAUNCHER"; exit 1; }
    [ -d "$QDIR" ] || mkdir -p $QDIR
    cd $QDIR || { echo "ОШИБКА: не зайти в $QDIR"; exit 1; }

    # Окружение — как у живого лаунчера (см. /proc/<pid>/environ).
    export CA_CERTIFICATES=/system/vendor/quasar/ca-certificates.crt
    export GST_PLUGIN_PATH=/system/vendor/quasar/libs
    export LD_LIBRARY_PATH=/system/vendor/quasar/libs
    export PATH="/system/vendor/quasar:$PATH"
    ulimit -n 10240
    ulimit -s 1024

    echo "Запускаю quasar_launcher2..."
    led_spin
    setsid $LAUNCHER $LAUNCH_CFG </dev/null >>"$LOG" 2>&1 &
    [ $? -eq 0 ] || { echo "ОШИБКА запуска"; exit 1; }

    i=0
    while [ $i -lt $START_WAIT ]; do
        lp=$(launcher_pids)
        pd=$(svc_pid --plat formd)
        md=$(svc_pid --me diad)
        [ -n "$lp" ] && [ -n "$pd" ] && [ -n "$md" ] && break
        sleep 1
        i=$((i + 1))
    done

    if [ -n "$lp" ]; then
        echo "quasar_launcher2 запущен (pid $lp)"
        svc_status
        led_halt release
        [ -n "$pd" ] && [ -n "$md" ] && echo "OK: quasar работает" \
            || echo "ВНИМАНИЕ: platformd/mediad ещё поднимаются, проверь qsdmn.sh status"
        return 0
    fi
    echo "ОШИБКА: лаунчер не поднялся, смотри $LOG"
    tail -5 "$LOG" 2>/dev/null
    led_halt dark
    exit 1
}

case "$1" in
    stop)    do_stop ;;
    start)   do_start ;;
    restart) do_stop && sleep 1 && do_start ;;
    reboot)
        echo "Перезагружаю колонку..."
        sync
        sleep 1
        /sbin/reboot
        ;;
    status|'') do_status ;;
    *)
        echo "Использование: $0 stop|start|restart|reboot|status" >&2
        exit 2
        ;;
esac
