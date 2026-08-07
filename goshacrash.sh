#!/bin/sh
# GoshaCrash controller for ASUSWRT.
# One management script: Mihomo lifecycle, routing, config, logs and packages.
# Zashboard updates are triggered from the native button inside Zashboard.

VERSION="3.4.4-config-dashboard-fix"
BUILD_ID="2026-08-07-config-dashboard-fix-r7"

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
PLATFORM_FILE="$STATE/platform.env"
PIDFILE="$RUN/mihomo.pid"
WATCHDOG_PIDFILE="$RUN/watchdog.pid"
BOOT_PIDFILE="$RUN/boot.pid"
START_LOCK="$RUN/start.lock"
CONTROL_LOCK="$RUN/control.lock"
MANUAL_STOP="$STATE/manual-stop"

MIHOMO_LOG="$LOGS/mihomo.log"
SYSTEM_LOG="$LOGS/goshacrash.log"
INSTALL_LOG="$LOGS/install.log"
BOOT_LOG="$LOGS/boot.log"
WATCHDOG_LOG="$LOGS/watchdog.log"
PACKAGES_LOG="$LOGS/packages.log"

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
WATCHDOG_INTERVAL="${GOSHACRASH_WATCHDOG_INTERVAL:-60}"
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

PLATFORM=""
LEGACY="1"
ROUTING_MODE="manual"
TUN_STACK="gvisor"
MIHOMO_TARGET="armv5"
MIHOMO_SOURCE=""
MIHOMO_VERSION=""
MIHOMO_URL=""
GCNET_BIN="$BASE/bin/gcnet"
DM_ROOT=""
PKG_PATH=""
ROUTER_MODEL=""
ROUTER_ARCH=""
ROUTER_KERNEL=""

PKG=""
NVRAM_BIN=""
IP_BIN=""
IPTABLES=""
IPT_WAIT=""

ensure_dirs(){ mkdir -p "$BASE/bin" "$UI" "$RUN" "$LOGS" "$STATE" "$BACKUPS" "$ROUTE_STATE" "$BASE/proxies" "$BASE/rulesets"; }
now(){ date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date; }

rotate_log(){
    file="$1"; limit="${2:-1048576}"
    [ -f "$file" ] || return 0
    size="$(wc -c < "$file" 2>/dev/null)"
    case "$size" in ''|*[!0-9]*) return 0;; esac
    [ "$size" -lt "$limit" ] && return 0
    rm -f "$file.3" 2>/dev/null || true
    [ -f "$file.2" ] && mv -f "$file.2" "$file.3" 2>/dev/null || true
    [ -f "$file.1" ] && mv -f "$file.1" "$file.2" 2>/dev/null || true
    mv -f "$file" "$file.1" 2>/dev/null || true
    : > "$file"
}

log_event(){
    level="$1"; area="$2"; shift 2
    ensure_dirs >/dev/null 2>&1 || true
    rotate_log "$SYSTEM_LOG" 1048576
    printf '[%s] [%s] [%s] %s\n' "$(now)" "$level" "$area" "$*" >> "$SYSTEM_LOG" 2>/dev/null || true
}

say(){ printf '%s\n' "[GoshaCrash] $*"; log_event INFO main "$*"; }
ok(){ printf '%s\n' "[GoshaCrash:OK] $*"; log_event OK main "$*"; }
warn(){ printf '%s\n' "[GoshaCrash:WARN] $*" >&2; log_event WARN main "$*"; }
fail(){ printf '%s\n' "[GoshaCrash:ERROR] $*" >&2; log_event ERROR main "$*"; return 1; }

load_platform(){
    [ -f "$PLATFORM_FILE" ] || { fail "Не найден $PLATFORM_FILE. Повтори установку через install.sh"; return 1; }
    . "$PLATFORM_FILE"
    [ -n "${CONFIG_FILE:-}" ] && CONFIG="$CONFIG_FILE"
    [ -n "${GCNET_BIN:-}" ] || GCNET_BIN="$BASE/bin/gcnet"
    [ -n "${DM_ROOT:-}" ] || DM_ROOT=""
    return 0
}

find_dm_root(){
    if [ -n "$DM_ROOT" ] && [ -d "$DM_ROOT" ]; then return 0; fi
    DM_ROOT=""
    for d in "$USB_MOUNT/asusware.arm" "$USB_MOUNT/asusware.arm64" "$USB_MOUNT/asusware"; do
        [ -d "$d" ] && { DM_ROOT="$d"; return 0; }
    done
    return 1
}

refresh_path(){
    find_dm_root >/dev/null 2>&1 || true
    PATH="$BASE/bin:$DM_ROOT/bin:$DM_ROOT/sbin:/opt/bin:/opt/sbin:/tmp/opt/bin:/tmp/opt/sbin:/jffs/scripts:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
    export PATH
    hash -r 2>/dev/null || true
    IP_BIN=""
    for p in /opt/sbin/ip /opt/bin/ip /tmp/opt/sbin/ip /tmp/opt/bin/ip /usr/sbin/ip /sbin/ip /usr/bin/ip /bin/ip; do
        [ -x "$p" ] && { IP_BIN="$p"; break; }
    done
    IPTABLES=""
    for p in /usr/sbin/iptables /sbin/iptables /usr/bin/iptables /bin/iptables; do
        [ -x "$p" ] && { IPTABLES="$p"; break; }
    done
}

tool_path(){
    name="$1"
    refresh_path >/dev/null 2>&1 || true
    for p in \
        "/opt/bin/$name" "/opt/sbin/$name" \
        "/tmp/opt/bin/$name" "/tmp/opt/sbin/$name" \
        "$DM_ROOT/bin/$name" "$DM_ROOT/sbin/$name" \
        "/usr/sbin/$name" "/usr/bin/$name" "/sbin/$name" "/bin/$name"; do
        [ -n "$p" ] && [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    command -v "$name" 2>/dev/null || return 1
}

have(){ tool_path "$1" >/dev/null 2>&1; }

find_nvram(){
    [ -n "$NVRAM_BIN" ] && [ -x "$NVRAM_BIN" ] && return 0
    refresh_path >/dev/null 2>&1 || true
    for p in /usr/sbin/nvram /sbin/nvram /usr/bin/nvram /bin/nvram; do
        [ -x "$p" ] && { NVRAM_BIN="$p"; return 0; }
    done
    p="$(command -v nvram 2>/dev/null)"
    [ -n "$p" ] && [ -x "$p" ] && { NVRAM_BIN="$p"; return 0; }
    return 1
}

nvram_get(){
    key="$1"
    find_nvram || return 0
    "$NVRAM_BIN" get "$key" 2>/dev/null || true
}

nvram_set(){
    key="$1"; value="$2"
    find_nvram || return 1
    "$NVRAM_BIN" set "$key=$value" 2>/dev/null
}

nvram_commit(){
    find_nvram || return 1
    "$NVRAM_BIN" commit >/dev/null 2>&1
}

find_pkg(){
    PKG=""
    find_dm_root || return 1
    for p in "$DM_ROOT/bin/opkg" "$DM_ROOT/bin/ipkg" /opt/bin/opkg /opt/bin/ipkg /tmp/opt/bin/opkg /tmp/opt/bin/ipkg; do
        [ -x "$p" ] && { PKG="$p"; break; }
    done
    [ -n "$PKG" ]
}

repair_opt(){
    find_dm_root || { fail "Download Master не найден на $USB_MOUNT"; return 1; }
    refresh_path
    if find_pkg; then ok "Download Master и пакетный менеджер готовы: $PKG"; return 0; fi

    say "Пробую штатно перезапустить окружение Download Master"
    for script in /tmp/opt/S50downloadmaster.1 "$DM_ROOT/etc/init.d/S50downloadmaster" "$DM_ROOT/etc/init.d/S50downloadmaster.1"; do
        [ -x "$script" ] || continue
        "$script" restart >> "$PACKAGES_LOG" 2>&1 || "$script" start >> "$PACKAGES_LOG" 2>&1 || true
        sleep 3
        refresh_path
        find_pkg && { ok "Пакетный менеджер восстановлен: $PKG"; return 0; }
    done
    fail "Download Master найден, но ipkg/opkg не готов. Перезапусти Download Master в веб-интерфейсе ASUS"
}

pkg_update_index(){
    repair_opt >/dev/null 2>&1 || return 1
    find_pkg || return 1
    rotate_log "$PACKAGES_LOG" 1048576
    say "Обновляю только индекс пакетов через $PKG"
    printf '[%s] RUN: %s update\n' "$(now)" "$PKG" >> "$PACKAGES_LOG"
    "$PKG" update >> "$PACKAGES_LOG" 2>&1 || { fail "Не удалось обновить индекс пакетов. См. $PACKAGES_LOG"; return 1; }
    ok "Индекс пакетов обновлён; установленные пакеты не обновлялись"
}

pkg_install(){
    name="$1"
    case "$name" in ''|*[!A-Za-z0-9+_.-]*) fail "Недопустимое имя пакета: $name"; return 1;; esac
    repair_opt >/dev/null 2>&1 || return 1
    find_pkg || return 1
    rotate_log "$PACKAGES_LOG" 1048576
    say "Устанавливаю пакет $name через $PKG"
    printf '[%s] RUN: %s install %s\n' "$(now)" "$PKG" "$name" >> "$PACKAGES_LOG"
    if ! "$PKG" install "$name" >> "$PACKAGES_LOG" 2>&1; then
        warn "Первая установка не удалась; обновляю индекс и повторяю"
        "$PKG" update >> "$PACKAGES_LOG" 2>&1 || true
        "$PKG" install "$name" >> "$PACKAGES_LOG" 2>&1 || { fail "Пакет $name не установлен. См. $PACKAGES_LOG"; return 1; }
    fi
    refresh_path
    ok "Пакет установлен: $name"
}

lan_ip(){ x="$(nvram_get lan_ipaddr)"; [ -n "$x" ] || x=192.168.1.1; printf '%s\n' "$x"; }
lan_ifaces(){ if [ -n "${GOSHACRASH_LAN_IFACES:-}" ]; then printf '%s\n' "$GOSHACRASH_LAN_IFACES"; else x="$(nvram_get lan_ifname)"; [ -n "$x" ] || x=br0; printf '%s\n' "$x"; fi; }

strip_value(){ printf '%s\n' "$1" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//'; }
yaml_top(){
    file="$1"; key="$2"
    awk -v key="$key" '
      {sub(/\r$/, "")}
      $0 ~ "^" key ":[[:space:]]*" {
        line=$0
        sub("^" key ":[[:space:]]*", "", line)
        print line
        exit
      }
    ' "$file" 2>/dev/null | while IFS= read -r line; do strip_value "$line"; done
}
yaml_section(){
    file="$1"; section="$2"; key="$3"
    awk -v section="$section" -v key="$key" '
      {sub(/\r$/, ""); sub(/[[:space:]]+$/, "")}
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

validate_binary_file(){
    file="$1"; require_gvisor="${2:-0}"
    [ -x "$file" ] || { fail "Не найден исполняемый Mihomo: $file"; return 1; }
    out="$("$file" -v 2>&1)" || { printf '%s\n' "$out" >&2; fail "Mihomo не запускается"; return 1; }
    printf '%s\n' "$out" | grep -qi mihomo || { printf '%s\n' "$out" >&2; fail "Файл не похож на Mihomo"; return 1; }
    if [ "$require_gvisor" = 1 ]; then
        printf '%s\n' "$out" | grep -Fq 'Use tags: with_gvisor' || { printf '%s\n' "$out" >&2; fail "Legacy-профилю нужна сборка with_gvisor"; return 1; }
    fi
}

required_config(){
    [ -f "$CONFIG" ] || { fail "Не найден $CONFIG"; return 1; }
    is_true "$(yaml_section "$CONFIG" tun enable)" || { fail "tun.enable должен быть true"; return 1; }
    [ "$(yaml_section "$CONFIG" tun stack)" = "$TUN_STACK" ] || { fail "tun.stack должен быть $TUN_STACK"; return 1; }
    [ "$(yaml_section "$CONFIG" tun device)" = "$TUN_DEVICE" ] || { fail "tun.device должен быть $TUN_DEVICE"; return 1; }
    is_true "$(yaml_section "$CONFIG" dns enable)" || { fail "dns.enable должен быть true"; return 1; }
    [ "$(yaml_section "$CONFIG" dns listen)" = "127.0.0.1:$DNS_PORT" ] || { fail "dns.listen должен быть 127.0.0.1:$DNS_PORT"; return 1; }
    [ "$(yaml_top "$CONFIG" external-ui)" = "ui" ] || { fail "external-ui должен быть ui"; return 1; }
    [ -n "$(yaml_top "$CONFIG" external-ui-url)" ] || { fail "Добавь external-ui-url для обновления Zashboard из самой панели"; return 1; }

    if [ "$ROUTING_MODE" = manual ]; then
        is_false "$(yaml_section "$CONFIG" tun auto-route)" || { fail "legacy: tun.auto-route должен быть false"; return 1; }
        is_false "$(yaml_section "$CONFIG" tun auto-redirect)" || { fail "legacy: tun.auto-redirect должен быть false"; return 1; }
        [ "$(yaml_top "$CONFIG" routing-mark)" = "$OUTBOUND_MARK_DEC" ] || { fail "legacy: routing-mark должен быть $OUTBOUND_MARK_DEC"; return 1; }
    else
        is_true "$(yaml_section "$CONFIG" tun auto-route)" || { fail "modern: tun.auto-route должен быть true"; return 1; }
        is_true "$(yaml_section "$CONFIG" tun auto-redirect)" || { fail "modern: tun.auto-redirect должен быть true"; return 1; }
        [ -z "$(yaml_top "$CONFIG" routing-mark)" ] || { fail "modern: routing-mark в config.yaml не нужен"; return 1; }
    fi
}

check_config_with(){
    file="$1"
    load_platform || return 1
    req=0; [ "$LEGACY" = 1 ] && req=1
    validate_binary_file "$file" "$req" || return 1
    required_config || return 1
    "$file" -t -d "$BASE" -f "$CONFIG"
}
check_config(){ check_config_with "$BIN"; }

wait_port(){ port="$1"; n=0; while [ "$n" -lt 20 ]; do netstat -ln 2>/dev/null | grep -Eq "[:.]$port[[:space:]]" && return 0; sleep 1; n=$((n + 1)); done; return 1; }

net_link_exists(){
    iface="$1"
    [ -n "$IP_BIN" ] && "$IP_BIN" link show "$iface" >/dev/null 2>&1 && return 0
    ifconfig "$iface" >/dev/null 2>&1 && return 0
    [ -x "$GCNET_BIN" ] && "$GCNET_BIN" link-exists "$iface" >/dev/null 2>&1
}
wait_tun(){ n=0; while [ "$n" -lt 20 ]; do net_link_exists "$TUN_DEVICE" && return 0; sleep 1; n=$((n + 1)); done; return 1; }

net_rule_add(){ if [ "$ROUTING_MODE" = manual ]; then "$GCNET_BIN" rule-add "$1" "$2" "$3"; else "$IP_BIN" rule add fwmark "$1" table "$2" pref "$3"; fi; }
net_rule_del(){
    mark="$1"; table="$2"; pref="${3:-}"
    if [ "$ROUTING_MODE" = manual ]; then
        if [ -n "$pref" ]; then "$GCNET_BIN" rule-del "$mark" "$table" "$pref"; else "$GCNET_BIN" rule-del "$mark" "$table"; fi
    else
        if [ -n "$pref" ]; then "$IP_BIN" rule del fwmark "$mark" table "$table" pref "$pref"; else "$IP_BIN" rule del fwmark "$mark" table "$table"; fi
    fi
}
net_rule_exists(){ if [ "$ROUTING_MODE" = manual ]; then "$GCNET_BIN" rule-exists "$1" "$2" >/dev/null 2>&1; else "$IP_BIN" rule show 2>/dev/null | grep -Eq "fwmark[[:space:]]+$1.*(lookup|table)[[:space:]]+$2"; fi; }
net_route_add_default(){ if [ "$ROUTING_MODE" = manual ]; then "$GCNET_BIN" route-add-default "$1" "$2"; else "$IP_BIN" route replace default dev "$1" table "$2"; fi; }
net_route_flush(){ if [ "$ROUTING_MODE" = manual ]; then "$GCNET_BIN" route-flush "$1"; else "$IP_BIN" route flush table "$1"; fi; }
net_route_default_exists(){ if [ "$ROUTING_MODE" = manual ]; then "$GCNET_BIN" route-default-exists "$1" "$2" >/dev/null 2>&1; else "$IP_BIN" route show table "$2" 2>/dev/null | grep -Eq "^default .*dev[[:space:]]+$1([[:space:]]|$)"; fi; }

flush_route_cache(){ [ -w "$PROC_SYS/net/ipv4/route/flush" ] && printf '%s\n' -1 > "$PROC_SYS/net/ipv4/route/flush" 2>/dev/null || true; }
ipt_init(){ IPT_WAIT=""; [ -x "$IPTABLES" ] && "$IPTABLES" -h 2>&1 | grep -q '\-w' && IPT_WAIT="-w"; }
ipt(){ if [ -n "$IPT_WAIT" ]; then "$IPTABLES" -w "$@"; else "$IPTABLES" "$@"; fi; }
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

cleanup_manual_rules(){
    [ -x "$IPTABLES" ] || return 0
    ipt_init
    for iface in $(lan_ifaces); do
        remove_jump mangle PREROUTING -i "$iface" -j "$LAN_CHAIN"
        remove_jump nat PREROUTING -i "$iface" -p udp --dport 53 -j "$DNS_LAN_CHAIN"
        remove_jump nat PREROUTING -i "$iface" -p tcp --dport 53 -j "$DNS_LAN_CHAIN"

        # Remove rules left by older GoshaCrash builds as well.
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
    while net_rule_del "$TUN_MARK" "$TUN_TABLE" "$TUN_RULE_PREF" 2>/dev/null; do :; done
    while net_rule_del "$TUN_MARK" "$TUN_TABLE" 2>/dev/null; do :; done
    net_route_flush "$TUN_TABLE" 2>/dev/null || true
    flush_route_cache
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

manual_route_start(){
    [ -x "$GCNET_BIN" ] || { fail "Legacy helper gcnet не найден: $GCNET_BIN"; return 1; }
    "$GCNET_BIN" link-exists lo >/dev/null 2>&1 || { fail "gcnet не запускается"; return 1; }
    [ -x "$IPTABLES" ] || { fail "iptables не найден"; return 1; }
    net_link_exists "$TUN_DEVICE" || { fail "TUN-интерфейс $TUN_DEVICE не найден"; return 1; }
    "$IPTABLES" -j MARK -h >/dev/null 2>&1 || { fail "Ядро не поддерживает iptables MARK"; return 1; }

    cleanup_manual_rules
    prepare_sysctls || return 1
    ipt_init
    net_route_add_default "$TUN_DEVICE" "$TUN_TABLE" || { cleanup_manual_rules; restore_sysctls; fail "Не создан default route table $TUN_TABLE"; return 1; }
    net_rule_add "$TUN_MARK" "$TUN_TABLE" "$TUN_RULE_PREF" || { cleanup_manual_rules; restore_sysctls; fail "Не создано policy rule"; return 1; }
    build_lan_chain || { cleanup_manual_rules; restore_sysctls; fail "Не создана LAN mangle-цепочка"; return 1; }
    build_router_chain || { cleanup_manual_rules; restore_sysctls; fail "Не создана router mangle-цепочка"; return 1; }
    build_dns || { cleanup_manual_rules; restore_sysctls; fail "Не создан DNS-перехват"; return 1; }
    build_forward || { cleanup_manual_rules; restore_sysctls; fail "Не созданы FORWARD-правила"; return 1; }
    flush_route_cache
    printf 'mode=manual\ndevice=%s\ntable=%s\nmark=%s\n' "$TUN_DEVICE" "$TUN_TABLE" "$TUN_MARK" > "$ROUTE_ACTIVE"
    log_event OK route "legacy route: mark $TUN_MARK -> table $TUN_TABLE -> $TUN_DEVICE"
}
manual_route_stop(){ cleanup_manual_rules; restore_sysctls; }
manual_route_status(){
    net_link_exists "$TUN_DEVICE" || return 1
    net_rule_exists "$TUN_MARK" "$TUN_TABLE" || return 1
    net_route_default_exists "$TUN_DEVICE" "$TUN_TABLE" || return 1
    ipt_init
    ipt -t mangle -S "$LAN_CHAIN" >/dev/null 2>&1 || return 1
    ipt -t nat -S "$DNS_OUT_CHAIN" >/dev/null 2>&1 || return 1
}

modern_route_start(){
    prepare_sysctls || true
    net_link_exists "$TUN_DEVICE" || { fail "Mihomo не создал $TUN_DEVICE"; return 1; }
    if [ -n "$IP_BIN" ]; then
        "$IP_BIN" route show table "$TUN_TABLE" 2>/dev/null | grep -q . || { fail "Mihomo не создал auto-route в table $TUN_TABLE"; return 1; }
        "$IP_BIN" rule show 2>/dev/null | grep -Eq "(lookup|table)[[:space:]]+$TUN_TABLE([[:space:]]|$)" || { fail "Mihomo не создал policy rule для table $TUN_TABLE"; return 1; }
    fi
    printf 'mode=auto\ndevice=%s\ntable=%s\n' "$TUN_DEVICE" "$TUN_TABLE" > "$ROUTE_ACTIVE"
    log_event OK route "modern auto-route: table $TUN_TABLE -> $TUN_DEVICE"
}
modern_route_stop(){ restore_sysctls; rm -f "$ROUTE_ACTIVE"; }
modern_route_status(){
    net_link_exists "$TUN_DEVICE" || return 1
    if [ -n "$IP_BIN" ]; then
        "$IP_BIN" route show table "$TUN_TABLE" 2>/dev/null | grep -q . || return 1
        "$IP_BIN" rule show 2>/dev/null | grep -Eq "(lookup|table)[[:space:]]+$TUN_TABLE([[:space:]]|$)" || return 1
    fi
}

route_start(){
    if [ "$ROUTING_MODE" = manual ]; then manual_route_start; else modern_route_start; fi
}
route_stop(){
    if [ "$ROUTING_MODE" = manual ]; then manual_route_stop; else modern_route_stop; fi
}
route_status(){
    if [ "$ROUTING_MODE" = manual ]; then manual_route_status; else modern_route_status; fi
}

start_runtime(){
    ensure_dirs || return 1
    load_platform || return 1
    refresh_path
    check_config || return 1
    ensure_tun || { fail "/dev/net/tun недоступен"; return 1; }
    if p="$(running_pid)"; then route_start || return 1; say "Mihomo уже работает, PID=$p"; return 0; fi

    [ "$ROUTING_MODE" = manual ] && route_stop >/dev/null 2>&1 || true
    kill_mihomo
    rotate_log "$MIHOMO_LOG" 2097152
    log_event INFO runtime "starting $BIN with $CONFIG"
    if have nohup; then
        GOGC="${GOGC:-50}" nohup "$BIN" -d "$BASE" -f "$CONFIG" </dev/null >> "$MIHOMO_LOG" 2>&1 &
    else
        GOGC="${GOGC:-50}" "$BIN" -d "$BASE" -f "$CONFIG" </dev/null >> "$MIHOMO_LOG" 2>&1 &
    fi
    p=$!; printf '%s\n' "$p" > "$PIDFILE"; sleep 3
    running_pid >/dev/null 2>&1 || { tail -n 80 "$MIHOMO_LOG" >&2; fail "Mihomo завершился при запуске"; return 1; }
    wait_port "$DNS_PORT" || { kill_mihomo; tail -n 80 "$MIHOMO_LOG" >&2; fail "DNS Mihomo не слушает порт $DNS_PORT"; return 1; }
    wait_tun || { kill_mihomo; tail -n 80 "$MIHOMO_LOG" >&2; fail "Mihomo не создал $TUN_DEVICE"; return 1; }
    route_start || { kill_mihomo; route_stop >/dev/null 2>&1 || true; fail "Маршрутизация не поднялась; оставлен DIRECT"; return 1; }
    cp -f "$CONFIG" "$BACKUPS/config.last-good.yaml" 2>/dev/null || true
    ok "Mihomo запущен, PID=$p; profile=$PLATFORM"
}

with_start_lock(){
    if ! mkdir "$START_LOCK" 2>/dev/null; then
        n=0; while [ -d "$START_LOCK" ] && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
        [ -d "$START_LOCK" ] && { fail "Другой запуск GoshaCrash не завершился"; return 1; }
        mkdir "$START_LOCK" 2>/dev/null || return 1
    fi
    "$@"; rc=$?; rmdir "$START_LOCK" 2>/dev/null || true; return "$rc"
}

stop_runtime(){
    if [ "$ROUTING_MODE" = auto ]; then kill_mihomo; route_stop >/dev/null 2>&1 || true; else route_stop >/dev/null 2>&1 || true; kill_mihomo; fi
    rm -rf "$START_LOCK" 2>/dev/null || true
    rm -f "$BOOT_PIDFILE" 2>/dev/null || true
}

watchdog_pid(){ [ -f "$WATCHDOG_PIDFILE" ] || return 1; p="$(cat "$WATCHDOG_PIDFILE" 2>/dev/null)"; case "$p" in ''|*[!0-9]*) return 1;; esac; kill -0 "$p" 2>/dev/null || { rm -f "$WATCHDOG_PIDFILE"; return 1; }; printf '%s\n' "$p"; }
watchdog_stop(){ if p="$(watchdog_pid)"; then kill "$p" 2>/dev/null || true; sleep 1; kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null || true; fi; rm -f "$WATCHDOG_PIDFILE"; }
watchdog_start(){
    [ -f "$MANUAL_STOP" ] && return 0
    watchdog_pid >/dev/null 2>&1 && return 0
    rotate_log "$WATCHDOG_LOG" 524288
    if have nohup; then GOSHACRASH_BASE="$BASE" nohup "$BASE/goshacrash.sh" watchdog-loop </dev/null >> "$WATCHDOG_LOG" 2>&1 & else GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" watchdog-loop </dev/null >> "$WATCHDOG_LOG" 2>&1 & fi
    p=$!; echo "$p" > "$WATCHDOG_PIDFILE"; sleep 1; kill -0 "$p" 2>/dev/null || { rm -f "$WATCHDOG_PIDFILE"; return 1; }
}
watchdog_check(){
    [ -f "$MANUAL_STOP" ] && return 0
    [ -d "$CONTROL_LOCK" ] && return 0
    [ -d "$START_LOCK" ] && return 0
    if ! running_pid >/dev/null 2>&1; then printf '%s Mihomo stopped; restart\n' "$(now)" >> "$WATCHDOG_LOG"; with_start_lock start_runtime >> "$WATCHDOG_LOG" 2>&1 || true; return 0; fi
    if ! route_status >/dev/null 2>&1; then printf '%s route broken; repair\n' "$(now)" >> "$WATCHDOG_LOG"; route_start >> "$WATCHDOG_LOG" 2>&1 || { stop_runtime; with_start_lock start_runtime >> "$WATCHDOG_LOG" 2>&1 || true; }; fi
}
watchdog_loop(){
    ensure_dirs || exit 1; echo "$$" > "$WATCHDOG_PIDFILE"; trap 'rm -f "$WATCHDOG_PIDFILE"; exit 0' HUP INT TERM
    while :; do sleep "$WATCHDOG_INTERVAL"; watchdog_check; rotate_log "$WATCHDOG_LOG" 524288; done
}

start(){
    ensure_dirs || return 1; load_platform || return 1; rm -f "$MANUAL_STOP"; mkdir "$CONTROL_LOCK" 2>/dev/null || true
    with_start_lock start_runtime; rc=$?; rmdir "$CONTROL_LOCK" 2>/dev/null || true; [ "$rc" -eq 0 ] && watchdog_start; return "$rc"
}
stop(){
    ensure_dirs || return 1; load_platform || true; touch "$MANUAL_STOP"; mkdir "$CONTROL_LOCK" 2>/dev/null || true
    watchdog_stop; stop_runtime; rmdir "$CONTROL_LOCK" 2>/dev/null || true; ok "Mihomo остановлен; обычный DIRECT восстановлен"
}
restart(){
    ensure_dirs || return 1; load_platform || return 1; rm -f "$MANUAL_STOP"; mkdir "$CONTROL_LOCK" 2>/dev/null || true
    watchdog_stop; stop_runtime; with_start_lock start_runtime; rc=$?; rmdir "$CONTROL_LOCK" 2>/dev/null || true; [ "$rc" -eq 0 ] && watchdog_start; return "$rc"
}

main_default_route(){
    refresh_path
    if [ -n "$IP_BIN" ]; then "$IP_BIN" route show default 2>/dev/null | grep -q '^default '; else route -n 2>/dev/null | awk '$1=="0.0.0.0" {ok=1} END{exit !ok}'; fi
}
boot(){
    ensure_dirs || return 1; load_platform || return 1
    [ -f "$MANUAL_STOP" ] && { say "Автозапуск пропущен после ручной остановки"; return 0; }
    if [ -f "$BOOT_PIDFILE" ]; then old="$(cat "$BOOT_PIDFILE" 2>/dev/null)"; case "$old" in ''|*[!0-9]*) old="";; esac; [ -n "$old" ] && kill -0 "$old" 2>/dev/null && return 0; fi
    echo "$$" > "$BOOT_PIDFILE"; repair_opt >/dev/null 2>&1 || true
    waited=0; while ! main_default_route; do [ "$waited" -ge "$BOOT_WAIT" ] && { warn "Default route не появился за $BOOT_WAIT секунд"; rm -f "$BOOT_PIDFILE"; return 0; }; sleep 5; waited=$((waited + 5)); done
    sleep 5; start; rc=$?; rm -f "$BOOT_PIDFILE"; return "$rc"
}
firewall_reload(){ load_platform || return 0; running_pid >/dev/null 2>&1 || return 0; if [ "$ROUTING_MODE" = manual ]; then route_start || { warn "Не восстановлены legacy-правила после firewall restart"; return 1; }; else restart; fi; }

add_once(){ file="$1"; line="$2"; [ -f "$file" ] || printf '#!/bin/sh\n' > "$file"; grep -Fqx "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"; chmod 755 "$file"; }
remove_hook_line(){ file="$1"; pattern="$2"; [ -f "$file" ] || return 0; tmp="$file.gc.$$"; grep -Fv "$pattern" "$file" > "$tmp" 2>/dev/null || true; mv -f "$tmp" "$file"; chmod 755 "$file" 2>/dev/null || true; }

write_command_wrapper(){
    dst="$1"
    cat > "$dst" <<'WRAP'
#!/bin/sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -n "$BASE" ] && [ -x "$BASE/goshacrash.sh" ] || { echo "GoshaCrash не найден на USB" >&2; exit 1; }
GOSHACRASH_BASE="$BASE"
export GOSHACRASH_BASE
exec "$BASE/goshacrash.sh" "$@"
WRAP
    chmod 755 "$dst"
}

remove_legacy_hook_lines(){
    file="$1"
    [ -f "$file" ] || return 0
    tmp="$file.goshacrash.$$"
    awk '
      /goshacrash-autostart/ {next}
      /goshacrash-route/ {next}
      /GoshaCrash-USB\/install\.sh/ {next}
      /GoshaCrash-USB\/goshacrash[[:space:]]+(boot|firewall|firewall-reload)/ {next}
      /\/jffs\/scripts\/goshacrash-start/ {next}
      /\/jffs\/scripts\/goshacrash-firewall/ {next}
      {print}
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$file" || return 1
    chmod 755 "$file" 2>/dev/null || true
}

rewrite_nvram_hook(){
    key="$1"; begin="$2"; end="$3"; body="$4"
    find_nvram || return 0
    tmp="$RUN/nvram-hook.$$"
    old="$(nvram_get "$key")"
    printf '%s\n' "$old" | awk -v b="$begin" -v e="$end" '
      index($0,b) {skip=1; next}
      index($0,e) {skip=0; next}
      !skip {print}
    ' > "$tmp" || return 1
    {
        cat "$tmp"
        printf '%s\n' "$begin"
        printf '%s\n' "$body"
        printf '%s\n' "$end"
    } > "$tmp.new" || return 1
    value="$(cat "$tmp.new")"
    nvram_set "$key" "$value" || { rm -f "$tmp" "$tmp.new"; return 1; }
    rm -f "$tmp" "$tmp.new"
}

install_nvram_usb_hooks(){
    find_nvram || { warn "nvram недоступен: USB hooks через NVRAM пропущены; JFFS и Download Master hooks уже установлены"; return 0; }
    rewrite_nvram_hook script_usbmount '# GOSHACRASH_USBMOUNT_BEGIN' '# GOSHACRASH_USBMOUNT_END'       'BASE=$(cat /jffs/addons/goshacrash/base 2>/dev/null); [ -x "$BASE/goshacrash.sh" ] && /jffs/addons/goshacrash/start.sh &' || warn "Не удалось записать stock ASUS USB-mount hook"
    rewrite_nvram_hook script_usbumount '# GOSHACRASH_USBUMOUNT_BEGIN' '# GOSHACRASH_USBUMOUNT_END'       'BASE=$(cat /jffs/addons/goshacrash/base 2>/dev/null); [ -x "$BASE/goshacrash.sh" ] && GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" stop >/dev/null 2>&1' || warn "Не удалось записать stock ASUS USB-unmount hook"
    [ "$(nvram_get jffs2_scripts)" = 1 ] || nvram_set jffs2_scripts 1 || true
    nvram_commit || true
}

remove_nvram_usb_hooks(){
    find_nvram || return 0
    for spec in       'script_usbmount|# GOSHACRASH_USBMOUNT_BEGIN|# GOSHACRASH_USBMOUNT_END'       'script_usbumount|# GOSHACRASH_USBMOUNT_BEGIN|# GOSHACRASH_USBUMOUNT_END'; do
        key="${spec%%|*}"; rest="${spec#*|}"; begin="${rest%%|*}"; end="${rest#*|}"
        tmp="$RUN/nvram-remove.$$"
        nvram_get "$key" | awk -v b="$begin" -v e="$end" '
          index($0,b) {skip=1; next}
          index($0,e) {skip=0; next}
          !skip {print}
        ' > "$tmp" || continue
        value="$(cat "$tmp")"
        nvram_set "$key" "$value" || true
        rm -f "$tmp"
    done
    nvram_commit || true
}

write_nano_wrapper(){
    dst="$1"
    cat > "$dst" <<'WRAP'
#!/bin/sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
DM=""
[ -f "$BASE/state/platform.env" ] && . "$BASE/state/platform.env"
for p in /opt/bin/nano /tmp/opt/bin/nano "$DM_ROOT/bin/nano"; do
  [ -x "$p" ] && exec "$p" "$@"
done
echo "nano не найден. Запусти: goshacrash pkg install nano" >&2
exit 1
WRAP
    chmod 755 "$dst"
}

install_hooks(){
    ensure_dirs || return 1; load_platform || return 1; find_dm_root || { fail "Download Master не найден"; return 1; }
    mkdir -p "$JFFS_DIR" /jffs/scripts /jffs/configs "$DM_ROOT/bin" "$DM_ROOT/etc/init.d" || return 1
    printf '%s\n' "$BASE" > "$JFFS_BASE_FILE" || return 1

    cat > "$JFFS_DIR/start.sh" <<'HOOK'
#!/bin/sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -x "$BASE/goshacrash.sh" ] || exit 0
mkdir -p "$BASE/logs" "$BASE/run" "$BASE/state" 2>/dev/null || true
touch "$BASE/state/autostart-hook-ran" 2>/dev/null || true
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

    remove_legacy_hook_lines /jffs/scripts/services-start || return 1
    remove_legacy_hook_lines /jffs/scripts/firewall-start || return 1
    rm -f /jffs/scripts/goshacrash-start /jffs/scripts/goshacrash-firewall /jffs/scripts/goshacrash-autostart /jffs/scripts/goshacrash-route 2>/dev/null || true
    add_once /jffs/scripts/services-start "$JFFS_DIR/start.sh &"
    add_once /jffs/scripts/firewall-start "$JFFS_DIR/firewall.sh &"
    write_command_wrapper /jffs/scripts/goshacrash
    write_nano_wrapper /jffs/scripts/nano
    write_command_wrapper "$DM_ROOT/bin/goshacrash"

    # /opt is managed by Download Master. Copy only when its bin directory is writable.
    if [ -d /opt/bin ] && [ -w /opt/bin ]; then write_command_wrapper /opt/bin/goshacrash 2>/dev/null || true; fi

    add_once /jffs/configs/profile.add 'export PATH="/jffs/scripts:/opt/bin:/opt/sbin:/tmp/opt/bin:/tmp/opt/sbin:$PATH"'

    cat > "$DM_ROOT/etc/init.d/S99goshacrash" <<'INIT'
#!/bin/sh
case "$1" in
  start) /jffs/addons/goshacrash/start.sh & ;;
  stop) /jffs/scripts/goshacrash stop ;;
  restart) /jffs/scripts/goshacrash restart ;;
  firewall-start|firewall-restart) /jffs/addons/goshacrash/firewall.sh & ;;
esac
INIT
    chmod 755 "$DM_ROOT/etc/init.d/S99goshacrash" || return 1

    install_nvram_usb_hooks || true
    ok "Автозапуск установлен: JFFS + Download Master + stock ASUS USB hook"
    ok "goshacrash и nano доступны без привязки к текущему каталогу"
}

remove_hooks(){
    load_platform >/dev/null 2>&1 || true; find_dm_root >/dev/null 2>&1 || true
    remove_hook_line /jffs/scripts/services-start "$JFFS_DIR/start.sh &"
    remove_hook_line /jffs/scripts/firewall-start "$JFFS_DIR/firewall.sh &"
    rm -f /jffs/scripts/goshacrash /jffs/scripts/nano 2>/dev/null || true
    if [ -n "$DM_ROOT" ]; then
        rm -f "$DM_ROOT/bin/goshacrash" "$DM_ROOT/etc/init.d/S99goshacrash" 2>/dev/null || true
    fi
    remove_nvram_usb_hooks || true
    rm -rf "$JFFS_DIR" 2>/dev/null || true
}

backup_config(){
    [ -f "$CONFIG" ] || return 1
    stamp="$(date '+%Y%m%d-%H%M%S' 2>/dev/null)"; [ -n "$stamp" ] || stamp="backup"
    dst="$BACKUPS/config-$stamp.yaml"; cp -f "$CONFIG" "$dst" || return 1; printf '%s\n' "$dst"
}

find_editor(){
    refresh_path
    for e in /opt/bin/nano /tmp/opt/bin/nano "$DM_ROOT/bin/nano" /jffs/scripts/nano; do [ -x "$e" ] && { printf '%s\n' "$e"; return 0; }; done
    return 1
}

apply_config(){
    check_config || return 1
    backup="$(backup_config)" || true
    if restart; then ok "config.yaml проверен и применён"; return 0; fi
    if [ -f "$BACKUPS/config.last-good.yaml" ]; then
        warn "Новый конфиг не запустился; возвращаю последний рабочий"
        cp -f "$BACKUPS/config.last-good.yaml" "$CONFIG" || return 1
        restart
        return $?
    fi
    [ -n "$backup" ] && warn "Резервная копия: $backup"
    return 1
}

edit_config(){
    load_platform || return 1; refresh_path
    editor="$(find_editor 2>/dev/null)"
    if [ -z "$editor" ]; then
        warn "nano не найден; устанавливаю через Download Master"
        pkg_install nano || return 1
        editor="$(find_editor 2>/dev/null)" || { fail "nano не найден после установки"; return 1; }
    fi
    backup="$(backup_config)" || { fail "Не создана резервная копия config.yaml"; return 1; }
    say "Резервная копия: $backup"
    TERM="${TERM:-xterm}" "$editor" "$CONFIG" || { warn "Редактор завершился с ошибкой"; return 1; }
    if ! check_config; then cp -f "$backup" "$CONFIG"; fail "Конфиг некорректен; восстановлена предыдущая версия"; return 1; fi
    if ! restart; then cp -f "$backup" "$CONFIG"; warn "Новый конфиг не запустился; восстановлен старый"; restart || true; return 1; fi
    ok "config.yaml сохранён и применён"
}

controller_port(){
    c="$(yaml_top "$CONFIG" external-controller)"
    [ -n "$c" ] || c="0.0.0.0:9090"
    p="${c##*:}"
    case "$p" in ''|*[!0-9]*) p=9090;; esac
    printf '%s\n' "$p"
}

dashboard_base_url(){
    ip="$(lan_ip)"
    port="$(controller_port)"
    printf 'http://%s:%s/ui/
' "$ip" "$port"
}

dashboard_url(){
    load_platform >/dev/null 2>&1 || true
    ip="$(lan_ip)"
    port="$(controller_port)"
    secret="$(yaml_top "$CONFIG" secret)"
    url="http://$ip:$port/ui/#/setup?hostname=$ip&port=$port"
    [ -n "$secret" ] && url="$url&secret=$secret"
    [ "${LEGACY:-1}" = 1 ] && url="$url&disableUpgradeCore=1"
    url="$url&type=clash"
    printf '%s
' "$url"
}


show_logs(){
    kind="${1:-mihomo}"; lines="${2:-100}"; case "$lines" in ''|*[!0-9]*) lines=100;; esac
    case "$kind" in
        mihomo) tail -n "$lines" "$MIHOMO_LOG" 2>/dev/null || true;;
        system|goshacrash) tail -n "$lines" "$SYSTEM_LOG" 2>/dev/null || true;;
        install) tail -n "$lines" "$INSTALL_LOG" 2>/dev/null || true;;
        boot) tail -n "$lines" "$BOOT_LOG" 2>/dev/null || true;;
        watchdog) tail -n "$lines" "$WATCHDOG_LOG" 2>/dev/null || true;;
        packages) tail -n "$lines" "$PACKAGES_LOG" 2>/dev/null || true;;
        follow) tail -f "$MIHOMO_LOG";;
        *) echo "logs: mihomo|system|install|boot|watchdog|packages|follow"; return 1;;
    esac
}

status(){
    ensure_dirs >/dev/null 2>&1 || true
    load_platform >/dev/null 2>&1 || true
    refresh_path

    if p="$(running_pid)"; then
        echo "Mihomo: работает, PID=$p"
    else
        echo "Mihomo: не запущен"
    fi

    if [ "${LEGACY:-0}" = 1 ]; then
        echo "Профиль: legacy"
    else
        echo "Профиль: modern"
    fi

    echo "Конфиг: $CONFIG"
    net_link_exists "$TUN_DEVICE" && echo "TUN: $TUN_DEVICE работает" || echo "TUN: $TUN_DEVICE не найден"
    if running_pid >/dev/null 2>&1 && route_status >/dev/null 2>&1; then
        echo "Маршрутизация: работает"
    else
        echo "Маршрутизация: не работает"
    fi
    echo "Zashboard: $(dashboard_base_url)"
}

doctor(){
    load_platform >/dev/null 2>&1 || true; refresh_path
    echo '=== platform ==='; cat "$PLATFORM_FILE" 2>/dev/null || true
    echo; echo '=== files ==='; ls -l "$BASE/goshacrash.sh" "$BIN" "$GCNET_BIN" "$CONFIG" "$UI/index.html" 2>/dev/null || true
    echo; echo '=== package environment ==='; ls -ld /opt /tmp/opt "$DM_ROOT" 2>/dev/null || true; find_pkg && echo "PKG=$PKG" || echo 'PKG=MISSING'
    echo; echo '=== binary ==='; [ -x "$BIN" ] && "$BIN" -v 2>&1 || true
    echo; echo '=== config ==='; check_config || true
    echo; echo '=== tun ==='; ensure_tun && echo '/dev/net/tun: OK' || echo '/dev/net/tun: ERROR'
    echo; echo '=== status ==='; status
    echo; echo '=== routes ==='
    if [ "$ROUTING_MODE" = manual ] && [ -x "$GCNET_BIN" ]; then "$GCNET_BIN" rule-list 2>/dev/null || true; "$GCNET_BIN" route-list "$TUN_TABLE" 2>/dev/null || true; elif [ -n "$IP_BIN" ]; then "$IP_BIN" rule show 2>/dev/null || true; "$IP_BIN" route show table "$TUN_TABLE" 2>/dev/null || true; fi
    echo; echo '=== iptables ==='; [ -x "$IPTABLES" ] && { "$IPTABLES" -t mangle -L "$LAN_CHAIN" -n -v 2>/dev/null || true; "$IPTABLES" -t nat -L "$DNS_OUT_CHAIN" -n -v 2>/dev/null || true; }
    echo; echo '=== recent Mihomo log ==='; tail -n 100 "$MIHOMO_LOG" 2>/dev/null || true
}

usage(){
    cat <<USAGE
GoshaCrash

  goshacrash help
  goshacrash status
  goshacrash start
  goshacrash restart
  goshacrash stop
  goshacrash check
  goshacrash apply
  goshacrash edit
  goshacrash dashboard
  goshacrash logs [mihomo|system|install|boot|watchdog|packages|follow] [N]
  goshacrash pkg repair
  goshacrash pkg update
  goshacrash pkg install ИМЯ
  goshacrash doctor

Zashboard обновляется кнопкой в самой панели.
На legacy обновление Mihomo не предлагается.
USAGE
}

ensure_dirs >/dev/null 2>&1 || true
load_platform >/dev/null 2>&1 || true
refresh_path >/dev/null 2>&1 || true
case "${1:-help}" in
    help|-h|--help) usage;;
    start) start;;
    stop|direct) stop;;
    restart) restart;;
    status) status;;
    check) check_config;;
    apply) apply_config;;
    edit|nano) edit_config;;
    dashboard|url|ui) dashboard_url;;
    logs) shift; show_logs "${1:-mihomo}" "${2:-100}";;
    pkg|package)
        shift
        case "${1:-}" in
            repair|check) repair_opt;;
            update) pkg_update_index;;
            install) [ -n "${2:-}" ] || { fail "Укажи имя пакета"; exit 1; }; pkg_install "$2";;
            *) echo 'Использование: goshacrash pkg repair|update|install ИМЯ'; exit 1;;
        esac
        ;;
    doctor) doctor;;
    boot) boot;;
    firewall-reload) firewall_reload;;
    watchdog-loop) watchdog_loop;;
    watchdog-check) watchdog_check;;
    install-hooks) install_hooks;;
    remove-hooks) remove_hooks;;
    version) echo "$VERSION";;
    *) echo "Неизвестная команда: $1" >&2; echo >&2; usage; exit 1;;
esac
