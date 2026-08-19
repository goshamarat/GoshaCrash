#!/bin/sh
# GoshaCrash controller for ASUSWRT.
# One management script: Mihomo lifecycle, routing, config, logs and packages.
# Zashboard updates are triggered from the native button inside Zashboard.

VERSION="3.8.6"
BUILD_ID="2026-08-19-shell-compat-r2"

# Stock ASUSWRT may invoke hooks with a minimal/empty PATH and some builds
# do not expose the BusyBox `[` applet as /bin/[.
PATH="/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

# Create a private `[` command before the first shell test is executed.
# Do this unconditionally: it is tiny and /tmp is recreated on every boot.
GC_COMPAT_BIN="/tmp/goshacrash-compat"
mkdir -p "$GC_COMPAT_BIN" 2>/dev/null
cat > "$GC_COMPAT_BIN/[" <<'GC_BRACKET'
#!/bin/sh
exec /bin/busybox '[' "$@"
GC_BRACKET
chmod 755 "$GC_COMPAT_BIN/[" 2>/dev/null
PATH="$GC_COMPAT_BIN:$PATH"
export PATH
hash -r 2>/dev/null || true

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
INSTALL_LOG="$LOGS/install.log"
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
WATCHDOG_INTERVAL="${GOSHACRASH_WATCHDOG_INTERVAL:-10}"
WAN_FAIL_LIMIT="${GOSHACRASH_WAN_FAIL_LIMIT:-3}"
WAN_RECOVER_LIMIT="${GOSHACRASH_WAN_RECOVER_LIMIT:-2}"
WAN_PROBE_TIMEOUT="${GOSHACRASH_WAN_PROBE_TIMEOUT:-2}"
WAN_PROBE_IPS="${GOSHACRASH_WAN_PROBE_IPS:-1.1.1.1 8.8.8.8 9.9.9.9}"
WAN_OFFLINE="$STATE/wan-offline"
WAN_FAIL_COUNT="$STATE/wan-fail-count"
WAN_OK_COUNT="$STATE/wan-ok-count"
WAN_STATE="$STATE/internet.state"
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

log_event(){ :; }

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

    PATH="$GC_COMPAT_BIN:/jffs/scripts"
    [ -n "$DM_ROOT" ] && PATH="$DM_ROOT/bin:$DM_ROOT/sbin:$PATH"
    PATH="/opt/bin:/opt/sbin:/tmp/opt/bin:/tmp/opt/sbin:$PATH"
    PATH="$PATH:/usr/sbin:/usr/bin:/sbin:/bin"
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



ensure_optware_link(){
    find_dm_root || return 1
    [ -d "$DM_ROOT" ] || return 1
    touch "$DM_ROOT/.asusrouter" 2>/dev/null || true
    if [ -L /tmp/opt ]; then
      target="$(readlink /tmp/opt 2>/dev/null)"
      [ "$target" = "$DM_ROOT" ] || ln -snf "$DM_ROOT" /tmp/opt 2>/dev/null || return 1
    elif [ -d /tmp/opt ]; then
      if [ ! -x /tmp/opt/bin/ipkg ] && [ ! -x /tmp/opt/bin/opkg ]; then
        rmdir /tmp/opt 2>/dev/null && ln -s "$DM_ROOT" /tmp/opt 2>/dev/null || true
      fi
    elif [ ! -e /tmp/opt ]; then
      ln -s "$DM_ROOT" /tmp/opt 2>/dev/null || return 1
    fi
    return 0
}
optware_runtime_ready(){
    ensure_optware_link >/dev/null 2>&1 || true
    [ -x /tmp/opt/bin/ipkg ] || [ -x /tmp/opt/bin/opkg ] || [ -x /opt/bin/ipkg ] || [ -x /opt/bin/opkg ] || [ -x "$DM_ROOT/bin/ipkg" ] || [ -x "$DM_ROOT/bin/opkg" ]
}
repair_opt(){
    find_dm_root || return 1
    ensure_optware_link >/dev/null 2>&1 || true
    refresh_path
    find_pkg || return 1
    optware_runtime_ready && return 0
    for script in "$DM_ROOT/S50downloadmaster.1" "$DM_ROOT/etc/init.d/S50downloadmaster" "$DM_ROOT/etc/init.d/S50downloadmaster.1"; do
      [ -x "$script" ] || continue
      "$script" start >> "$PACKAGES_LOG" 2>&1 || true
      sleep 2
      ensure_optware_link >/dev/null 2>&1 || true
      refresh_path
      optware_runtime_ready && return 0
    done
    [ -x "$DM_ROOT/bin/ipkg" ] || [ -x "$DM_ROOT/bin/opkg" ]
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
    for probe_ip in $WAN_PROBE_IPS; do
        ipt -t mangle -A "$ROUTER_CHAIN" -d "$probe_ip/32" -j RETURN || return 1
    done
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

wan_nvram_up(){
    state="$(nvram_get wan0_state_t)"
    aux="$(nvram_get wan0_auxstate_t)"
    ip="$(nvram_get wan0_ipaddr)"
    gateway="$(nvram_get wan0_gateway)"

    [ "$state" = "2" ] || return 1
    [ "$aux" = "0" ] || return 1
    [ -n "$ip" ] && [ "$ip" != "0.0.0.0" ] || return 1
    [ -n "$gateway" ] && [ "$gateway" != "0.0.0.0" ] || return 1
    main_default_route
}

counter_get(){ n="$(cat "$1" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0;; esac; printf '%s\n' "$n"; }
counter_set(){ printf '%s\n' "$2" > "$1" 2>/dev/null || true; }
set_wan_state(){ printf '%s\n' "$1" > "$WAN_STATE" 2>/dev/null || true; }
internet_probe_once(){
    # WAN probing must never depend on Optware PATH.
    ping_bin=""
    for p in /bin/ping /usr/bin/ping /sbin/ping /usr/sbin/ping; do
        [ -x "$p" ] && { ping_bin="$p"; break; }
    done

    if [ -n "$ping_bin" ]; then
        for ip in $WAN_PROBE_IPS; do
            "$ping_bin" -c 1 -W "$WAN_PROBE_TIMEOUT" "$ip" >/dev/null 2>&1 && return 0
        done
    fi

    # Some providers block ICMP. Try a direct HTTP request without DNS.
    wget_bin=""
    for p in /usr/sbin/wget /usr/bin/wget /bin/wget; do
        [ -x "$p" ] && { wget_bin="$p"; break; }
    done
    if [ -n "$wget_bin" ]; then
        "$wget_bin" -q -T "$WAN_PROBE_TIMEOUT" -O /dev/null \
            http://1.1.1.1/cdn-cgi/trace >/dev/null 2>&1 && return 0
    fi

    curl_bin=""
    for p in /usr/sbin/curl /usr/bin/curl /bin/curl; do
        [ -x "$p" ] && { curl_bin="$p"; break; }
    done
    if [ -n "$curl_bin" ]; then
        "$curl_bin" -fsS --connect-timeout "$WAN_PROBE_TIMEOUT" \
            --max-time "$WAN_PROBE_TIMEOUT" \
            http://1.1.1.1/cdn-cgi/trace >/dev/null 2>&1 && return 0
    fi

    return 1
}
wan_mark_offline(){ touch "$WAN_OFFLINE" 2>/dev/null || true; counter_set "$WAN_OK_COUNT" 0; set_wan_state offline; }
wan_mark_online(){ rm -f "$WAN_OFFLINE" 2>/dev/null || true; counter_set "$WAN_FAIL_COUNT" 0; set_wan_state online; }
runtime_health_ok(){
    running_pid >/dev/null 2>&1 || return 1
    netstat -ln 2>/dev/null | grep -Eq "[:.]$DNS_PORT[[:space:]]" || return 1
    net_link_exists "$TUN_DEVICE" || return 1
    route_status >/dev/null 2>&1 || return 1
}
watchdog_connectivity_step(){
    if internet_probe_once; then
        counter_set "$WAN_FAIL_COUNT" 0

        n="$(counter_get "$WAN_OK_COUNT")"
        n=$((n + 1))
        counter_set "$WAN_OK_COUNT" "$n"

        if [ -f "$WAN_OFFLINE" ]; then
            [ "$n" -ge "$WAN_RECOVER_LIMIT" ] || return 1
            wan_mark_online
        else
            set_wan_state online
        fi
        return 0
    fi

    counter_set "$WAN_OK_COUNT" 0

    n="$(counter_get "$WAN_FAIL_COUNT")"
    n=$((n + 1))
    counter_set "$WAN_FAIL_COUNT" "$n"

    [ "$n" -ge "$WAN_FAIL_LIMIT" ] || return 1

    if [ ! -f "$WAN_OFFLINE" ]; then
        wan_mark_offline
        stop_runtime
    else
        set_wan_state offline
    fi

    return 1
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
    if have nohup; then
      GOSHACRASH_BASE="$BASE" nohup "$BASE/goshacrash.sh" watchdog-loop </dev/null >/dev/null 2>&1 &
    else
      GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" watchdog-loop </dev/null >/dev/null 2>&1 &
    fi
    p=$!; echo "$p" > "$WATCHDOG_PIDFILE"; sleep 1
    kill -0 "$p" 2>/dev/null || { rm -f "$WATCHDOG_PIDFILE"; return 1; }
}
watchdog_check(){
    [ -f "$MANUAL_STOP" ] && return 0
    [ -d "$CONTROL_LOCK" ] && return 0
    [ -d "$START_LOCK" ] && return 0
    watchdog_connectivity_step || true
    [ -f "$WAN_OFFLINE" ] && return 0
    if ! running_pid >/dev/null 2>&1; then
      with_start_lock start_runtime >/dev/null 2>&1 || true
      return 0
    fi
    if ! runtime_health_ok; then
      stop_runtime
      with_start_lock start_runtime >/dev/null 2>&1 || true
    fi
}
watchdog_loop(){
    ensure_dirs || exit 1
    echo "$$" > "$WATCHDOG_PIDFILE"
    trap 'rm -f "$WATCHDOG_PIDFILE"; exit 0' HUP INT TERM
    while :; do sleep "$WATCHDOG_INTERVAL"; watchdog_check; done
}

start(){
    ensure_dirs || return 1
    load_platform || return 1
    refresh_path

    rm -f "$MANUAL_STOP"
    mkdir "$CONTROL_LOCK" 2>/dev/null || true

    if internet_probe_once; then
        wan_mark_online
        with_start_lock start_runtime
        rc=$?
    elif wan_nvram_up; then
        # ASUS reports a live WAN and a default route. One lost probe is not
        # enough reason to keep VPN down; watchdog will verify continuously.
        rm -f "$WAN_OFFLINE" 2>/dev/null || true
        set_wan_state checking
        with_start_lock start_runtime
        rc=$?
        warn "Внешний probe не ответил, но WAN ASUS активен; runtime запущен, watchdog перепроверит связь"
    else
        wan_mark_offline
        stop_runtime
        rc=0
        warn "WAN действительно недоступен: Mihomo остановлен, watchdog ждёт восстановления"
    fi

    rmdir "$CONTROL_LOCK" 2>/dev/null || true
    watchdog_start
    return "$rc"
}
stop(){
    ensure_dirs || return 1; load_platform || true; touch "$MANUAL_STOP"; mkdir "$CONTROL_LOCK" 2>/dev/null || true
    watchdog_stop; stop_runtime; rmdir "$CONTROL_LOCK" 2>/dev/null || true; ok "Mihomo остановлен; обычный DIRECT восстановлен"
}

service_stop(){
    # Internal stop for Download Master shutdown / USB unmount / reboot.
    # Unlike public `gc stop`, this MUST NOT create state/manual-stop,
    # otherwise the next boot would intentionally skip autostart.
    ensure_dirs || return 1
    load_platform || true
    mkdir "$CONTROL_LOCK" 2>/dev/null || true
    watchdog_stop
    stop_runtime
    rmdir "$CONTROL_LOCK" 2>/dev/null || true
    return 0
}
restart(){
    ensure_dirs || return 1
    load_platform || return 1
    refresh_path

    check_config || return 1
    backup_config >/dev/null 2>&1 || true

    rm -f "$MANUAL_STOP"
    mkdir "$CONTROL_LOCK" 2>/dev/null || true
    watchdog_stop
    stop_runtime

    if internet_probe_once; then
        wan_mark_online
        with_start_lock start_runtime
        rc=$?
    elif wan_nvram_up; then
        rm -f "$WAN_OFFLINE" 2>/dev/null || true
        set_wan_state checking
        with_start_lock start_runtime
        rc=$?
        warn "Внешний probe не ответил, но WAN ASUS активен; Mihomo запущен, watchdog перепроверит связь"
    else
        wan_mark_offline
        rc=0
        warn "WAN действительно недоступен: Mihomo оставлен остановленным; watchdog запустит его после восстановления"
    fi

    rmdir "$CONTROL_LOCK" 2>/dev/null || true
    watchdog_start

    [ "$rc" -eq 0 ] && return 0

    if [ -f "$BACKUPS/config.last-good.yaml" ]; then
        warn "Новый config.yaml не запустился; возвращаю последний рабочий"
        cp -f "$BACKUPS/config.last-good.yaml" "$CONFIG" || return 1
        if internet_probe_once || wan_nvram_up; then
            with_start_lock start_runtime >/dev/null 2>&1 || true
        fi
    fi
    return 1
}

main_default_route(){
    route_bin=""
    for p in /sbin/route /bin/route /usr/sbin/route /usr/bin/route; do
        [ -x "$p" ] && { route_bin="$p"; break; }
    done

    if [ -n "$route_bin" ]; then
        "$route_bin" -n 2>/dev/null | awk '
          $1=="0.0.0.0" && $4 ~ /G/ {found=1}
          END {exit !found}
        ' && return 0
    fi

    refresh_path
    [ -n "$IP_BIN" ] && "$IP_BIN" route show default 2>/dev/null | grep -q '^default ' && return 0
    return 1
}
boot(){
    ensure_dirs || return 1
    load_platform || return 1
    refresh_path

    [ -f "$MANUAL_STOP" ] && return 0

    if [ -f "$BOOT_PIDFILE" ]; then
        old="$(cat "$BOOT_PIDFILE" 2>/dev/null)"
        case "$old" in ''|*[!0-9]*) old="";; esac
        [ -n "$old" ] && kill -0 "$old" 2>/dev/null && return 0
    fi

    echo "$$" > "$BOOT_PIDFILE"
    repair_opt >/dev/null 2>&1 || true
    refresh_path

    waited=0
    while ! main_default_route; do
        [ "$waited" -ge "$BOOT_WAIT" ] && break
        sleep 5
        waited=$((waited + 5))
    done

    rm -f "$BOOT_PIDFILE"

    if internet_probe_once || wan_nvram_up; then
        rm -f "$WAN_OFFLINE" 2>/dev/null || true
        set_wan_state checking
        start
    else
        wan_mark_offline
        stop_runtime
        watchdog_start
        return 0
    fi
}
firewall_reload(){
    load_platform || return 0
    [ -f "$WAN_OFFLINE" ] && return 0
    running_pid >/dev/null 2>&1 || return 0
    if [ "$ROUTING_MODE" = manual ]; then route_start || return 1; else restart; fi
}

backup_config(){
    [ -f "$CONFIG" ] || return 1
    stamp="$(date '+%Y%m%d-%H%M%S' 2>/dev/null)"; [ -n "$stamp" ] || stamp="backup"
    dst="$BACKUPS/config-$stamp.yaml"; cp -f "$CONFIG" "$dst" || return 1; printf '%s\n' "$dst"
}

find_editor(){
    refresh_path

    for e in \
        /opt/bin/nano \
        /tmp/opt/bin/nano \
        "$DM_ROOT/bin/nano" \
        "$DM_ROOT/sbin/nano"
    do
        [ -x "$e" ] && { printf '%s\n' "$e"; return 0; }
    done

    return 1
}

repair_nano_runtime(){
    find_editor >/dev/null 2>&1 && return 0
    repair_opt >/dev/null 2>&1 || true
    find_editor >/dev/null 2>&1 && return 0
    find_pkg || return 1
    if "$PKG" list_installed 2>/dev/null | grep -q '^nano[[:space:]]*-'; then
      "$PKG" install nano >> "$PACKAGES_LOG" 2>&1 || {
        "$PKG" remove nano >> "$PACKAGES_LOG" 2>&1 || true
        "$PKG" install nano >> "$PACKAGES_LOG" 2>&1 || return 1
      }
    else
      "$PKG" update >> "$PACKAGES_LOG" 2>&1 || true
      "$PKG" install nano >> "$PACKAGES_LOG" 2>&1 || return 1
    fi
    ensure_optware_link >/dev/null 2>&1 || true
    refresh_path
    find_editor >/dev/null 2>&1
}

edit_config(){
    load_platform || return 1
    refresh_path

    editor="$(find_editor 2>/dev/null)"
    if [ -z "$editor" ]; then
        repair_nano_runtime || {
            fail "nano не удалось восстановить. См. $PACKAGES_LOG"
            return 1
        }
        editor="$(find_editor 2>/dev/null)" || {
            fail "nano не найден после восстановления Optware"
            return 1
        }
    fi

    backup="$(backup_config)" || {
        fail "Не создана резервная копия config.yaml"
        return 1
    }
    say "Резервная копия: $backup"

    TERM="${TERM:-xterm}" "$editor" "$CONFIG" || {
        warn "Редактор завершился с ошибкой"
        return 1
    }

    if ! check_config; then
        cp -f "$backup" "$CONFIG"
        fail "Конфиг некорректен; восстановлена предыдущая версия"
        return 1
    fi

    if ! restart; then
        cp -f "$backup" "$CONFIG"
        warn "Новый конфиг не запустился; восстановлен старый"
        restart || true
        return 1
    fi

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
      install) printf '%s\n' "$INSTALL_LOG";;
      packages) printf '%s\n' "$PACKAGES_LOG";;
      *) return 1;;
    esac
}

show_logs(){
    kind="${1:-mihomo}"; lines="${2:-100}"
    case "$lines" in ''|*[!0-9]*) lines=100;; esac
    file="$(log_file_for_kind "$kind")" || { echo "logs: mihomo|install|packages"; return 1; }
    tail -n "$lines" "$file" 2>/dev/null || true
}

follow_logs(){
    kind="${1:-mihomo}"; lines="${2:-100}"
    case "$lines" in ''|*[!0-9]*) lines=100;; esac
    [ "$kind" = mihomo ] || { echo "Live доступен только для Mihomo"; return 1; }
    [ -e "$MIHOMO_LOG" ] || : > "$MIHOMO_LOG"
    tail -n "$lines" -f "$MIHOMO_LOG"
}

status(){
    ensure_dirs >/dev/null 2>&1 || true; load_platform >/dev/null 2>&1 || true; refresh_path
    if p="$(running_pid 2>/dev/null)"; then echo "Mihomo: работает, PID=$p"; else echo "Mihomo: не запущен"; fi
    if [ -f "$WAN_OFFLINE" ]; then echo "Интернет: OFFLINE"; else state="$(cat "$WAN_STATE" 2>/dev/null)"; [ -n "$state" ] || state=unknown; echo "Интернет: $state"; fi
    if p="$(watchdog_pid 2>/dev/null)"; then echo "Watchdog: работает, PID=$p"; else echo "Watchdog: не запущен"; fi
    if [ "${LEGACY:-0}" = 1 ]; then echo "Профиль: legacy"; [ "${MIHOMO_TARGET:-}" = armv5 ] && echo "Ядро: закреплено для legacy ARMv5"; else echo "Профиль: modern"; fi
    echo "Режим маршрутизации: $ROUTING_MODE"
    echo "Конфиг: $CONFIG"
    net_link_exists "$TUN_DEVICE" && echo "TUN: $TUN_DEVICE работает" || echo "TUN: $TUN_DEVICE не найден"
    if runtime_health_ok; then echo "Runtime: OK (process + DNS + TUN + routing)"; elif [ -f "$WAN_OFFLINE" ]; then echo "Runtime: остановлен из-за отсутствия интернета"; else echo "Runtime: требует восстановления"; fi
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
    menu_item "$selected" 2 "Edit config"
    menu_item "$selected" 3 "Restart"
    menu_item "$selected" 4 "Stop"
    menu_item "$selected" 5 "Logs"
    menu_item "$selected" 6 "Exit"
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
      printf '\033[1;36m=== MIHOMO LOG ===\033[0m\n\n'
      echo "  1) Последние 100 строк"
      echo "  2) LIVE"
      echo "  3) Назад"
      echo
      printf "Выбор [1-3]: "
      IFS= read -r log_choice || return 0
      case "$log_choice" in
        1) show_logs mihomo 100; menu_pause ;;
        2) follow_logs mihomo 100; menu_pause ;;
        3|q|Q) return 0 ;;
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
        echo "  2) Edit config"
        echo "  3) Restart"
        echo "  4) Stop"
        echo "  5) Logs"
        echo "  6) Exit"
        printf '\nВыбор [1-6]: '
        IFS= read -r choice || return 0
        case "$choice" in
            1) status ;;
            2) edit_config ;;
            3) restart ;;
            4) stop ;;
            5) menu_logs ;;
            6|q|Q) return 0 ;;
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

    items_count=6
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
                    2) edit_config; menu_pause ;;
                    3) restart; menu_pause ;;
                    4) stop; menu_pause ;;
                    5) menu_logs ;;
                    6) break ;;
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

autostart_status(){
    ensure_dirs >/dev/null 2>&1 || true; load_platform >/dev/null 2>&1 || true
    echo "Autostart (stock ASUSWRT)"
    [ -x /jffs/addons/goshacrash/start.sh ] && echo "  start.sh: OK" || echo "  start.sh: FAIL"
    [ -x /jffs/scripts/usb-mount-script ] && echo "  usb-mount-script: OK" || echo "  usb-mount-script: FAIL"
    [ -x "$DM_ROOT/etc/init.d/S50usb-mount-script" ] && echo "  ASUS app bridge: OK" || echo "  ASUS app bridge: FAIL"
    [ -f "$STATE/autostart-hook-ran" ] && echo "  last hook: $(cat "$STATE/autostart-hook-ran" 2>/dev/null)" || echo "  last hook: never"
    [ -f "$MANUAL_STOP" ] && echo "  manual-stop: YES" || echo "  manual-stop: no"
    return 0
}

sftp_status(){
    echo "SFTP / Optware"
    p="$(cat "$STATE/sftp-server.path" 2>/dev/null)"
    v="$(cat "$STATE/sftp-server.version" 2>/dev/null)"

    if [ -n "$p" ] && [ -x "$p" ]; then
        echo "  binary: OK"
        echo "  path: $p"
        [ -n "$v" ] && echo "  version: $v"
    else
        found=""
        for x in /opt/libexec/sftp-server /opt/lib/openssh/sftp-server; do
            [ -x "$x" ] && { found="$x"; break; }
        done
        [ -n "$found" ] && echo "  path: $found" || echo "  binary: НЕ НАЙДЕН"
    fi
    echo "  SSH daemon: stock ASUS Dropbear не заменяется"
    echo "  Проверка с ПК: sftp admin@<IP роутера>"
}

doctor(){
    load_platform >/dev/null 2>&1 || true
    refresh_path

    echo "GoshaCrash doctor"
    echo "  version: $VERSION"
    echo "  model: $(nvram_get productid)"
    echo "  kernel: $(uname -r 2>/dev/null)"
    echo "  arch: $(uname -m 2>/dev/null)"
    echo "  PATH: $PATH"
    if /bin/busybox '[' -n "ok" ']' >/dev/null 2>&1; then
        if test -x /jffs/scripts/'[' && /jffs/scripts/'[' -n "ok" ']' >/dev/null 2>&1; then
            echo "  shell [: OK (/jffs/scripts/[)"
        elif test -x "$GC_COMPAT_BIN/[" && "$GC_COMPAT_BIN/[" -n "ok" ']' >/dev/null 2>&1; then
            echo "  shell [: OK ($GC_COMPAT_BIN/[)"
        else
            echo "  shell [: BusyBox OK, wrapper FAIL"
        fi
    else
        echo "  shell [: FAIL"
    fi

    [ -x /bin/ping ] && echo "  firmware ping: /bin/ping" || echo "  firmware ping: NOT FOUND"
    wan_nvram_up && echo "  ASUS WAN: UP" || echo "  ASUS WAN: DOWN"
    internet_probe_once && echo "  external probe: OK" || echo "  external probe: FAIL"

    running_pid >/dev/null 2>&1 && echo "  Mihomo: OK" || echo "  Mihomo: FAIL"
    netstat -ln 2>/dev/null | grep -Eq "[:.]$DNS_PORT[[:space:]]" \
        && echo "  DNS: OK" || echo "  DNS: FAIL"
    net_link_exists "$TUN_DEVICE" && echo "  TUN: OK" || echo "  TUN: FAIL"
    route_status >/dev/null 2>&1 && echo "  routing: OK" || echo "  routing: FAIL"
    watchdog_pid >/dev/null 2>&1 && echo "  watchdog: OK" || echo "  watchdog: FAIL"

    find_dm_root >/dev/null 2>&1 && echo "  Download Master: $DM_ROOT" || echo "  Download Master: FAIL"
    ensure_optware_link >/dev/null 2>&1 && echo "  /tmp/opt: OK" || echo "  /tmp/opt: FAIL"
    find_pkg >/dev/null 2>&1 && echo "  package manager: $PKG" || echo "  package manager: FAIL"

    editor="$(find_editor 2>/dev/null)"
    [ -n "$editor" ] && echo "  nano: $editor" || echo "  nano: NOT FOUND"

    [ -x /jffs/scripts/usb-mount-script ] && echo "  stock USB hook: OK" || echo "  stock USB hook: FAIL"
    [ -n "$DM_ROOT" ] && [ -x "$DM_ROOT/etc/init.d/S50usb-mount-script" ] \
        && echo "  ASUS app bridge: OK" || echo "  ASUS app bridge: FAIL"

    state="$(cat "$WAN_STATE" 2>/dev/null)"
    [ -n "$state" ] || state="unknown"
    echo "  Internet state: $state"
    return 0
}
usage(){
cat <<'USAGE'
GoshaCrash 3.8.1 — что буквально вводить в SSH

КАТАЛОГ УСТАНОВКИ
  BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
  [ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
  echo "$BASE"

МЕНЮ
  gc

СТАТУС
  gc status

ПОЛНАЯ ДИАГНОСТИКА
  gc doctor

ПРОВЕРИТЬ ТОЛЬКО INTERNET PROBE
  gc internet-probe

ПРОВЕРИТЬ SHELL [
  command -v '['
  /bin/busybox '[' -n "ok" ']'
  echo "BRACKET_RC=$?"

ПРОВЕРИТЬ СИСТЕМНЫЙ PING
  /bin/ping -c 2 -W 2 1.1.1.1
  echo "PING_RC=$?"

СБРОСИТЬ ЛОЖНЫЙ OFFLINE
  BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
  [ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
  rm -f "$BASE/state/wan-offline" "$BASE/state/wan-fail-count" "$BASE/state/wan-ok-count"
  echo online > "$BASE/state/internet.state"
  gc restart


ИЗМЕНИТЬ CONFIG
  gc edit

ОТКРЫТЬ CONFIG ВРУЧНУЮ
  BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
  [ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
  /jffs/scripts/nano "$BASE/config.yaml"

BACKUP CONFIG
  BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
  [ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
  cp "$BASE/config.yaml" "$BASE/backups/config-manual.yaml"

ПРОВЕРИТЬ CONFIG
  BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
  [ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
  "$BASE/bin/mihomo" -t -d "$BASE" -f "$BASE/config.yaml"

ВЕРНУТЬ BACKUP
  BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
  [ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
  cp "$BASE/backups/config-manual.yaml" "$BASE/config.yaml"
  gc restart

ПЕРЕЗАПУСТИТЬ VPN
  gc restart

ОСТАНОВИТЬ VPN
  gc stop

ВКЛЮЧИТЬ ПОСЛЕ gc stop
  gc restart

ЛОГ MIHOMO
  gc logs

200 СТРОК MIHOMO
  gc logs mihomo 200

LIVE MIHOMO
  gc logs live mihomo 100

ЛОГ MIHOMO ВРУЧНУЮ
  BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
  [ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
  tail -n 100 "$BASE/logs/mihomo.log"

LIVE ВРУЧНУЮ
  BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
  [ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
  tail -f "$BASE/logs/mihomo.log"

ЛОГ УСТАНОВКИ
  BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
  [ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
  tail -n 200 "$BASE/logs/install.log"

ЛОГ ПАКЕТОВ
  BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
  [ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
  tail -n 200 "$BASE/logs/packages.log"

ПРОЦЕСС MIHOMO
  ps | grep '[m]ihomo'

PID MIHOMO
  BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
  [ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
  cat "$BASE/run/mihomo.pid" 2>/dev/null

TUN
  ifconfig tun0

DNS MIHOMO
  netstat -ln | grep ':1053'

МАРШРУТЫ
  route -n

IPTABLES MANGLE
  iptables -t mangle -L -n -v

IPTABLES NAT
  iptables -t nat -L -n -v

ROUTING STATUS
  gc routing status

ПРОВЕРИТЬ MANUAL ROUTING-ФУНКЦИЮ
  grep -n '^manual_route_start()' /tmp/mnt/SANDISK/goshacrash/goshacrash.sh


MANUAL ROUTING
  gc routing manual

AUTO ROUTING
  gc routing auto

RT-AC68U / LEGACY
  gc routing manual

WATCHDOG
  BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
  [ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
  cat "$BASE/run/watchdog.pid" 2>/dev/null
  PID="$(cat "$BASE/run/watchdog.pid" 2>/dev/null)"
  [ -n "$PID" ] && kill -0 "$PID" && echo "watchdog OK"

СОСТОЯНИЕ INTERNET WATCHDOG
  BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
  [ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
  cat "$BASE/state/internet.state" 2>/dev/null
  ls -l "$BASE/state/wan-offline" 2>/dev/null

АВТОЗАПУСК
  gc autostart status

HOOK AUTOSTART
  ls -l /jffs/scripts/usb-mount-script
  ls -l /jffs/addons/goshacrash/start.sh

СРАБОТАЛ ЛИ AUTOSTART ПОСЛЕ REBOOT
  BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
  [ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
  cat "$BASE/state/autostart-hook-ran" 2>/dev/null

ПРОВЕРИТЬ /opt ПОСЛЕ REBOOT
  ls -ld /opt /tmp/opt
  readlink /tmp/opt 2>/dev/null
  mount | grep -E '/opt|asusware|SANDISK'

NANO
  which nano
  ls -l /opt/bin/nano /tmp/opt/bin/nano 2>/dev/null

NANO ЧЕРЕЗ IPKG НА RT-AC68U
  IPKG=/tmp/mnt/SANDISK/asusware.arm/bin/ipkg
  "$IPKG" list_installed | grep '^nano '
  "$IPKG" files nano

ПЕРЕУСТАНОВИТЬ NANO
  IPKG=/tmp/mnt/SANDISK/asusware.arm/bin/ipkg
  "$IPKG" update
  "$IPKG" remove nano
  "$IPKG" install nano

UNZIP
  which unzip
  ls -l /opt/bin/unzip /opt/bin/unzip-unzip /tmp/opt/bin/unzip-unzip 2>/dev/null

UNZIP ЧЕРЕЗ IPKG НА RT-AC68U
  IPKG=/tmp/mnt/SANDISK/asusware.arm/bin/ipkg
  "$IPKG" list_installed | grep '^unzip '
  "$IPKG" files unzip

ПЕРЕУСТАНОВИТЬ UNZIP
  IPKG=/tmp/mnt/SANDISK/asusware.arm/bin/ipkg
  "$IPKG" update
  "$IPKG" remove unzip
  "$IPKG" install unzip

SFTP
  gc sftp status

SFTP ЧЕРЕЗ IPKG
  IPKG=/tmp/mnt/SANDISK/asusware.arm/bin/ipkg
  "$IPKG" list | grep '^openssh-sftp-server '
  "$IPKG" list_installed | grep '^openssh-sftp-server '
  "$IPKG" files openssh-sftp-server

УСТАНОВИТЬ SFTP
  IPKG=/tmp/mnt/SANDISK/asusware.arm/bin/ipkg
  "$IPKG" update
  "$IPKG" install openssh-sftp-server

SFTP С WINDOWS
  sftp admin@10.10.10.100

ZASHBOARD
  gc dashboard

CONTROLLER И SECRET
  BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
  [ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
  grep '^external-controller:' "$BASE/config.yaml"
  grep '^secret:' "$BASE/config.yaml"

РУЧНОЙ RESTART ТОЛЬКО MIHOMO
  BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
  [ -n "$BASE" ] || BASE=/tmp/mnt/SANDISK/goshacrash
  PID="$(cat "$BASE/run/mihomo.pid" 2>/dev/null)"
  [ -n "$PID" ] && kill "$PID"
  rm -f "$BASE/run/mihomo.pid"
  GOGC=50 nohup "$BASE/bin/mihomo" -d "$BASE" -f "$BASE/config.yaml" </dev/null >>"$BASE/logs/mihomo.log" 2>&1 &
  echo $! > "$BASE/run/mihomo.pid"

ПОСЛЕ РУЧНОГО ЗАПУСКА ВЕРНУТЬ ПОЛНЫЙ RUNTIME
  gc restart

ПОСЛЕ REBOOT
  gc doctor
  gc autostart status
  gc status
  gc edit

ТЕСТ ПОТЕРИ WAN
  gc status
  ps | grep '[m]ihomo'

Отключи WAN примерно на 40 секунд, затем введи:
  gc status
  ps | grep '[m]ihomo'

Верни WAN, подожди примерно 30 секунд, затем введи:
  gc status
  ps | grep '[m]ihomo'

USAGE
}
refresh_path >/dev/null 2>&1 || true
ensure_dirs >/dev/null 2>&1 || true
load_platform >/dev/null 2>&1 || true
refresh_path >/dev/null 2>&1 || true
case "${1:-menu}" in
    menu) menu;;
    help|-h|--help) usage;;
    stop) stop;;
    service-stop) service_stop;;
    restart) restart;;
    status) status;;
    edit) edit_config;;
    dashboard) dashboard_url;;
    autostart)
        shift
        case "${1:-status}" in
            status) autostart_status;;
            *) echo 'Использование: gc autostart status'; exit 1;;
        esac
        ;;
    sftp)
        shift
        case "${1:-status}" in
            status) sftp_status;;
            *) echo 'Использование: gc sftp status'; exit 1;;
        esac
        ;;
    internet-probe)
        if internet_probe_once; then
            echo "Internet probe: OK"
            exit 0
        else
            echo "Internet probe: FAIL"
            exit 1
        fi
        ;;
    doctor) doctor;;
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
