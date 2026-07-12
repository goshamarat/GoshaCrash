#!/bin/sh
# Возвращает штатный DNS ASUS после dns-test.sh.

BASE="$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)"
CTL="$BASE/goshacrash"
RUNTIME_CONFIG="$BASE/runtime.yaml"
STATE_DIR="$BASE/state"
DNSMASQ_ADD="/jffs/configs/dnsmasq.conf.add"
DNS_MODE_FILE="/jffs/addons/goshacrash/dns.mode"

restart_dnsmasq() {
    service restart_dnsmasq >/dev/null 2>&1 && return 0
    rc_service restart_dnsmasq >/dev/null 2>&1 && return 0
    return 1
}

[ -x "$CTL" ] && "$CTL" stop >/dev/null 2>&1 || true

mkdir -p /jffs/configs /jffs/addons/goshacrash 2>/dev/null || true

if [ -f "$STATE_DIR/dnsmasq.conf.add.before-dns-test" ]; then
    cp "$STATE_DIR/dnsmasq.conf.add.before-dns-test" "$DNSMASQ_ADD"
elif [ -f "$STATE_DIR/dnsmasq.conf.add.did-not-exist" ]; then
    rm -f "$DNSMASQ_ADD"
fi

if [ -f "$STATE_DIR/dns.mode.before-dns-test" ]; then
    cp "$STATE_DIR/dns.mode.before-dns-test" "$DNS_MODE_FILE"
else
    printf '%s\n' none > "$DNS_MODE_FILE"
fi

restart_dnsmasq || {
    echo "[GoshaCrash:ERROR] Не удалось перезапустить dnsmasq" >&2
    exit 1
}

if [ -f "$STATE_DIR/runtime.before-dns-test.yaml" ]; then
    cp "$STATE_DIR/runtime.before-dns-test.yaml" "$RUNTIME_CONFIG"
elif [ -f "$STATE_DIR/runtime.did-not-exist" ]; then
    rm -f "$RUNTIME_CONFIG"
fi

rm -f "$STATE_DIR/dns-test.active"

echo "[GoshaCrash] Штатный DNS ASUS возвращён"
netstat -lnp 2>/dev/null | grep ':53[[:space:]]' || true
