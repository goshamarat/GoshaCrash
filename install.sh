#!/bin/sh
# GoshaCrash 0.8.0 hybrid TCP REDIRECT + UDP TUN patch installer
# Target: ASUS RT-AC68U / old stock ASUSWRT with Download Master.
#
# Installs a thin controller wrapper around the currently working GoshaCrash:
#   TCP from LAN -> Mihomo redir-port 7893
#   UDP from LAN -> fwmark 0x2333 -> table 2022 -> mihomo0
#   DNS from LAN -> existing GoshaCrash DNS hijack -> Mihomo 1053
#
# The existing controller is preserved as goshacrash.core.

set -u

TARGET="${1:-/tmp/mnt/GOSHACRASH/goshacrash/goshacrash}"
BASE="$(CDPATH= cd "$(dirname "$TARGET")" 2>/dev/null && pwd)"
CORE="$BASE/goshacrash.core"
CONFIG="$BASE/config.yaml"
RUNTIME="$BASE/runtime.yaml"
VERSION="0.8.0-hybrid-asuswrt"
REDIR_PORT="${GOSHACRASH_REDIR_PORT:-7893}"

say() {
    printf '%s\n' "[GoshaCrash 0.8 installer] $*"
}

fail() {
    printf '%s\n' "[GoshaCrash 0.8 installer:ERROR] $*" >&2
    exit 1
}

[ -f "$TARGET" ] || fail "Контроллер не найден: $TARGET"
[ -d "$BASE" ] || fail "Каталог установки не найден: $BASE"

STAMP="$(date '+%Y%m%d-%H%M%S' 2>/dev/null)"
[ -n "$STAMP" ] || STAMP="backup"
BACKUP="$BASE/goshacrash.before-hybrid-$STAMP"

# Stop the current installation before replacing the command entrypoint.
"$TARGET" stop >/dev/null 2>&1 || true

cp "$TARGET" "$BACKUP" || fail "Не удалось создать резервную копию"
say "Резервная копия: $BACKUP"

# On the first installation preserve the old controller as the core.
# On repeated installations keep the already preserved core.
if [ ! -f "$CORE" ]; then
    cp "$TARGET" "$CORE" || fail "Не удалось сохранить старый контроллер"
fi
chmod 755 "$CORE" || fail "Не удалось выставить права на core"

# Fix the known shell-global-variable PID display bug when this exact line exists.
sed -i \
    -e 's/echo "Mihomo запущен, PID=$p"/echo "Mihomo запущен, PID=$(cat "$PIDFILE" 2>\/dev\/null)"/g' \
    -e 's/echo "Mihomo уже запущен, PID=$p"/echo "Mihomo уже запущен, PID=$(cat "$PIDFILE" 2>\/dev\/null)"/g' \
    "$CORE" 2>/dev/null || true

sh -n "$CORE" || fail "Исходный контроллер повреждён после PID-исправления"

cat > "$TARGET" <<'WRAPPER_EOF'
#!/bin/sh
# BUILD: 2026-07-14-hybrid-redir-tun-080
# GoshaCrash 0.8.0 — TCP REDIRECT + UDP TUN for old stock ASUSWRT.

VERSION="0.8.0-hybrid-asuswrt"

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)"
BASE="${GOSHACRASH_BASE:-$SCRIPT_DIR}"
CORE="$BASE/goshacrash.core"
CONFIG="$BASE/config.yaml"
RUNTIME="$BASE/runtime.yaml"
PIDFILE="$BASE/run/mihomo.pid"

REDIR_PORT="${GOSHACRASH_REDIR_PORT:-7893}"
REDIR_CHAIN="GOSHACRASH_TCP_REDIR"
MANGLE_CHAIN="GOSHACRASH_TUN"
DNS_CHAIN="GOSHACRASH_DNS_HIJACK"
TUN_DEVICE="${GOSHACRASH_TUN_DEVICE:-mihomo0}"
TUN_TABLE="${GOSHACRASH_TUN_TABLE:-2022}"
TUN_MARK="${GOSHACRASH_TUN_MARK:-0x2333}"

PATH="/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin:/opt/sbin:/tmp/opt/bin:/tmp/opt/sbin:$BASE/../asusware.arm/bin:$BASE/../asusware.arm/sbin"
export PATH

say() {
    printf '%s\n' "[GoshaCrash] $*"
}

warn() {
    printf '%s\n' "[GoshaCrash:WARN] $*" >&2
}

fail() {
    printf '%s\n' "[GoshaCrash:ERROR] $*" >&2
    return 1
}

lan_ifaces() {
    if [ -n "${GOSHACRASH_LAN_IFACES:-}" ]; then
        printf '%s\n' "$GOSHACRASH_LAN_IFACES"
        return
    fi

    value="$(nvram get lan_ifname 2>/dev/null)"
    [ -n "$value" ] || value=br0
    printf '%s\n' "$value"
}

ensure_top_level_redir_port() {
    file="$1"
    [ -f "$file" ] || return 0

    temp="$file.hybrid.$$"
    awk -v port="$REDIR_PORT" '
        BEGIN {
            print "redir-port: " port
        }
        /^[^[:space:]#][^:]*:[[:space:]]*/ {
            line=$0
            key=line
            sub(/:.*/, "", key)
            if (key == "redir-port" || key == "routing-mark")
                next
        }
        { print }
    ' "$file" > "$temp" || {
        rm -f "$temp"
        return 1
    }

    mv -f "$temp" "$file" || return 1
}

wait_port() {
    port="$1"
    count=0

    while [ "$count" -lt 15 ]; do
        if netstat -ln 2>/dev/null | grep -Eq "[:.]$port[[:space:]]"; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    return 1
}

hybrid_remove() {
    for iface in $(lan_ifaces); do
        while iptables -t nat -D PREROUTING -i "$iface" -p tcp -j "$REDIR_CHAIN" 2>/dev/null; do :; done
    done

    iptables -t nat -F "$REDIR_CHAIN" 2>/dev/null || true
    iptables -t nat -X "$REDIR_CHAIN" 2>/dev/null || true
}

build_tcp_redirect() {
    iptables -t nat -N "$REDIR_CHAIN" 2>/dev/null || true
    iptables -t nat -F "$REDIR_CHAIN" || return 1

    # DNS is handled by the dedicated DNS hijack chain.
    iptables -t nat -A "$REDIR_CHAIN" -p tcp --dport 53 -j RETURN || return 1

    # Do not intercept router/LAN/private/multicast destinations.
    for network in \
        0.0.0.0/8 \
        10.0.0.0/8 \
        100.64.0.0/10 \
        127.0.0.0/8 \
        169.254.0.0/16 \
        172.16.0.0/12 \
        192.168.0.0/16 \
        224.0.0.0/4 \
        240.0.0.0/4 \
        255.255.255.255/32
    do
        iptables -t nat -A "$REDIR_CHAIN" -d "$network" -j RETURN || return 1
    done

    # Fake-IP 198.18.0.0/16 is intentionally NOT excluded.
    iptables -t nat -A "$REDIR_CHAIN" -p tcp -j REDIRECT --to-ports "$REDIR_PORT" || return 1

    for iface in $(lan_ifaces); do
        while iptables -t nat -D PREROUTING -i "$iface" -p tcp -j "$REDIR_CHAIN" 2>/dev/null; do :; done
        iptables -t nat -I PREROUTING 1 -i "$iface" -p tcp -j "$REDIR_CHAIN" || return 1
    done
}

rebuild_udp_tun_marking() {
    # The core controller has already created route table 2022 and the chain.
    # Rebuild only the classification: TCP returns to REDIRECT; UDP continues to TUN.
    iptables -t mangle -N "$MANGLE_CHAIN" 2>/dev/null || true
    iptables -t mangle -F "$MANGLE_CHAIN" || return 1

    iptables -t mangle -A "$MANGLE_CHAIN" -p udp --dport 53 -j RETURN || return 1
    iptables -t mangle -A "$MANGLE_CHAIN" -p tcp --dport 53 -j RETURN || return 1
    iptables -t mangle -A "$MANGLE_CHAIN" -p tcp -j RETURN || return 1

    for network in \
        0.0.0.0/8 \
        10.0.0.0/8 \
        100.64.0.0/10 \
        127.0.0.0/8 \
        169.254.0.0/16 \
        172.16.0.0/12 \
        192.168.0.0/16 \
        224.0.0.0/4 \
        240.0.0.0/4 \
        255.255.255.255/32
    do
        iptables -t mangle -A "$MANGLE_CHAIN" -d "$network" -j RETURN || return 1
    done

    iptables -t mangle -A "$MANGLE_CHAIN" -j MARK --set-mark "$TUN_MARK" || return 1
}

hybrid_apply() {
    [ -x "$CORE" ] || {
        fail "Не найден исходный контроллер: $CORE"
        return 1
    }

    if ! wait_port "$REDIR_PORT"; then
        fail "Mihomo не слушает redir-port $REDIR_PORT"
        return 1
    fi

    if ! ip route show table "$TUN_TABLE" 2>/dev/null | grep -q "dev $TUN_DEVICE"; then
        fail "Не найден маршрут table $TUN_TABLE -> $TUN_DEVICE"
        return 1
    fi

    hybrid_remove
    build_tcp_redirect || {
        hybrid_remove
        fail "Не удалось установить TCP REDIRECT"
        return 1
    }

    rebuild_udp_tun_marking || {
        hybrid_remove
        fail "Не удалось переключить TUN на UDP-only"
        return 1
    }

    ip route flush cache 2>/dev/null || true
    say "Hybrid включён: TCP -> REDIRECT:$REDIR_PORT; UDP -> mark $TUN_MARK -> table $TUN_TABLE -> $TUN_DEVICE"
}

real_pid() {
    [ -f "$PIDFILE" ] || return 1
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    printf '%s\n' "$pid"
}

show_status() {
    temp="/tmp/goshacrash-status.$$"
    "$CORE" status > "$temp" 2>&1
    rc=$?

    sed "s/^GoshaCrash:.*/GoshaCrash: $VERSION/" "$temp"
    rm -f "$temp"

    if netstat -ln 2>/dev/null | grep -Eq "[:.]$REDIR_PORT[[:space:]]"; then
        echo "TCP: REDIRECT -> $REDIR_PORT"
    else
        echo "TCP: redir-port $REDIR_PORT не слушается"
    fi

    if iptables -t nat -S "$REDIR_CHAIN" >/dev/null 2>&1; then
        echo "Hybrid firewall: работает"
    else
        echo "Hybrid firewall: не установлен"
    fi

    return "$rc"
}

hybrid_test() {
    echo "=== GoshaCrash hybrid test ==="
    show_status
    echo
    echo "=== Ports ==="
    netstat -ln 2>/dev/null | grep -E "(:1053[[:space:]]|:$REDIR_PORT[[:space:]]|:7892[[:space:]]|:9090[[:space:]])" || true
    echo
    echo "=== TCP REDIRECT ==="
    iptables -t nat -L "$REDIR_CHAIN" -n -v --line-numbers 2>/dev/null || true
    echo
    echo "=== UDP TUN marking ==="
    iptables -t mangle -L "$MANGLE_CHAIN" -n -v --line-numbers 2>/dev/null || true
    echo
    echo "=== Policy routing ==="
    ip rule show 2>/dev/null | grep -E "($TUN_MARK|$TUN_TABLE)" || true
    ip route show table "$TUN_TABLE" 2>/dev/null || true
    echo
    echo "Windows test:"
    echo "  curl.exe -v -I --http1.1 --connect-timeout 15 https://example.com"
    echo "  curl.exe -v -I --http1.1 --connect-timeout 15 https://chatgpt.com"
}

run_and_enable_hybrid() {
    ensure_top_level_redir_port "$CONFIG" || return 1
    ensure_top_level_redir_port "$RUNTIME" || return 1

    "$CORE" "$@"
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    hybrid_apply || return 1

    pid="$(real_pid 2>/dev/null)"
    [ -n "$pid" ] && say "Mihomo работает, PID=$pid"
    return 0
}

menu() {
    while :; do
        printf '\033[2J\033[H'
        echo '========================================'
        echo '       GoshaCrash 0.8 Hybrid'
        echo '========================================'
        show_status
        echo
        echo '1) Запустить Mihomo'
        echo '2) Остановить Mihomo'
        echo '3) Перезапустить Mihomo'
        echo '4) Редактировать config.yaml и применить'
        echo '5) Применить config.yaml'
        echo '6) Включить Hybrid-маршрутизацию'
        echo '7) Отключить маршрутизацию'
        echo '8) Показать последние логи'
        echo '9) Полная диагностика'
        echo '10) Показать адрес Zashboard'
        echo '11) Обновить Mihomo и Zashboard'
        echo '12) Установить/проверить nano'
        echo '13) Hybrid-тест'
        echo '0) Выход'
        echo '========================================'
        printf 'Выбери пункт: '
        read choice

        case "$choice" in
            1) "$0" start;;
            2) "$0" stop;;
            3) "$0" restart;;
            4) "$CORE" edit && "$0" apply;;
            5) "$0" apply;;
            6) "$0" hybrid-enable;;
            7) "$0" tun-disable;;
            8) "$CORE" logs 100;;
            9) "$0" doctor;;
            10) "$CORE" dashboard;;
            11) "$0" update;;
            12) "$CORE" install-editor;;
            13) "$0" test;;
            0) return 0;;
            *) echo "Неизвестный пункт";;
        esac

        printf '\nНажми Enter для продолжения...'
        read _dummy
    done
}

[ -x "$CORE" ] || {
    fail "Не найден $CORE"
    exit 1
}

command_name="${1:-menu}"

case "$command_name" in
    menu)
        menu
        ;;

    version)
        echo "$VERSION"
        ;;

    status)
        show_status
        ;;

    start|restart|boot|apply|firewall-reload|tun-enable)
        run_and_enable_hybrid "$@"
        ;;

    hybrid-enable)
        ensure_top_level_redir_port "$CONFIG" || exit 1
        ensure_top_level_redir_port "$RUNTIME" || exit 1
        hybrid_apply
        ;;

    stop)
        hybrid_remove
        "$CORE" stop
        ;;

    tun-disable)
        hybrid_remove
        "$CORE" tun-disable
        ;;

    doctor)
        "$CORE" doctor
        echo
        hybrid_test
        ;;

    test|hybrid-test)
        hybrid_test
        ;;

    update|install)
        "$CORE" "$@"
        rc=$?
        [ "$rc" -eq 0 ] || exit "$rc"
        ensure_top_level_redir_port "$CONFIG" || exit 1
        ensure_top_level_redir_port "$RUNTIME" || exit 1
        hybrid_apply
        ;;

    *)
        "$CORE" "$@"
        ;;
esac
WRAPPER_EOF

chmod 755 "$TARGET" || fail "Не удалось выставить права на новый контроллер"
sh -n "$TARGET" || fail "Новый wrapper содержит синтаксическую ошибку"

# Permanently request the working redir listener in both source and current runtime.
for file in "$CONFIG" "$RUNTIME"; do
    [ -f "$file" ] || continue
    temp="$file.hybrid-install.$$"
    awk -v port="$REDIR_PORT" '
        BEGIN { print "redir-port: " port }
        /^[^[:space:]#][^:]*:[[:space:]]*/ {
            line=$0
            key=line
            sub(/:.*/, "", key)
            if (key == "redir-port" || key == "routing-mark")
                next
        }
        { print }
    ' "$file" > "$temp" || fail "Не удалось изменить $file"
    mv -f "$temp" "$file" || fail "Не удалось сохранить $file"
done

say "Установлен $VERSION"
say "Core: $CORE"
say "Wrapper: $TARGET"
say "TCP REDIRECT port: $REDIR_PORT"
say "Запускаю применение конфигурации..."

GOSHACRASH_BASE="$BASE" "$TARGET" apply || fail "Финальный запуск не удался"

echo
GOSHACRASH_BASE="$BASE" "$TARGET" test