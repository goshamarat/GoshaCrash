#!/bin/sh
# Безопасный тест DNS Mihomo на порту 53.
# Исходный config.yaml не изменяется. В runtime.yaml TUN временно отключается.

BASE="$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)"
CTL="$BASE/goshacrash"
BIN="$BASE/bin/mihomo"
SOURCE_CONFIG="$BASE/config.yaml"
RUNTIME_CONFIG="$BASE/runtime.yaml"
STATE_DIR="$BASE/state"
BACKUP_DIR="$BASE/backups"
DNSMASQ_ADD="/jffs/configs/dnsmasq.conf.add"
DNS_MODE_FILE="/jffs/addons/goshacrash/dns.mode"
MARK_BEGIN="# GOSHACRASH_DNS_TEST_BEGIN"
MARK_END="# GOSHACRASH_DNS_TEST_END"

say() { printf '%s\n' "[GoshaCrash DNS test] $*"; }
fail() { printf '%s\n' "[GoshaCrash DNS test:ERROR] $*" >&2; exit 1; }

restart_dnsmasq() {
    service restart_dnsmasq >/dev/null 2>&1 && return 0
    rc_service restart_dnsmasq >/dev/null 2>&1 && return 0
    return 1
}

remove_managed_block() {
    input="$1"
    output="$2"

    awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
        $0 == begin { skip = 1; next }
        $0 == end   { skip = 0; next }
        !skip       { print }
    ' "$input" > "$output"
}

restore_after_error() {
    say "Возвращаю предыдущие настройки"
    "$CTL" stop >/dev/null 2>&1 || true

    if [ -f "$STATE_DIR/runtime.before-dns-test.yaml" ]; then
        cp "$STATE_DIR/runtime.before-dns-test.yaml" "$RUNTIME_CONFIG" 2>/dev/null || true
    elif [ -f "$STATE_DIR/runtime.did-not-exist" ]; then
        rm -f "$RUNTIME_CONFIG"
    fi

    mkdir -p /jffs/configs /jffs/addons/goshacrash 2>/dev/null || true

    if [ -f "$STATE_DIR/dnsmasq.conf.add.before-dns-test" ]; then
        cp "$STATE_DIR/dnsmasq.conf.add.before-dns-test" "$DNSMASQ_ADD" 2>/dev/null || true
    elif [ -f "$STATE_DIR/dnsmasq.conf.add.did-not-exist" ]; then
        rm -f "$DNSMASQ_ADD"
    fi

    if [ -f "$STATE_DIR/dns.mode.before-dns-test" ]; then
        cp "$STATE_DIR/dns.mode.before-dns-test" "$DNS_MODE_FILE" 2>/dev/null || true
    else
        printf '%s\n' none > "$DNS_MODE_FILE" 2>/dev/null || true
    fi

    restart_dnsmasq >/dev/null 2>&1 || true
}

[ -x "$CTL" ] || fail "Не найден исполняемый $CTL"
[ -x "$BIN" ] || fail "Не найден Mihomo: $BIN"
[ -f "$SOURCE_CONFIG" ] || fail "Не найден $SOURCE_CONFIG"

mkdir -p "$STATE_DIR" "$BACKUP_DIR" /jffs/configs /jffs/addons/goshacrash ||
    fail "Не удалось создать служебные каталоги"

rm -f \
    "$STATE_DIR/runtime.before-dns-test.yaml" \
    "$STATE_DIR/runtime.did-not-exist" \
    "$STATE_DIR/dnsmasq.conf.add.before-dns-test" \
    "$STATE_DIR/dnsmasq.conf.add.did-not-exist" \
    "$STATE_DIR/dns.mode.before-dns-test"

if [ -f "$RUNTIME_CONFIG" ]; then
    cp "$RUNTIME_CONFIG" "$STATE_DIR/runtime.before-dns-test.yaml" ||
        fail "Не удалось сохранить runtime.yaml"
else
    : > "$STATE_DIR/runtime.did-not-exist"
fi

if [ -f "$DNSMASQ_ADD" ]; then
    cp "$DNSMASQ_ADD" "$STATE_DIR/dnsmasq.conf.add.before-dns-test" ||
        fail "Не удалось сохранить dnsmasq.conf.add"
else
    : > "$STATE_DIR/dnsmasq.conf.add.did-not-exist"
    : > "$DNSMASQ_ADD"
fi

if [ -f "$DNS_MODE_FILE" ]; then
    cp "$DNS_MODE_FILE" "$STATE_DIR/dns.mode.before-dns-test" || true
fi

stamp="$(date '+%Y%m%d-%H%M%S' 2>/dev/null)"
[ -n "$stamp" ] || stamp="dns-test"
cp "$SOURCE_CONFIG" "$BACKUP_DIR/config-$stamp.yaml" ||
    fail "Не удалось сделать резервную копию config.yaml"

say "Создаю runtime.yaml из личного config.yaml"
"$CTL" render || fail "Не удалось создать runtime.yaml"

# Временно отключаем только TUN в runtime.yaml. Личный config.yaml не меняется.
awk '
    /^tun:[[:space:]]*$/ {
        in_tun = 1
        print
        next
    }

    in_tun && /^[^[:space:]#]/ {
        in_tun = 0
    }

    in_tun && /^[[:space:]]+enable:[[:space:]]*/ {
        sub(/enable:[[:space:]]*.*/, "enable: false")
        print
        next
    }

    { print }
' "$RUNTIME_CONFIG" > "$RUNTIME_CONFIG.dns-test" || {
    restore_after_error
    fail "Не удалось подготовить runtime для DNS-теста"
}

mv -f "$RUNTIME_CONFIG.dns-test" "$RUNTIME_CONFIG" || {
    restore_after_error
    fail "Не удалось установить runtime для DNS-теста"
}

say "Проверяю runtime.yaml"
if ! "$BIN" -t -d "$BASE" -f "$RUNTIME_CONFIG"; then
    restore_after_error
    fail "Mihomo отклонил runtime.yaml"
fi

say "Останавливаю старый Mihomo"
"$CTL" stop >/dev/null 2>&1 || true

say "Отключаю только DNS-функцию dnsmasq; DHCP остаётся включён"
tmp="$DNSMASQ_ADD.goshacrash.tmp"
remove_managed_block "$DNSMASQ_ADD" "$tmp" || {
    restore_after_error
    fail "Не удалось обработать dnsmasq.conf.add"
}

{
    cat "$tmp"
    printf '%s\n' "$MARK_BEGIN"
    printf '%s\n' 'port=0'
    printf '%s\n' "$MARK_END"
} > "$DNSMASQ_ADD" || {
    rm -f "$tmp"
    restore_after_error
    fail "Не удалось записать port=0"
}
rm -f "$tmp"

printf '%s\n' exclusive53 > "$DNS_MODE_FILE" || {
    restore_after_error
    fail "Не удалось сохранить DNS-режим"
}

nvram set jffs2_scripts=1 >/dev/null 2>&1 || true
nvram commit >/dev/null 2>&1 || true

restart_dnsmasq || {
    restore_after_error
    fail "Не удалось перезапустить dnsmasq"
}

sleep 4

if netstat -lnp 2>/dev/null | grep ':53[[:space:]]' | grep -q 'dnsmasq'; then
    netstat -lnp 2>/dev/null | grep ':53[[:space:]]' >&2 || true
    restore_after_error
    fail "dnsmasq всё ещё занимает порт 53"
fi

say "Порт 53 освобождён, запускаю Mihomo без TUN"
if ! "$CTL" start; then
    restore_after_error
    fail "Mihomo не запустился"
fi

sleep 3

if ! netstat -lnp 2>/dev/null | grep ':53[[:space:]]' | grep -q 'mihomo'; then
    say "Текущие слушающие сокеты порта 53:"
    netstat -lnp 2>/dev/null | grep ':53[[:space:]]' || true
    restore_after_error
    fail "Mihomo не занял порт 53"
fi

: > "$STATE_DIR/dns-test.active"

echo
say "DNS-тест запущен успешно"
netstat -lnp 2>/dev/null | grep -E '(:53[[:space:]]|:7892[[:space:]]|:9090[[:space:]])' || true
echo
"$CTL" status

echo
printf '%s\n' "Для возврата штатного DNS: sh $BASE/restore-dns.sh"
