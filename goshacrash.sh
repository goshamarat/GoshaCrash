#!/bin/sh
# GoshaCrash controller for ASUSWRT.
# One management script: Mihomo lifecycle, routing, config, logs and packages.
# Zashboard updates are triggered from the native button inside Zashboard.

VERSION="3.10.2-rc40-test2"
BUILD_ID="2026-09-03-dynamic-usb-utf8-coldboot-v3-editpause"

# Never inherit an Optware/uClibc loader path into stock firmware tools.
unset LD_LIBRARY_PATH 2>/dev/null || true

# Stock ASUSWRT may invoke hooks with a minimal/empty PATH and some builds
# do not expose the BusyBox `[` applet as /bin/[.
PATH="/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

# Create a private `[` command before the first shell test is executed.
# Do this unconditionally: it is tiny and /tmp is recreated on every boot.
GC_COMPAT_BIN="/tmp/goshacrash-compat"
mkdir -p "$GC_COMPAT_BIN" 2>/dev/null
cat > "$GC_COMPAT_BIN/test" <<'GC_TEST'
#!/bin/sh
exec /bin/busybox test "$@"
GC_TEST
cat > "$GC_COMPAT_BIN/[" <<'GC_BRACKET'
#!/bin/sh
exec /bin/busybox '[' "$@"
GC_BRACKET
chmod 755 "$GC_COMPAT_BIN/test" "$GC_COMPAT_BIN/[" 2>/dev/null
PATH="$GC_COMPAT_BIN:$PATH"
export PATH
hash -r 2>/dev/null || true

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)"
BASE="${GOSHACRASH_BASE:-$SCRIPT_DIR}"
USB_MOUNT="$(dirname "$BASE")"
USB_DEVICE=""
USB_DISK=""
USB_NAME="${USB_MOUNT##*/}"
USB_FS=""
DM_LAYOUT=""
RUNTIME_BASE_FILE="/tmp/goshacrash-base"
BIN="$BASE/bin/mihomo"
UI="$BASE/ui"
CONFIG="$BASE/config.yaml"
RUN="$BASE/run"
LOGS="$BASE/logs"
STATE="$BASE/state"
PLATFORM_FILE="$STATE/platform.env"
PIDFILE="$RUN/mihomo.pid"
WATCHDOG_PIDFILE="$RUN/watchdog.pid"
WATCHDOG_LOG="$LOGS/watchdog.log"
WATCHDOG_START_LOCK="$RUN/watchdog-start.lock"
WATCHDOG_HEARTBEAT="$STATE/watchdog-heartbeat"
BOOT_PIDFILE="$RUN/boot.pid"
BOOT_LOCK="$RUN/boot.lock"
START_LOCK="$RUN/start.lock"
CONTROL_LOCK="$RUN/control.lock"
MANUAL_STOP="$STATE/manual-stop"
BOOT_TOKEN_FILE="/tmp/goshacrash-boot-token"

MIHOMO_LOG="$LOGS/mihomo.log"
INSTALL_LOG="$LOGS/install.log"
PACKAGES_LOG="$LOGS/packages.log"

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

ensure_dirs(){ mkdir -p "$BASE/bin" "$UI" "$RUN" "$LOGS" "$STATE" "$ROUTE_STATE"; }
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
    level="$1"; component="$2"; shift 2
    mkdir -p "$LOGS" 2>/dev/null || true
    logfile="$LOGS/goshacrash.log"
    rotate_log "$logfile" 1048576
    printf '[%s] [%s] [%s] %s\n' "$(now)" "$level" "$component" "$*" >> "$logfile" 2>/dev/null || true
}

say(){ printf '%s\n' "[GoshaCrash] $*"; log_event INFO main "$*"; }
ok(){ printf '%s\n' "[GoshaCrash:OK] $*"; log_event OK main "$*"; }
warn(){ printf '%s\n' "[GoshaCrash:WARN] $*" >&2; log_event WARN main "$*"; }
fail(){ printf '%s\n' "[GoshaCrash:ERROR] $*" >&2; log_event ERROR main "$*"; return 1; }

refresh_storage_identity(){
    USB_MOUNT="$(dirname "$BASE")"
    USB_NAME="${USB_MOUNT##*/}"
    USB_DEVICE="$(awk -v m="$USB_MOUNT" '$2==m && $1 ~ "^/dev/sd" {print $1; exit}' /proc/mounts 2>/dev/null)"
    if [ -z "$USB_DEVICE" ]; then
        USB_DEVICE="$(df -P "$USB_MOUNT" 2>/dev/null | awk 'NR==2 && $1 ~ "^/dev/sd" {print $1; exit}')"
    fi
    USB_DISK="$(printf '%s\n' "$USB_DEVICE" | sed 's/[0-9][0-9]*$//')"
    USB_FS="$(awk -v d="$USB_DEVICE" '$1==d {print $3; exit}' /proc/mounts 2>/dev/null)"

    DM_ROOT=""
    DM_LAYOUT=""
    for d in "$USB_MOUNT/asusware.arm" "$USB_MOUNT/asusware.arm64" "$USB_MOUNT/asusware"; do
        [ -d "$d" ] || continue
        DM_ROOT="$d"
        DM_LAYOUT="${d##*/}"
        break
    done

    printf '%s\n' "$BASE" > "$RUNTIME_BASE_FILE" 2>/dev/null || true
    return 0
}

load_platform(){
    [ -f "$PLATFORM_FILE" ] || { fail "Не найден $PLATFORM_FILE. Повтори установку через install.sh"; return 1; }
    . "$PLATFORM_FILE"

    # Old builds persisted absolute /tmp/mnt/<name> paths. They are invalid as
    # soon as /dev/sdb1 becomes /dev/sda1 or ASUS changes the mount name.
    # Runtime paths are always rebuilt from the current script location.
    CONFIG="$BASE/${CONFIG_REL:-config.yaml}"
    GCNET_BIN="$BASE/${GCNET_REL:-bin/gcnet}"
    PKG_PATH=""
    DM_ROOT=""
    refresh_storage_identity
    return 0
}

find_dm_root(){
    refresh_storage_identity >/dev/null 2>&1 || true
    [ -n "$DM_ROOT" ] && [ -d "$DM_ROOT" ]
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
    for p in /usr/sbin/ip /sbin/ip /usr/bin/ip /bin/ip /opt/sbin/ip /opt/bin/ip /tmp/opt/sbin/ip /tmp/opt/bin/ip; do
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
    return 1
}

have(){ tool_path "$1" >/dev/null 2>&1; }

find_nohup(){
    refresh_path >/dev/null 2>&1 || true
    for p in /usr/bin/nohup /bin/nohup /usr/sbin/nohup /sbin/nohup \
        "$DM_ROOT/bin/nohup" /opt/bin/nohup /tmp/opt/bin/nohup; do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

find_nvram(){
    [ -n "$NVRAM_BIN" ] && [ -x "$NVRAM_BIN" ] && return 0
    refresh_path >/dev/null 2>&1 || true
    for p in /usr/sbin/nvram /sbin/nvram /usr/bin/nvram /bin/nvram; do
        [ -x "$p" ] && { NVRAM_BIN="$p"; return 0; }
    done
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


OPT_NAMESPACE_STATE="/tmp/goshacrash-opt-bind.state"

find_system_mount_runtime(){
    for p in /bin/mount /sbin/mount /usr/bin/mount /usr/sbin/mount; do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

find_system_umount_runtime(){
    for p in /bin/umount /sbin/umount /usr/bin/umount /usr/sbin/umount; do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

opt_namespace_write_through_runtime(){
    [ -n "$DM_ROOT" ] && [ -d "$DM_ROOT" ] || return 1
    probe=".goshacrash-opt-probe.$$"
    rm -f "/opt/$probe" "$DM_ROOT/$probe" 2>/dev/null || true

    if ( : > "/opt/$probe" ) 2>/dev/null; then
        if [ -e "$DM_ROOT/$probe" ]; then
            rm -f "/opt/$probe" "$DM_ROOT/$probe" 2>/dev/null || true
            return 0
        fi
        rm -f "/opt/$probe" 2>/dev/null || true
    fi
    return 1
}

usb_storage_sanity_runtime(){
    for probe_dir in "$DM_ROOT" "$DM_ROOT/scripts" "$BASE/ui"; do
        [ -d "$probe_dir" ] || continue
        if ! ls -la "$probe_dir" >/dev/null 2>> "$PACKAGES_LOG"; then
            log_event ERROR opt "USB filesystem metadata unreadable at $probe_dir; offline fsck required"
            return 1
        fi
    done
    return 0
}

preserve_stock_opt_payload_runtime(){
    for entry in /opt/*; do
        [ -e "$entry" ] || continue
        [ -L "$entry" ] && continue
        name="${entry##*/}"
        target="$DM_ROOT/$name"
        if [ -d "$target" ]; then
            ls -la "$target" >/dev/null 2>> "$PACKAGES_LOG" || {
                log_event ERROR opt "USB/Optware target unreadable: $target; offline fsck required"
                return 1
            }
        fi
        printf '[%s] OPT PRESERVE(runtime): %s -> %s\n' "$(now)" "$entry" "$target" >> "$PACKAGES_LOG" 2>/dev/null || true
        if [ -d "$entry" ]; then
            mkdir -p "$target" >> "$PACKAGES_LOG" 2>&1 || return 1
            cp -R "$entry/." "$target/" >> "$PACKAGES_LOG" 2>&1 || return 1
        elif [ -f "$entry" ]; then
            cp -f "$entry" "$target" >> "$PACKAGES_LOG" 2>&1 || return 1
        fi
    done
    return 0
}

prepare_optware_topdirs_runtime(){
    [ -n "$DM_ROOT" ] && [ -d "$DM_ROOT" ] || return 1
    mkdir -p \
        "$DM_ROOT/libexec" \
        "$DM_ROOT/man/man1" \
        "$DM_ROOT/var" 2>/dev/null || return 1
    return 0
}

prepare_optware_namespace_runtime(){
    ensure_optware_link || return 1
    usb_storage_sanity_runtime || return 1

    if opt_namespace_write_through_runtime; then
        prepare_optware_topdirs_runtime || return 1
        if awk '$2=="/opt" {found=1} END {exit !found}' /proc/mounts 2>/dev/null; then
            printf '%s\n' "$DM_ROOT" > "$OPT_NAMESPACE_STATE" 2>/dev/null || true
        fi
        return 0
    fi

    mount_bin="$(find_system_mount_runtime 2>/dev/null)"
    [ -n "$mount_bin" ] || return 1

    if awk '$2=="/opt" {found=1} END {exit !found}' /proc/mounts 2>/dev/null; then
        return 1
    fi

    preserve_stock_opt_payload_runtime || return 1
    touch "$DM_ROOT/.goshacrash-opt-root" 2>/dev/null || true

    "$mount_bin" -o bind "$DM_ROOT" /opt >> "$PACKAGES_LOG" 2>&1 || \
      "$mount_bin" --bind "$DM_ROOT" /opt >> "$PACKAGES_LOG" 2>&1 || return 1

    opt_namespace_write_through_runtime || {
        umount_bin="$(find_system_umount_runtime 2>/dev/null)"
        [ -n "$umount_bin" ] && "$umount_bin" /opt >/dev/null 2>&1 || true
        return 1
    }

    prepare_optware_topdirs_runtime || return 1
    printf '%s\n' "$DM_ROOT" > "$OPT_NAMESPACE_STATE" 2>/dev/null || true
    log_event INFO opt "writable /opt bound to $DM_ROOT; libexec/man/var ready"
    return 0
}
optware_runtime_ready(){
    ensure_optware_link >/dev/null 2>&1 || true
    [ -x /tmp/opt/bin/ipkg ] || [ -x /tmp/opt/bin/opkg ] || [ -x /opt/bin/ipkg ] || [ -x /opt/bin/opkg ] || [ -x "$DM_ROOT/bin/ipkg" ] || [ -x "$DM_ROOT/bin/opkg" ]
}
runtime_copy_alias(){
    src="$1"
    dst="$2"
    test -f "$src" || return 1
    test -f "$dst" && return 0
    cp -f "$src" "$dst" 2>/dev/null || return 1
    chmod 755 "$dst" 2>/dev/null || true
}

runtime_first_versioned(){
    pattern="$1"
    for f in $pattern; do
        test -f "$f" && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

OPTWARE_OVERLAY="/tmp/goshacrash-opt"
OPTWARE_OVERLAY_LIB="$OPTWARE_OVERLAY/lib"

build_optware_overlay_runtime(){
    test -n "$DM_ROOT" && test -d "$DM_ROOT/lib" || return 1
    rm -rf "$OPTWARE_OVERLAY" 2>/dev/null || true
    mkdir -p "$OPTWARE_OVERLAY_LIB" || return 1

    for src in "$DM_ROOT"/lib/lib*.so.[0-9]*.[0-9]*; do
        test -f "$src" || continue
        base="${src##*/}"
        prefix="${base%%.so.*}"
        ver="${base#*.so.}"
        major="${ver%%.*}"
        case "$major" in ''|*[!0-9]*) continue ;; esac
        ln -sf "$src" "$OPTWARE_OVERLAY_LIB/$prefix.so.$major" 2>/dev/null || true
    done

    for src in "$DM_ROOT"/lib/libuClibc-*.so; do
        test -f "$src" && ln -sf "$src" "$OPTWARE_OVERLAY_LIB/libc.so.0" 2>/dev/null
    done
    for src in "$DM_ROOT"/lib/ld-uClibc-*.so; do
        test -f "$src" && ln -sf "$src" "$OPTWARE_OVERLAY_LIB/ld-uClibc.so.0" 2>/dev/null
    done
    for base in libcrypt libdl libm libnsl libpthread libresolv librt libutil; do
        for src in "$DM_ROOT"/lib/"$base"-*.so; do
            test -f "$src" && {
                ln -sf "$src" "$OPTWARE_OVERLAY_LIB/$base.so.0" 2>/dev/null
                break
            }
        done
    done
    for src in "$DM_ROOT"/lib/lib*.so.[0-9]; do
        test -f "$src" || continue
        ln -sf "$src" "$OPTWARE_OVERLAY_LIB/${src##*/}" 2>/dev/null || true
    done
    return 0
}

optware_env_runtime(){
    build_optware_overlay_runtime || return 1
    printf '%s\n' "$OPTWARE_OVERLAY_LIB:$DM_ROOT/lib:/lib:/usr/lib"
}

repair_generic_sonames_runtime(){
    test -n "$DM_ROOT" && test -d "$DM_ROOT/lib" || return 1

    for src in "$DM_ROOT"/lib/lib*.so.[0-9]*.[0-9]*; do
        test -f "$src" || continue

        base="${src##*/}"
        prefix="${base%%.so.*}"
        ver="${base#*.so.}"
        major="${ver%%.*}"

        case "$major" in
            ''|*[!0-9]*) continue ;;
        esac

        dst="$DM_ROOT/lib/$prefix.so.$major"
        test -f "$dst" && continue
        runtime_copy_alias "$src" "$dst" || return 1
    done
    return 0
}

repair_optware_abi_runtime(){
    build_optware_overlay_runtime
}

run_optware_runtime(){
    ldpath="$(optware_env_runtime)" || return 1
    LD_LIBRARY_PATH="$ldpath" "$@"
}

repair_opt(){
    find_dm_root >/dev/null 2>&1 || return 1
    test -n "$DM_ROOT" && test -d "$DM_ROOT" || return 1

    if test -L /tmp/opt; then
        current="$(readlink /tmp/opt 2>/dev/null)"
        if test "$current" != "$DM_ROOT"; then
            rm -f /tmp/opt 2>/dev/null || return 1
            ln -s "$DM_ROOT" /tmp/opt 2>/dev/null || return 1
        fi
    elif test -e /tmp/opt; then
        mv /tmp/opt "/tmp/opt.goshacrash.$$.stale" 2>/dev/null || return 1
        ln -s "$DM_ROOT" /tmp/opt 2>/dev/null || return 1
    else
        ln -s "$DM_ROOT" /tmp/opt 2>/dev/null || return 1
    fi

    prepare_optware_namespace_runtime || {
        log_event ERROR opt "cannot prepare writable /opt namespace for $DM_ROOT"
        return 1
    }
    repair_optware_abi_runtime >/dev/null 2>&1 || true
    refresh_path
    return 0
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

pkg_is_installed_runtime(){
    name="$1"
    find_pkg >/dev/null 2>&1 || return 1
    "$PKG" list_installed 2>/dev/null | grep -q "^$name "
}

pkg_reinstall_runtime(){
    name="$1"
    repair_opt >/dev/null 2>&1 || return 1
    find_pkg || return 1
    rotate_log "$PACKAGES_LOG" 1048576
    printf '[%s] RUN: %s remove %s\n' "$(now)" "$PKG" "$name" >> "$PACKAGES_LOG"
    "$PKG" remove "$name" >> "$PACKAGES_LOG" 2>&1 || true
    printf '[%s] RUN: %s update\n' "$(now)" "$PKG" >> "$PACKAGES_LOG"
    "$PKG" update >> "$PACKAGES_LOG" 2>&1 || true
    printf '[%s] RUN: %s install %s\n' "$(now)" "$PKG" "$name" >> "$PACKAGES_LOG"
    "$PKG" install "$name" >> "$PACKAGES_LOG" 2>&1 || return 1
    ensure_optware_link >/dev/null 2>&1 || true
    refresh_path
    return 0
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
    LC_ALL=C awk -v key="$key" '
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
    LC_ALL=C awk -v section="$section" -v key="$key" '
      {sub(/\r$/, ""); sub(/[[:space:]]+$/, "")}
      $0 ~ "^" section ":[[:space:]]*($|#)" {inside=1; next}
      inside && /^[^[:space:]#]/ {exit}
      inside && $0 ~ "^[[:space:]]+" key ":[[:space:]]*" {line=$0; sub("^[[:space:]]+" key ":[[:space:]]*", "", line); print line; exit}
    ' "$file" 2>/dev/null | while IFS= read -r line; do strip_value "$line"; done
}
yaml_section_has_key(){
    file="$1"; section="$2"; key="$3"
    LC_ALL=C awk -v section="$section" -v key="$key" '
      {sub(/\r$/, "")}
      $0 ~ "^" section ":[[:space:]]*($|#)" {inside=1; next}
      inside && /^[^[:space:]]/ {exit}
      inside && $0 ~ "^[[:space:]]+" key ":[[:space:]]*" {found=1; exit}
      END{exit found ? 0 : 1}
    ' "$file" >/dev/null 2>&1
}
is_true(){ case "$1" in true|True|TRUE|yes|Yes|YES|1|on|On|ON) return 0;; *) return 1;; esac; }
is_false(){ case "$1" in false|False|FALSE|no|No|NO|0|off|Off|OFF) return 0;; *) return 1;; esac; }

proc_cmdline(){
    p="$1"
    [ -n "$p" ] && [ -r "/proc/$p/cmdline" ] || return 1
    /bin/busybox tr '\000' ' ' < "/proc/$p/cmdline" 2>/dev/null
}

current_boot_token(){
    # Linux exposes a per-boot UUID on both modern ASUSWRT and most 2.6 builds.
    # It is the strongest way to distinguish persistent USB locks from the
    # process that owned them before a hard power cut.
    if [ -r /proc/sys/kernel/random/boot_id ]; then
        token="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
        [ -n "$token" ] && { printf '%s\n' "$token"; return 0; }
    fi

    # Fallback for old kernels: /tmp is recreated on every boot, so a token
    # stored here cannot survive a power cycle even though run/ on USB does.
    if [ ! -s "$BOOT_TOKEN_FILE" ]; then
        token=""
        if [ -r /dev/urandom ]; then
            token="$(/bin/busybox od -An -N16 -tx1 /dev/urandom 2>/dev/null | /bin/busybox tr -d ' \n')"
        fi
        [ -n "$token" ] || token="$$-$(/bin/busybox awk '{print $1}' /proc/uptime 2>/dev/null)-$(uname -r 2>/dev/null)"
        tmp="$BOOT_TOKEN_FILE.$$"
        printf '%s\n' "$token" > "$tmp" 2>/dev/null || return 1
        if [ ! -s "$BOOT_TOKEN_FILE" ]; then
            mv -f "$tmp" "$BOOT_TOKEN_FILE" 2>/dev/null || true
        fi
        rm -f "$tmp" 2>/dev/null || true
    fi
    cat "$BOOT_TOKEN_FILE" 2>/dev/null
}

lock_stamp(){
    dir="$1"
    token="$(current_boot_token 2>/dev/null)" || return 1
    [ -n "$token" ] || return 1
    printf '%s\n' "$$" > "$dir/pid" 2>/dev/null || return 1
    printf '%s\n' "$token" > "$dir/boot" 2>/dev/null || return 1
}

lock_is_current_boot(){
    dir="$1"
    [ -d "$dir" ] && [ -f "$dir/boot" ] || return 1
    saved="$(cat "$dir/boot" 2>/dev/null)"
    current="$(current_boot_token 2>/dev/null)" || return 1
    [ -n "$saved" ] && [ "$saved" = "$current" ]
}

pid_matches(){
    p="$1"; needle1="$2"; needle2="${3:-}"
    case "$p" in ''|*[!0-9]*) return 1;; esac
    kill -0 "$p" 2>/dev/null || return 1
    cmd="$(proc_cmdline "$p" 2>/dev/null)" || return 1
    case "$cmd" in *"$needle1"*) : ;; *) return 1;; esac
    if [ -n "$needle2" ]; then
        case "$cmd" in *"$needle2"*) : ;; *) return 1;; esac
    fi
    return 0
}

controller_pid_alive(){
    pid_matches "$1" "$BASE/goshacrash.sh"
}

running_pid(){
    [ -f "$PIDFILE" ] || return 1
    p="$(cat "$PIDFILE" 2>/dev/null)"
    case "$p" in ''|*[!0-9]*) rm -f "$PIDFILE" 2>/dev/null || true; return 1;; esac
    pid_matches "$p" "$BIN" || { rm -f "$PIDFILE" 2>/dev/null || true; return 1; }
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

tun_kernel_ready(){
    [ -c /dev/net/tun ] || return 1
    dd_bin=""
    for p in /bin/dd /usr/bin/dd /sbin/dd /usr/sbin/dd; do
        [ -x "$p" ] && { dd_bin="$p"; break; }
    done
    [ -n "$dd_bin" ] || return 1
    "$dd_bin" if=/dev/net/tun of=/dev/null bs=1 count=0 >/dev/null 2>&1
}

ensure_tun(){
    tun_kernel_ready && return 0

    modprobe_bin=""
    for p in /sbin/modprobe /usr/sbin/modprobe /bin/modprobe /usr/bin/modprobe; do
        [ -x "$p" ] && { modprobe_bin="$p"; break; }
    done
    [ -n "$modprobe_bin" ] && "$modprobe_bin" tun >/dev/null 2>&1 || true

    if ! tun_kernel_ready; then
        insmod_bin=""
        for p in /sbin/insmod /usr/sbin/insmod /bin/insmod /usr/bin/insmod; do
            [ -x "$p" ] && { insmod_bin="$p"; break; }
        done
        for m in "$BASE/modules/tun.ko" "/lib/modules/$(uname -r)/kernel/drivers/net/tun.ko" "/lib/modules/$(uname -r)/tun.ko"; do
            tun_kernel_ready && break
            [ -n "$insmod_bin" ] && [ -f "$m" ] && "$insmod_bin" "$m" >/dev/null 2>&1 || true
        done
    fi

    if [ ! -c /dev/net/tun ]; then
        mkdir -p /dev/net 2>/dev/null || true
        mknod_bin=""
        for p in /bin/mknod /sbin/mknod /usr/bin/mknod /usr/sbin/mknod; do
            [ -x "$p" ] && { mknod_bin="$p"; break; }
        done
        [ -n "$mknod_bin" ] && "$mknod_bin" /dev/net/tun c 10 200 2>/dev/null || true
        chmod 600 /dev/net/tun 2>/dev/null || true
    fi

    tun_kernel_ready
}


mihomo_elf_header_runtime(){
    file="$1"
    od_bin=""; dd_bin=""
    for p in /usr/bin/od /bin/od /usr/sbin/od /sbin/od "$DM_ROOT/bin/od" /opt/bin/od /tmp/opt/bin/od; do
        [ -x "$p" ] && { od_bin="$p"; break; }
    done
    for p in /bin/dd /usr/bin/dd /sbin/dd /usr/sbin/dd "$DM_ROOT/bin/dd" /opt/bin/dd /tmp/opt/bin/dd; do
        [ -x "$p" ] && { dd_bin="$p"; break; }
    done
    [ -n "$od_bin" ] && [ -n "$dd_bin" ] || return 2
    "$dd_bin" if="$file" bs=1 count=20 2>/dev/null | "$od_bin" -An -tx1 2>/dev/null | tr -d ' \n\r'
}

validate_binary_arch(){
    file="$1"
    hex="$(mihomo_elf_header_runtime "$file")"; rc=$?
    [ "$rc" -eq 2 ] && return 0
    [ "$rc" -eq 0 ] || return 0
    magic="$(printf '%s' "$hex" | cut -c 1-8)"
    class="$(printf '%s' "$hex" | cut -c 9-10)"
    machine="$(printf '%s' "$hex" | cut -c 37-40)"
    [ "$magic" = 7f454c46 ] || { fail "Mihomo повреждён: файл не является ELF (header=${hex:-empty})"; return 1; }
    case "$MIHOMO_TARGET" in
      armv5|armv7)
        [ "$class" = 01 ] && [ "$machine" = 2800 ] || { fail "Mihomo не той архитектуры: нужен 32-bit ARM ($MIHOMO_TARGET), ELF class=$class machine=$machine. Повтори установку rc40-test2"; return 1; }
        ;;
      arm64|aarch64)
        [ "$class" = 02 ] && [ "$machine" = b700 ] || { fail "Mihomo не той архитектуры: нужен ARM64, ELF class=$class machine=$machine. Повтори установку rc40-test2"; return 1; }
        ;;
      amd64|amd64-compatible|x86_64)
        [ "$class" = 02 ] && [ "$machine" = 3e00 ] || { fail "Mihomo не той архитектуры: нужен x86_64, ELF class=$class machine=$machine. Повтори установку rc40-test2"; return 1; }
        ;;
    esac
    return 0
}

validate_binary_file(){
    file="$1"; require_gvisor="${2:-0}"
    [ -x "$file" ] || { fail "Не найден исполняемый Mihomo: $file"; return 1; }
    validate_binary_arch "$file" || return 1
    out="$("$file" -v 2>&1)" || { printf '%s\n' "$out" >&2; fail "Mihomo не запускается"; return 1; }
    printf '%s\n' "$out" | grep -qi mihomo || { printf '%s\n' "$out" >&2; fail "Файл не похож на Mihomo"; return 1; }
    if [ "$require_gvisor" = 1 ]; then
        printf '%s\n' "$out" | grep -Fq 'Use tags: with_gvisor' || { printf '%s\n' "$out" >&2; fail "Legacy-профилю нужна сборка with_gvisor"; return 1; }
    fi
}

find_od_runtime(){
    for od_candidate in /usr/bin/od /bin/od /usr/sbin/od /sbin/od; do
        [ -x "$od_candidate" ] && { printf '%s\n' "$od_candidate"; return 0; }
    done
    [ -x /bin/busybox ] && /bin/busybox od -An -tu1 -v /dev/null >/dev/null 2>&1 && { printf '%s\n' '/bin/busybox'; return 0; }
    return 1
}

config_utf8_valid(){
    [ -f "$CONFIG" ] || return 1
    od_bin="$(find_od_runtime 2>/dev/null)" || return 2
    if [ "$od_bin" = /bin/busybox ]; then
        /bin/busybox od -An -tu1 -v "$CONFIG" 2>/dev/null
    else
        "$od_bin" -An -tu1 -v "$CONFIG" 2>/dev/null
    fi | LC_ALL=C awk '
      BEGIN { need=0; ok=1; minc=128; maxc=191 }
      {
        for (i=1; i<=NF; i++) {
          b=$i+0
          if (need == 0) {
            if (b <= 127) continue
            if (b >= 194 && b <= 223) { need=1; minc=128; maxc=191; continue }
            if (b >= 224 && b <= 239) {
              need=2
              if (b == 224) { minc=160; maxc=191 }
              else if (b == 237) { minc=128; maxc=159 }
              else { minc=128; maxc=191 }
              continue
            }
            if (b >= 240 && b <= 244) {
              need=3
              if (b == 240) { minc=144; maxc=191 }
              else if (b == 244) { minc=128; maxc=143 }
              else { minc=128; maxc=191 }
              continue
            }
            ok=0; exit
          }
          if (b < minc || b > maxc) { ok=0; exit }
          need--
          minc=128; maxc=191
        }
      }
      END { if (!ok || need != 0) exit 1; exit 0 }
    '
}

required_config(){
    [ -f "$CONFIG" ] || { fail "Не найден $CONFIG"; return 1; }

    is_true "$(yaml_section "$CONFIG" tun enable)" || { fail "tun.enable должен быть true"; return 1; }
    stack="$(yaml_section "$CONFIG" tun stack)"
    [ -n "$stack" ] || { fail "tun.stack не задан"; return 1; }
    [ "$stack" = "$TUN_STACK" ] || { fail "tun.stack должен быть $TUN_STACK для текущего профиля"; return 1; }
    [ "$(yaml_section "$CONFIG" tun device)" = "$TUN_DEVICE" ] || { fail "tun.device должен быть $TUN_DEVICE"; return 1; }
    yaml_section_has_key "$CONFIG" tun dns-hijack || { fail "tun.dns-hijack не задан"; return 1; }

    is_true "$(yaml_section "$CONFIG" dns enable)" || { fail "dns.enable должен быть true"; return 1; }
    [ "$(yaml_section "$CONFIG" dns listen)" = "127.0.0.1:$DNS_PORT" ] || { fail "dns.listen должен быть 127.0.0.1:$DNS_PORT"; return 1; }

    [ -n "$(yaml_top "$CONFIG" external-controller)" ] || { fail "external-controller не задан"; return 1; }
    [ "$(yaml_top "$CONFIG" external-ui)" = "ui" ] || { fail "external-ui должен быть ui"; return 1; }
    [ -n "$(yaml_top "$CONFIG" external-ui-url)" ] || { fail "Добавь external-ui-url для обновления Zashboard из самой панели"; return 1; }

    if [ "$ROUTING_MODE" = manual ]; then
        is_false "$(yaml_section "$CONFIG" tun auto-route)" || { fail "manual: tun.auto-route должен быть false"; return 1; }
        is_false "$(yaml_section "$CONFIG" tun auto-redirect)" || { fail "manual: tun.auto-redirect должен быть false"; return 1; }
        is_false "$(yaml_section "$CONFIG" tun auto-detect-interface)" || { fail "manual: tun.auto-detect-interface должен быть false"; return 1; }
        [ "$(yaml_top "$CONFIG" routing-mark)" = "$OUTBOUND_MARK_DEC" ] || { fail "manual: routing-mark должен быть $OUTBOUND_MARK_DEC"; return 1; }
    else
        [ "$MIHOMO_TARGET" != armv5 ] || { fail "ARMv5 не поддерживает automatic routing в GoshaCrash"; return 1; }
        is_true "$(yaml_section "$CONFIG" tun auto-route)" || { fail "auto: tun.auto-route должен быть true"; return 1; }
        is_true "$(yaml_section "$CONFIG" tun auto-redirect)" || { fail "auto: tun.auto-redirect должен быть true"; return 1; }
        is_true "$(yaml_section "$CONFIG" tun auto-detect-interface)" || { fail "auto: tun.auto-detect-interface должен быть true"; return 1; }
        [ -z "$(yaml_top "$CONFIG" routing-mark)" ] || { fail "auto: routing-mark в конфиге не нужен"; return 1; }
    fi
}

check_config_with(){
    mihomo_file="$1"
    load_platform || return 1
    req=0; [ "$MIHOMO_TARGET" = armv5 ] && req=1
    validate_binary_file "$mihomo_file" "$req" || return 1
    config_utf8_valid
    utf8_rc=$?
    if [ "$utf8_rc" = 1 ]; then
        fail "config.yaml имеет повреждённую/не-UTF-8 кодировку. Mihomo принимает YAML только в корректном UTF-8"
        return 1
    fi
    required_config || return 1
    "$mihomo_file" -t -d "$BASE" -f "$CONFIG"
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

wait_route_ready(){
    n=0
    while [ "$n" -lt 15 ]; do
        route_status >/dev/null 2>&1 && return 0
        sleep 1
        n=$((n + 1))
    done
    return 1
}


modern_uplink_signature(){
    [ "${LEGACY:-1}" = 0 ] || { printf '%s\n' legacy; return 0; }
    refresh_path
    [ -n "$IP_BIN" ] && [ -x "$IP_BIN" ] || return 1

    out="$($IP_BIN route get 1.1.1.1 2>/dev/null | /bin/busybox head -n 1)"
    [ -n "$out" ] || return 1

    dev="$(printf '%s\n' "$out" | awk '{for(i=1;i<=NF;i++) if($i=="dev" && (i+1)<=NF){print $(i+1); exit}}')"
    [ -n "$dev" ] || return 1
    [ "$dev" != "$TUN_DEVICE" ] && [ "$dev" != lo ] || return 1

    # A route may exist before the interface is usable. Require that the
    # kernel can still resolve the device and that it exists in the link set.
    "$IP_BIN" link show "$dev" >/dev/null 2>&1 || return 1
    printf '%s\n' "$dev|$out"
}

wait_modern_uplink(){
    [ "${LEGACY:-1}" = 0 ] || return 0
    limit="${1:-60}"
    waited=0
    stable=0
    previous=""

    while [ "$waited" -lt "$limit" ]; do
        sig="$(modern_uplink_signature 2>/dev/null)"
        if [ -n "$sig" ]; then
            if [ "$sig" = "$previous" ]; then
                stable=$((stable + 1))
            else
                stable=1
                previous="$sig"
            fi
            [ "$stable" -ge 3 ] && return 0
        else
            stable=0
            previous=""
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

start_runtime(){
    ensure_dirs || return 1
    load_platform || return 1
    repair_opt >/dev/null 2>&1 || true
    refresh_path
    check_config || return 1
    ensure_tun || { fail "/dev/net/tun недоступен"; return 1; }
    if p="$(running_pid)"; then route_start || return 1; say "Mihomo уже работает, PID=$p"; return 0; fi
    if [ "${LEGACY:-1}" = 0 ]; then
        wait_modern_uplink 60 || { fail "Modern uplink ещё не готов: стабильный ip route get не получен"; return 1; }
    fi

    [ "$ROUTING_MODE" = manual ] && route_stop >/dev/null 2>&1 || true
    kill_mihomo
    rotate_log "$MIHOMO_LOG" 2097152
    log_event INFO runtime "starting $BIN with $CONFIG"
    nohup_bin="$(find_nohup 2>/dev/null)"
    if [ -n "$nohup_bin" ]; then
        GOGC="${GOGC:-50}" "$nohup_bin" "$BIN" -d "$BASE" -f "$CONFIG" </dev/null >> "$MIHOMO_LOG" 2>&1 &
    else
        GOGC="${GOGC:-50}" "$BIN" -d "$BASE" -f "$CONFIG" </dev/null >> "$MIHOMO_LOG" 2>&1 &
    fi
    p=$!; printf '%s\n' "$p" > "$PIDFILE"; sleep 3
    running_pid >/dev/null 2>&1 || { tail -n 80 "$MIHOMO_LOG" >&2; fail "Mihomo завершился при запуске"; return 1; }
    wait_port "$DNS_PORT" || { kill_mihomo; tail -n 80 "$MIHOMO_LOG" >&2; fail "DNS Mihomo не слушает порт $DNS_PORT"; return 1; }
    wait_tun || { kill_mihomo; tail -n 80 "$MIHOMO_LOG" >&2; fail "Mihomo не создал $TUN_DEVICE"; return 1; }
    route_start || { kill_mihomo; route_stop >/dev/null 2>&1 || true; fail "Маршрутизация не поднялась; оставлен DIRECT"; return 1; }
    wait_route_ready || { kill_mihomo; route_stop >/dev/null 2>&1 || true; tail -n 80 "$MIHOMO_LOG" >&2; fail "Маршрутизация не стала рабочей после запуска; оставлен DIRECT"; return 1; }
    ok "Mihomo запущен, PID=$p; profile=$PLATFORM"
}

start_lock_active(){
    [ -d "$START_LOCK" ] || return 1
    lock_is_current_boot "$START_LOCK" || { rm -rf "$START_LOCK" 2>/dev/null || true; return 1; }
    p="$(cat "$START_LOCK/pid" 2>/dev/null)"
    if controller_pid_alive "$p"; then
        return 0
    fi
    rm -rf "$START_LOCK" 2>/dev/null || true
    return 1
}

with_start_lock(){
    if ! mkdir "$START_LOCK" 2>/dev/null; then
        if ! start_lock_active; then
            mkdir "$START_LOCK" 2>/dev/null || return 1
        else
            n=0
            while start_lock_active && [ "$n" -lt 20 ]; do
                sleep 1
                n=$((n + 1))
            done
            start_lock_active && { fail "Другой запуск GoshaCrash не завершился"; return 1; }
            mkdir "$START_LOCK" 2>/dev/null || return 1
        fi
    fi
    lock_stamp "$START_LOCK" || { rm -rf "$START_LOCK" 2>/dev/null || true; return 1; }
    "$@"
    rc=$?
    rm -rf "$START_LOCK" 2>/dev/null || true
    return "$rc"
}

control_lock_set(){
    if [ -d "$CONTROL_LOCK" ]; then
        if control_lock_active; then
            p="$(cat "$CONTROL_LOCK/pid" 2>/dev/null)"
            [ "$p" = "$$" ] && return 0
            n=0
            while control_lock_active && [ "$n" -lt 20 ]; do
                sleep 1
                n=$((n + 1))
            done
            control_lock_active && return 1
        fi
        rm -rf "$CONTROL_LOCK" 2>/dev/null || true
    fi
    mkdir "$CONTROL_LOCK" 2>/dev/null || return 1
    lock_stamp "$CONTROL_LOCK" || { rm -rf "$CONTROL_LOCK" 2>/dev/null || true; return 1; }
}

control_lock_clear(){
    [ -d "$CONTROL_LOCK" ] || return 0
    lock_is_current_boot "$CONTROL_LOCK" || { rm -rf "$CONTROL_LOCK" 2>/dev/null || true; return 0; }
    p="$(cat "$CONTROL_LOCK/pid" 2>/dev/null)"
    [ "$p" = "$$" ] && rm -rf "$CONTROL_LOCK" 2>/dev/null || true
}

control_lock_active(){
    [ -d "$CONTROL_LOCK" ] || return 1
    lock_is_current_boot "$CONTROL_LOCK" || { rm -rf "$CONTROL_LOCK" 2>/dev/null || true; return 1; }
    p="$(cat "$CONTROL_LOCK/pid" 2>/dev/null)"
    if controller_pid_alive "$p"; then
        return 0
    fi
    rm -rf "$CONTROL_LOCK" 2>/dev/null || true
    return 1
}

boot_pid(){
    [ -f "$BOOT_PIDFILE" ] || return 1
    p="$(cat "$BOOT_PIDFILE" 2>/dev/null)"
    if pid_matches "$p" "$BASE/goshacrash.sh" " boot"; then
        printf '%s\n' "$p"
        return 0
    fi
    rm -f "$BOOT_PIDFILE" 2>/dev/null || true
    return 1
}

boot_lock_acquire(){
    if mkdir "$BOOT_LOCK" 2>/dev/null; then
        lock_stamp "$BOOT_LOCK" || { rm -rf "$BOOT_LOCK" 2>/dev/null || true; return 1; }
        return 0
    fi

    if lock_is_current_boot "$BOOT_LOCK"; then
        p="$(cat "$BOOT_LOCK/pid" 2>/dev/null)"
        if pid_matches "$p" "$BASE/goshacrash.sh" " boot"; then
            return 1
        fi
    fi

    rm -rf "$BOOT_LOCK" 2>/dev/null || true
    mkdir "$BOOT_LOCK" 2>/dev/null || return 1
    lock_stamp "$BOOT_LOCK" || { rm -rf "$BOOT_LOCK" 2>/dev/null || true; return 1; }
    return 0
}

boot_lock_active(){
    [ -d "$BOOT_LOCK" ] || return 1
    lock_is_current_boot "$BOOT_LOCK" || { rm -rf "$BOOT_LOCK" 2>/dev/null || true; return 1; }
    p="$(cat "$BOOT_LOCK/pid" 2>/dev/null)"
    pid_matches "$p" "$BASE/goshacrash.sh" " boot" || { rm -rf "$BOOT_LOCK" 2>/dev/null || true; return 1; }
    return 0
}

boot_lock_release(){
    rm -f "$BOOT_PIDFILE" 2>/dev/null || true
    rm -rf "$BOOT_LOCK" 2>/dev/null || true
}

cleanup_stale_runtime_state(){
    # WAN probe state is runtime-only. Keeping it on USB across a reboot can
    # make a fresh boot inherit an old offline decision. Reset only transient
    # connectivity state; manual-stop remains persistent by design.
    rm -f "$WAN_OFFLINE" "$WAN_FAIL_COUNT" "$WAN_OK_COUNT" "$WAN_STATE" "$WATCHDOG_HEARTBEAT" 2>/dev/null || true

    # Files under run/ live on USB and survive a hard power cut.  A PID alone
    # is not proof that it still belongs to GoshaCrash after the next boot.
    running_pid >/dev/null 2>&1 || rm -f "$PIDFILE" 2>/dev/null || true
    watchdog_pid >/dev/null 2>&1 || rm -f "$WATCHDOG_PIDFILE" 2>/dev/null || true
    boot_pid >/dev/null 2>&1 || rm -f "$BOOT_PIDFILE" 2>/dev/null || true

    # boot_lock serializes concurrent USB hooks, so these can only be stale
    # leftovers from an interrupted controller action at this point.
    start_lock_active >/dev/null 2>&1 || rm -rf "$START_LOCK" 2>/dev/null || true
    control_lock_active >/dev/null 2>&1 || rm -rf "$CONTROL_LOCK" 2>/dev/null || true

    # A watchdog-start lock from a previous boot is always stale, even if its
    # PID has already been reused by another GoshaCrash process.
    if [ -d "$WATCHDOG_START_LOCK" ]; then
        if ! lock_is_current_boot "$WATCHDOG_START_LOCK"; then
            rm -rf "$WATCHDOG_START_LOCK" 2>/dev/null || true
        else
            p="$(cat "$WATCHDOG_START_LOCK/pid" 2>/dev/null)"
            controller_pid_alive "$p" || rm -rf "$WATCHDOG_START_LOCK" 2>/dev/null || true
        fi
    fi
}

stop_runtime(){
    if [ "$ROUTING_MODE" = auto ]; then kill_mihomo; route_stop >/dev/null 2>&1 || true; else route_stop >/dev/null 2>&1 || true; kill_mihomo; fi
    rm -rf "$START_LOCK" 2>/dev/null || true
}

watchdog_pid(){
    [ -f "$WATCHDOG_PIDFILE" ] || return 1
    p="$(cat "$WATCHDOG_PIDFILE" 2>/dev/null)"
    if pid_matches "$p" "$BASE/goshacrash.sh" " watchdog-loop"; then
        printf '%s\n' "$p"
        return 0
    fi
    rm -f "$WATCHDOG_PIDFILE" 2>/dev/null || true
    return 1
}

watchdog_stop(){
    if p="$(watchdog_pid)"; then
        kill "$p" 2>/dev/null || true
        sleep 1
        pid_matches "$p" "$BASE/goshacrash.sh" " watchdog-loop" && kill -9 "$p" 2>/dev/null || true
    fi
    rm -f "$WATCHDOG_PIDFILE" 2>/dev/null || true
    rm -rf "$WATCHDOG_START_LOCK" 2>/dev/null || true
}

watchdog_start(){
    [ -f "$MANUAL_STOP" ] && return 0
    watchdog_pid >/dev/null 2>&1 && return 0

    if ! mkdir "$WATCHDOG_START_LOCK" 2>/dev/null; then
        watchdog_pid >/dev/null 2>&1 && return 0
        if lock_is_current_boot "$WATCHDOG_START_LOCK"; then
            p="$(cat "$WATCHDOG_START_LOCK/pid" 2>/dev/null)"
            if controller_pid_alive "$p"; then
                sleep 1
                watchdog_pid >/dev/null 2>&1 && return 0
                return 1
            fi
        fi
        rm -rf "$WATCHDOG_START_LOCK" 2>/dev/null || true
        mkdir "$WATCHDOG_START_LOCK" 2>/dev/null || return 1
    fi
    lock_stamp "$WATCHDOG_START_LOCK" || { rm -rf "$WATCHDOG_START_LOCK" 2>/dev/null || true; return 1; }

    watchdog_pid >/dev/null 2>&1 && { rm -rf "$WATCHDOG_START_LOCK" 2>/dev/null || true; return 0; }
    rotate_log "$WATCHDOG_LOG" 1048576
    printf '[%s] watchdog: launch requested by pid=%s\n' "$(now)" "$$" >> "$WATCHDOG_LOG" 2>/dev/null || true

    nohup_bin="$(find_nohup 2>/dev/null)"
    if [ -n "$nohup_bin" ]; then
        GOSHACRASH_BASE="$BASE" "$nohup_bin" /bin/sh "$BASE/goshacrash.sh" watchdog-loop </dev/null >> "$WATCHDOG_LOG" 2>&1 &
    else
        GOSHACRASH_BASE="$BASE" /bin/sh "$BASE/goshacrash.sh" watchdog-loop </dev/null >> "$WATCHDOG_LOG" 2>&1 &
    fi
    p=$!
    printf '%s\n' "$p" > "$WATCHDOG_PIDFILE" 2>/dev/null || true
    sleep 1

    if ! pid_matches "$p" "$BASE/goshacrash.sh" " watchdog-loop"; then
        printf '[%s] watchdog: launch failed, pid=%s is not watchdog-loop\n' "$(now)" "$p" >> "$WATCHDOG_LOG" 2>/dev/null || true
        test "$(cat "$WATCHDOG_PIDFILE" 2>/dev/null)" = "$p" && rm -f "$WATCHDOG_PIDFILE" 2>/dev/null || true
        rm -rf "$WATCHDOG_START_LOCK" 2>/dev/null || true
        return 1
    fi

    printf '[%s] watchdog: started pid=%s\n' "$(now)" "$p" >> "$WATCHDOG_LOG" 2>/dev/null || true
    rm -rf "$WATCHDOG_START_LOCK" 2>/dev/null || true
    return 0
}

watchdog_check(){
    [ -f "$MANUAL_STOP" ] && return 0
    boot_lock_active && return 0
    control_lock_active && return 0
    start_lock_active && return 0
    watchdog_connectivity_step || true
    [ -f "$WAN_OFFLINE" ] && return 0
    if ! running_pid >/dev/null 2>&1; then
      rotate_log "$WATCHDOG_LOG" 1048576
      printf '[%s] watchdog: Mihomo down; recovery start\n' "$(now)" >> "$WATCHDOG_LOG" 2>/dev/null || true
      if ! with_start_lock start_runtime >> "$WATCHDOG_LOG" 2>&1; then
        printf '[%s] watchdog: recovery failed\n' "$(now)" >> "$WATCHDOG_LOG" 2>/dev/null || true
      fi
      return 0
    fi
    if ! runtime_health_ok; then
      rotate_log "$WATCHDOG_LOG" 1048576
      printf '[%s] watchdog: runtime unhealthy; restart\n' "$(now)" >> "$WATCHDOG_LOG" 2>/dev/null || true
      stop_runtime
      if ! with_start_lock start_runtime >> "$WATCHDOG_LOG" 2>&1; then
        printf '[%s] watchdog: restart failed\n' "$(now)" >> "$WATCHDOG_LOG" 2>/dev/null || true
      fi
    fi
}

watchdog_loop(){
    ensure_dirs || exit 1
    printf '%s\n' "$$" > "$WATCHDOG_PIDFILE" 2>/dev/null || exit 1
    printf '[%s] watchdog: loop entered pid=%s interval=%ss\n' "$(now)" "$$" "$WATCHDOG_INTERVAL" >> "$WATCHDOG_LOG" 2>/dev/null || true
    trap 'printf "[%s] watchdog: loop stopping pid=%s\n" "$(now)" "$$" >> "$WATCHDOG_LOG" 2>/dev/null || true; rm -f "$WATCHDOG_PIDFILE" 2>/dev/null || true; exit 0' HUP INT TERM

    # Do not sleep first: after a hard power cut recovery must start as soon as
    # the controller reaches the watchdog, not one interval later.
    printf '%s pid=%s\n' "$(now)" "$$" > "$WATCHDOG_HEARTBEAT" 2>/dev/null || true
    watchdog_check
    while :; do
        sleep "$WATCHDOG_INTERVAL"
        printf '%s pid=%s\n' "$(now)" "$$" > "$WATCHDOG_HEARTBEAT" 2>/dev/null || true
        watchdog_check
    done
}

start(){
    ensure_dirs || return 1
    load_platform || return 1
    refresh_path
    check_config || return 1

    rm -f "$MANUAL_STOP"
    control_lock_set || { fail "Другая операция GoshaCrash ещё выполняется"; return 1; }

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

    control_lock_clear
    watchdog_start
    return "$rc"
}
stop(){
    ensure_dirs || return 1; load_platform || true; touch "$MANUAL_STOP"
    control_lock_set || { fail "Другая операция GoshaCrash ещё выполняется"; return 1; }
    watchdog_stop; stop_runtime; control_lock_clear; ok "Mihomo остановлен; обычный DIRECT восстановлен"
}

service_stop(){
    # Internal stop for Download Master shutdown / USB unmount / reboot.
    # Unlike public `gc stop`, this MUST NOT create state/manual-stop,
    # otherwise the next boot would intentionally skip autostart.
    ensure_dirs || return 1
    load_platform || true
    control_lock_set || { warn "service-stop: другая операция ещё выполняется"; return 1; }
    watchdog_stop
    stop_runtime
    control_lock_clear
    return 0
}
restart(){
    ensure_dirs || return 1
    load_platform || return 1
    refresh_path

    check_config || return 1
    rm -f "$MANUAL_STOP"
    control_lock_set || { fail "Другая операция GoshaCrash ещё выполняется"; return 1; }
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

    control_lock_clear
    watchdog_start

    [ "$rc" -eq 0 ] && return 0

    warn "Конфиг синтаксически корректен, но runtime не поднялся; config.yaml не откатываю автоматически"
    warn "Проверь $MIHOMO_LOG и $WATCHDOG_LOG: причина может быть в TUN/uplink/маршрутизации, а не в конфиге"
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

    if [ -f "$MANUAL_STOP" ]; then
        printf '[%s] boot: manual-stop present; autostart skipped\n' "$(now)"
        return 0
    fi

    if ! boot_lock_acquire; then
        printf '[%s] boot: another valid boot worker is already running; duplicate hook ignored\n' "$(now)"
        return 0
    fi
    printf '%s\n' "$$" > "$BOOT_PIDFILE" 2>/dev/null || true
    trap 'boot_lock_release; exit 0' HUP INT TERM

    printf '[%s] boot: entered pid=%s profile=%s device=%s mount=%s name=%s fs=%s boot-token=%s\n' "$(now)" "$$" "${PLATFORM:-unknown}" "${USB_DEVICE:-unknown}" "$USB_MOUNT" "$USB_NAME" "${USB_FS:-unknown}" "$(current_boot_token 2>/dev/null)"
    cleanup_stale_runtime_state

    # Keep the recovery worker alive from the beginning of a cold boot.  It
    # deliberately skips checks while BOOT_LOCK belongs to this boot worker,
    # then takes over on the next interval if the primary start path fails.
    watchdog_start || printf '[%s] boot: watchdog could not start yet; will retry later\n' "$(now)"

    repair_opt >/dev/null 2>&1 || {
        log_event ERROR boot "Optware namespace not ready"
        printf '[%s] boot: Optware namespace not ready; watchdog fallback requested\n' "$(now)"
        watchdog_start || true
        boot_lock_release
        trap - HUP INT TERM
        return 0
    }
    refresh_path
    printf '[%s] boot: Optware namespace ready\n' "$(now)"

    waited=0
    while ! main_default_route; do
        [ "$waited" -ge "$BOOT_WAIT" ] && break
        sleep 5
        waited=$((waited + 5))
    done
    if main_default_route; then
        printf '[%s] boot: default route ready after %ss\n' "$(now)" "$waited"
    else
        printf '[%s] boot: default route still missing after %ss\n' "$(now)" "$waited"
    fi

    if [ "${LEGACY:-1}" = 0 ]; then
        if ensure_tun; then
            printf '[%s] boot: /dev/net/tun ready\n' "$(now)"
        else
            log_event WARN boot "TUN device is not ready yet"
            printf '[%s] boot: TUN device not ready yet\n' "$(now)"
        fi
        if wait_modern_uplink "$BOOT_WAIT"; then
            printf '[%s] boot: modern physical uplink stable\n' "$(now)"
        else
            log_event WARN boot "modern uplink did not become stable within ${BOOT_WAIT}s"
            printf '[%s] boot: modern uplink not stable within %ss\n' "$(now)" "$BOOT_WAIT"
        fi
    fi

    # Cold boot already waited for the physical uplink above. Do not call the
    # public start() here: start() performs another independent WAN probe and a
    # single transient miss could mark the fresh boot offline after the first
    # probe had just succeeded. Probe once, then start the runtime directly.
    if internet_probe_once; then
        wan_mark_online
        printf '[%s] boot: Internet probe OK; starting runtime directly\n' "$(now)"
        with_start_lock start_runtime
        rc=$?
    elif wan_nvram_up; then
        rm -f "$WAN_OFFLINE" 2>/dev/null || true
        counter_set "$WAN_FAIL_COUNT" 0
        counter_set "$WAN_OK_COUNT" 0
        set_wan_state checking
        printf '[%s] boot: ASUS WAN reports UP; starting runtime directly\n' "$(now)"
        with_start_lock start_runtime
        rc=$?
    else
        wan_mark_offline
        stop_runtime
        rc=0
        printf '[%s] boot: WAN unavailable; runtime kept DIRECT and watchdog enabled\n' "$(now)"
    fi

    if [ "$rc" -eq 0 ] && running_pid >/dev/null 2>&1; then
        printf '[%s] boot: runtime is UP\n' "$(now)"
    elif [ "$rc" -ne 0 ]; then
        printf '[%s] boot: runtime start returned rc=%s; watchdog will retry after boot lock release\n' "$(now)" "$rc"
    fi

    boot_lock_release
    trap - HUP INT TERM
    watchdog_start || true

    # Give the already-running watchdog one immediate recovery opportunity
    # instead of waiting for the next 10 second interval. This is safe only
    # after BOOT_LOCK has been released.
    if [ "$rc" -ne 0 ] || ! running_pid >/dev/null 2>&1; then
        watchdog_check || true
    fi
    return "$rc"
}
firewall_reload(){
    load_platform || return 0
    [ -f "$WAN_OFFLINE" ] && return 0
    running_pid >/dev/null 2>&1 || return 0
    if [ "$ROUTING_MODE" = manual ]; then route_start || return 1; else restart; fi
}

find_editor(){
    # Nano can run directly from persistent USB with the Optware ABI overlay.
    # Do not require or mutate the global /opt bind merely to edit config.yaml.
    find_dm_root >/dev/null 2>&1 || true
    ensure_optware_link >/dev/null 2>&1 || true
    repair_optware_abi_runtime >/dev/null 2>&1 || true
    refresh_path

    for e in "$DM_ROOT/bin/nano" /tmp/opt/bin/nano /opt/bin/nano; do
        test -x "$e" || continue
        run_optware_runtime "$e" --version >/dev/null 2>&1 || continue
        printf '%s\n' "$e"
        return 0
    done
    return 1
}

editor_utf8_locale(){
    printf '%s\n' 'en_US.UTF-8'
}

run_editor_utf8(){
    editor="$1"
    shift
    ldpath="$(optware_env_runtime)" || return 1
    editor_term="${GOSHACRASH_EDITOR_TERM:-${TERM:-xterm-256color}}"
    (
        LANG=en_US.UTF-8
        LC_ALL=en_US.UTF-8
        TERM="$editor_term"
        LD_LIBRARY_PATH="$ldpath"
        export LANG LC_ALL TERM LD_LIBRARY_PATH
        exec "$editor" "$@"
    )
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

    # Только временная копия для отката невалидной правки. Она живёт в /tmp
    # и удаляется сразу после проверки; постоянные backup-файлы не создаются.
    original="/tmp/goshacrash-config-edit.$$"
    rm -f "$original" 2>/dev/null || true
    cp -f "$CONFIG" "$original" || {
        fail "Не удалось подготовить временную копию config.yaml"
        return 1
    }

    run_editor_utf8 "$editor" "$CONFIG" || {
        cp -f "$original" "$CONFIG" 2>/dev/null || true
        rm -f "$original" 2>/dev/null || true
        warn "Редактор завершился с ошибкой; исходный config.yaml восстановлен"
        return 1
    }

    say "Проверяю config.yaml встроенной проверкой Mihomo (-t)..."
    if ! check_config; then
        cp -f "$original" "$CONFIG" || {
            rm -f "$original" 2>/dev/null || true
            fail "Конфиг некорректен, и не удалось восстановить предыдущую версию"
            return 1
        }
        rm -f "$original" 2>/dev/null || true
        fail "Проверка не пройдена; предыдущий config.yaml восстановлен. Неудачная правка не сохранялась."
        return 1
    fi

    rm -f "$original" 2>/dev/null || true
    mkdir -p "$STATE" 2>/dev/null || true
    printf '%s\n' user > "$STATE/config-origin" 2>/dev/null || true
    ok "Синтаксис config.yaml: OK"
    say "Конфиг сохранён. Mihomo НЕ перезапускался — для применения выбери Restart."
    return 0
}


yaml_set_section_key(){
    file="$1"; section="$2"; key="$3"; value="$4"; tmp="$file.gc.$$"
    LC_ALL=C awk -v section="$section" -v key="$key" -v value="$value" '
      BEGIN {inside=0; found=0; section_seen=0}
      $0 ~ "^" section ":[[:space:]]*($|#)" {
        inside=1
        found=0
        section_seen=1
        print
        next
      }
      inside && /^[^[:space:]]/ {
        if (!found) print "  " key ": " value
        inside=0
      }
      inside && $0 ~ "^[[:space:]]+" key ":[[:space:]]*" {
        indent=$0
        sub(/[^[:space:]].*$/, "", indent)
        print indent key ": " value
        found=1
        next
      }
      {print}
      END {
        if (inside && !found) {
          print "  " key ": " value
        } else if (!section_seen) {
          if (NR > 0) print ""
          print section ":"
          print "  " key ": " value
        }
      }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$file"
}

yaml_set_top_key(){
    file="$1"; key="$2"; value="$3"; tmp="$file.gc.$$"
    LC_ALL=C awk -v key="$key" -v value="$value" 'BEGIN{done=0} $0 ~ "^" key ":[[:space:]]*" {if(!done){print key ": " value; done=1}; next} {print} END{if(!done) print key ": " value}' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$file"
}

yaml_remove_top_key(){
    file="$1"; key="$2"; tmp="$file.gc.$$"
    LC_ALL=C awk -v key="$key" '$0 !~ "^" key ":[[:space:]]*" {print}' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$file"
}

platform_set(){
    key="$1"; value="$2"; tmp="$PLATFORM_FILE.gc.$$"
    LC_ALL=C awk -v key="$key" -v value="$value" '
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

    # Keep the controller-owned runtime fields coherent while changing only
    # the routing mode. Missing block sections are created if necessary.
    yaml_set_section_key "$CONFIG" tun enable true || return 1
    yaml_set_section_key "$CONFIG" tun device "$TUN_DEVICE" || return 1
    yaml_set_section_key "$CONFIG" dns enable true || return 1
    yaml_set_section_key "$CONFIG" dns listen "127.0.0.1:$DNS_PORT" || return 1

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
    cfg_snapshot="/tmp/goshacrash-routing-config.$$"
    state_snapshot="/tmp/goshacrash-routing-platform.$$"
    rm -f "$cfg_snapshot" "$state_snapshot" 2>/dev/null || true
    cp -f "$CONFIG" "$cfg_snapshot" || return 1
    cp -f "$PLATFORM_FILE" "$state_snapshot" || { rm -f "$cfg_snapshot"; return 1; }

    watchdog_stop
    stop_runtime
    if ! rewrite_config_for_routing "$mode"; then
        cp -f "$cfg_snapshot" "$CONFIG" 2>/dev/null || true
        rm -f "$cfg_snapshot" "$state_snapshot" 2>/dev/null || true
        return 1
    fi
    stack="system"; [ "$MIHOMO_TARGET" = armv5 ] && stack="gvisor"
    if ! platform_set ROUTING_MODE "$mode" || ! platform_set TUN_STACK "$stack" || ! load_platform; then
        cp -f "$cfg_snapshot" "$CONFIG" 2>/dev/null || true
        cp -f "$state_snapshot" "$PLATFORM_FILE" 2>/dev/null || true
        rm -f "$cfg_snapshot" "$state_snapshot" 2>/dev/null || true
        load_platform >/dev/null 2>&1 || true
        return 1
    fi

    if check_config && with_start_lock start_runtime; then
        rm -f "$MANUAL_STOP"
        watchdog_start
        rm -f "$cfg_snapshot" "$state_snapshot" 2>/dev/null || true
        ok "Маршрутизация переключена на $mode"
        return 0
    fi

    warn "Новый режим не запустился; возвращаю предыдущую конфигурацию"
    stop_runtime >/dev/null 2>&1 || true
    cp -f "$cfg_snapshot" "$CONFIG" 2>/dev/null || true
    cp -f "$state_snapshot" "$PLATFORM_FILE" 2>/dev/null || true
    rm -f "$cfg_snapshot" "$state_snapshot" 2>/dev/null || true
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

tcp_listener_exists(){
    port="$1"
    netstat -ln 2>/dev/null | grep -Eq "[:.]$port[[:space:]]" && return 0
    hex="$(printf '%04X' "$port" 2>/dev/null)"
    [ -n "$hex" ] || return 1
    for table in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$table" ] || continue
        awk -v p=":$hex" '$2 ~ p"$" && $4=="0A" {found=1} END {exit !found}' "$table" 2>/dev/null && return 0
    done
    return 1
}

runtime_usb_device(){
    mp="$(dirname "$BASE")"
    awk -v m="$mp" '$2==m {print $1; exit}' /proc/mounts 2>/dev/null
}

usb_kernel_fs_errors(){
    dev="$(runtime_usb_device 2>/dev/null)"
    [ -n "$dev" ] || return 1
    short="${dev##*/}"
    dmesg 2>/dev/null | grep -Eq "EXT[234]-fs error \(device $short\)|I/O error.*$short|Buffer I/O error.*$short"
}

usb_metadata_probe_runtime(){
    [ -n "$DM_ROOT" ] && [ -d "$DM_ROOT" ] || return 1
    for probe_dir in "$DM_ROOT" "$DM_ROOT/scripts" "$BASE/ui"; do
        [ -d "$probe_dir" ] || continue
        ls -la "$probe_dir" >/dev/null 2>&1 || return 1
    done
    return 0
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
    url="http://$ip:$port/ui/#/setup?hostname=$ip&port=$port"
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
    if [ "${LEGACY:-0}" = 1 ] && [ "${MIHOMO_TARGET:-}" = armv5 ]; then echo "Совместимость: legacy ARMv5 + gVisor"; fi
    echo "Режим маршрутизации: $ROUTING_MODE"
    echo "USB: ${USB_DEVICE:-?} -> $USB_MOUNT (name=$USB_NAME, fs=${USB_FS:-?})"
    echo "Конфиг: $CONFIG"
    net_link_exists "$TUN_DEVICE" && echo "TUN: $TUN_DEVICE работает" || echo "TUN: $TUN_DEVICE не найден"
    if runtime_health_ok; then echo "Runtime: OK (process + DNS + TUN + routing)"; elif [ -f "$WAN_OFFLINE" ]; then echo "Runtime: остановлен из-за отсутствия интернета"; else echo "Runtime: требует восстановления"; fi
    dash_url="$(dashboard_base_url)"
    dash_port="$(controller_port)"
    if ! running_pid >/dev/null 2>&1; then
        echo "Zashboard: недоступен (Mihomo не запущен); URL: $dash_url"
    elif [ ! -s "$BASE/ui/index.html" ]; then
        echo "Zashboard: UI-файлы отсутствуют; URL: $dash_url"
    elif tcp_listener_exists "$dash_port"; then
        echo "Zashboard: OK; URL: $dash_url"
    else
        echo "Zashboard: controller $dash_port не слушает; URL: $dash_url"
    fi
}

menu_find_stty(){
    MENU_STTY_BACKEND=""
    MENU_STTY_BIN=""

    stty_bin=""
    for p in /usr/bin/stty /bin/stty /usr/sbin/stty /sbin/stty /opt/bin/stty; do
        [ -x "$p" ] && { stty_bin="$p"; break; }
    done
    if [ -n "$stty_bin" ] && [ -x "$stty_bin" ]; then
        MENU_STTY_BACKEND="binary"
        MENU_STTY_BIN="$stty_bin"
        return 0
    fi

    busybox_bin=""
    for p in /bin/busybox /usr/bin/busybox /sbin/busybox /usr/sbin/busybox; do
        [ -x "$p" ] && { busybox_bin="$p"; break; }
    done
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

menu_read_byte_timeout(){
    # Arrow keys arrive as ESC [ A/B, while a standalone Esc should leave the
    # menu.  Temporarily use VMIN=0/VTIME=2 (0.2 s) only after ESC so we can
    # distinguish those cases without making normal navigation laggy.
    menu_stty -echo -icanon min 0 time 2 >/dev/null 2>&1 || return 1
    if [ "$MENU_TTY_MODE" = "devtty" ]; then
        _gc_byte="$(dd if=/dev/tty bs=1 count=1 2>/dev/null)"
    else
        _gc_byte="$(dd bs=1 count=1 2>/dev/null)"
    fi
    menu_stty -echo -icanon min 1 time 0 >/dev/null 2>&1 || true
    printf '%s' "$_gc_byte"
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

menu_print_state(){
    value="$1"
    width="$2"
    case "$value" in
        ONLINE|UP) printf '\033[1;32m%-*s\033[0m' "$width" "$value" ;;
        OFFLINE|DOWN) printf '\033[1;31m%-*s\033[0m' "$width" "$value" ;;
        *) printf '%-*s' "$width" "$value" ;;
    esac
}

menu_item_render(){
    current="$1"; number="$2"; label="$3"
    if [ "$current" -eq "$number" ]; then
        printf '│    \033[1;36m▶ %-34s\033[0m   │' "$label"
    else
        printf '│      %-34s   │' "$label"
    fi
}

menu_item(){
    menu_item_render "$1" "$2" "$3"
    printf '\n'
}

menu_item_label(){
    case "$1" in
        1) printf 'Status' ;;
        2) printf 'Edit config' ;;
        3) printf 'Restart' ;;
        4) printf 'Stop' ;;
        5) printf 'Logs' ;;
        6) printf 'Exit' ;;
        *) printf '' ;;
    esac
}

menu_repaint_item(){
    current="$1"
    number="$2"
    row=$((6 + number))
    label="$(menu_item_label "$number")"
    # Rewrite only one menu row.  This avoids clearing/redrawing the whole
    # terminal on every Up/Down key press (visible flicker over SSH).
    printf '\033[%s;1H' "$row"
    menu_item_render "$current" "$number" "$label"
}

menu_repaint_selection(){
    old_selected="$1"
    new_selected="$2"
    [ "$old_selected" -eq "$new_selected" ] && return 0
    menu_repaint_item "$new_selected" "$old_selected"
    menu_repaint_item "$new_selected" "$new_selected"
    # Keep the hidden cursor below the menu so terminals do not visibly jump.
    printf '\033[16;1H'
}

menu_draw(){
    selected="$1"
    # Every visible row is exactly 45 terminal columns wide. Keeping the same
    # width is important over SSH: otherwise the right border appears to jump.
    printf '\033[?25l\033[2J\033[H'
    printf '\033[1;36m'
    printf '┌───────────────────────────────────────────┐\n'
    printf '│             G O S H A C R A S H           │\n'
    printf '│            ROUTER CONTROLLER              │\n'
    printf '├───────────────────────────────────────────┤\n'
    printf '\033[0m'
    core_state="$(menu_state_core)"
    tun_state="$(menu_state_tun)"
    printf '│  MIHOMO: '
    menu_print_state "$core_state" 10
    printf '  TUN: '
    menu_print_state "$tun_state" 6
    printf '          │\n'
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
    printf '│  \033[2m↑/↓ Navigate   Enter Select   Esc Quit\033[0m   │\n'
    printf '\033[1;36m'
    printf '└───────────────────────────────────────────┘\n'
    printf '\033[0m'
}

menu_read_key(){
    k="$(menu_read_byte)"
    case "$k" in
        "$(printf '\033')")
            k2="$(menu_read_byte_timeout)"
            # Nothing followed ESC within the short terminal timeout: this was
            # a real Esc key press, not the prefix of an arrow sequence.
            [ -z "$k2" ] && { echo quit; return; }
            if [ "$k2" = "[" ]; then
                k3="$(menu_read_byte_timeout)"
                [ "$k3" = A ] && { echo up; return; }
                [ "$k3" = B ] && { echo down; return; }
            fi
            echo other
            ;;
        ''|"$(printf '\r')"|"$(printf '\n')") echo enter ;;
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
        3) return 0 ;;
        *) echo "Неверный выбор"; sleep 1 ;;
      esac
    done
}

menu_basic(){
    while :; do
        load_platform >/dev/null 2>&1 || true
        printf '\n=== GoshaCrash ===\n'
        printf 'MIHOMO: %s | TUN: %s | ROUTING: %s\n\n' \
            "$(menu_state_core)" "$(menu_state_tun)" "${ROUTING_MODE:-unknown}"
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
            6) return 0 ;;
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

    # Always restore the terminal and cursor, including Ctrl+C / lost SSH.
    trap 'menu_stty "$MENU_OLD_STTY" >/dev/null 2>&1; printf "\033[0m\033[?25h\n"' HUP INT TERM EXIT

    load_platform >/dev/null 2>&1 || true
    menu_draw "$selected"

    while :; do
        key="$(menu_read_key)"
        case "$key" in
            up)
                old_selected="$selected"
                selected=$((selected - 1))
                [ "$selected" -lt 1 ] && selected=$items_count
                menu_repaint_selection "$old_selected" "$selected"
                ;;
            down)
                old_selected="$selected"
                selected=$((selected + 1))
                [ "$selected" -gt "$items_count" ] && selected=1
                menu_repaint_selection "$old_selected" "$selected"
                ;;
            quit)
                break
                ;;
            enter)
                menu_stty "$MENU_OLD_STTY" >/dev/null 2>&1 || true
                # Actions/editors need a normal visible cursor.  A full screen
                # refresh here is intentional; arrow navigation never clears it.
                printf '\033[?25h\033[2J\033[H'
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
                menu_draw "$selected"
                ;;
        esac
    done

    menu_stty "$MENU_OLD_STTY" >/dev/null 2>&1 || true
    trap - HUP INT TERM EXIT
    printf '\033[0m\033[?25h\033[2J\033[H'
}

autostart_status(){
    ensure_dirs >/dev/null 2>&1 || true; load_platform >/dev/null 2>&1 || true
    echo "Autostart (stock ASUSWRT)"
    [ -x /jffs/scripts/usb-mount-script ] && echo "  usb-mount-script: OK" || echo "  usb-mount-script: FAIL"
    hook_version="$(sed -n 's/^# GoshaCrash USB hook //p' /jffs/scripts/usb-mount-script 2>/dev/null | /bin/busybox head -n 1)"
    [ -n "$hook_version" ] && echo "  USB hook version: $hook_version" || echo "  USB hook version: old/unknown"
    [ "$hook_version" = "$VERSION" ] && echo "  hook/controller: MATCH" || echo "  hook/controller: MISMATCH"
    [ -x "$DM_ROOT/etc/init.d/S50usb-mount-script" ] && echo "  ASUS app bridge: OK" || echo "  ASUS app bridge: FAIL"
    bridge_version="$(sed -n 's/^# GoshaCrash Download Master bridge //p' "$DM_ROOT/etc/init.d/S50usb-mount-script" 2>/dev/null | /bin/busybox head -n 1)"
    [ -n "$bridge_version" ] && echo "  bridge version: $bridge_version" || echo "  bridge version: old/unknown"
    [ -f "$STATE/autostart-hook-ran" ] && echo "  last hook: $(cat "$STATE/autostart-hook-ran" 2>/dev/null)" || echo "  last hook: never"
    [ -f "$LOGS/coldboot.log" ] && echo "  coldboot trace: $LOGS/coldboot.log" || echo "  coldboot trace: not written yet"
    [ -d /jffs/addons/goshacrash ] && echo "  legacy JFFS dir: PRESENT (remove/reinstall rc40-test2)" || echo "  legacy JFFS dir: clean"
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

packages_repair(){
    repair_opt || { fail "Не удалось восстановить /tmp/opt"; return 1; }
    repair_optware_abi_runtime || { fail "Не удалось построить Optware RAM overlay"; return 1; }

    echo "Optware overlay: $OPTWARE_OVERLAY_LIB"
    if test -n "$PKG" || find_pkg; then
        run_optware_runtime "$PKG" list_installed >/dev/null 2>&1 && echo "ipkg: OK" || echo "ipkg: BROKEN"
    else
        echo "ipkg: MISSING"
    fi

    if test -x "$DM_ROOT/bin/nano" && run_optware_runtime "$DM_ROOT/bin/nano" --version >/dev/null 2>&1; then
        echo "nano: OK"
    else
        echo "nano: BROKEN/MISSING"
    fi
    test -x "$DM_ROOT/libexec/sftp-server" && echo "sftp-server payload: OK" || echo "sftp-server payload: MISSING"
    return 0
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
    echo "  USB device: ${USB_DEVICE:-unknown}"
    echo "  USB disk: ${USB_DISK:-unknown}"
    echo "  USB mount: $USB_MOUNT"
    echo "  USB name: $USB_NAME"
    echo "  USB filesystem: ${USB_FS:-unknown}"
    echo "  Persistent Optware: ${DM_ROOT:-not-found}"
    if test -n "$DM_ROOT"; then
        test -f "$DM_ROOT/lib/libipkg.so.0" && echo "  libipkg.so.0: OK" || echo "  libipkg.so.0: MISSING"
        test -f "$DM_ROOT/lib/libc.so.0" && echo "  libc.so.0: OK" || echo "  libc.so.0: MISSING"
        test -f "$DM_ROOT/lib/ld-uClibc.so.0" && echo "  ld-uClibc.so.0: OK" || echo "  ld-uClibc.so.0: MISSING"
        test -f "$DM_ROOT/lib/libncurses.so.5" && echo "  libncurses.so.5: OK" || echo "  libncurses.so.5: MISSING"
    fi
    if test -n "$DM_ROOT"; then
        test -x "$DM_ROOT/bin/nano" && echo "  USB nano: OK" || echo "  USB nano: MISSING"
        if test -x "$DM_ROOT/bin/unzip" || test -x "$DM_ROOT/bin/unzip-unzip"; then
            echo "  USB unzip: OK"
        else
            echo "  USB unzip: MISSING"
        fi
        test -x "$DM_ROOT/libexec/sftp-server" && echo "  USB SFTP: OK" || echo "  USB SFTP: MISSING"
    fi
    if [ "${LEGACY:-0}" = 1 ]; then
        if /bin/busybox '[' -n "ok" ']' >/dev/null 2>&1; then
            echo "  legacy shell [: OK"
        else
            echo "  legacy shell [: FAIL"
        fi
    fi

    [ -x /bin/ping ] && echo "  firmware ping: /bin/ping" || echo "  firmware ping: NOT FOUND"
    internet_probe_once && echo "  Internet probe: OK" || echo "  Internet probe: FAIL"
    if wan_nvram_up; then
        echo "  ASUS WAN NVRAM: UP (informational)"
    else
        echo "  ASUS WAN NVRAM: DOWN (informational)"
    fi

    [ -f "$MANUAL_STOP" ] && echo "  manual stop: YES" || echo "  manual stop: no"
    echo "  nano UTF-8 locale: $(editor_utf8_locale)"
    if grep -Fq 'export LANG=en_US.UTF-8' /jffs/configs/profile.add 2>/dev/null \
       && grep -Fq 'export LC_ALL=en_US.UTF-8' /jffs/configs/profile.add 2>/dev/null; then
        echo "  shell UTF-8 locale profile.add: OK"
    else
        echo "  shell UTF-8 locale profile.add: MISSING"
    fi
    if grep -Fq 'export LANG=en_US.UTF-8' /jffs/etc/profile 2>/dev/null \
       && grep -Fq 'export LC_ALL=en_US.UTF-8' /jffs/etc/profile 2>/dev/null; then
        echo "  shell UTF-8 locale /jffs/etc/profile: OK (optional)"
    else
        echo "  shell UTF-8 locale /jffs/etc/profile: not present (optional)"
    fi
    config_utf8_valid
    utf8_rc=$?
    if [ "$utf8_rc" = 0 ]; then
        echo "  config UTF-8: OK"
    elif [ "$utf8_rc" = 1 ]; then
        echo "  config UTF-8: FAIL"
    else
        echo "  config UTF-8: UNKNOWN (od unavailable)"
    fi
    tun_kernel_ready && echo "  kernel TUN (/dev/net/tun): OK" || echo "  kernel TUN (/dev/net/tun): FAIL"
    if running_pid >/dev/null 2>&1; then
        echo "  Mihomo process: OK"
    else
        echo "  Mihomo process: DOWN"
    fi
    netstat -ln 2>/dev/null | grep -Eq "[:.]$DNS_PORT[[:space:]]" \
        && echo "  Mihomo DNS: OK" || echo "  Mihomo DNS: DOWN"
    if net_link_exists "$TUN_DEVICE"; then
        echo "  Mihomo TUN $TUN_DEVICE: UP"
        route_status >/dev/null 2>&1 && echo "  routing runtime: OK" || echo "  routing runtime: FAIL"
    else
        echo "  Mihomo TUN $TUN_DEVICE: DOWN"
        echo "  routing runtime: N/A (TUN down)"
    fi
    if watchdog_pid >/dev/null 2>&1; then
        echo "  watchdog: OK"
        if [ -s "$WATCHDOG_HEARTBEAT" ]; then
            echo "  watchdog heartbeat: $(cat "$WATCHDOG_HEARTBEAT" 2>/dev/null)"
        else
            echo "  watchdog heartbeat: not written yet"
        fi
    else
        echo "  watchdog: DOWN"
    fi

    find_dm_root >/dev/null 2>&1 && echo "  Download Master: $DM_ROOT" || echo "  Download Master: FAIL"
    ensure_optware_link >/dev/null 2>&1 && echo "  /tmp/opt: OK" || echo "  /tmp/opt: FAIL"
    if opt_namespace_write_through_runtime >/dev/null 2>&1; then
        echo "  /opt -> USB: OK"
    else
        echo "  /opt -> USB: FAIL"
    fi
    find_pkg >/dev/null 2>&1 && echo "  package manager: $PKG" || echo "  package manager: FAIL"

    editor="$(find_editor 2>/dev/null)"
    [ -n "$editor" ] && echo "  nano: $editor" || echo "  nano: NOT FOUND"
    if [ -s "$DM_ROOT/share/terminfo/x/xterm" ] && [ -s "$DM_ROOT/share/terminfo/x/xterm-256color" ]; then
        echo "  terminfo xterm/xterm-256color: OK"
    else
        echo "  terminfo xterm/xterm-256color: FAIL"
    fi

    [ -x /jffs/scripts/usb-mount-script ] && echo "  stock USB hook: OK" || echo "  stock USB hook: FAIL"
    [ -n "$DM_ROOT" ] && [ -x "$DM_ROOT/etc/init.d/S50usb-mount-script" ] \
        && echo "  ASUS app bridge: OK" || echo "  ASUS app bridge: FAIL"

    if usb_metadata_probe_runtime; then
        echo "  USB metadata probe: OK"
    else
        echo "  USB metadata probe: FAIL (offline fsck recommended)"
    fi
    if usb_kernel_fs_errors; then
        echo "  kernel filesystem log: ERRORS DETECTED"
    else
        echo "  kernel filesystem log: no current USB ext errors found"
    fi

    if [ -s "$BASE/ui/index.html" ]; then
        echo "  Zashboard files: OK"
    else
        echo "  Zashboard files: MISSING/BROKEN"
    fi
    dport="$(controller_port)"
    if running_pid >/dev/null 2>&1 && tcp_listener_exists "$dport"; then
        echo "  Zashboard controller $dport: LISTEN"
    elif running_pid >/dev/null 2>&1; then
        echo "  Zashboard controller $dport: NOT LISTENING"
    else
        echo "  Zashboard controller $dport: N/A (Mihomo down)"
    fi

    state="$(cat "$WAN_STATE" 2>/dev/null)"
    [ -n "$state" ] || state="unknown"
    echo "  Internet state: $state"
    return 0
}
usage(){
cat <<'USAGE'
GoshaCrash 3.10.2-rc40-test2 — что буквально вводить в SSH

КАТАЛОГ УСТАНОВКИ
  BASE="$(gc base)"
  echo "$BASE"

МЕНЮ
  gc

СТАТУС
  gc status

ПОЛНАЯ ДИАГНОСТИКА
  gc doctor

АВТОЗАПУСК / COLD BOOT
  gc autostart status
  BASE="$(gc base)"
  cat "$BASE/logs/coldboot.log"
  tail -n 100 "$BASE/logs/boot.log"
  tail -n 100 "$BASE/logs/watchdog.log"

ПРОВЕРИТЬ ТОЛЬКО INTERNET PROBE
  gc internet-probe

ПРОВЕРИТЬ SHELL [
  type '['
  /bin/busybox '[' -n "ok" ']'
  echo "BRACKET_RC=$?"

ПРОВЕРИТЬ СИСТЕМНЫЙ PING
  /bin/ping -c 2 -W 2 1.1.1.1
  echo "PING_RC=$?"

СБРОСИТЬ ЛОЖНЫЙ OFFLINE
  BASE="$(gc base)"
  rm -f "$BASE/state/wan-offline" "$BASE/state/wan-fail-count" "$BASE/state/wan-ok-count"
  echo online > "$BASE/state/internet.state"
  gc restart


ИЗМЕНИТЬ CONFIG
  gc edit

ОТКРЫТЬ CONFIG ВРУЧНУЮ
  BASE="$(gc base)"
  /jffs/scripts/nano "$BASE/config.yaml"

ПРОВЕРИТЬ CONFIG
  BASE="$(gc base)"
  "$BASE/bin/mihomo" -t -d "$BASE" -f "$BASE/config.yaml"

ЗАПУСТИТЬ VPN
  gc start

ПЕРЕЗАПУСТИТЬ VPN
  gc restart

ОСТАНОВИТЬ VPN
  gc stop

ВКЛЮЧИТЬ ПОСЛЕ gc stop
  gc start

ЛОГ MIHOMO
  gc logs

200 СТРОК MIHOMO
  gc logs mihomo 200

LIVE MIHOMO
  gc logs live mihomo 100

ЛОГ MIHOMO ВРУЧНУЮ
  BASE="$(gc base)"
  tail -n 100 "$BASE/logs/mihomo.log"

LIVE ВРУЧНУЮ
  BASE="$(gc base)"
  tail -f "$BASE/logs/mihomo.log"

ЛОГ УСТАНОВКИ
  BASE="$(gc base)"
  tail -n 200 "$BASE/logs/install.log"

ЛОГ ПАКЕТОВ
  BASE="$(gc base)"
  tail -n 200 "$BASE/logs/packages.log"

ПРОЦЕСС MIHOMO
  ps | grep '[m]ihomo'

PID MIHOMO
  BASE="$(gc base)"
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
  grep -n '^manual_route_start()' $BASE/goshacrash.sh


MANUAL ROUTING
  gc routing manual

AUTO ROUTING
  gc routing auto

RT-AC68U / LEGACY
  gc routing manual

WATCHDOG
  BASE="$(gc base)"
  cat "$BASE/run/watchdog.pid" 2>/dev/null
  PID="$(cat "$BASE/run/watchdog.pid" 2>/dev/null)"
  [ -n "$PID" ] && kill -0 "$PID" && echo "watchdog OK"

СОСТОЯНИЕ INTERNET WATCHDOG
  BASE="$(gc base)"
  cat "$BASE/state/internet.state" 2>/dev/null
  ls -l "$BASE/state/wan-offline" 2>/dev/null

АВТОЗАПУСК
  gc autostart status

HOOK AUTOSTART
  ls -l /jffs/scripts/usb-mount-script
  ls -l /tmp/opt/etc/init.d/S50usb-mount-script

СРАБОТАЛ ЛИ AUTOSTART ПОСЛЕ REBOOT
  BASE="$(gc base)"
  cat "$BASE/state/autostart-hook-ran" 2>/dev/null

ПРОВЕРИТЬ /opt ПОСЛЕ REBOOT
  ls -ld /opt /tmp/opt
  readlink /tmp/opt 2>/dev/null
  mount | grep -E '/opt|asusware|/tmp/mnt/'

NANO
  which nano
  ls -l /opt/bin/nano /tmp/opt/bin/nano 2>/dev/null

NANO ЧЕРЕЗ IPKG НА RT-AC68U
  IPKG=$DM_ROOT/bin/ipkg
  "$IPKG" list_installed | grep '^nano '
  "$IPKG" files nano

ПЕРЕУСТАНОВИТЬ NANO
  IPKG=$DM_ROOT/bin/ipkg
  "$IPKG" update
  "$IPKG" remove nano
  "$IPKG" install nano

UNZIP
  which unzip
  ls -l /opt/bin/unzip /opt/bin/unzip-unzip /tmp/opt/bin/unzip-unzip 2>/dev/null

UNZIP ЧЕРЕЗ IPKG НА RT-AC68U
  IPKG=$DM_ROOT/bin/ipkg
  "$IPKG" list_installed | grep '^unzip '
  "$IPKG" files unzip

ПЕРЕУСТАНОВИТЬ UNZIP
  IPKG=$DM_ROOT/bin/ipkg
  "$IPKG" update
  "$IPKG" remove unzip
  "$IPKG" install unzip

SFTP
  gc sftp status

SFTP ЧЕРЕЗ IPKG
  IPKG=$DM_ROOT/bin/ipkg
  "$IPKG" list | grep '^openssh-sftp-server '
  "$IPKG" list_installed | grep '^openssh-sftp-server '
  "$IPKG" files openssh-sftp-server

УСТАНОВИТЬ SFTP
  IPKG=$DM_ROOT/bin/ipkg
  "$IPKG" update
  "$IPKG" install openssh-sftp-server

SFTP С WINDOWS
  sftp admin@<IP_РОУТЕРА>

ZASHBOARD
  gc dashboard

CONTROLLER
  BASE="$(gc base)"
  grep '^external-controller:' "$BASE/config.yaml"

РУЧНОЙ RESTART ТОЛЬКО MIHOMO
  BASE="$(gc base)"
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
GC_COMMAND="${1:-menu}"
# Read-only metadata/help commands must not create runtime directories or touch logs.
case "$GC_COMMAND" in
    version) echo "$VERSION"; exit 0;;
    help|-h|--help) usage; exit 0;;
    base) printf '%s\n' "$BASE"; exit 0;;
esac

refresh_path >/dev/null 2>&1 || true
ensure_dirs >/dev/null 2>&1 || true
load_platform >/dev/null 2>&1 || true
refresh_path >/dev/null 2>&1 || true
case "$GC_COMMAND" in
    menu) menu;;
    start) start;;
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
    packages-repair)
        packages_repair
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
    *) echo "Неизвестная команда: $1" >&2; echo >&2; usage; exit 1;;
esac
