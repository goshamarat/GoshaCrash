#!/bin/sh
# GoshaCrash online installer for real ASUSWRT routers.
# One copied file installs the controller, a matching Mihomo core, Zashboard,
# package tools through ASUS Download Master, configuration and autostart.

INSTALLER_VERSION="3.7.11"
STOCK_USB_MOUNT_ZIP_URL="${STOCK_USB_MOUNT_ZIP_URL:-https://raw.githubusercontent.com/jacklul/asuswrt-scripts/master/asusware-usb-mount-script/asusware-usb-mount-script.zip}"
REPO="${REPO:-goshamarat/GoshaCrash}"
BRANCH="${BRANCH:-main}"

LEGACY_MIHOMO_VERSION="${LEGACY_MIHOMO_VERSION:-v1.19.28}"
LEGACY_MIHOMO_TAG="${LEGACY_MIHOMO_TAG:-mihomo-gvisor-armv5-$LEGACY_MIHOMO_VERSION}"
OFFICIAL_MIHOMO_FALLBACK="${OFFICIAL_MIHOMO_FALLBACK:-v1.19.29}"
ZASHBOARD_PRIMARY="${ZASHBOARD_URL:-https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip}"

TMP_ROOT="/tmp/goshacrash-install.$$"
TMP_LOG="/tmp/goshacrash-install.log"
INSTALL_LOG="$TMP_LOG"
USB_MOUNT=""
DM_ROOT=""
BASE=""
PKG=""
UNZIP_BIN=""
GZIP_BIN=""
DOWNLOADER=""
NVRAM_BIN=""
LOCK_DIR="/tmp/goshacrash-install.lock"
LOCK_HELD="0"

PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH

PLATFORM=""
LEGACY="0"
ROUTING_REQUEST="${GOSHACRASH_ROUTING:-${ROUTING_MODE:-}}"
ROUTING_MODE=""
TUN_STACK=""
MIHOMO_TARGET=""
MIHOMO_SOURCE=""
MIHOMO_VERSION_SELECTED=""
MIHOMO_URL_SELECTED=""
ACTIVE_CONFIG=""
GCNET_BIN=""

now(){ date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date; }
_emit(){ level="$1"; shift; line="[$(now)] [$level] [install] $*"; printf '%s\n' "$line"; printf '%s\n' "$line" >> "$INSTALL_LOG" 2>/dev/null || true; }
say(){ _emit INFO "$@"; }
ok(){ _emit OK "$@"; }
warn(){ _emit WARN "$@" >&2; }
fail(){ _emit ERROR "$@" >&2; return 1; }

cleanup(){
    rm -rf "$TMP_ROOT" 2>/dev/null || true
    [ "$LOCK_HELD" = 1 ] && rm -rf "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

acquire_lock(){
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
        LOCK_HELD="1"
        return 0
    fi

    oldpid="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
        fail "Установщик уже запущен, PID=$oldpid. Не запускай несколько установок одновременно"
        return 1
    fi

    rm -rf "$LOCK_DIR" 2>/dev/null || true
    mkdir "$LOCK_DIR" 2>/dev/null || { fail "Не удалось создать блокировку установщика"; return 1; }
    printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
    LOCK_HELD="1"
}


find_nvram(){
    [ -n "$NVRAM_BIN" ] && [ -x "$NVRAM_BIN" ] && return 0
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

verify_asuswrt(){
    [ -d /jffs ] || { fail "/jffs не найден: это не поддерживаемая ASUSWRT-среда"; return 1; }
    [ -d /tmp/mnt ] || { fail "/tmp/mnt не найден: USB-подсистема ASUSWRT не готова"; return 1; }
    [ -r /proc/version ] || { fail "/proc/version не найден: среда Linux не готова"; return 1; }
    find_nvram || warn "Утилита nvram не найдена; модель роутера будет определена по архитектуре и ядру"
}

tool_path(){
    if [ "$1" = "unzip" ]; then
        for p in /opt/bin/unzip /opt/bin/unzip-unzip; do
            [ -x "$p" ] && { echo "$p"; return 0; }
        done
        if [ -n "$DM_ROOT" ]; then
            for p in "$DM_ROOT/bin/unzip" "$DM_ROOT/bin/unzip-unzip"; do
                [ -x "$p" ] && { echo "$p"; return 0; }
            done
        fi
    fi

    name="$1"
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

# ASUSWRT ships a BusyBox unzip applet.  It can extract many archives, but it
# does not implement Info-ZIP's test mode (-t/-tqq), which older revisions of
# this installer used to validate Zashboard.  Prefer a real unzip from
# Download Master when available and install it automatically when needed.
unzip_is_full(){
    u="$1"
    [ -n "$u" ] && [ -x "$u" ] || return 1

    # Do not probe Info-ZIP by parsing `unzip -h`: old Optware builds have
    # different help text and were falsely rejected. BusyBox lives in the
    # firmware paths; Download Master candidates below are the full package.
    case "$u" in
        /usr/bin/unzip|/bin/unzip|/usr/sbin/unzip|/sbin/unzip)
            "$u" -h 2>&1 | grep -qi 'BusyBox' && return 1
            ;;
    esac
    return 0
}

find_full_unzip(){
    # Old ASUS Download Master / Optware commonly installs the actual Info-ZIP
    # executable as /opt/bin/unzip-unzip. The alternatives symlink
    # /opt/bin/unzip is not reliably created on stock ASUSWRT.
    for p in \
        /opt/bin/unzip-unzip /opt/bin/unzip \
        /tmp/opt/bin/unzip-unzip /tmp/opt/bin/unzip \
        "$DM_ROOT/bin/unzip-unzip" "$DM_ROOT/bin/unzip" \
        "$DM_ROOT/sbin/unzip"; do
        unzip_is_full "$p" && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

refresh_tools(){
    hash -r 2>/dev/null || true
    UNZIP_BIN="$(find_full_unzip 2>/dev/null)"
    [ -n "$UNZIP_BIN" ] || UNZIP_BIN="$(tool_path unzip 2>/dev/null)"
    GZIP_BIN="$(tool_path gzip 2>/dev/null)"
    if have wget; then DOWNLOADER="wget"; elif have curl; then DOWNLOADER="curl"; else DOWNLOADER=""; fi
}

find_download_master(){
    if [ -n "${INSTALL_ROOT:-}" ]; then
        USB_MOUNT="$INSTALL_ROOT"
        [ -d "$USB_MOUNT" ] || { fail "INSTALL_ROOT не существует: $USB_MOUNT"; return 1; }
        for d in "$USB_MOUNT/asusware.arm" "$USB_MOUNT/asusware.arm64" "$USB_MOUNT/asusware"; do
            [ -d "$d" ] && { DM_ROOT="$d"; return 0; }
        done
        fail "На $USB_MOUNT не найден Download Master (asusware.arm/asusware.arm64/asusware)"
        return 1
    fi

    count=0
    for mount in /tmp/mnt/*; do
        [ -d "$mount" ] || continue
        [ -w "$mount" ] || continue
        for d in "$mount/asusware.arm" "$mount/asusware.arm64" "$mount/asusware"; do
            [ -d "$d" ] || continue
            count=$((count + 1))
            USB_MOUNT="$mount"
            DM_ROOT="$d"
            break
        done
    done

    [ "$count" -eq 1 ] && return 0
    if [ "$count" -gt 1 ]; then
        fail "Найдено несколько флешек с Download Master. Укажи INSTALL_ROOT=/tmp/mnt/МЕТКА"
    else
        fail "Download Master не найден. Установи его через веб-интерфейс ASUS на USB-флешку"
    fi
    return 1
}

prepare_path(){
    PATH="$DM_ROOT/bin:$DM_ROOT/sbin:/opt/bin:/opt/sbin:/tmp/opt/bin:/tmp/opt/sbin:/jffs/scripts:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
    export PATH
    hash -r 2>/dev/null || true
}

find_pkg(){
    PKG=""
    # Prefer the manager belonging to the detected Download Master tree.
    for p in "$DM_ROOT/bin/opkg" "$DM_ROOT/bin/ipkg" /opt/bin/opkg /opt/bin/ipkg /tmp/opt/bin/opkg /tmp/opt/bin/ipkg; do
        [ -x "$p" ] && { PKG="$p"; break; }
    done
    [ -n "$PKG" ]
}

pkg_log(){
    mkdir -p "$BASE/logs" 2>/dev/null || true
    printf '[%s] %s\n' "$(now)" "$*" >> "$BASE/logs/packages.log" 2>/dev/null || true
}

pkg_update_index(){
    [ -n "$PKG" ] || return 1
    pkg_log "RUN: $PKG update"
    "$PKG" update >> "$BASE/logs/packages.log" 2>&1
}

pkg_install_one(){
    name="$1"
    [ -n "$PKG" ] || return 1
    pkg_log "RUN: $PKG install $name"
    "$PKG" install "$name" >> "$BASE/logs/packages.log" 2>&1
}

repair_unzip_package(){
    find_full_unzip >/dev/null 2>&1 && return 0

    # Some old Optware installations keep package metadata while the actual
    # alternatives target is missing. Force one clean reinstall in that case.
    if "$PKG" list_installed 2>/dev/null | grep -q '^unzip[[:space:]]*-'; then
        warn "Пакет unzip числится установленным, но бинарник не найден; переустанавливаю"
        "$PKG" remove unzip >> "$BASE/logs/packages.log" 2>&1 || true
        "$PKG" install unzip >> "$BASE/logs/packages.log" 2>&1 || return 1
        prepare_path
        normalize_legacy_optware_unzip
        refresh_tools
    fi

    find_full_unzip >/dev/null 2>&1
}

find_nano(){
    for p in \
        /opt/bin/nano \
        /tmp/opt/bin/nano \
        "$DM_ROOT/bin/nano" \
        "$DM_ROOT/sbin/nano"; do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    command -v nano 2>/dev/null || return 1
}

restart_download_master_env(){
    # Stock RT-AC68U keeps its main Download Master startup script in the
    # asusware root as S50downloadmaster.1. Older layouts may use etc/init.d.
    for script in \
        "$DM_ROOT/S50downloadmaster.1" \
        /tmp/opt/S50downloadmaster.1 \
        "$DM_ROOT/etc/init.d/S50downloadmaster" \
        "$DM_ROOT/etc/init.d/S50downloadmaster.1"; do
        [ -x "$script" ] || continue
        pkg_log "RUN: $script restart"
        "$script" restart >> "$BASE/logs/packages.log" 2>&1 || \
            "$script" start >> "$BASE/logs/packages.log" 2>&1 || true
        sleep 2
        prepare_path
        refresh_tools
        find_nano >/dev/null 2>&1 && return 0
    done
    return 1
}

repair_nano_package(){
    find_nano >/dev/null 2>&1 && return 0

    # First try to restore /opt / Download Master environment. This matters
    # after a clean USB install where ipkg may exist before all Optware links
    # are fully ready.
    restart_download_master_env >/dev/null 2>&1 || true
    find_nano >/dev/null 2>&1 && return 0

    # ipkg can keep package metadata even when the binary is missing.
    if "$PKG" list_installed 2>/dev/null | grep -q '^nano[[:space:]]*-'; then
        warn "Пакет nano числится установленным, но бинарник не найден; переустанавливаю"
        pkg_log "RUN: $PKG remove nano"
        "$PKG" remove nano >> "$BASE/logs/packages.log" 2>&1 || true
        pkg_log "RUN: $PKG install nano"
        "$PKG" install nano >> "$BASE/logs/packages.log" 2>&1 || return 1
        prepare_path
        refresh_tools
        restart_download_master_env >/dev/null 2>&1 || true
    fi

    find_nano >/dev/null 2>&1
}


find_sftp_server(){
    for p in \
        /opt/libexec/sftp-server \
        /opt/lib/openssh/sftp-server \
        "$DM_ROOT/libexec/sftp-server" \
        "$DM_ROOT/lib/openssh/sftp-server"
    do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

optware_sftp_package_line(){
    "$PKG_MGR" list 2>/dev/null | awk '$1=="openssh-sftp-server" {print; exit}'
}

install_optware_sftp(){
    [ -x "$PKG_MGR" ] || {
        fail "Optware ipkg не найден; SFTP установить нельзя"
        return 1
    }

    say "Обновляю список Optware для SFTP"
    "$PKG_MGR" update >> "$INSTALL_LOG" 2>&1 || \
        warn "ipkg update завершился с ошибкой; использую текущий package list"

    pkg_line="$(optware_sftp_package_line)"
    [ -n "$pkg_line" ] || {
        fail "В текущем Optware feed нет openssh-sftp-server"
        return 1
    }

    pkg_ver="$(printf '%s\n' "$pkg_line" | awk '{print $3}')"
    [ -n "$pkg_ver" ] || pkg_ver="unknown"
    say "Optware SFTP package: openssh-sftp-server $pkg_ver"

    if sftp_bin="$(find_sftp_server 2>/dev/null)"; then
        mkdir -p "$BASE/state" 2>/dev/null || true
        printf '%s\n' "$sftp_bin" > "$BASE/state/sftp-server.path" 2>/dev/null || true
        printf '%s\n' "$pkg_ver" > "$BASE/state/sftp-server.version" 2>/dev/null || true
        ok "SFTP server уже установлен: $sftp_bin ($pkg_ver)"
        return 0
    fi

    say "Устанавливаю openssh-sftp-server через Optware/ipkg"
    "$PKG_MGR" install openssh-sftp-server >> "$INSTALL_LOG" 2>&1 || {
        fail "Optware не смог установить openssh-sftp-server"
        return 1
    }

    manifest="$("$PKG_MGR" files openssh-sftp-server 2>/dev/null)"
    sftp_bin="$(printf '%s\n' "$manifest" | awk '/\/sftp-server$/ {print $1; exit}')"

    if [ -z "$sftp_bin" ] || [ ! -x "$sftp_bin" ]; then
        sftp_bin="$(find_sftp_server 2>/dev/null)"
    fi

    [ -n "$sftp_bin" ] && [ -x "$sftp_bin" ] || {
        fail "openssh-sftp-server установлен, но исполняемый sftp-server не найден"
        printf '%s\n' "$manifest" >> "$INSTALL_LOG"
        return 1
    }

    chmod 755 "$sftp_bin" 2>/dev/null || true
    mkdir -p "$BASE/state" 2>/dev/null || true
    printf '%s\n' "$sftp_bin" > "$BASE/state/sftp-server.path" 2>/dev/null || true
    printf '%s\n' "$pkg_ver" > "$BASE/state/sftp-server.version" 2>/dev/null || true

    ok "SFTP subsystem установлен через Optware: $sftp_bin ($pkg_ver)"
    return 0
}

install_stock_usb_mount_bridge(){
    case "${DM_ROOT##*/}" in
        asusware.arm) : ;;
        *)
            fail "Stock ASUSWRT autostart bridge ожидает asusware.arm, найдено: ${DM_ROOT##*/}"
            return 1
            ;;
    esac

    bridge_zip="$TMP_ROOT/stock-usb-mount-script.zip"
    bridge_dir="$TMP_ROOT/stock-usb-mount-script"
    rm -rf "$bridge_dir" "$bridge_zip" 2>/dev/null || true
    mkdir -p "$bridge_dir" || return 1

    say "Ставлю stock ASUSWRT USB-mount autostart bridge"
    fetch "$STOCK_USB_MOUNT_ZIP_URL" "$bridge_zip" || {
        fail "Не скачан stock ASUSWRT USB-mount bridge"
        return 1
    }
    "$UNZIP_BIN" -o "$bridge_zip" -d "$bridge_dir" >> "$INSTALL_LOG" 2>&1 || {
        fail "Не распакован stock ASUSWRT USB-mount bridge"
        return 1
    }

    bridge_src="$bridge_dir/asusware.arm"
    bridge_init="$bridge_src/etc/init.d/S50usb-mount-script"
    [ -f "$bridge_init" ] || { fail "В bridge нет S50usb-mount-script"; return 1; }

    mkdir -p "$DM_ROOT/etc/init.d" "$DM_ROOT/lib/ipkg/info" "$DM_ROOT/lib/ipkg/lists" || return 1
    cp -f "$bridge_init" "$DM_ROOT/etc/init.d/S50usb-mount-script" || return 1
    chmod 755 "$DM_ROOT/etc/init.d/S50usb-mount-script" || return 1

    if [ -f "$bridge_src/lib/ipkg/status" ]; then
        merge_ipkg_stanza "$bridge_src/lib/ipkg/status" "$DM_ROOT/lib/ipkg/status" "usb-mount-script" || return 1
    fi
    if [ -f "$bridge_src/lib/ipkg/info/usb-mount-script.control" ]; then
        cp -f "$bridge_src/lib/ipkg/info/usb-mount-script.control" \
              "$DM_ROOT/lib/ipkg/info/usb-mount-script.control" || return 1
    fi
    if [ -f "$bridge_src/lib/ipkg/lists/optware.asus" ]; then
        cp -f "$bridge_src/lib/ipkg/lists/optware.asus" \
              "$DM_ROOT/lib/ipkg/lists/goshacrash-usb-mount" 2>/dev/null || true
    fi
    [ -e "$DM_ROOT/.asusrouter" ] || : > "$DM_ROOT/.asusrouter"
    ok "Stock ASUSWRT USB-mount bridge установлен"
}

remove_old_autostart_hooks(){
    remove_legacy_hook_lines /jffs/scripts/services-start >/dev/null 2>&1 || true
    remove_legacy_hook_lines /jffs/scripts/firewall-start >/dev/null 2>&1 || true
    rm -f "$DM_ROOT/S99goshacrash.1" "$DM_ROOT/etc/init.d/S99goshacrash" 2>/dev/null || true

    if find_nvram >/dev/null 2>&1; then
        for key in script_usbmount script_usbumount; do
            old="$(nvram_get "$key")"
            tmp="$TMP_ROOT/remove-$key.$$"
            printf '%s\n' "$old" | awk '
              /# GOSHACRASH_USBMOUNT_BEGIN/ {skip=1; next}
              /# GOSHACRASH_USBMOUNT_END/ {skip=0; next}
              /# GOSHACRASH_USBUMOUNT_BEGIN/ {skip=1; next}
              /# GOSHACRASH_USBUMOUNT_END/ {skip=0; next}
              !skip {print}
            ' > "$tmp" 2>/dev/null || true
            cleaned="$(cat "$tmp" 2>/dev/null)"
            [ "$cleaned" = "$old" ] || nvram_set "$key" "$cleaned" >/dev/null 2>&1 || true
            rm -f "$tmp"
        done
        nvram_commit >/dev/null 2>&1 || true
    fi
}

install_hooks(){
    JFFS_DIR="/jffs/addons/goshacrash"
    mkdir -p "$JFFS_DIR" /jffs/scripts /jffs/configs "$DM_ROOT/bin" "$DM_ROOT/etc/init.d" || return 1
    printf '%s\n' "$BASE" > "$JFFS_DIR/base" || return 1

    cat > "$JFFS_DIR/start.sh" <<'HOOK'
#!/bin/sh
BASE_FILE=/jffs/addons/goshacrash/base
WAIT_MAX=300
WAITED=0
BASE="$(cat "$BASE_FILE" 2>/dev/null)"

while [ -z "$BASE" ] || [ ! -x "$BASE/goshacrash.sh" ]; do
  if [ "$WAITED" -ge "$WAIT_MAX" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) GoshaCrash: USB/base not ready after ${WAIT_MAX}s" >> /tmp/goshacrash-autostart.log
    exit 0
  fi
  sleep 5
  WAITED=$((WAITED + 5))
  BASE="$(cat "$BASE_FILE" 2>/dev/null)"
done

mkdir -p "$BASE/logs" "$BASE/run" "$BASE/state" 2>/dev/null || true
STAMP="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
[ -n "$STAMP" ] || STAMP="unknown-time"
printf '%s\n' "$STAMP" > "$BASE/state/autostart-hook-ran" 2>/dev/null || true
echo "$STAMP stock usb-mount start hook: BASE=$BASE waited=${WAITED}s" >> "$BASE/logs/boot.log"

if command -v nohup >/dev/null 2>&1; then
  GOSHACRASH_BASE="$BASE" nohup "$BASE/goshacrash.sh" boot </dev/null >> "$BASE/logs/boot.log" 2>&1 &
else
  GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" boot </dev/null >> "$BASE/logs/boot.log" 2>&1 &
fi
HOOK
    chmod 755 "$JFFS_DIR/start.sh" || return 1

    cat > /jffs/scripts/usb-mount-script <<'HOOK'
#!/bin/sh
DEVICE="$1"
MOUNT_POINT="$2"
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -n "$BASE" ] || exit 0
case "$BASE" in
  "$MOUNT_POINT"/*)
    logger -t goshacrash "USB mounted: $DEVICE -> $MOUNT_POINT"
    /jffs/addons/goshacrash/start.sh &
    ;;
esac
exit 0
HOOK
    chmod 755 /jffs/scripts/usb-mount-script || return 1

    cat > /jffs/scripts/usb-umount-script <<'HOOK'
#!/bin/sh
MOUNT_POINT="$2"
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
[ -n "$BASE" ] || exit 0
case "$BASE" in
  "$MOUNT_POINT"/*)
    if [ -x "$BASE/goshacrash.sh" ]; then
      GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" service-stop >/dev/null 2>&1 || true
    fi
    ;;
esac
exit 0
HOOK
    chmod 755 /jffs/scripts/usb-umount-script || return 1

    rm -f /jffs/scripts/goshacrash /opt/bin/goshacrash "$DM_ROOT/bin/goshacrash" \
          /jffs/scripts/crash /opt/bin/gc "$DM_ROOT/bin/crash" \
          /jffs/scripts/gc /opt/bin/gc "$DM_ROOT/bin/gc" 2>/dev/null || true
    write_command_wrapper /jffs/scripts/gc
    write_nano_wrapper /jffs/scripts/nano
    write_command_wrapper "$DM_ROOT/bin/gc"
    if [ -d /opt/bin ] && [ -w /opt/bin ]; then write_command_wrapper /opt/bin/gc 2>/dev/null || true; fi
    add_once /jffs/configs/profile.add 'export PATH="/jffs/scripts:/opt/bin:/opt/sbin:/tmp/opt/bin:/tmp/opt/sbin:$PATH"'

    remove_old_autostart_hooks
    install_stock_usb_mount_bridge || return 1
    ok "Автозапуск установлен через stock ASUSWRT USB-mount bridge"
}

write_platform_state(){
    cat > "$BASE/state/platform.env" <<EOF
PLATFORM='$PLATFORM'
LEGACY='$LEGACY'
ROUTING_MODE='$ROUTING_MODE'
TUN_STACK='$TUN_STACK'
MIHOMO_TARGET='$MIHOMO_TARGET'
MIHOMO_SOURCE='$MIHOMO_SOURCE'
MIHOMO_VERSION='$MIHOMO_VERSION_SELECTED'
MIHOMO_URL='$MIHOMO_URL_SELECTED'
GCNET_BIN='$GCNET_BIN'
CONFIG_FILE='$ACTIVE_CONFIG'
DM_ROOT='$DM_ROOT'
PKG_PATH='$PKG'
ROUTER_MODEL='$(nvram_get productid)'
ROUTER_ARCH='$(uname -m 2>/dev/null)'
ROUTER_KERNEL='$(uname -r 2>/dev/null)'
INSTALLED_BY='$INSTALLER_VERSION'
EOF
    chmod 600 "$BASE/state/platform.env" 2>/dev/null || true
}

save_install_log(){
    mkdir -p "$BASE/logs" 2>/dev/null || return 0
    if [ "$INSTALL_LOG" = "$TMP_LOG" ]; then
        cat "$TMP_LOG" >> "$BASE/logs/install.log" 2>/dev/null || true
        INSTALL_LOG="$BASE/logs/install.log"
    fi
}



normalize_legacy_optware_unzip() {
    # Old ASUS Download Master / Optware packages may install Info-ZIP as
    # /opt/bin/unzip-unzip and rely on an alternatives symlink that is absent
    # on some ASUSWRT builds. Create the compatibility symlink ourselves.
    if [ ! -x /opt/bin/unzip ] && [ -x /opt/bin/unzip-unzip ]; then
        ln -sf /opt/bin/unzip-unzip /opt/bin/unzip 2>/dev/null || true
    fi

    # Some installs expose /opt through the USB prefix only.
    if [ -n "$DM_ROOT" ] && [ -x "$DM_ROOT/bin/unzip-unzip" ] && [ ! -x "$DM_ROOT/bin/unzip" ]; then
        ln -sf "$DM_ROOT/bin/unzip-unzip" "$DM_ROOT/bin/unzip" 2>/dev/null || true
    fi
}


main(){
    : > "$TMP_LOG"
    [ "$#" -eq 0 ] || { fail "install.sh запускается без аргументов"; return 1; }
    acquire_lock || return 1

    verify_asuswrt || return 1
    find_download_master || return 1
    BASE="${INSTALL_DIR:-$USB_MOUNT/goshacrash}"
    mkdir -p "$TMP_ROOT" "$BASE/bin" "$BASE/ui" "$BASE/logs" "$BASE/run" "$BASE/state" "$BASE/backups" "$BASE/rulesets" "$BASE/proxies" || return 1
    save_install_log

    say "GoshaCrash installer $INSTALLER_VERSION"
    say "USB: $USB_MOUNT"
    say "Download Master: $DM_ROOT"
    say "Каталог установки: $BASE"

    # During a reinstall, keep the currently running process alive until every
    # downloaded component has passed validation. The final restart performs
    # the controlled switchover.

    detect_platform || return 1
    choose_routing_mode || return 1
    model_name="$(nvram_get productid)"; [ -n "$model_name" ] || model_name="$(hostname 2>/dev/null)"; [ -n "$model_name" ] || model_name="ASUSWRT"
    say "Роутер: $model_name, архитектура $(uname -m 2>/dev/null), ядро $(uname -r 2>/dev/null)"
    say "Профиль: $PLATFORM; routing=$ROUTING_MODE; tun.stack=$TUN_STACK"

    prepare_packages || return 1
    install_controller || return 1
    install_network_helper || return 1
    install_configs || return 1
    install_mihomo || return 1
    install_zashboard || return 1
    write_platform_state || return 1

    install_hooks || return 1
    GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" check || return 1
    GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" restart || {
        fail "Первый запуск не удался. Проверь $BASE/logs/mihomo.log и команду gc logs"
        return 1
    }

    save_install_log
    ok "Установка завершена"
    echo
    GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" status
    echo
    echo "Меню: gc    |    Справка: gc help"
    echo "Zashboard: $(GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" dashboard)"
    echo "Обновление Zashboard: кнопка в панели"
}

main "$@"
