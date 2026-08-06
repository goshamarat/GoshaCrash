#!/bin/sh
# GoshaCrash 3.0.0-online — one controller for legacy ASUSWRT.
# Mihomo lifecycle, TUN/DNS routing, logs, packages and Zashboard updates.

VERSION="3.0.0-online"
BUILD_ID="2026-08-06-one-installer-one-controller"

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)"
BASE="${GOSHACRASH_BASE:-$SCRIPT_DIR}"
USB_MOUNT="$(dirname "$BASE")"
BIN="$BASE/bin/mihomo"
UI="$BASE/ui"
CONFIG="$BASE/config.yaml"
RUN="$BASE/run"
LOGS="$BASE/logs"
STATE="$BASE/state"
BACKUPS="$BASE/backups"
PIDFILE="$RUN/mihomo.pid"
MIHOMO_LOG="$LOGS/mihomo.log"
SYSTEM_LOG="$LOGS/goshacrash.log"
INSTALL_LOG="$LOGS/install.log"
START_LOCK="$RUN/start.lock"
BOOT_PIDFILE="$RUN/boot.pid"
MANUAL_STOP="$STATE/manual-stop"
JFFS_DIR="/jffs/addons/goshacrash"
JFFS_BASE_FILE="$JFFS_DIR/base"

TUN_DEVICE="${GOSHACRASH_TUN_DEVICE:-tun0}"
TUN_TABLE="${GOSHACRASH_TUN_TABLE:-2022}"
TUN_RULE_PREF="${GOSHACRASH_TUN_RULE_PREF:-10010}"
TUN_MARK="${GOSHACRASH_TUN_MARK:-0x2333}"
OUTBOUND_MARK_DEC="${GOSHACRASH_OUTBOUND_MARK_DEC:-9012}"
OUTBOUND_MARK="${GOSHACRASH_OUTBOUND_MARK:-0x2334}"
DNS_PORT="${MIHOMO_DNS_PORT:-1053}"
ROUTE_ROUTER="${GOSHACRASH_ROUTE_ROUTER:-1}"
BOOT_WAIT="${GOSHACRASH_BOOT_WAIT:-300}"
PROC_SYS="${GOSHACRASH_PROC_SYS:-/proc/sys}"

ROUTE_STATE="$STATE/route"
ROUTE_ACTIVE="$ROUTE_STATE/active"
LAN_CHAIN="GOSHACRASH_TUN_LAN"
ROUTER_CHAIN="GOSHACRASH_TUN_ROUTER"
FORWARD_CHAIN="GOSHACRASH_TUN_FORWARD"
DNS_LAN_CHAIN="GOSHACRASH_DNS_LAN"
DNS_OUT_CHAIN="GOSHACRASH_DNS_OUT"

REPO="${REPO:-goshamarat/GoshaCrash}"
BRANCH="${BRANCH:-main}"
ZASHBOARD_URL="${ZASHBOARD_URL:-https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip}"

DM_ROOT=""
PKG=""
IPT_WAIT=""

PATH="$BASE/bin:/usr/sbin:/usr/bin:/sbin:/bin:/jffs/scripts:/opt/bin:/opt/sbin:$USB_MOUNT/asusware.arm/bin:$USB_MOUNT/asusware.arm/sbin:$USB_MOUNT/asusware.arm64/bin:$USB_MOUNT/asusware.arm64/sbin:$USB_MOUNT/asusware/bin:$USB_MOUNT/asusware/sbin:$PATH"
export PATH

now(){ date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date; }
ensure_dirs(){ mkdir -p "$BASE/bin" "$UI" "$RUN" "$LOGS" "$STATE" "$BACKUPS" "$ROUTE_STATE"; }
log_event(){ level="$1"; area="$2"; shift 2; ensure_dirs >/dev/null 2>&1 || true; printf '[%s] [%s] [%s] %s\n' "$(now)" "$level" "$area" "$*" >> "$SYSTEM_LOG" 2>/dev/null || true; }
say(){ printf '%s\n' "[GoshaCrash] $*"; log_event INFO main "$*"; }
ok(){ printf '%s\n' "[GoshaCrash:OK] $*"; log_event OK main "$*"; }
warn(){ printf '%s\n' "[GoshaCrash:WARN] $*" >&2; log_event WARN main "$*"; }
fail(){ printf '%s\n' "[GoshaCrash:ERROR] $*" >&2; log_event ERROR main "$*"; return 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

lan_ip(){ x="$(nvram get lan_ipaddr 2>/dev/null)"; [ -n "$x" ] || x=192.168.1.1; printf '%s\n' "$x"; }
lan_ifaces(){
    if [ -n "${GOSHACRASH_LAN_IFACES:-}" ]; then printf '%s\n' "$GOSHACRASH_LAN_IFACES"; return; fi
    x="$(nvram get lan_ifname 2>/dev/null)"; [ -n "$x" ] || x=br0; printf '%s\n' "$x"
}

find_dm_root(){
    DM_ROOT=""
    for d in "$USB_MOUNT/asusware.arm" "$USB_MOUNT/asusware.arm64" "$USB_MOUNT/asusware"; do
        [ -d "$d" ] && { DM_ROOT="$d"; break; }
    done
    [ -n "$DM_ROOT" ]
}

attach_opt(){
    find_dm_root || return 1
    if [ -L /opt ]; then
        [ -d /opt ] || { rm -f /opt 2>/dev/null || true; ln -s "$DM_ROOT" /opt 2>/dev/null || true; }
    elif [ ! -e /opt ]; then
        ln -s "$DM_ROOT" /opt 2>/dev/null || true
    fi
    PATH="$BASE/bin:$DM_ROOT/bin:$DM_ROOT/sbin:/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
    export PATH
}

find_pkg(){
    PKG=""
    find_dm_root || return 1
    for p in "$DM_ROOT/bin/ipkg" "$DM_ROOT/bin/opkg" /opt/bin/ipkg /opt/bin/opkg; do
        [ -x "$p" ] && { PKG="$p"; break; }
    done
    [ -n "$PKG" ]
}

pkg_update(){
    attach_opt || { fail "Download Master не найден"; return 1; }
    find_pkg || { fail "ipkg/opkg не найден в Download Master"; return 1; }
    say "Обновляю индекс пакетов через $PKG"
    "$PKG" update >> "$SYSTEM_LOG" 2>&1 || { fail "Не удалось обновить индекс пакетов"; return 1; }
    ok "Индекс пакетов обновлён"
}

pkg_install(){
    name="$1"
    case "$name" in ''|*[!A-Za-z0-9+_.-]*) fail "Недопустимое имя пакета: $name"; return 1;; esac
    attach_opt || { fail "Download Master не найден"; return 1; }
    find_pkg || { fail "ipkg/opkg не найден в Download Master"; return 1; }
    say "Устанавливаю пакет: $name"
    "$PKG" install "$name" >> "$SYSTEM_LOG" 2>&1 || { fail "Пакет $name не установлен"; return 1; }
    ok "Пакет установлен: $name"
}

strip_value(){ printf '%s\n' "$1" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//'; }
yaml_top(){
    key="$2"
    awk -v key="$key" '{sub(/\r$/,"")} $0 ~ "^" key ":[[:space:]]*" {line=$0; sub("^" key ":[[:space:]]*", "", line); print line; exit}' "$1" 2>/dev/null |
    while IFS= read -r line; do strip_value "$line"; done
}
yaml_section(){
    file="$1"; section="$2"; key="$3"
    awk -v section="$section" -v key="$key" '
      {sub(/\r$/,"")}
      $0 ~ "^" section ":[[:space:]]*($|#)" {inside=1; next}
      inside && /^[^[:space:]#]/ {exit}
      inside && $0 ~ "^[[:space:]]+" key ":[[:space:]]*" {line=$0; sub("^[[:space:]]+" key ":[[:space:]]*", "", line); print line; exit}
    ' "$file" 2>/dev/null | while IFS= read -r line; do strip_value "$line"; done
}
is_true(){ case "$1" in true|True|TRUE|yes|Yes|YES|1|on|On|ON) return 0;; *) return 1;; esac; }
is_false(){ case "$1" in false|False|FALSE|no|No|NO|0|off|Off|OFF) return 0;; *) return 1;; esac; }

running_pid(){
    [ -f "$PIDFILE" ] || return 1
    p="$(cat "$PIDFILE" 2>/dev/null)"
    case "$p" in ''|*[!0-9]*) return 1;; esac
    kill -0 "$p" 2>/dev/null || { rm -f "$PIDFILE"; return 1; }
    if [ -r "/proc/$p/cmdline" ]; then tr '\000' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "$BIN" || return 1; fi
    printf '%s\n' "$p"
}

kill_mihomo(){
    if p="$(running_pid)"; then
        kill "$p" 2>/dev/null || true
        n=0
        while kill -0 "$p" 2>/dev/null && [ "$n" -lt 10 ]; do sleep 1; n=$((n + 1)); done
        kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null || true
    fi
    for p in $(pidof mihomo 2>/dev/null); do kill "$p" 2>/dev/null || true; done
    rm -f "$PIDFILE"
}

ensure_tun(){
    [ -c /dev/net/tun ] || {
        modprobe tun >/dev/null 2>&1 || true
        for m in "$BASE/modules/tun.ko" "/lib/modules/$(uname -r)/kernel/drivers/net/tun.ko" "/lib/modules/$(uname -r)/tun.ko"; do
            [ -c /dev/net/tun ] && break
            [ -f "$m" ] && insmod "$m" >/dev/null 2>&1 || true
        done
    }
    if [ ! -c /dev/net/tun ]; then
        mkdir -p /dev/net 2>/dev/null || true
        mknod /dev/net/tun c 10 200 2>/dev/null || true
        chmod 600 /dev/net/tun 2>/dev/null || true
    fi
    [ -c /dev/net/tun ] || return 1
    dd if=/dev/net/tun of=/dev/null bs=1 count=0 >/dev/null 2>&1
}

validate_binary(){
    [ -x "$BIN" ] || { fail "Не найден $BIN"; return 1; }
    out="$($BIN -v 2>&1)" || { printf '%s\n' "$out" >&2; fail "Mihomo не запускается"; return 1; }
    printf '%s\n' "$out" | grep -Fq 'Use tags: with_gvisor' || { printf '%s\n' "$out" >&2; fail "Mihomo собран без with_gvisor"; return 1; }
    printf '%s\n' "$out" | grep -Eqi 'linux (arm|arm32)' || { printf '%s\n' "$out" >&2; fail "Mihomo не является Linux ARM-сборкой"; return 1; }
}

required_config(){
    [ -f "$CONFIG" ] || { fail "Не найден $CONFIG"; return 1; }
    is_true "$(yaml_section "$CONFIG" tun enable)" || { fail "tun.enable должен быть true"; return 1; }
    [ "$(yaml_section "$CONFIG" tun stack)" = gvisor ] || { fail "tun.stack должен быть gvisor"; return 1; }
    [ "$(yaml_section "$CONFIG" tun device)" = "$TUN_DEVICE" ] || { fail "tun.device должен быть $TUN_DEVICE"; return 1; }
    is_false "$(yaml_section "$CONFIG" tun auto-route)" || { fail "tun.auto-route должен быть false"; return 1; }
    is_false "$(yaml_section "$CONFIG" tun auto-redirect)" || { fail "tun.auto-redirect должен быть false"; return 1; }
    is_true "$(yaml_section "$CONFIG" dns enable)" || { fail "dns.enable должен быть true"; return 1; }
    [ "$(yaml_section "$CONFIG" dns listen)" = "127.0.0.1:$DNS_PORT" ] || { fail "dns.listen должен быть 127.0.0.1:$DNS_PORT"; return 1; }
    [ "$(yaml_top "$CONFIG" routing-mark)" = "$OUTBOUND_MARK_DEC" ] || { fail "routing-mark должен быть $OUTBOUND_MARK_DEC"; return 1; }
    is_false "$(yaml_top "$CONFIG" ipv6)" || { fail "ipv6 должен быть false для этой legacy-сборки"; return 1; }
}

check_config(){
    ensure_dirs || return 1
    validate_binary || return 1
    required_config || return 1
    "$BIN" -t -d "$BASE" -f "$CONFIG"
}

wait_port(){
    port="$1"; n=0
    while [ "$n" -lt 20 ]; do
        netstat -ln 2>/dev/null | grep -Eq "[:.]$port[[:space:]]" && return 0
        sleep 1; n=$((n + 1))
    done
    return 1
}

wait_tun(){
    n=0
    while [ "$n" -lt 20 ]; do
        ip link show "$TUN_DEVICE" >/dev/null 2>&1 && return 0
        ifconfig "$TUN_DEVICE" >/dev/null 2>&1 && return 0
        sleep 1; n=$((n + 1))
    done
    return 1
}

ipt_init(){ IPT_WAIT=""; iptables -h 2>&1 | grep -q '\-w' && IPT_WAIT="-w"; }
ipt(){ if [ -n "$IPT_WAIT" ]; then iptables -w "$@"; else iptables "$@"; fi; }
remove_jump(){ table="$1"; chain="$2"; shift 2; while ipt -t "$table" -D "$chain" "$@" 2>/dev/null; do :; done; }
delete_chain(){ table="$1"; chain="$2"; ipt -t "$table" -F "$chain" 2>/dev/null || true; ipt -t "$table" -X "$chain" 2>/dev/null || true; }

reserved_destinations(){
    cat <<'NETS'
0.0.0.0/8
10.0.0.0/8
100.64.0.0/10
127.0.0.0/8
169.254.0.0/16
172.16.0.0/12
192.168.0.0/16
224.0.0.0/4
240.0.0.0/4
255.255.255.255/32
NETS
}

save_sysctl(){ name="$1"; path="$2"; [ -r "$path" ] || return 0; mkdir -p "$ROUTE_STATE" || return 1; file="$ROUTE_STATE/sysctl.$name"; [ -f "$file" ] || cat "$path" > "$file"; }
set_sysctl_zero(){ name="$1"; path="$2"; save_sysctl "$name" "$path" || return 1; [ -w "$path" ] && printf '0\n' > "$path" 2>/dev/null || true; }
prepare_sysctls(){
    set_sysctl_zero all_rp_filter "$PROC_SYS/net/ipv4/conf/all/rp_filter"
    set_sysctl_zero default_rp_filter "$PROC_SYS/net/ipv4/conf/default/rp_filter"
    for iface in $(lan_ifaces) "$TUN_DEVICE"; do safe="$(printf '%s\n' "$iface" | tr '/ ' '__')"; set_sysctl_zero "${safe}_rp_filter" "$PROC_SYS/net/ipv4/conf/$iface/rp_filter"; done
    [ -w "$PROC_SYS/net/ipv4/ip_forward" ] && printf '1\n' > "$PROC_SYS/net/ipv4/ip_forward" 2>/dev/null || true
}
restore_sysctls(){
    [ -d "$ROUTE_STATE" ] || return 0
    for f in "$ROUTE_STATE"/sysctl.*; do
        [ -f "$f" ] || continue
        name="${f##*/sysctl.}"
        case "$name" in
            all_rp_filter) path="$PROC_SYS/net/ipv4/conf/all/rp_filter";;
            default_rp_filter) path="$PROC_SYS/net/ipv4/conf/default/rp_filter";;
            *_rp_filter) iface="${name%_rp_filter}"; path="$PROC_SYS/net/ipv4/conf/$iface/rp_filter";;
            *) continue;;
        esac
        [ -w "$path" ] && cat "$f" > "$path" 2>/dev/null || true
        rm -f "$f"
    done
}

route_cleanup(){
    have iptables || return 0
    ipt_init
    for iface in $(lan_ifaces); do
        remove_jump mangle PREROUTING -i "$iface" -j "$LAN_CHAIN"
        remove_jump nat PREROUTING -i "$iface" -p udp --dport 53 -j "$DNS_LAN_CHAIN"
        remove_jump nat PREROUTING -i "$iface" -p tcp --dport 53 -j "$DNS_LAN_CHAIN"
        remove_jump mangle PREROUTING -i "$iface" -j GOSHACRASH_TUN
        remove_jump nat PREROUTING -i "$iface" -p tcp -j GOSHACRASH_TCP_REDIR
        remove_jump nat PREROUTING -i "$iface" -p udp --dport 53 -j GOSHACRASH_DNS_HIJACK
        remove_jump nat PREROUTING -i "$iface" -p tcp --dport 53 -j GOSHACRASH_DNS_HIJACK
    done
    remove_jump mangle OUTPUT -j "$ROUTER_CHAIN"
    remove_jump nat OUTPUT -p udp --dport 53 -j "$DNS_OUT_CHAIN"
    remove_jump nat OUTPUT -p tcp --dport 53 -j "$DNS_OUT_CHAIN"
    remove_jump filter FORWARD -j "$FORWARD_CHAIN"
    remove_jump mangle OUTPUT -j GOSHACRASH_ROUTER_TUN
    remove_jump nat OUTPUT -p tcp -j GOSHACRASH_ROUTER_TCP
    remove_jump nat OUTPUT -p udp --dport 53 -j GOSHACRASH_DNSMASQ_UPSTREAM
    remove_jump nat OUTPUT -p tcp --dport 53 -j GOSHACRASH_DNSMASQ_UPSTREAM
    remove_jump filter FORWARD -j GOSHACRASH_FORWARD
    delete_chain mangle "$LAN_CHAIN"; delete_chain mangle "$ROUTER_CHAIN"
    delete_chain nat "$DNS_LAN_CHAIN"; delete_chain nat "$DNS_OUT_CHAIN"
    delete_chain filter "$FORWARD_CHAIN"
    for c in GOSHACRASH_TUN GOSHACRASH_ROUTER_TUN; do delete_chain mangle "$c"; done
    for c in GOSHACRASH_DNS_HIJACK GOSHACRASH_TCP_REDIR GOSHACRASH_ROUTER_TCP GOSHACRASH_DNSMASQ_UPSTREAM; do delete_chain nat "$c"; done
    delete_chain filter GOSHACRASH_FORWARD
    if have ip; then
        while ip rule del fwmark "$TUN_MARK" table "$TUN_TABLE" pref "$TUN_RULE_PREF" 2>/dev/null; do :; done
        while ip rule del fwmark "$TUN_MARK" table "$TUN_TABLE" 2>/dev/null; do :; done
        ip route flush table "$TUN_TABLE" 2>/dev/null || true
        ip route flush cache 2>/dev/null || true
    fi
    rm -f "$ROUTE_ACTIVE"
}

add_exclusions(){ table="$1"; chain="$2"; reserved_destinations | while read net; do [ -n "$net" ] || continue; ipt -t "$table" -A "$chain" -d "$net" -j RETURN || exit 1; done; }
build_lan_chain(){
    ipt -t mangle -N "$LAN_CHAIN" || return 1
    ipt -t mangle -A "$LAN_CHAIN" -m mark --mark "$OUTBOUND_MARK" -j RETURN || return 1
    ipt -t mangle -A "$LAN_CHAIN" -p udp --dport 53 -j RETURN || return 1
    ipt -t mangle -A "$LAN_CHAIN" -p tcp --dport 53 -j RETURN || return 1
    add_exclusions mangle "$LAN_CHAIN" || return 1
    ipt -t mangle -A "$LAN_CHAIN" -j MARK --set-mark "$TUN_MARK" || return 1
    for iface in $(lan_ifaces); do ipt -t mangle -I PREROUTING 1 -i "$iface" -j "$LAN_CHAIN" || return 1; done
}
build_router_chain(){
    [ "$ROUTE_ROUTER" = 1 ] || return 0
    ipt -t mangle -N "$ROUTER_CHAIN" || return 1
    ipt -t mangle -A "$ROUTER_CHAIN" -m mark --mark "$OUTBOUND_MARK" -j RETURN || return 1
    ipt -t mangle -A "$ROUTER_CHAIN" -p udp --dport 53 -j RETURN || return 1
    ipt -t mangle -A "$ROUTER_CHAIN" -p tcp --dport 53 -j RETURN || return 1
    add_exclusions mangle "$ROUTER_CHAIN" || return 1
    ipt -t mangle -A "$ROUTER_CHAIN" -j MARK --set-mark "$TUN_MARK" || return 1
    ipt -t mangle -I OUTPUT 1 -j "$ROUTER_CHAIN" || return 1
}
build_dns(){
    ipt -t nat -N "$DNS_LAN_CHAIN" || return 1
    ipt -t nat -A "$DNS_LAN_CHAIN" -p udp -j REDIRECT --to-ports 53 || return 1
    ipt -t nat -A "$DNS_LAN_CHAIN" -p tcp -j REDIRECT --to-ports 53 || return 1
    for iface in $(lan_ifaces); do
        ipt -t nat -I PREROUTING 1 -i "$iface" -p udp --dport 53 -j "$DNS_LAN_CHAIN" || return 1
        ipt -t nat -I PREROUTING 1 -i "$iface" -p tcp --dport 53 -j "$DNS_LAN_CHAIN" || return 1
    done
    ipt -t nat -N "$DNS_OUT_CHAIN" || return 1
    ipt -t nat -A "$DNS_OUT_CHAIN" -m mark --mark "$OUTBOUND_MARK" -j RETURN || return 1
    ipt -t nat -A "$DNS_OUT_CHAIN" -d 127.0.0.0/8 -j RETURN || return 1
    ipt -t nat -A "$DNS_OUT_CHAIN" -p udp -j REDIRECT --to-ports "$DNS_PORT" || return 1
    ipt -t nat -A "$DNS_OUT_CHAIN" -p tcp -j REDIRECT --to-ports "$DNS_PORT" || return 1
    ipt -t nat -I OUTPUT 1 -p udp --dport 53 -j "$DNS_OUT_CHAIN" || return 1
    ipt -t nat -I OUTPUT 1 -p tcp --dport 53 -j "$DNS_OUT_CHAIN" || return 1
}
build_forward(){
    ipt -t filter -N "$FORWARD_CHAIN" || return 1
    for iface in $(lan_ifaces); do
        ipt -t filter -A "$FORWARD_CHAIN" -i "$iface" -o "$TUN_DEVICE" -j ACCEPT || return 1
        ipt -t filter -A "$FORWARD_CHAIN" -i "$TUN_DEVICE" -o "$iface" -j ACCEPT || return 1
    done
    ipt -t filter -I FORWARD 1 -j "$FORWARD_CHAIN" || return 1
}

route_start(){
    have ip || { fail "Не найдена команда ip"; return 1; }
    have iptables || { fail "Не найдена команда iptables"; return 1; }
    ip link show "$TUN_DEVICE" >/dev/null 2>&1 || ifconfig "$TUN_DEVICE" >/dev/null 2>&1 || { fail "TUN $TUN_DEVICE не найден"; return 1; }
    iptables -j MARK -h >/dev/null 2>&1 || { fail "Ядро не поддерживает iptables MARK"; return 1; }
    route_cleanup
    prepare_sysctls || { route_cleanup; return 1; }
    ipt_init
    ip route add default dev "$TUN_DEVICE" table "$TUN_TABLE" || { fail "Не создан default route table $TUN_TABLE"; route_cleanup; restore_sysctls; return 1; }
    ip rule add fwmark "$TUN_MARK" table "$TUN_TABLE" pref "$TUN_RULE_PREF" || { fail "Не создано ip rule"; route_cleanup; restore_sysctls; return 1; }
    build_lan_chain || { fail "Не создана LAN mangle-цепочка"; route_cleanup; restore_sysctls; return 1; }
    build_router_chain || { fail "Не создана OUTPUT mangle-цепочка"; route_cleanup; restore_sysctls; return 1; }
    build_dns || { fail "Не создан DNS-перехват"; route_cleanup; restore_sysctls; return 1; }
    build_forward || { fail "Не созданы FORWARD-правила"; route_cleanup; restore_sysctls; return 1; }
    ip route flush cache 2>/dev/null || true
    printf 'device=%s\ntable=%s\nmark=%s\n' "$TUN_DEVICE" "$TUN_TABLE" "$TUN_MARK" > "$ROUTE_ACTIVE"
    log_event OK route "LAN и роутер -> mark $TUN_MARK -> table $TUN_TABLE -> $TUN_DEVICE"
}

route_stop(){ route_cleanup; restore_sysctls; log_event INFO route "Маршрутизация остановлена"; }
route_status(){
    rc=0
    (ip link show "$TUN_DEVICE" >/dev/null 2>&1 || ifconfig "$TUN_DEVICE" >/dev/null 2>&1) || rc=1
    ip rule show 2>/dev/null | grep -q "lookup $TUN_TABLE" || rc=1
    ip route show table "$TUN_TABLE" 2>/dev/null | grep -q "default.*dev $TUN_DEVICE" || rc=1
    iptables -t mangle -S "$LAN_CHAIN" >/dev/null 2>&1 || rc=1
    iptables -t nat -S "$DNS_OUT_CHAIN" >/dev/null 2>&1 || rc=1
    return "$rc"
}

rotate_mihomo_log(){
    [ -f "$MIHOMO_LOG" ] || return 0
    size="$(wc -c < "$MIHOMO_LOG" 2>/dev/null)"; case "$size" in ''|*[!0-9]*) size=0;; esac
    [ "$size" -gt 1048576 ] || return 0
    rm -f "$MIHOMO_LOG.3"
    [ -f "$MIHOMO_LOG.2" ] && mv "$MIHOMO_LOG.2" "$MIHOMO_LOG.3"
    [ -f "$MIHOMO_LOG.1" ] && mv "$MIHOMO_LOG.1" "$MIHOMO_LOG.2"
    mv "$MIHOMO_LOG" "$MIHOMO_LOG.1"
}

start_inner(){
    ensure_dirs || return 1
    attach_opt >/dev/null 2>&1 || true
    check_config || return 1
    ensure_tun || { fail "Драйвер /dev/net/tun недоступен"; return 1; }
    rm -f "$MANUAL_STOP"
    if p="$(running_pid)"; then route_start || return 1; say "Mihomo уже работает, PID=$p"; return 0; fi
    route_stop >/dev/null 2>&1 || true
    kill_mihomo
    rotate_mihomo_log
    if have nohup; then GOGC="${GOGC:-50}" nohup "$BIN" -d "$BASE" -f "$CONFIG" </dev/null >> "$MIHOMO_LOG" 2>&1 &
    else GOGC="${GOGC:-50}" "$BIN" -d "$BASE" -f "$CONFIG" </dev/null >> "$MIHOMO_LOG" 2>&1 & fi
    p=$!; printf '%s\n' "$p" > "$PIDFILE"; sleep 2
    running_pid >/dev/null 2>&1 || { tail -n 80 "$MIHOMO_LOG" >&2; fail "Mihomo завершился при запуске"; return 1; }
    wait_port "$DNS_PORT" || { kill_mihomo; tail -n 80 "$MIHOMO_LOG" >&2; fail "DNS Mihomo не слушает $DNS_PORT"; return 1; }
    wait_tun || { kill_mihomo; tail -n 80 "$MIHOMO_LOG" >&2; fail "Mihomo не создал $TUN_DEVICE"; return 1; }
    route_start || { kill_mihomo; route_stop >/dev/null 2>&1 || true; fail "Маршрутизация не поднялась; оставлен DIRECT"; return 1; }
    cp "$CONFIG" "$BACKUPS/config.last-good.yaml" 2>/dev/null || true
    ok "Mihomo запущен, PID=$p"
}

start(){
    ensure_dirs || return 1
    if ! mkdir "$START_LOCK" 2>/dev/null; then
        n=0; while [ -d "$START_LOCK" ] && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
        [ -d "$START_LOCK" ] && { fail "Другой запуск GoshaCrash не завершился"; return 1; }
        mkdir "$START_LOCK" 2>/dev/null || return 1
    fi
    start_inner; rc=$?; rmdir "$START_LOCK" 2>/dev/null || true; return "$rc"
}

stop(){
    touch "$MANUAL_STOP" 2>/dev/null || true
    route_stop >/dev/null 2>&1 || true
    kill_mihomo
    rm -rf "$START_LOCK" 2>/dev/null || true
    rm -f "$BOOT_PIDFILE" 2>/dev/null || true
    say "Mihomo остановлен; обычный DIRECT восстановлен"
}
restart(){ route_stop >/dev/null 2>&1 || true; kill_mihomo; rm -f "$MANUAL_STOP"; start; }

main_default_route(){ ip route show table main 2>/dev/null | grep -q '^default '; }
boot(){
    ensure_dirs || return 1
    [ -f "$MANUAL_STOP" ] && { say "Автозапуск пропущен: ранее выполнена ручная остановка"; return 0; }
    if [ -f "$BOOT_PIDFILE" ]; then old="$(cat "$BOOT_PIDFILE" 2>/dev/null)"; case "$old" in ''|*[!0-9]*) old="";; esac; [ -n "$old" ] && kill -0 "$old" 2>/dev/null && return 0; fi
    echo "$$" > "$BOOT_PIDFILE"
    attach_opt >/dev/null 2>&1 || true
    waited=0
    while ! main_default_route; do
        [ "$waited" -ge "$BOOT_WAIT" ] && { warn "Default route не появился за $BOOT_WAIT секунд"; rm -f "$BOOT_PIDFILE"; return 0; }
        sleep 5; waited=$((waited + 5))
    done
    sleep 5; start; rc=$?; rm -f "$BOOT_PIDFILE"; return "$rc"
}
firewall_reload(){ running_pid >/dev/null 2>&1 || return 0; route_start || { warn "Не восстановлены правила после firewall restart"; route_stop; return 1; }; }

add_once(){ file="$1"; line="$2"; [ -f "$file" ] || printf '#!/bin/sh\n' > "$file"; grep -Fqx "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"; chmod 755 "$file"; }
install_hooks(){
    ensure_dirs || return 1
    find_dm_root || { fail "Download Master не найден в $USB_MOUNT"; return 1; }
    mkdir -p "$JFFS_DIR" /jffs/scripts "$DM_ROOT/bin" "$DM_ROOT/etc/init.d" || return 1
    printf '%s\n' "$BASE" > "$JFFS_BASE_FILE" || return 1

    cat > "$JFFS_DIR/start.sh" <<'HOOK'
#!/bin/sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -x "$BASE/goshacrash.sh" ] || exit 0
mkdir -p "$BASE/logs" "$BASE/run" 2>/dev/null || true
if command -v nohup >/dev/null 2>&1; then
  GOSHACRASH_BASE="$BASE" nohup "$BASE/goshacrash.sh" boot </dev/null >> "$BASE/logs/boot.log" 2>&1 &
else
  GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" boot </dev/null >> "$BASE/logs/boot.log" 2>&1 &
fi
HOOK
    chmod 755 "$JFFS_DIR/start.sh" || return 1

    cat > "$JFFS_DIR/firewall.sh" <<'HOOK'
#!/bin/sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -x "$BASE/goshacrash.sh" ] && GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" firewall-reload >/dev/null 2>&1
HOOK
    chmod 755 "$JFFS_DIR/firewall.sh" || return 1
    add_once /jffs/scripts/services-start "$JFFS_DIR/start.sh &"
    add_once /jffs/scripts/firewall-start "$JFFS_DIR/firewall.sh &"

    cat > "$DM_ROOT/bin/goshacrash" <<'WRAP'
#!/bin/sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -n "$BASE" ] || { echo "GoshaCrash: не найден BASE" >&2; exit 1; }
GOSHACRASH_BASE="$BASE" exec "$BASE/goshacrash.sh" "$@"
WRAP
    chmod 755 "$DM_ROOT/bin/goshacrash" || return 1
    attach_opt >/dev/null 2>&1 || true
    [ -d /opt/bin ] && ln -sf "$DM_ROOT/bin/goshacrash" /opt/bin/goshacrash 2>/dev/null || true

    cat > "$DM_ROOT/etc/init.d/S99goshacrash" <<'INIT'
#!/bin/sh
case "$1" in
  start) /jffs/addons/goshacrash/start.sh & ;;
  stop) BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"; [ -x "$BASE/goshacrash.sh" ] && GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" stop ;;
  restart) BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"; [ -x "$BASE/goshacrash.sh" ] && GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" restart ;;
  firewall-start|firewall-restart) /jffs/addons/goshacrash/firewall.sh & ;;
esac
INIT
    chmod 755 "$DM_ROOT/etc/init.d/S99goshacrash" || return 1
    ok "Автозапуск и команда goshacrash установлены"
}

backup_config(){
    [ -f "$CONFIG" ] || return 1
    stamp="$(date '+%Y%m%d-%H%M%S' 2>/dev/null)"; [ -n "$stamp" ] || stamp="backup"
    dst="$BACKUPS/config-$stamp.yaml"; cp "$CONFIG" "$dst" || return 1; printf '%s\n' "$dst"
}

find_editor(){
    for e in "$DM_ROOT/bin/nano" /opt/bin/nano "$(command -v nano 2>/dev/null)"; do [ -n "$e" ] && [ -x "$e" ] && { printf '%s\n' "$e"; return 0; }; done
    return 1
}

edit_config(){
    attach_opt >/dev/null 2>&1 || true
    if ! editor="$(find_editor)"; then
        warn "nano не найден; пробую установить через Download Master"
        pkg_update >/dev/null 2>&1 || true
        pkg_install nano || return 1
        editor="$(find_editor)" || { fail "nano не найден после установки"; return 1; }
    fi
    backup="$(backup_config)" || { fail "Не создана резервная копия config.yaml"; return 1; }
    say "Резервная копия: $backup"
    "$editor" "$CONFIG"
    if check_config; then apply_config
    else
        cp "$backup" "$CONFIG" || true
        fail "Конфиг некорректен; восстановлена резервная копия"
        return 1
    fi
}

apply_config(){
    check_config || return 1
    if restart; then
        return 0
    fi
    if [ -f "$BACKUPS/config.last-good.yaml" ]; then
        warn "Новый конфиг не запустился; возвращаю последний рабочий"
        cp "$BACKUPS/config.last-good.yaml" "$CONFIG" || return 1
        restart
        return $?
    fi
    return 1
}

wget_fetch(){
    url="$1"; out="$2"
    for w in "$DM_ROOT/bin/wget" /opt/bin/wget /usr/sbin/wget /usr/bin/wget; do
        [ -x "$w" ] || continue
        "$w" -q --no-check-certificate -O "$out.part" "$url" >/dev/null 2>&1 && [ -s "$out.part" ] && { mv -f "$out.part" "$out"; return 0; }
        "$w" -q -O "$out.part" "$url" >/dev/null 2>&1 && [ -s "$out.part" ] && { mv -f "$out.part" "$out"; return 0; }
    done
    return 1
}
fetch(){
    url="$1"; out="$2"; rm -f "$out" "$out.part"; n=1
    while [ "$n" -le 3 ]; do
        wget_fetch "$url" "$out" && return 0
        if have curl; then curl -k -fL --connect-timeout 25 -o "$out.part" "$url" >/dev/null 2>&1 && [ -s "$out.part" ] && { mv -f "$out.part" "$out"; return 0; }; fi
        sleep 2; n=$((n + 1))
    done
    rm -f "$out" "$out.part"; return 1
}

flatten_ui(){ src="$1"; dst="$2"; index="$(find "$src" -type f -name index.html 2>/dev/null | head -n 1)"; [ -n "$index" ] || return 1; root="$(dirname "$index")"; rm -rf "$dst"; mkdir -p "$dst" || return 1; cp -R "$root"/. "$dst"/ || return 1; [ -f "$dst/index.html" ]; }
update_zashboard(){
    attach_opt >/dev/null 2>&1 || true
    have unzip || pkg_install unzip || { fail "Не удалось установить unzip"; return 1; }
    work="$BASE/.zashboard-update"; archive="$work/zashboard.zip"; unpack="$work/unpack"; ui_new="$BASE/ui.new"
    rm -rf "$work" "$ui_new"; mkdir -p "$unpack" || return 1
    say "Скачиваю последнюю Zashboard"
    fetch "$ZASHBOARD_URL" "$archive" || { rm -rf "$work"; fail "Zashboard не скачана"; return 1; }
    unzip -oq "$archive" -d "$unpack" >> "$SYSTEM_LOG" 2>&1 || { rm -rf "$work"; fail "Архив Zashboard повреждён"; return 1; }
    flatten_ui "$unpack" "$ui_new" || { rm -rf "$work" "$ui_new"; fail "В архиве нет index.html"; return 1; }
    rm -rf "$BASE/ui.previous"
    [ -d "$UI" ] && mv "$UI" "$BASE/ui.previous" || true
    mv "$ui_new" "$UI" || { [ -d "$BASE/ui.previous" ] && mv "$BASE/ui.previous" "$UI"; rm -rf "$work"; fail "Не удалось заменить панель"; return 1; }
    rm -rf "$work"
    ok "Zashboard обновлена. Mihomo и правила не изменялись"
}

status(){
    ensure_dirs >/dev/null 2>&1 || true
    if p="$(running_pid)"; then echo "Mihomo: работает, PID=$p"; else echo "Mihomo: не запущен"; fi
    echo "GoshaCrash: $VERSION"
    echo "BASE: $BASE"
    echo "Config: $CONFIG"
    if ip link show "$TUN_DEVICE" >/dev/null 2>&1 || ifconfig "$TUN_DEVICE" >/dev/null 2>&1; then echo "TUN: $TUN_DEVICE работает"; else echo "TUN: $TUN_DEVICE не найден"; fi
    if running_pid >/dev/null 2>&1 && route_status; then echo "Маршрутизация: mark $TUN_MARK -> table $TUN_TABLE -> $TUN_DEVICE"; else echo "Маршрутизация: выключена или неполна"; fi
    find_dm_root && echo "Download Master: $DM_ROOT" || echo "Download Master: не найден"
    find_pkg && echo "Пакеты: $PKG" || echo "Пакеты: ipkg/opkg не найден"
    c="$(yaml_top "$CONFIG" external-controller)"; [ -n "$c" ] || c=0.0.0.0:9090; p="${c##*:}"; case "$p" in ''|*[!0-9]*) p=9090;; esac
    echo "Zashboard: http://$(lan_ip):$p/ui/"
    s="$(yaml_top "$CONFIG" secret)"; [ -n "$s" ] && echo "API secret: $s"
}

doctor(){
    echo '=== GoshaCrash ==='; echo "Version=$VERSION"; echo "Build=$BUILD_ID"; echo "BASE=$BASE"; echo "USB=$USB_MOUNT"; echo "MODEL=$(nvram get productid 2>/dev/null)"; echo "ARCH=$(uname -m 2>/dev/null)"; echo "KERNEL=$(uname -r 2>/dev/null)"
    echo; echo '=== files ==='; ls -l "$BIN" "$CONFIG" "$UI/index.html" 2>/dev/null || true
    echo; echo '=== binary ==='; "$BIN" -v 2>&1 || true
    echo; echo '=== config ==='; check_config || true
    echo; echo '=== tun ==='; ensure_tun && echo '/dev/net/tun: OK' || echo '/dev/net/tun: ERROR'
    echo; echo '=== status ==='; status
    echo; echo '=== ip rule ==='; ip rule show 2>/dev/null || true
    echo; echo "=== table $TUN_TABLE ==="; ip route show table "$TUN_TABLE" 2>/dev/null || true
    echo; echo '=== mangle ==='; iptables -t mangle -L "$LAN_CHAIN" -n -v 2>/dev/null || true; iptables -t mangle -L "$ROUTER_CHAIN" -n -v 2>/dev/null || true
    echo; echo '=== nat DNS ==='; iptables -t nat -L "$DNS_LAN_CHAIN" -n -v 2>/dev/null || true; iptables -t nat -L "$DNS_OUT_CHAIN" -n -v 2>/dev/null || true
    echo; echo '=== recent mihomo log ==='; tail -n 100 "$MIHOMO_LOG" 2>/dev/null || true
}

show_logs(){
    kind="${1:-mihomo}"; lines="${2:-100}"
    case "$lines" in ''|*[!0-9]*) lines=100;; esac
    case "$kind" in
        mihomo) tail -n "$lines" "$MIHOMO_LOG" 2>/dev/null || true;;
        system|goshacrash) tail -n "$lines" "$SYSTEM_LOG" 2>/dev/null || true;;
        install) tail -n "$lines" "$INSTALL_LOG" 2>/dev/null || true;;
        boot) tail -n "$lines" "$LOGS/boot.log" 2>/dev/null || true;;
        follow) tail -f "$MIHOMO_LOG";;
        *) echo "logs: mihomo|system|install|boot|follow"; return 1;;
    esac
}

packages_menu(){
    while :; do
        echo '--- Пакеты Download Master ---'
        echo '1) Проверить /opt и менеджер пакетов'
        echo '2) Обновить индекс пакетов'
        echo '3) Установить nano'
        echo '4) Установить wget'
        echo '5) Установить unzip'
        echo '6) Установить пакет по имени'
        echo '0) Назад'
        printf 'Выбери пункт: '; read choice
        case "$choice" in
            1) attach_opt && find_pkg && echo "OK: $PKG" || echo 'Не готово';;
            2) pkg_update;;
            3) pkg_install nano;;
            4) pkg_install wget;;
            5) pkg_install unzip;;
            6) printf 'Имя пакета: '; read name; pkg_install "$name";;
            0) return 0;;
            *) echo 'Неизвестный пункт';;
        esac
        echo
    done
}

logs_menu(){
    echo '1) Mihomo'; echo '2) GoshaCrash'; echo '3) Установка'; echo '4) Автозапуск'; echo '5) Mihomo в реальном времени'; echo '0) Назад'
    printf 'Выбери пункт: '; read choice
    case "$choice" in 1) show_logs mihomo 100;; 2) show_logs system 100;; 3) show_logs install 100;; 4) show_logs boot 100;; 5) show_logs follow;; 0) return 0;; *) echo 'Неизвестный пункт';; esac
}

menu(){
    while :; do
        echo '========================================'
        echo "          GoshaCrash $VERSION"
        echo '========================================'
        echo '1) Статус'
        echo '2) Перезапустить Mihomo'
        echo '3) Остановить Mihomo'
        echo '4) Редактировать config.yaml и применить'
        echo '5) Логи'
        echo '6) Обновить Zashboard'
        echo '7) Пакеты / восстановление Download Master'
        echo '8) Полная диагностика'
        echo '0) Выход'
        printf 'Выбери пункт: '; read choice
        case "$choice" in
            1) status;; 2) restart;; 3) stop;; 4) edit_config;; 5) logs_menu;; 6) update_zashboard;; 7) packages_menu;; 8) doctor;; 0) return 0;; *) echo 'Неизвестный пункт';;
        esac
        echo
    done
}

usage(){
    cat <<USAGE
GoshaCrash $VERSION

  goshacrash                       открыть меню
  goshacrash start                 запустить Mihomo и правила
  goshacrash stop                  остановить и вернуть DIRECT
  goshacrash restart               перезапустить
  goshacrash status                показать состояние
  goshacrash check                 проверить config.yaml
  goshacrash apply                 проверить и применить config.yaml
  goshacrash edit                  открыть config.yaml в nano
  goshacrash logs [тип] [N]        тип: mihomo/system/install/boot/follow
  goshacrash update                обновить только Zashboard
  goshacrash pkg update            обновить индекс ipkg/opkg
  goshacrash pkg install ИМЯ       установить пакет через Download Master
  goshacrash doctor                полная диагностика
USAGE
}

ensure_dirs >/dev/null 2>&1 || true
case "${1:-menu}" in
    menu) menu;;
    start) start;;
    stop|direct) stop;;
    restart) restart;;
    status) status;;
    check) check_config;;
    apply) apply_config;;
    edit|nano) edit_config;;
    logs) shift; show_logs "${1:-mihomo}" "${2:-100}";;
    update|update-ui|update-zashboard) update_zashboard;;
    pkg|package)
        shift
        case "${1:-}" in
            update) pkg_update;;
            install) [ -n "${2:-}" ] || { fail "Укажи имя пакета"; exit 1; }; pkg_install "$2";;
            *) echo 'Использование: goshacrash pkg update | goshacrash pkg install ИМЯ'; exit 1;;
        esac
        ;;
    doctor) doctor;;
    boot) boot;;
    firewall-reload) firewall_reload;;
    install-hooks) install_hooks;;
    version) echo "$VERSION";;
    help|-h|--help) usage;;
    *) usage; exit 1;;
esac
