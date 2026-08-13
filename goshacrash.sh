#!/bin/sh
# GoshaCrash controller for ASUSWRT.
# One management script: Mihomo lifecycle, routing, config, logs and packages.
# Zashboard updates are triggered from the native button inside Zashboard.

VERSION="3.7.4"
BUILD_ID="2026-08-13-release-r4"

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
NET_BACKEND=""

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
    stack="$(yaml_section "$CONFIG" tun stack)"
    [ -n "$stack" ] || { fail "tun.stack не задан"; return 1; }
    if [ "$MIHOMO_TARGET" = armv5 ] && [ "$stack" != gvisor ]; then
        fail "ARMv5 требует tun.stack: gvisor"
        return 1
    fi
    [ "$(yaml_section "$CONFIG" tun device)" = "$TUN_DEVICE" ] || { fail "tun.device должен быть $TUN_DEVICE"; return 1; }
    is_true "$(yaml_section "$CONFIG" dns enable)" || { fail "dns.enable должен быть true"; return 1; }
    [ "$(yaml_section "$CONFIG" dns listen)" = "127.0.0.1:$DNS_PORT" ] || { fail "dns.listen должен быть 127.0.0.1:$DNS_PORT"; return 1; }
    [ "$(yaml_top "$CONFIG" external-ui)" = "ui" ] || { fail "external-ui должен быть ui"; return 1; }
    [ -n "$(yaml_top "$CONFIG" external-ui-url)" ] || { fail "Добавь external-ui-url для обновления Zashboard из самой панели"; return 1; }

    if [ "$ROUTING_MODE" = manual ]; then
        is_false "$(yaml_section "$CONFIG" tun auto-route)" || { fail "manual: tun.auto-route должен быть false"; return 1; }
        is_false "$(yaml_section "$CONFIG" tun auto-redirect)" || { fail "manual: tun.auto-redirect должен быть false"; return 1; }
        [ "$(yaml_top "$CONFIG" routing-mark)" = "$OUTBOUND_MARK_DEC" ] || { fail "manual: routing-mark должен быть $OUTBOUND_MARK_DEC"; return 1; }
    else
        [ "$MIHOMO_TARGET" != armv5 ] || { fail "ARMv5 не поддерживает automatic routing в GoshaCrash"; return 1; }
        is_true "$(yaml_section "$CONFIG" tun auto-route)" || { fail "auto: tun.auto-route должен быть true"; return 1; }
        is_true "$(yaml_section "$CONFIG" tun auto-redirect)" || { fail "auto: tun.auto-redirect должен быть true"; return 1; }
        [ -z "$(yaml_top "$CONFIG" routing-mark)" ] || { fail "auto: routing-mark в конфиге не нужен"; return 1; }
    fi
}

check_config_with(){
    file="$1"
    load_platform || return 1
    req=0; [ "$MIHOMO_TARGET" = armv5 ] && req=1
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

select_net_backend(){
    NET_BACKEND=""
    if [ "$MIHOMO_TARGET" = armv5 ] && [ -x "$GCNET_BIN" ]; then
        "$GCNET_BIN" link-exists lo >/dev/null 2>&1 && NET_BACKEND="gcnet"
    fi
    if [ -z "$NET_BACKEND" ] && [ -n "$IP_BIN" ]; then NET_BACKEND="ip"; fi
    if [ -z "$NET_BACKEND" ] && [ -x "$GCNET_BIN" ]; then
        "$GCNET_BIN" link-exists lo >/dev/null 2>&1 && NET_BACKEND="gcnet"
    fi
    [ -n "$NET_BACKEND" ] || { fail "Нет инструмента policy routing: нужен ip или совместимый gcnet"; return 1; }
}

net_rule_add(){
    [ -n "$NET_BACKEND" ] || select_net_backend || return 1
    if [ "$NET_BACKEND" = gcnet ]; then "$GCNET_BIN" rule-add "$1" "$2" "$3"; else "$IP_BIN" rule add fwmark "$1" table "$2" pref "$3"; fi
}
net_rule_del(){
    mark="$1"; table="$2"; pref="${3:-}"
    [ -n "$NET_BACKEND" ] || select_net_backend >/dev/null 2>&1 || return 1
    if [ "$NET_BACKEND" = gcnet ]; then
        if [ -n "$pref" ]; then "$GCNET_BIN" rule-del "$mark" "$table" "$pref"; else "$GCNET_BIN" rule-del "$mark" "$table"; fi
    else
        if [ -n "$pref" ]; then "$IP_BIN" rule del fwmark "$mark" table "$table" pref "$pref"; else "$IP_BIN" rule del fwmark "$mark" table "$table"; fi
    fi
}
net_rule_exists(){
    [ -n "$NET_BACKEND" ] || select_net_backend >/dev/null 2>&1 || return 1
    if [ "$NET_BACKEND" = gcnet ]; then "$GCNET_BIN" rule-exists "$1" "$2" >/dev/null 2>&1; else "$IP_BIN" rule show 2>/dev/null | grep -Eq "fwmark[[:space:]]+$1.*(lookup|table)[[:space:]]+$2"; fi
}
net_route_add_default(){
    [ -n "$NET_BACKEND" ] || select_net_backend || return 1
    if [ "$NET_BACKEND" = gcnet ]; then "$GCNET_BIN" route-add-default "$1" "$2"; else "$IP_BIN" route replace default dev "$1" table "$2"; fi
}
net_route_flush(){
    [ -n "$NET_BACKEND" ] || select_net_backend >/dev/null 2>&1 || return 0
    if [ "$NET_BACKEND" = gcnet ]; then "$GCNET_BIN" route-flush "$1"; else "$IP_BIN" route flush table "$1"; fi
}
net_route_default_exists(){
    [ -n "$NET_BACKEND" ] || select_net_backend >/dev/null 2>&1 || return 1
    if [ "$NET_BACKEND" = gcnet ]; then "$GCNET_BIN" route-default-exists "$1" "$2" >/dev/null 2>&1; else "$IP_BIN" route show table "$2" 2>/dev/null | grep -Eq "^default .*dev[[:space:]]+$1([[:space:]]|$)"; fi
}

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
    select_net_backend || return 1
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
    log_event OK route "manual route ($NET_BACKEND): mark $TUN_MARK -> table $TUN_TABLE -> $TUN_DEVICE"
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
    is_true "$(yaml_section "$CONFIG" tun auto-route)" || { fail "В конфиге выключен auto-route"; return 1; }
    is_true "$(yaml_section "$CONFIG" tun auto-redirect)" || { fail "В конфиге выключен auto-redirect"; return 1; }
    printf 'mode=auto\ndevice=%s\n' "$TUN_DEVICE" > "$ROUTE_ACTIVE"
    log_event OK route "automatic routing управляется Mihomo"
}
modern_route_stop(){ restore_sysctls; rm -f "$ROUTE_ACTIVE"; }
modern_route_status(){
    net_link_exists "$TUN_DEVICE" || return 1
    is_true "$(yaml_section "$CONFIG" tun auto-route)" || return 1
    is_true "$(yaml_section "$CONFIG" tun auto-redirect)" || return 1
    if [ -n "$IP_BIN" ]; then
        "$IP_BIN" route show table all 2>/dev/null | grep -Eq "dev[[:space:]]+$TUN_DEVICE([[:space:]]|$)" || return 1
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
    ensure_dirs || return 1
    load_platform || return 1
    refresh_path

    # restart is the only public start/apply action:
    # validate before touching a working runtime, then restart/start it.
    check_config || return 1
    backup_config >/dev/null 2>&1 || true

    rm -f "$MANUAL_STOP"
    mkdir "$CONTROL_LOCK" 2>/dev/null || true
    watchdog_stop
    stop_runtime
    with_start_lock start_runtime
    rc=$?
    rmdir "$CONTROL_LOCK" 2>/dev/null || true
    if [ "$rc" -eq 0 ]; then
        watchdog_start
        return 0
    fi

    # If a newly edited config starts badly, restore the last known-good one.
    if [ -f "$BACKUPS/config.last-good.yaml" ]; then
        warn "Новый config.yaml не запустился; возвращаю последний рабочий"
        cp -f "$BACKUPS/config.last-good.yaml" "$CONFIG" || return 1
        rm -f "$MANUAL_STOP"
        mkdir "$CONTROL_LOCK" 2>/dev/null || true
        with_start_lock start_runtime >/dev/null 2>&1 || true
        rmdir "$CONTROL_LOCK" 2>/dev/null || true
        running_pid >/dev/null 2>&1 && watchdog_start >/dev/null 2>&1 || true
    fi
    return 1
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


yaml_set_section_key(){
    file="$1"; section="$2"; key="$3"; value="$4"; tmp="$file.gc.$$"
    awk -v section="$section" -v key="$key" -v value="$value" '
      BEGIN {inside=0; found=0}
      $0 ~ "^" section ":[[:space:]]*($|#)" {inside=1; found=0; print; next}
      inside && /^[^[:space:]#]/ {if(!found) print "  " key ": " value; inside=0}
      inside && $0 ~ "^[[:space:]]+" key ":[[:space:]]*" {indent=$0; sub(/[^[:space:]].*$/, "", indent); print indent key ": " value; found=1; next}
      {print}
      END {if(inside && !found) print "  " key ": " value}
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$file"
}

yaml_set_top_key(){
    file="$1"; key="$2"; value="$3"; tmp="$file.gc.$$"
    awk -v key="$key" -v value="$value" 'BEGIN{done=0} $0 ~ "^" key ":[[:space:]]*" {if(!done){print key ": " value; done=1}; next} {print} END{if(!done) print key ": " value}' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$file"
}

yaml_remove_top_key(){
    file="$1"; key="$2"; tmp="$file.gc.$$"
    awk -v key="$key" '$0 !~ "^" key ":[[:space:]]*" {print}' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$file"
}

platform_set(){
    key="$1"; value="$2"; tmp="$PLATFORM_FILE.gc.$$"
    awk -v key="$key" -v value="$value" '
      BEGIN{done=0}
      $0 ~ "^" key "=" {if(!done){print key "=\"" value "\""; done=1}; next}
      {print}
      END{if(!done) print key "=\"" value "\""}
    ' "$PLATFORM_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$PLATFORM_FILE"
    chmod 600 "$PLATFORM_FILE" 2>/dev/null || true
}

rewrite_config_for_routing(){
    mode="$1"
    if [ "$mode" = auto ]; then
        [ "$MIHOMO_TARGET" != armv5 ] || { fail "ARMv5: automatic routing недоступен"; return 1; }
        yaml_set_section_key "$CONFIG" tun stack system || return 1
        yaml_set_section_key "$CONFIG" tun auto-route true || return 1
        yaml_set_section_key "$CONFIG" tun auto-redirect true || return 1
        yaml_set_section_key "$CONFIG" tun auto-detect-interface true || return 1
        yaml_remove_top_key "$CONFIG" routing-mark || return 1
    else
        stack="system"; [ "$MIHOMO_TARGET" = armv5 ] && stack="gvisor"
        yaml_set_section_key "$CONFIG" tun stack "$stack" || return 1
        yaml_set_section_key "$CONFIG" tun auto-route false || return 1
        yaml_set_section_key "$CONFIG" tun auto-redirect false || return 1
        yaml_set_section_key "$CONFIG" tun auto-detect-interface false || return 1
        yaml_set_top_key "$CONFIG" routing-mark "$OUTBOUND_MARK_DEC" || return 1
    fi
}

set_routing_mode(){
    mode="$1"
    case "$mode" in manual|auto) ;; *) fail "routing: manual|auto|status"; return 1;; esac
    load_platform || return 1
    [ "$mode" != auto ] || [ "$MIHOMO_TARGET" != armv5 ] || { fail "ARMv5 поддерживает только manual routing"; return 1; }
    if [ "$ROUTING_MODE" = "$mode" ]; then
        say "Маршрутизация уже: $mode"
        return 0
    fi

    ensure_dirs || return 1
    cfg_backup="$BACKUPS/$(basename "$CONFIG").routing-before-$(date '+%Y%m%d-%H%M%S' 2>/dev/null)"
    state_backup="$BACKUPS/platform.env.routing-before-$$"
    cp -f "$CONFIG" "$cfg_backup" || return 1
    cp -f "$PLATFORM_FILE" "$state_backup" || return 1

    watchdog_stop
    stop_runtime
    if ! rewrite_config_for_routing "$mode"; then
        cp -f "$cfg_backup" "$CONFIG"; return 1
    fi
    stack="system"; [ "$MIHOMO_TARGET" = armv5 ] && stack="gvisor"
    platform_set ROUTING_MODE "$mode" || { cp -f "$cfg_backup" "$CONFIG"; cp -f "$state_backup" "$PLATFORM_FILE"; return 1; }
    platform_set TUN_STACK "$stack" || { cp -f "$cfg_backup" "$CONFIG"; cp -f "$state_backup" "$PLATFORM_FILE"; return 1; }
    load_platform || return 1

    if check_config && with_start_lock start_runtime; then
        rm -f "$MANUAL_STOP"
        watchdog_start
        cp -f "$CONFIG" "$BACKUPS/config.last-good.yaml" 2>/dev/null || true
        ok "Маршрутизация переключена на $mode"
        return 0
    fi

    warn "Новый режим не запустился; возвращаю предыдущую конфигурацию"
    stop_runtime >/dev/null 2>&1 || true
    cp -f "$cfg_backup" "$CONFIG"
    cp -f "$state_backup" "$PLATFORM_FILE"
    load_platform >/dev/null 2>&1 || true
    with_start_lock start_runtime >/dev/null 2>&1 || true
    watchdog_start >/dev/null 2>&1 || true
    return 1
}

routing_status(){
    load_platform || return 1
    echo "Routing: $ROUTING_MODE"
    echo "Mihomo target: $MIHOMO_TARGET"
    if [ "$MIHOMO_TARGET" = armv5 ]; then echo "Automatic: недоступен для ARMv5"; else echo "Automatic: доступен"; fi
}

controller_port(){
    c="$(yaml_top "$CONFIG" external-controller)"
    [ -n "$c" ] || c="0.0.0.0:9090"
    p="${c##*:}"
    case "$p" in ''|*[!0-9]*) p=9090;; esac
    printf '%s\n' "$p"
}

dashboard_plain_url(){
    ip="$(lan_ip)"
    port="$(controller_port)"
    printf 'http://%s:%s/ui/\n' "$ip" "$port"
}

dashboard_url(){
    # Always hand users a setup URL so Zashboard receives the per-backend
    # feature flags.  On legacy ARMv5 the Mihomo binary is deliberately
    # pinned, therefore the native core-upgrade action must never be offered.
    load_platform >/dev/null 2>&1 || true
    ip="$(lan_ip)"
    port="$(controller_port)"
    secret="$(yaml_top "$CONFIG" secret)"
    url="http://$ip:$port/ui/#/setup?hostname=$ip&port=$port"
    [ -n "$secret" ] && url="$url&secret=$secret"
    if [ "${MIHOMO_TARGET:-}" = armv5 ] || [ "${LEGACY:-0}" = 1 ]; then
        url="$url&disableUpgradeCore=1"
    fi
    url="$url&type=clash"
    printf '%s\n' "$url"
}

dashboard_base_url(){
    # Do not leak an unprotected plain /ui/ URL for legacy ARMv5. Opening the
    # plain URL bypasses Zashboard's disableUpgradeCore setup flag and makes
    # the dangerous core-upgrade button visible again.
    load_platform >/dev/null 2>&1 || true
    if [ "${MIHOMO_TARGET:-}" = armv5 ] || [ "${LEGACY:-0}" = 1 ]; then
        dashboard_url
    else
        dashboard_plain_url
    fi
}


log_file_for_kind(){
    case "${1:-mihomo}" in
        mihomo) printf '%s\n' "$MIHOMO_LOG";;
        system|goshacrash) printf '%s\n' "$SYSTEM_LOG";;
        install) printf '%s\n' "$INSTALL_LOG";;
        boot) printf '%s\n' "$BOOT_LOG";;
        watchdog) printf '%s\n' "$WATCHDOG_LOG";;
        packages) printf '%s\n' "$PACKAGES_LOG";;
        *) return 1;;
    esac
}

show_logs(){
    kind="${1:-mihomo}"; lines="${2:-100}"; case "$lines" in ''|*[!0-9]*) lines=100;; esac
    file="$(log_file_for_kind "$kind")" || {
        echo "logs: mihomo|system|install|boot|watchdog|packages"
        return 1
    }
    tail -n "$lines" "$file" 2>/dev/null || true
}

follow_logs(){
    kind="${1:-mihomo}"; lines="${2:-100}"; case "$lines" in ''|*[!0-9]*) lines=100;; esac
    file="$(log_file_for_kind "$kind")" || {
        echo "live logs: mihomo|system|install|boot|watchdog|packages"
        return 1
    }
    [ -e "$file" ] || : > "$file"
    echo "Live log: $kind ($file)"
    echo "Ctrl+C — выйти из live-режима"
    tail -n "$lines" -f "$file"
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
        [ "${MIHOMO_TARGET:-}" = armv5 ] && echo "Ядро: закреплено для legacy ARMv5; обновление ядра отключено"
    else
        echo "Профиль: modern"
    fi
    echo "Режим маршрутизации: $ROUTING_MODE"

    echo "Конфиг: $CONFIG"
    net_link_exists "$TUN_DEVICE" && echo "TUN: $TUN_DEVICE работает" || echo "TUN: $TUN_DEVICE не найден"
    if running_pid >/dev/null 2>&1 && route_status >/dev/null 2>&1; then
        echo "Состояние маршрутизации: работает"
    else
        echo "Состояние маршрутизации: не работает"
    fi
    echo "Zashboard: $(dashboard_base_url)"
}

menu_find_stty(){
    MENU_STTY_BACKEND=""
    MENU_STTY_BIN=""

    stty_bin="$(command -v stty 2>/dev/null)"
    if [ -n "$stty_bin" ] && [ -x "$stty_bin" ]; then
        MENU_STTY_BACKEND="binary"
        MENU_STTY_BIN="$stty_bin"
        return 0
    fi

    busybox_bin="$(command -v busybox 2>/dev/null)"
    if [ -n "$busybox_bin" ] && "$busybox_bin" stty --help >/dev/null 2>&1; then
        MENU_STTY_BACKEND="busybox"
        MENU_STTY_BIN="$busybox_bin"
        return 0
    fi

    return 1
}

menu_stty_raw(){
    case "$MENU_STTY_BACKEND" in
        binary) "$MENU_STTY_BIN" "$@" ;;
        busybox) "$MENU_STTY_BIN" stty "$@" ;;
        *) return 127 ;;
    esac
}

menu_terminal_init(){
    MENU_TTY_MODE=""
    MENU_OLD_STTY=""
    MENU_STTY_BACKEND=""
    MENU_STTY_BIN=""

    menu_find_stty || return 1

    if [ -r /dev/tty ] || [ -w /dev/tty ]; then
        MENU_OLD_STTY="$(menu_stty_raw -g </dev/tty 2>/dev/null)" || MENU_OLD_STTY=""
        if [ -n "$MENU_OLD_STTY" ]; then
            MENU_TTY_MODE="devtty"
            return 0
        fi
    fi

    if [ -t 0 ] && [ -t 1 ]; then
        MENU_OLD_STTY="$(menu_stty_raw -g 2>/dev/null)" || MENU_OLD_STTY=""
        if [ -n "$MENU_OLD_STTY" ]; then
            MENU_TTY_MODE="stdin"
            return 0
        fi
    fi

    return 1
}

menu_stty(){
    if [ "$MENU_TTY_MODE" = "devtty" ]; then
        menu_stty_raw "$@" </dev/tty 2>/dev/null
    else
        menu_stty_raw "$@" 2>/dev/null
    fi
}

menu_read_byte(){
    if [ "$MENU_TTY_MODE" = "devtty" ]; then
        dd if=/dev/tty bs=1 count=1 2>/dev/null
    else
        dd bs=1 count=1 2>/dev/null
    fi
}

menu_pause(){
    printf '\n\033[2mPress any key to return...\033[0m'
    pause_stty="$(menu_stty -g 2>/dev/null)"
    menu_stty -echo -icanon min 1 time 0 >/dev/null 2>&1 || true
    menu_read_byte >/dev/null 2>&1 || true
    [ -n "$pause_stty" ] && menu_stty "$pause_stty" >/dev/null 2>&1 || true
}

menu_state_core(){
    if running_pid >/dev/null 2>&1; then
        printf 'ONLINE'
    else
        printf 'OFFLINE'
    fi
}

menu_state_tun(){
    if net_link_exists "$TUN_DEVICE"; then
        printf 'UP'
    else
        printf 'DOWN'
    fi
}

menu_profile_name(){
    if [ "${LEGACY:-1}" = 1 ]; then
        printf 'LEGACY'
    else
        printf 'MODERN'
    fi
}

menu_print_state(){
    value="$1"
    width="$2"
    case "$value" in
        ONLINE|UP) printf '\033[1;32m%-*s\033[0m' "$width" "$value" ;;
        OFFLINE|DOWN) printf '\033[1;31m%-*s\033[0m' "$width" "$value" ;;
        *) printf '%-*s' "$width" "$value" ;;
    esac
}

menu_item(){
    current="$1"; number="$2"; label="$3"
    if [ "$current" -eq "$number" ]; then
        printf '│    \033[1;36m▶ %-34s\033[0m   │\n' "$label"
    else
        printf '│      %-34s   │\n' "$label"
    fi
}

menu_draw(){
    selected="$1"
    printf '\033[2J\033[H'
    printf '\033[1;36m'
    printf '┌───────────────────────────────────────────┐\n'
    printf '│               G O S H A C R A S H         │\n'
    printf '│              ROUTER CONTROLLER             │\n'
    printf '├───────────────────────────────────────────┤\n'
    printf '\033[0m'
    core_state="$(menu_state_core)"
    tun_state="$(menu_state_tun)"
    profile_state="$(menu_profile_name)"
    routing_state="$(printf '%s' "${ROUTING_MODE:-unknown}" | tr '[:lower:]' '[:upper:]')"
    printf '│  MIHOMO  '
    menu_print_state "$core_state" 12
    printf ' TUN  '
    menu_print_state "$tun_state" 10
    printf ' │\n'
    printf '│  PROFILE %-10s       ROUTING %-8s │\n' "$profile_state" "$routing_state"
    printf '\033[1;36m'
    printf '├───────────────────────────────────────────┤\n'
    printf '\033[0m'
    menu_item "$selected" 1 "Status"
    menu_item "$selected" 2 "Restart"
    menu_item "$selected" 3 "Stop"
    menu_item "$selected" 4 "Logs"
    menu_item "$selected" 5 "Exit"
    printf '\033[1;36m'
    printf '├───────────────────────────────────────────┤\n'
    printf '\033[0m'
    printf '│  \033[2m↑/↓ Navigate    Enter Select    Q Quit\033[0m     │\n'
    printf '\033[1;36m'
    printf '└───────────────────────────────────────────┘\n'
    printf '\033[0m'
}

menu_read_key(){
    k="$(menu_read_byte)"
    case "$k" in
        "$(printf '\033')")
            k2="$(menu_read_byte)"
            k3="$(menu_read_byte)"
            [ "$k2" = "[" ] && {
                [ "$k3" = A ] && { echo up; return; }
                [ "$k3" = B ] && { echo down; return; }
            }
            echo other
            ;;
        ''|"$(printf '\r')"|"$(printf '\n')") echo enter ;;
        q|Q) echo quit ;;
        *) echo other ;;
    esac
}

menu_logs(){
    while :; do
        printf '\033[2J\033[H'
        printf '\033[1;36m=== LOGS ===\033[0m\n\n'
        echo "  1) Mihomo — последние 100 строк"
        echo "  2) GoshaCrash — последние 100 строк"
        echo "  3) Mihomo — LIVE"
        echo "  4) GoshaCrash — LIVE"
        echo "  5) Назад"
        echo
        printf "Выбор [1-5]: "
        IFS= read -r log_choice || return 0
        case "$log_choice" in
            1) show_logs mihomo 100; menu_pause ;;
            2) show_logs system 100; menu_pause ;;
            3) follow_logs mihomo 100; menu_pause ;;
            4) follow_logs system 100; menu_pause ;;
            5|q|Q) return 0 ;;
            *) echo "Неверный выбор"; sleep 1 ;;
        esac
    done
}

menu_basic(){
    while :; do
        load_platform >/dev/null 2>&1 || true
        printf '\n=== GoshaCrash ===\n'
        printf 'Mihomo: %s | TUN: %s | Profile: %s | Routing: %s\n\n' \
            "$(menu_state_core)" "$(menu_state_tun)" "$(menu_profile_name)" "${ROUTING_MODE:-unknown}"
        echo "  1) Status"
        echo "  2) Restart"
        echo "  3) Stop"
        echo "  4) Logs"
        echo "  5) Exit"
        printf '\nВыбор [1-5]: '
        IFS= read -r choice || return 0
        case "$choice" in
            1) status ;;
            2) restart ;;
            3) stop ;;
            4) menu_logs ;;
            5|q|Q) return 0 ;;
            *) echo "Неверный выбор" ;;
        esac
        printf '\nНажми Enter, чтобы вернуться в меню...'
        IFS= read -r _gc_menu_dummy || return 0
    done
}

menu(){
    if ! menu_terminal_init; then
        # Older ASUSWRT/BusyBox builds may have a perfectly usable SSH stdin
        # but no compatible stty applet or no reliable test -t support.
        # Fall back to a portable line-oriented menu instead of rejecting gc.
        menu_basic
        return $?
    fi

    items_count=5
    selected=1

    menu_stty -echo -icanon min 1 time 0 >/dev/null 2>&1 || {
        echo "Failed to initialize interactive terminal." >&2
        return 1
    }

    trap 'menu_stty "$MENU_OLD_STTY" >/dev/null 2>&1; printf "\033[0m\n"' HUP INT TERM EXIT

    while :; do
        load_platform >/dev/null 2>&1 || true
        menu_draw "$selected"
        key="$(menu_read_key)"
        case "$key" in
            up)
                selected=$((selected - 1))
                [ "$selected" -lt 1 ] && selected=$items_count
                ;;
            down)
                selected=$((selected + 1))
                [ "$selected" -gt "$items_count" ] && selected=1
                ;;
            quit)
                break
                ;;
            enter)
                menu_stty "$MENU_OLD_STTY" >/dev/null 2>&1 || true
                printf '\033[2J\033[H'
                case "$selected" in
                    1) status; menu_pause ;;
                    2) restart; menu_pause ;;
                    3) stop; menu_pause ;;
                    4) menu_logs ;;
                    5) break ;;
                esac
                load_platform >/dev/null 2>&1 || true
                menu_stty -echo -icanon min 1 time 0 >/dev/null 2>&1 || true
                ;;
        esac
    done

    menu_stty "$MENU_OLD_STTY" >/dev/null 2>&1 || true
    trap - HUP INT TERM EXIT
    printf '\033[0m\033[2J\033[H'
}

usage(){
    cat <<'USAGE'
GoshaCrash — словарь команд и кода

Формат:
  команда
    вызов: какие функции реально вызываются
    код:   ключевые строки из goshacrash.sh
    итог:  что происходит

gc
  вызов: menu -> menu_terminal_init -> menu/menu_basic
  код:   menu) menu;;
  итог:  открывает интерактивное меню; на старом ASUSWRT используется line-mode fallback.

gc status
  вызов: status -> running_pid / route_status / dashboard_base_url
  код:   status) status;;
         if p="$(running_pid)"; then
         if running_pid >/dev/null 2>&1 && route_status >/dev/null 2>&1; then
         echo "Zashboard: $(dashboard_base_url)"
  итог:  только читает состояние; ничего не перезапускает и не меняет.

gc edit
  вызов: edit_config -> find_editor -> backup_config -> nano -> check_config -> restart
  код:   edit) edit_config;;
         backup="$(backup_config)" || { fail "Не создана резервная копия config.yaml"; return 1; }
         TERM="${TERM:-xterm}" "$editor" "$CONFIG" || { warn "Редактор завершился с ошибкой"; return 1; }
         if ! check_config; then cp -f "$backup" "$CONFIG"; fail "Конфиг некорректен; восстановлена предыдущая версия"; return 1; fi
         if ! restart; then cp -f "$backup" "$CONFIG"; warn "Новый конфиг не запустился; восстановлен старый"; restart || true; return 1; fi
  итог:  backup -> nano -> проверка Mihomo -> restart; при ошибке возвращает старый config.yaml.

gc restart
  вызов: restart -> check_config -> backup_config -> watchdog_stop -> stop_runtime -> start_runtime -> watchdog_start
  код:   restart) restart;;
         check_config || return 1
         backup_config >/dev/null 2>&1 || true
         watchdog_stop
         stop_runtime
         with_start_lock start_runtime
         [ "$rc" -eq 0 ] && watchdog_start
  итог:  валидирует конфиг до остановки рабочего Mihomo, затем полностью пересобирает runtime.

gc stop
  вызов: stop -> watchdog_stop -> stop_runtime
  код:   stop) stop;;
         touch "$MANUAL_STOP"
         watchdog_stop; stop_runtime
         ok "Mihomo остановлен; обычный DIRECT восстановлен"
  итог:  останавливает watchdog/Mihomo, снимает маршрутизацию и ставит manual-stop для автозапуска.

gc logs [mihomo|system|install|boot|watchdog|packages] [N]
  вызов: show_logs -> log_file_for_kind -> tail
  код:   *) show_logs "${1:-mihomo}" "${2:-100}" ;;
         tail -n "$lines" "$file" 2>/dev/null || true
  итог:  показывает последние N строк выбранного журнала; по умолчанию Mihomo, 100 строк.

gc logs live [kind] [N]
  вызов: follow_logs -> log_file_for_kind -> tail -f
  код:   follow_logs "${1:-mihomo}" "${2:-100}"
         tail -n "$lines" -f "$file"
  итог:  показывает хвост журнала и продолжает читать новые строки до Ctrl+C.

gc dashboard
  вызов: dashboard_url -> lan_ip / controller_port / yaml_top
  код:   dashboard) dashboard_url;;
         url="http://$ip:$port/ui/#/setup?hostname=$ip&port=$port"
         [ -n "$secret" ] && url="$url&secret=$secret"
         url="$url&disableUpgradeCore=1"   # legacy ARMv5
  итог:  печатает setup URL Zashboard; на legacy ARMv5 скрывает native core-upgrade.

gc routing status
  вызов: routing_status
  код:   status) routing_status;;
         echo "Routing: $ROUTING_MODE"
         echo "Mihomo target: $MIHOMO_TARGET"
  итог:  только показывает режим и доступность automatic routing.

gc routing manual
  вызов: set_routing_mode manual -> rewrite_config_for_routing -> check_config -> start_runtime
  код:   manual) set_routing_mode manual;;
         yaml_set_section_key "$CONFIG" tun auto-route false
         yaml_set_section_key "$CONFIG" tun auto-redirect false
         yaml_set_top_key "$CONFIG" routing-mark "$OUTBOUND_MARK_DEC"
  итог:  делает backup, переводит TUN на manual routing, проверяет и запускает; при ошибке откатывает.

gc routing auto
  вызов: set_routing_mode auto -> rewrite_config_for_routing -> check_config -> start_runtime
  код:   auto) set_routing_mode auto;;
         [ "$MIHOMO_TARGET" != armv5 ] || { fail "ARMv5: automatic routing недоступен"; return 1; }
         yaml_set_section_key "$CONFIG" tun auto-route true
         yaml_set_section_key "$CONFIG" tun auto-redirect true
  итог:  включает native automatic routing Mihomo только на поддерживаемых платформах; ARMv5 запрещён.

gc help
  вызов: usage
  код:   help|-h|--help) usage;;
  итог:  показывает этот словарь.

Внутренние команды install/autostart/watchdog намеренно не являются публичным CLI:
  check, boot, firewall-reload, watchdog-loop, watchdog-check, version
USAGE
}
ensure_dirs >/dev/null 2>&1 || true
load_platform >/dev/null 2>&1 || true
refresh_path >/dev/null 2>&1 || true
case "${1:-menu}" in
    menu) menu;;
    help|-h|--help) usage;;
    stop) stop;;
    restart) restart;;
    status) status;;
    edit) edit_config;;
    dashboard) dashboard_url;;
    routing)
        shift
        case "${1:-status}" in
            status) routing_status;;
            manual) set_routing_mode manual;;
            auto) set_routing_mode auto;;
            *) echo 'Использование: gc routing status|manual|auto'; exit 1;;
        esac
        ;;
    logs)
        shift
        case "${1:-mihomo}" in
            live)
                shift
                follow_logs "${1:-mihomo}" "${2:-100}"
                ;;
            *) show_logs "${1:-mihomo}" "${2:-100}" ;;
        esac
        ;;

    # Internal commands used by install/autostart/watchdog. They are intentionally
    # omitted from help and are not part of the public CLI.
    check) check_config;;
    boot) boot;;
    firewall-reload) firewall_reload;;
    watchdog-loop) watchdog_loop;;
    watchdog-check) watchdog_check;;
    version) echo "$VERSION";;
    *) echo "Неизвестная команда: $1" >&2; echo >&2; usage; exit 1;;
esac
