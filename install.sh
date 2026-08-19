#!/bin/sh
# GoshaCrash online installer for real ASUSWRT routers.
# One copied file installs the controller, a matching Mihomo core, Zashboard,
# package tools through ASUS Download Master, configuration and autostart.

INSTALLER_VERSION="3.8.12"
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

# Old stock ASUSWRT can ship BusyBox applets without /bin/test and /bin/[ links.
# Bootstrap private wrappers before the installer executes its first condition.
GC_BOOTSTRAP_BIN="/tmp/goshacrash-bootstrap"
mkdir -p "$GC_BOOTSTRAP_BIN" 2>/dev/null
cat > "$GC_BOOTSTRAP_BIN/test" <<'GC_TEST'
#!/bin/sh
exec /bin/busybox test "$@"
GC_TEST
cat > "$GC_BOOTSTRAP_BIN/[" <<'GC_BRACKET'
#!/bin/sh
exec /bin/busybox '[' "$@"
GC_BRACKET
chmod 755 "$GC_BOOTSTRAP_BIN/test" "$GC_BOOTSTRAP_BIN/[" 2>/dev/null
PATH="$GC_BOOTSTRAP_BIN:$PATH"
export PATH
hash -r 2>/dev/null || true


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
    test "$LOCK_HELD" = 1 && rm -rf "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

acquire_lock(){
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
        LOCK_HELD="1"
        return 0
    fi

    oldpid="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
    if test -n "$oldpid" && kill -0 "$oldpid" 2>/dev/null; then
        fail "Установщик уже запущен, PID=$oldpid. Не запускай несколько установок одновременно"
        return 1
    fi

    rm -rf "$LOCK_DIR" 2>/dev/null || true
    mkdir "$LOCK_DIR" 2>/dev/null || { fail "Не удалось создать блокировку установщика"; return 1; }
    printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
    LOCK_HELD="1"
}


find_nvram(){
    test -n "$NVRAM_BIN" && test -x "$NVRAM_BIN" && return 0
    for p in /usr/sbin/nvram /sbin/nvram /usr/bin/nvram /bin/nvram; do
        test -x "$p" && { NVRAM_BIN="$p"; return 0; }
    done
    p="$(command -v nvram 2>/dev/null)"
    test -n "$p" && test -x "$p" && { NVRAM_BIN="$p"; return 0; }
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
    test -d /jffs || { fail "/jffs не найден: это не поддерживаемая ASUSWRT-среда"; return 1; }
    test -d /tmp/mnt || { fail "/tmp/mnt не найден: USB-подсистема ASUSWRT не готова"; return 1; }
    test -r /proc/version || { fail "/proc/version не найден: среда Linux не готова"; return 1; }
    find_nvram || warn "Утилита nvram не найдена; модель роутера будет определена по архитектуре и ядру"
}

tool_path(){
    if test "$1" = "unzip"; then
        for p in /opt/bin/unzip /opt/bin/unzip-unzip; do
            test -x "$p" && { echo "$p"; return 0; }
        done
        if test -n "$DM_ROOT"; then
            for p in "$DM_ROOT/bin/unzip" "$DM_ROOT/bin/unzip-unzip"; do
                test -x "$p" && { echo "$p"; return 0; }
            done
        fi
    fi

    name="$1"
    for p in \
        "/opt/bin/$name" "/opt/sbin/$name" \
        "/tmp/opt/bin/$name" "/tmp/opt/sbin/$name" \
        "$DM_ROOT/bin/$name" "$DM_ROOT/sbin/$name" \
        "/usr/sbin/$name" "/usr/bin/$name" "/sbin/$name" "/bin/$name"; do
        test -n "$p" && test -x "$p" && { printf '%s\n' "$p"; return 0; }
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
    test -n "$u" && test -x "$u" || return 1

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
    test -n "$UNZIP_BIN" || UNZIP_BIN="$(tool_path unzip 2>/dev/null)"
    GZIP_BIN="$(tool_path gzip 2>/dev/null)"
    if have wget; then DOWNLOADER="wget"; elif have curl; then DOWNLOADER="curl"; else DOWNLOADER=""; fi
}

find_download_master(){
    if test -n "${INSTALL_ROOT:-}"; then
        USB_MOUNT="$INSTALL_ROOT"
        test -d "$USB_MOUNT" || { fail "INSTALL_ROOT не существует: $USB_MOUNT"; return 1; }
        for d in "$USB_MOUNT/asusware.arm" "$USB_MOUNT/asusware.arm64" "$USB_MOUNT/asusware"; do
            test -d "$d" && { DM_ROOT="$d"; return 0; }
        done
        fail "На $USB_MOUNT не найден Download Master (asusware.arm/asusware.arm64/asusware)"
        return 1
    fi

    count=0
    for mount in /tmp/mnt/*; do
        test -d "$mount" || continue
        test -w "$mount" || continue
        for d in "$mount/asusware.arm" "$mount/asusware.arm64" "$mount/asusware"; do
            test -d "$d" || continue
            count=$((count + 1))
            USB_MOUNT="$mount"
            DM_ROOT="$d"
            break
        done
    done

    test "$count" -eq 1 && return 0
    if test "$count" -gt 1; then
        fail "Найдено несколько флешек с Download Master. Укажи INSTALL_ROOT=/tmp/mnt/МЕТКА"
    else
        fail "Download Master не найден. Установи его через веб-интерфейс ASUS на USB-флешку"
    fi
    return 1
}

ensure_optware_link(){
    test -n "$DM_ROOT" && test -d "$DM_ROOT" || return 1
    touch "$DM_ROOT/.asusrouter" 2>/dev/null || true

    if test -L /tmp/opt; then
        target="$(readlink /tmp/opt 2>/dev/null)"
        test "$target" = "$DM_ROOT" || ln -snf "$DM_ROOT" /tmp/opt 2>/dev/null || return 1
    elif test -d /tmp/opt; then
        if test ! -x /tmp/opt/bin/ipkg && test ! -x /tmp/opt/bin/opkg; then
            rmdir /tmp/opt 2>/dev/null && ln -s "$DM_ROOT" /tmp/opt 2>/dev/null || true
        fi
    elif test ! -e /tmp/opt; then
        ln -s "$DM_ROOT" /tmp/opt 2>/dev/null || return 1
    fi
    return 0
}

prepare_path(){
    ensure_optware_link >/dev/null 2>&1 || true

    # Keep installer bootstrap tools in PATH on old stock ASUSWRT.
    PATH="$GC_BOOTSTRAP_BIN:/jffs/scripts"
    test -n "$DM_ROOT" && PATH="$DM_ROOT/bin:$DM_ROOT/sbin:$PATH"
    PATH="/opt/bin:/opt/sbin:/tmp/opt/bin:/tmp/opt/sbin:$PATH"
    PATH="$PATH:/usr/sbin:/usr/bin:/sbin:/bin"
    export PATH
    hash -r 2>/dev/null || true
}

find_pkg(){
    PKG=""
    # Prefer the manager belonging to the detected Download Master tree.
    for p in "$DM_ROOT/bin/opkg" "$DM_ROOT/bin/ipkg" /opt/bin/opkg /opt/bin/ipkg /tmp/opt/bin/opkg /tmp/opt/bin/ipkg; do
        test -x "$p" && { PKG="$p"; break; }
    done
    test -n "$PKG"
}

pkg_log(){
    mkdir -p "$BASE/logs" 2>/dev/null || true
    printf '[%s] %s\n' "$(now)" "$*" >> "$BASE/logs/packages.log" 2>/dev/null || true
}

PKG_INDEX_REFRESHED=0

pkg_update_index_once(){
    test "$PKG_INDEX_REFRESHED" = "1" && return 0
    pkg_progress "обновляю индекс пакетов (один раз)"
    pkg_log "RUN: $PKG update"
    "$PKG" update >> "$BASE/logs/packages.log" 2>&1 || return 1
    PKG_INDEX_REFRESHED=1
    return 0
}

pkg_progress(){
    say "Optware: $*"
}

pkg_update_index(){
    pkg_update_index_once
}

pkg_install_one(){
    name="$1"
    test -n "$PKG" || return 1

    ensure_optware_link >/dev/null 2>&1 || true
    pkg_progress "install $name (локальный индекс)"
    pkg_log "RUN: $PKG install $name"

    "$PKG" install "$name" >> "$BASE/logs/packages.log" 2>&1 && return 0

    warn "install $name не удался с текущим индексом"
    pkg_update_index_once || true
    pkg_progress "повторный install $name"
    "$PKG" install "$name" >> "$BASE/logs/packages.log" 2>&1
}

pkg_is_installed(){
    "$PKG" list_installed 2>/dev/null | grep -q "^$1[[:space:]]*-"
}

pkg_reinstall_one(){
    name="$1"
    test -n "$PKG" || return 1

    pkg_progress "remove $name"
    pkg_log "REINSTALL: $name"
    "$PKG" remove "$name" >> "$BASE/logs/packages.log" 2>&1 || true

    ensure_optware_link >/dev/null 2>&1 || true
    pkg_progress "install $name (локальный индекс)"
    "$PKG" install "$name" >> "$BASE/logs/packages.log" 2>&1 && return 0

    warn "reinstall $name не удался с текущим индексом"
    pkg_update_index_once || true
    pkg_progress "повторный install $name"
    "$PKG" install "$name" >> "$BASE/logs/packages.log" 2>&1
}

repair_unzip_package(){
    ensure_optware_link >/dev/null 2>&1 || true
    normalize_legacy_optware_unzip
    find_full_unzip >/dev/null 2>&1 && return 0
    if pkg_is_installed unzip; then
        warn "unzip числится установленным, но бинарник не найден; переустанавливаю"
        pkg_reinstall_one unzip || return 1
    else
        pkg_install_one unzip || return 1
    fi
    prepare_path
    normalize_legacy_optware_unzip
    refresh_tools
    find_full_unzip >/dev/null 2>&1
}

find_nano(){
    for p in \
        /opt/bin/nano \
        /tmp/opt/bin/nano \
        "$DM_ROOT/bin/nano" \
        "$DM_ROOT/sbin/nano"; do
        test -x "$p" && { printf '%s\n' "$p"; return 0; }
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
        test -x "$script" || continue
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
    ensure_optware_link >/dev/null 2>&1 || true
    find_nano >/dev/null 2>&1 && return 0

    if pkg_is_installed nano; then
        warn "nano числится установленным, но бинарник на USB не найден; переустанавливаю"
        pkg_reinstall_one nano || return 1
    else
        pkg_install_one nano || return 1
    fi

    prepare_path
    find_nano >/dev/null 2>&1
}



find_sftp_server(){
    for p in \
        /opt/libexec/sftp-server \
        /tmp/opt/libexec/sftp-server \
        /opt/lib/openssh/sftp-server \
        /tmp/opt/lib/openssh/sftp-server \
        "$DM_ROOT/libexec/sftp-server" \
        "$DM_ROOT/lib/openssh/sftp-server"
    do
        test -x "$p" && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

optware_sftp_package_line(){
    test -n "$PKG" || return 1
    "$PKG" list 2>/dev/null | awk '$1=="openssh-sftp-server" {print; exit}'
}

persistent_opt_path(){
    rel="$1"
    printf '%s/%s\n' "$DM_ROOT" "$rel"
}

ensure_persistent_optware_link(){
    test -n "$DM_ROOT" && test -d "$DM_ROOT" || return 1

    # /opt -> /tmp/opt is firmware-owned. /tmp is volatile.
    # Only /tmp/opt is recreated; the package files remain under DM_ROOT on USB.
    if test -L /tmp/opt; then
        current="$(readlink /tmp/opt 2>/dev/null)"
        test "$current" = "$DM_ROOT" && return 0
        rm -f /tmp/opt || return 1
    elif test -e /tmp/opt; then
        # Never delete a real directory blindly. Move it aside for diagnostics.
        mv /tmp/opt "/tmp/opt.goshacrash.$$.stale" 2>/dev/null || return 1
    fi

    ln -s "$DM_ROOT" /tmp/opt || return 1
    test -d /opt || return 1
    return 0
}

persistent_payload_exists(){
    for rel in "$@"; do
        test -x "$DM_ROOT/$rel" && return 0
    done
    return 1
}

install_or_repair_persistent_package(){
    package="$1"
    shift

    ensure_persistent_optware_link || return 1

    # Fast path: the physical USB payload is authoritative. No ipkg network work.
    if persistent_payload_exists "$@"; then
        pkg_progress "$package уже есть на USB — пропускаю"
        return 0
    fi

    if pkg_is_installed "$package"; then
        warn "$package зарегистрирован, но payload на USB отсутствует; переустанавливаю"
        pkg_reinstall_one "$package" || return 1
    else
        pkg_install_one "$package" || return 1
    fi

    ensure_persistent_optware_link || return 1
    persistent_payload_exists "$@"
}

verify_persistent_optware(){
    ensure_persistent_optware_link || {
        fail "Не удалось связать /tmp/opt с USB Download Master: $DM_ROOT"
        return 1
    }

    install_or_repair_persistent_package nano bin/nano || {
        fail "nano не сохранён на USB: $DM_ROOT/bin/nano"
        return 1
    }

    if ! persistent_payload_exists bin/unzip bin/unzip-unzip; then
        install_or_repair_persistent_package unzip bin/unzip bin/unzip-unzip || {
            fail "unzip не сохранён на USB"
            return 1
        }
    fi

    # SFTP is optional for VPN, but when available it must also be persistent.
    if pkg_is_installed openssh-sftp-server || test -n "$(optware_sftp_package_line)"; then
        install_or_repair_persistent_package openssh-sftp-server libexec/sftp-server || {
            warn "SFTP не удалось сохранить на USB; VPN продолжит работать"
        }
    fi

    say "Persistent Optware root: $DM_ROOT"
    test -x "$DM_ROOT/bin/nano" && say "USB payload: nano OK"
    if test -x "$DM_ROOT/bin/unzip" || test -x "$DM_ROOT/bin/unzip-unzip"; then
        say "USB payload: unzip OK"
    fi
    test -x "$DM_ROOT/libexec/sftp-server" && say "USB payload: SFTP OK"
    return 0
}

install_optware_sftp(){
    test -n "$PKG" && test -x "$PKG" || return 0
    ensure_optware_link >/dev/null 2>&1 || true

    if sftp_bin="$(find_sftp_server 2>/dev/null)"; then
        say "SFTP binary: $sftp_bin"
        return 0
    fi

    pkg_line="$(optware_sftp_package_line)"
    if test -z "$pkg_line"; then
        warn "openssh-sftp-server отсутствует в локальном индексе Optware; пропускаю SFTP без ipkg update"
        return 0
    fi

    pkg_ver="$(printf '%s\n' "$pkg_line" | awk '{print $3}')"
    say "Optware SFTP: openssh-sftp-server ${pkg_ver:-unknown}"

    if pkg_is_installed openssh-sftp-server; then
        warn "openssh-sftp-server числится установленным, но payload отсутствует; переустанавливаю"
        pkg_reinstall_one openssh-sftp-server || {
            warn "SFTP не удалось восстановить; VPN продолжит работать"
            return 0
        }
    else
        pkg_install_one openssh-sftp-server || {
            warn "SFTP не установился; VPN продолжит работать"
            return 0
        }
    fi

    ensure_optware_link >/dev/null 2>&1 || true
    prepare_path
    sftp_bin="$(find_sftp_server 2>/dev/null)"

    if test -n "$sftp_bin"; then
        mkdir -p "$BASE/state" 2>/dev/null || true
        printf '%s\n' "$sftp_bin" > "$BASE/state/sftp-server.path" 2>/dev/null || true
        printf '%s\n' "${pkg_ver:-unknown}" > "$BASE/state/sftp-server.version" 2>/dev/null || true
        ok "SFTP binary установлен: $sftp_bin"
    else
        warn "openssh-sftp-server зарегистрирован, но payload всё ещё отсутствует"
    fi
    return 0
}

prepare_packages(){
    prepare_path
    find_pkg || { fail "В Download Master не найден ipkg/opkg"; return 1; }
    say "Менеджер пакетов ASUS: $PKG"

    ensure_optware_link >/dev/null 2>&1 || true
    refresh_tools
    normalize_legacy_optware_unzip

    if ! find_full_unzip >/dev/null 2>&1; then
        say "Готовлю Info-ZIP"
        say "Проверяю unzip на USB: $DM_ROOT/bin/unzip*"
        repair_unzip_package || { fail "Не удалось получить полноценный unzip"; return 1; }
    else
        say "Info-ZIP уже есть на USB — пропускаю"
    fi

    if ! find_nano >/dev/null 2>&1; then
        say "Готовлю nano"
        say "Проверяю nano на USB: $DM_ROOT/bin/nano"
        repair_nano_package || { fail "Не удалось получить nano"; return 1; }
    else
        say "nano уже есть на USB — пропускаю"
    fi

    refresh_tools

    if test ! -x "$GZIP_BIN"; then
        say "Устанавливаю gzip"
        pkg_install_one gzip || { fail "Не удалось установить gzip"; return 1; }
        refresh_tools
    fi

    if test -z "$DOWNLOADER"; then
        say "Устанавливаю wget"
        pkg_install_one wget || { fail "Не удалось установить wget/curl"; return 1; }
        refresh_tools
    fi

    UNZIP_BIN="$(find_full_unzip 2>/dev/null)"
    NANO_BIN="$(find_nano 2>/dev/null)"

    test -n "$UNZIP_BIN" || { fail "Полноценный unzip не найден"; return 1; }
    test -n "$NANO_BIN" || { fail "nano не найден"; return 1; }
    test -x "$GZIP_BIN" || { fail "gzip не найден"; return 1; }
    test -n "$DOWNLOADER" || { fail "wget/curl не найден"; return 1; }

    install_optware_sftp || true
    say "Инструменты: nano=$NANO_BIN, unzip=$UNZIP_BIN, gzip=$GZIP_BIN, downloader=$DOWNLOADER"
}

wget_fetch(){
    url="$1"; out="$2"
    w=""
    for p in /usr/sbin/wget /usr/bin/wget "$DM_ROOT/bin/wget" /opt/bin/wget /tmp/opt/bin/wget; do
        test -x "$p" && { w="$p"; break; }
    done
    test -n "$w" || return 1

    echo "--- wget: $url"
    "$w" --no-check-certificate -O "$out.part" "$url" && test -s "$out.part" && {
        mv -f "$out.part" "$out"
        return 0
    }
    return 1
}

curl_fetch(){
    url="$1"; out="$2"
    c=""
    for p in "$DM_ROOT/bin/curl" /opt/bin/curl /tmp/opt/bin/curl /usr/bin/curl; do
        test -x "$p" && { c="$p"; break; }
    done
    test -n "$c" || return 1

    echo "--- curl: $url"
    # No connect timeout and no overall max-time: the transfer may continue as
    # long as the connection is alive. The progress bar remains visible.
    "$c" -k -fL --retry 3 --retry-delay 3 -# \
        -A "GoshaCrash/$INSTALLER_VERSION" -o "$out.part" "$url" && test -s "$out.part" && {
        mv -f "$out.part" "$out"
        return 0
    }
    return 1
}

fetch(){
    url="$1"; out="$2"
    rm -f "$out" "$out.part"

    if test "$DOWNLOADER" = "wget"; then
        wget_fetch "$url" "$out" && return 0
        warn "wget не скачал файл; пробую curl"
        curl_fetch "$url" "$out" && return 0
    else
        curl_fetch "$url" "$out" && return 0
        warn "curl не скачал файл; пробую wget"
        wget_fetch "$url" "$out" && return 0
    fi

    rm -f "$out" "$out.part"
    return 1
}

fetch_repo_file(){
    rel="$1"; out="$2"
    for url in \
        "https://raw.githubusercontent.com/$REPO/refs/heads/$BRANCH/$rel" \
        "https://github.com/$REPO/raw/refs/heads/$BRANCH/$rel" \
        "https://testingcf.jsdelivr.net/gh/$REPO@$BRANCH/$rel" \
        "https://cdn.jsdelivr.net/gh/$REPO@$BRANCH/$rel"; do
        say "Скачиваю $rel"
        fetch "$url" "$out" && return 0
        warn "Источник недоступен: $url"
    done
    return 1
}


detect_platform(){
    machine="$(uname -m 2>/dev/null | tr 'A-Z' 'a-z')"
    kernel="$(uname -r 2>/dev/null)"
    model="$(nvram_get productid)"

    case "$machine:$kernel:$model" in
        armv7*:2.6.*:*|arm*:2.6.*:*|*:*:RT-AC68U*|*:*:RT-AC68P*|*:*:RT-AC1900*|*:*:RT-AC66U_B1*)
            PLATFORM="legacy-armv5-gvisor"
            LEGACY="1"
            MIHOMO_TARGET="armv5"
            MIHOMO_SOURCE="project-legacy-release"
            MIHOMO_VERSION_SELECTED="$LEGACY_MIHOMO_VERSION"
            ACTIVE_CONFIG="$BASE/config.yaml"
            return 0
            ;;
    esac

    LEGACY="0"
    MIHOMO_SOURCE="official-latest"
    ACTIVE_CONFIG="$BASE/config.yaml"

    case "${MIHOMO_ARCH:-$machine}" in
        aarch64|arm64) MIHOMO_TARGET="arm64" ;;
        armv7l|armv7|arm32v7) MIHOMO_TARGET="armv7" ;;
        armv6l|armv6|arm32v6) MIHOMO_TARGET="armv6" ;;
        armv5l|armv5|arm) MIHOMO_TARGET="armv5" ;;
        x86_64|amd64) MIHOMO_TARGET="amd64-compatible" ;;
        i386|i486|i586|i686|386) MIHOMO_TARGET="386" ;;
        mipsel|mipsle) MIHOMO_TARGET="mipsle-softfloat" ;;
        mips) MIHOMO_TARGET="mips-softfloat" ;;
        mips64el|mips64le) MIHOMO_TARGET="mips64le" ;;
        mips64) MIHOMO_TARGET="mips64" ;;
        riscv64) MIHOMO_TARGET="riscv64" ;;
        ppc64le) MIHOMO_TARGET="ppc64le" ;;
        s390x) MIHOMO_TARGET="s390x" ;;
        *) fail "Неподдерживаемая архитектура: $machine"; return 1 ;;
    esac
    if test "$MIHOMO_TARGET" = armv5; then
        MIHOMO_SOURCE="project-legacy-release"
        MIHOMO_VERSION_SELECTED="$LEGACY_MIHOMO_VERSION"
        ACTIVE_CONFIG="$BASE/config.yaml"
    fi
    PLATFORM="modern-$MIHOMO_TARGET"
}

existing_routing_mode(){
    f="$BASE/state/platform.env"
    test -f "$f" || return 1
    mode="$( ( . "$f" 2>/dev/null; printf '%s\n' "${ROUTING_MODE:-}" ) 2>/dev/null )"
    case "$mode" in manual|auto) printf '%s\n' "$mode"; return 0;; esac
    return 1
}

choose_routing_mode(){
    # ARMv5 is intentionally manual-only: this includes the RT-AC68U legacy build.
    if test "$MIHOMO_TARGET" = armv5; then
        if test "$ROUTING_REQUEST" = auto; then
            fail "Автоматическая маршрутизация для ARMv5 отключена. Используй manual"
            return 1
        fi
        ROUTING_MODE="manual"
        TUN_STACK="gvisor"
        say "Маршрутизация: manual (ARMv5: auto-route запрещён)"
        return 0
    fi

    case "$ROUTING_REQUEST" in
        manual|auto) ROUTING_MODE="$ROUTING_REQUEST" ;;
        '')
            old="$(existing_routing_mode 2>/dev/null)"
            if test -n "$old"; then
                ROUTING_MODE="$old"
                say "Сохраняю ранее выбранную маршрутизацию: $ROUTING_MODE"
            elif test -t 0 && test -t 1; then
                echo
                echo "Выбери маршрутизацию:"
                echo "  1) automatic — маршруты создаёт Mihomo (auto-route + auto-redirect)"
                echo "  2) manual    — GoshaCrash создаёт ip rule / route / iptables"
                printf "Выбор [1]: "
                IFS= read -r choice
                case "$choice" in 2|manual|MANUAL) ROUTING_MODE="manual";; *) ROUTING_MODE="auto";; esac
            else
                ROUTING_MODE="auto"
                say "Неинтерактивная установка: выбрана automatic маршрутизация"
            fi
            ;;
        *) fail "Неизвестный GOSHACRASH_ROUTING=$ROUTING_REQUEST (manual|auto)"; return 1 ;;
    esac

    case "$ROUTING_MODE" in
        manual) TUN_STACK="system" ;;
        auto) TUN_STACK="system" ;;
    esac
    say "Маршрутизация выбрана: $ROUTING_MODE"
}

install_controller(){
    tmp="$TMP_ROOT/goshacrash.sh"
    fetch_repo_file goshacrash.sh "$tmp" || { fail "Не удалось скачать goshacrash.sh"; return 1; }
    test "$(sed -n '1p' "$tmp" 2>/dev/null)" = '#!/bin/sh' || { fail "goshacrash.sh скачан неверно"; return 1; }
    sh -n "$tmp" || { fail "Синтаксическая ошибка в goshacrash.sh"; return 1; }
    test -f "$BASE/goshacrash.sh" && cp -f "$BASE/goshacrash.sh" "$BASE/backups/goshacrash.sh.previous" 2>/dev/null || true
    mv -f "$tmp" "$BASE/goshacrash.sh" || return 1
    chmod 755 "$BASE/goshacrash.sh" || return 1
}

install_network_helper(){
    if test "$MIHOMO_TARGET" != armv5; then
        GCNET_BIN=""
        return 0
    fi
    tmp="$TMP_ROOT/gcnet-armv5"
    fetch_repo_file assets/gcnet-armv5 "$tmp" || { fail "Не удалось скачать legacy network helper gcnet"; return 1; }
    test -s "$tmp" || { fail "gcnet скачан пустым"; return 1; }
    chmod 755 "$tmp" || return 1
    "$tmp" link-exists lo >/dev/null 2>&1 || { fail "gcnet не запускается на этом legacy-роутере"; return 1; }
    mv -f "$tmp" "$BASE/bin/gcnet" || return 1
    chmod 755 "$BASE/bin/gcnet" || return 1
    GCNET_BIN="$BASE/bin/gcnet"
    say "Установлен совместимый legacy network helper: $GCNET_BIN"
}

generate_dashboard_secret(){
    secret=""
    if test -r /dev/urandom; then
        if command -v od >/dev/null 2>&1; then
            secret="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
        elif command -v hexdump >/dev/null 2>&1; then
            secret="$(hexdump -n 16 -e '16/1 "%02x"' /dev/urandom 2>/dev/null)"
        fi
    fi
    test -n "$secret" || secret="GC$(date +%s 2>/dev/null)$$"
    printf '%s\n' "$secret"
}

replace_placeholder_secret(){
    file="$1"
    grep -q '^secret:[[:space:]]*["'"'"']CHANGE_ME["'"'"'][[:space:]]*$' "$file" 2>/dev/null || return 0
    secret="$(generate_dashboard_secret)"
    test -n "$secret" || return 1
    sed -i "s@^secret:.*@secret: \"$secret\"@" "$file" || return 1
    say "Для Zashboard создан уникальный локальный secret"
}

yaml_set_section_key(){
    file="$1"; section="$2"; key="$3"; value="$4"; tmp="$file.gc.$$"
    awk -v section="$section" -v key="$key" -v value="$value" '
      BEGIN {inside=0; found=0}
      $0 ~ "^" section ":[[:space:]]*($|#)" {inside=1; found=0; print; next}
      inside && /^[^[:space:]#]/ {
        if (!found) print "  " key ": " value
        inside=0
      }
      inside && $0 ~ "^[[:space:]]+" key ":[[:space:]]*" {
        indent=$0; sub(/[^[:space:]].*$/, "", indent)
        print indent key ": " value
        found=1
        next
      }
      {print}
      END {if (inside && !found) print "  " key ": " value}
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$file"
}

yaml_set_top_key(){
    file="$1"; key="$2"; value="$3"; tmp="$file.gc.$$"
    awk -v key="$key" -v value="$value" '
      BEGIN{done=0}
      $0 ~ "^" key ":[[:space:]]*" {if(!done){print key ": " value; done=1}; next}
      {print}
      END{if(!done) print key ": " value}
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$file"
}

yaml_remove_top_key(){
    file="$1"; key="$2"; tmp="$file.gc.$$"
    awk -v key="$key" '$0 !~ "^" key ":[[:space:]]*" {print}' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$file"
}

configure_routing_in_config(){
    file="$1"
    test -f "$file" || return 1
    if test "$ROUTING_MODE" = manual; then
        yaml_set_section_key "$file" tun stack "$TUN_STACK" || return 1
        yaml_set_section_key "$file" tun auto-route false || return 1
        yaml_set_section_key "$file" tun auto-redirect false || return 1
        yaml_set_section_key "$file" tun auto-detect-interface false || return 1
        yaml_set_top_key "$file" routing-mark 9012 || return 1
    else
        yaml_set_section_key "$file" tun stack "$TUN_STACK" || return 1
        yaml_set_section_key "$file" tun auto-route true || return 1
        yaml_set_section_key "$file" tun auto-redirect true || return 1
        yaml_set_section_key "$file" tun auto-detect-interface true || return 1
        yaml_remove_top_key "$file" routing-mark || return 1
    fi
}

generate_base_config(){
    file="$1"
    secret="$(generate_dashboard_secret)"
    test -n "$secret" || { fail "Не удалось создать secret для Zashboard"; return 1; }

    cat > "$file" <<EOF
# GoshaCrash base configuration.
# Сгенерирован install.sh под текущую архитектуру роутера.
# Это безопасная DIRECT-заглушка: VPN включится после добавления своих proxy/rules.

external-controller: 0.0.0.0:9090
secret: "$secret"
external-ui: ui
external-ui-url: "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip"

profile:
  store-selected: true
  store-fake-ip: true

mixed-port: 7892
allow-lan: true
bind-address: "*"
mode: rule
log-level: info
ipv6: false

dns:
  enable: true
  listen: 127.0.0.1:1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver:
    - 1.1.1.1
    - 8.8.8.8
  nameserver:
    - 1.1.1.1
    - 8.8.8.8

tun:
  enable: true
  stack: $TUN_STACK
  device: tun0
  dns-hijack:
    - any:53
    - tcp://any:53

rules:
  - MATCH,DIRECT
EOF

    configure_routing_in_config "$file" || return 1
    chmod 600 "$file" 2>/dev/null || true
    return 0
}

install_configs(){
    test -n "$ACTIVE_CONFIG" || ACTIVE_CONFIG="$BASE/config.yaml"

    # Migration from GoshaCrash <= 3.5.x: legacy installations used
    # config-legacy.yaml as the active file. Keep the user's configuration.
    if test ! -f "$ACTIVE_CONFIG" && test -f "$BASE/config-legacy.yaml"; then
        cp -f "$BASE/config-legacy.yaml" "$BASE/backups/config-legacy.yaml.before-3.6" 2>/dev/null || true
        cp -f "$BASE/config-legacy.yaml" "$ACTIVE_CONFIG" || return 1
        say "Legacy-конфиг перенесён в единый $ACTIVE_CONFIG"
    fi

    if test ! -f "$ACTIVE_CONFIG"; then
        generate_base_config "$ACTIVE_CONFIG" || { fail "Не удалось сгенерировать базовый config.yaml"; return 1; }
        say "Базовый config.yaml создан install.sh для $PLATFORM (routing=$ROUTING_MODE, tun.stack=$TUN_STACK)"
        warn "VPN ещё не настроен: добавь свои proxy/rules и выполни gc restart"
    else
        cp -f "$ACTIVE_CONFIG" "$BASE/backups/config.yaml.before-install" 2>/dev/null || true
        say "Существующий $ACTIVE_CONFIG сохранён; меняются только параметры выбранной маршрутизации"
        configure_routing_in_config "$ACTIVE_CONFIG" || { fail "Не удалось применить routing=$ROUTING_MODE к конфигу"; return 1; }
        chmod 600 "$ACTIVE_CONFIG" 2>/dev/null || true
    fi
}

json_asset_urls(){
    file="$1"
    grep '"browser_download_url"' "$file" 2>/dev/null |
        sed -n 's#.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*#\1#p' |
        tr -d '\r'
}

latest_official_mihomo_url(){
    api="$TMP_ROOT/mihomo-latest.json"
    if fetch "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" "$api"; then
        case "$MIHOMO_TARGET" in
            amd64-compatible) pattern='/mihomo-linux-amd64-compatible-v[^/]*\.gz$' ;;
            *) pattern="/mihomo-linux-$MIHOMO_TARGET-v[^/]*\\.gz$" ;;
        esac
        url="$(json_asset_urls "$api" | grep -E "$pattern" | head -n 1)"
        if test -n "$url"; then
            MIHOMO_VERSION_SELECTED="$(printf '%s\n' "$url" | sed -n 's#.*/download/\([^/]*\)/.*#\1#p')"
            printf '%s\n' "$url"
            return 0
        fi
    fi

    MIHOMO_VERSION_SELECTED="$OFFICIAL_MIHOMO_FALLBACK"
    printf '%s\n' "https://github.com/MetaCubeX/mihomo/releases/download/$OFFICIAL_MIHOMO_FALLBACK/mihomo-linux-$MIHOMO_TARGET-$OFFICIAL_MIHOMO_FALLBACK.gz"
}

legacy_mihomo_urls(){
    # The legacy build is pinned and stored in the project release. Avoid the
    # GitHub API here: direct asset URLs are faster and predictable on ASUSWRT.
    printf '%s\n' \
        "https://github.com/$REPO/releases/download/$LEGACY_MIHOMO_TAG/mihomo-linux-armv5-gvisor-$LEGACY_MIHOMO_VERSION.gz" \
        "https://github.com/$REPO/releases/download/$LEGACY_MIHOMO_TAG/mihomo-linux-armv5-with_gvisor.gz" \
        "https://github.com/$REPO/releases/download/$LEGACY_MIHOMO_TAG/mihomo-linux-armv5-with-gvisor.gz"
}


validate_downloaded_mihomo(){
    archive="$1"; newbin="$2"
    "$GZIP_BIN" -t "$archive" >/dev/null 2>&1 || { fail "Архив Mihomo повреждён"; return 1; }
    "$GZIP_BIN" -dc "$archive" > "$newbin" || { fail "Не удалось распаковать Mihomo"; return 1; }
    chmod 755 "$newbin" || return 1
    out="$("$newbin" -v 2>&1)" || { printf '%s\n' "$out" >&2; fail "Mihomo не запускается на этой архитектуре"; return 1; }
    printf '%s\n' "$out" | grep -qi 'mihomo' || { printf '%s\n' "$out" >&2; fail "Скачанный файл не похож на Mihomo"; return 1; }
    if test "$MIHOMO_TARGET" = armv5; then
        printf '%s\n' "$out" | grep -Fq 'Use tags: with_gvisor' || { printf '%s\n' "$out" >&2; fail "Legacy-профилю нужна сборка Mihomo with_gvisor"; return 1; }
    fi
    printf '%s\n' "$out" > "$BASE/state/mihomo-version.txt"
}

install_mihomo(){
    archive="$TMP_ROOT/mihomo.gz"
    newbin="$BASE/bin/mihomo.new"
    rm -f "$archive" "$newbin"

    if test "$MIHOMO_TARGET" = armv5 && test "${FORCE_CORE_REINSTALL:-0}" != 1 && test -x "$BASE/bin/mihomo"; then
        existing_out="$("$BASE/bin/mihomo" -v 2>&1)"
        if printf '%s\n' "$existing_out" | grep -qi 'mihomo' && \
           printf '%s\n' "$existing_out" | grep -Fq 'Use tags: with_gvisor'; then
            printf '%s\n' "$existing_out" > "$BASE/state/mihomo-version.txt"
            say "Совместимый legacy Mihomo уже установлен; повторная загрузка ядра пропущена"
            return 0
        fi
    fi

    if test "$MIHOMO_TARGET" = armv5; then
        success=0
        legacy_mihomo_urls | while IFS= read -r url; do
            test -n "$url" || continue
            printf '%s\n' "$url"
        done > "$TMP_ROOT/legacy-urls.txt"
        while IFS= read -r url; do
            test -n "$url" || continue
            say "Скачиваю проверенный legacy Mihomo: $url"
            if fetch "$url" "$archive" && validate_downloaded_mihomo "$archive" "$newbin"; then
                MIHOMO_URL_SELECTED="$url"
                success=1
                break
            fi
            rm -f "$archive" "$newbin"
        done < "$TMP_ROOT/legacy-urls.txt"
        test "$success" -eq 1 || { fail "Не удалось скачать совместимый ARMv5+gVisor Mihomo из Releases проекта"; return 1; }
    else
        MIHOMO_URL_SELECTED="$(latest_official_mihomo_url)" || return 1
        MIHOMO_VERSION_SELECTED="$(printf '%s\n' "$MIHOMO_URL_SELECTED" | sed -n 's#.*/download/\([^/]*\)/.*#\1#p')"
        test -n "$MIHOMO_VERSION_SELECTED" || MIHOMO_VERSION_SELECTED="$OFFICIAL_MIHOMO_FALLBACK"
        say "Скачиваю официальный Mihomo $MIHOMO_VERSION_SELECTED для $MIHOMO_TARGET"
        fetch "$MIHOMO_URL_SELECTED" "$archive" || { fail "Не удалось скачать $MIHOMO_URL_SELECTED"; return 1; }
        validate_downloaded_mihomo "$archive" "$newbin" || return 1
    fi

    test -f "$BASE/bin/mihomo" && cp -f "$BASE/bin/mihomo" "$BASE/backups/mihomo.previous" 2>/dev/null || true
    mv -f "$newbin" "$BASE/bin/mihomo" || return 1
    chmod 755 "$BASE/bin/mihomo" || return 1
}

find_ui_root(){
    unpack="$1"
    for p in "$unpack/index.html" "$unpack"/*/index.html "$unpack"/*/*/index.html; do
        test -f "$p" && { dirname "$p"; return 0; }
    done
    p="$(find "$unpack" -type f -name index.html 2>/dev/null | head -n 1)"
    test -n "$p" && { dirname "$p"; return 0; }
    return 1
}

unpack_ui(){
    archive="$1"; unpack="$2"; dst="$3"
    rm -rf "$unpack" "$dst"
    mkdir -p "$unpack" "$dst" || return 1

    # Validate by actually extracting.  Do not use `unzip -tqq`: ASUSWRT's
    # BusyBox unzip does not support -t and used to make every valid Zashboard
    # archive look broken on RT-AC68U-class routers.
    "$UNZIP_BIN" -oq "$archive" -d "$unpack" >> "$INSTALL_LOG" 2>&1 || return 1
    src="$(find_ui_root "$unpack")" || return 1
    test -s "$src/index.html" || return 1
    cp -R "$src"/. "$dst"/ || return 1
    test -s "$dst/index.html"
}

install_zashboard(){
    archive="$TMP_ROOT/zashboard.zip"
    unpack="$TMP_ROOT/zashboard-unpack"
    ui_new="$BASE/ui.new"
    selected=""
    last_url=""
    for url in \
        "$ZASHBOARD_PRIMARY" \
        "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip" \
        "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip" \
        "https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip"; do
        test -n "$url" || continue
        test "$url" = "$last_url" && continue
        last_url="$url"
        say "Скачиваю Zashboard: $url"
        if fetch "$url" "$archive" && unpack_ui "$archive" "$unpack" "$ui_new"; then
            selected="$url"
            break
        fi
        warn "Архив Zashboard не подошёл: $url"
        rm -rf "$unpack" "$ui_new" "$archive"
    done
    test -n "$selected" || { fail "Не удалось скачать и распаковать Zashboard"; return 1; }

    rm -rf "$BASE/ui.previous"
    test -d "$BASE/ui" && mv "$BASE/ui" "$BASE/ui.previous" 2>/dev/null || true
    mv "$ui_new" "$BASE/ui" || {
        test -d "$BASE/ui.previous" && mv "$BASE/ui.previous" "$BASE/ui" 2>/dev/null || true
        fail "Не удалось активировать Zashboard"
        return 1
    }
    printf '%s\n' "$selected" > "$BASE/state/zashboard-source.txt"
}


add_once(){
    file="$1"; line="$2"
    test -f "$file" || printf '#!/bin/sh\n' > "$file"
    grep -Fqx "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"
    chmod 755 "$file" 2>/dev/null || true
}

remove_legacy_hook_lines(){
    file="$1"
    test -f "$file" || return 0
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

write_command_wrapper(){
    dst="$1"
    cat > "$dst" <<'WRAP'
#!/bin/sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
test -n "$BASE" && test -x "$BASE/goshacrash.sh" || { echo "GoshaCrash не найден на USB" >&2; exit 1; }
GOSHACRASH_BASE="$BASE"
export GOSHACRASH_BASE
exec "$BASE/goshacrash.sh" "$@"
WRAP
    chmod 755 "$dst"
}

write_test_wrapper(){
    target="$1"
    mkdir -p "$(dirname "$target")" || return 1
    cat > "$target" <<'WRAP'
#!/bin/sh
exec /bin/busybox test "$@"
WRAP
    chmod 755 "$target" || return 1
}

write_bracket_wrapper(){
    target="$1"
    mkdir -p "$(dirname "$target")" || return 1
    cat > "$target" <<'WRAP'
#!/bin/sh
exec /bin/busybox '[' "$@"
WRAP
    chmod 755 "$target" || return 1
}

write_nano_wrapper(){
    dst="$1"
    cat > "$dst" <<'WRAP'
#!/bin/sh
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
DM_ROOT=""
test -f "$BASE/state/platform.env" && . "$BASE/state/platform.env"
for p in /opt/bin/nano /tmp/opt/bin/nano "$DM_ROOT/bin/nano" "$DM_ROOT/sbin/nano"; do
  test -x "$p" && exec "$p" "$@"
done
echo "nano не найден. Установи nano через пакетный менеджер Download Master" >&2
exit 1
WRAP
    chmod 755 "$dst"
}

rewrite_nvram_hook(){
    key="$1"; begin="$2"; end="$3"; body="$4"
    find_nvram || return 0
    tmp="$TMP_ROOT/nvram-hook.$$"
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
    find_nvram || { warn "nvram недоступен: stock USB hook пропущен; JFFS и Download Master hooks установлены"; return 0; }
    rewrite_nvram_hook script_usbmount '# GOSHACRASH_USBMOUNT_BEGIN' '# GOSHACRASH_USBMOUNT_END' \
      'BASE=$(cat /jffs/addons/goshacrash/base 2>/dev/null); test -x "$BASE/goshacrash.sh" && /jffs/addons/goshacrash/start.sh &' || warn "Не удалось записать USB-mount hook"
    rewrite_nvram_hook script_usbumount '# GOSHACRASH_USBUMOUNT_BEGIN' '# GOSHACRASH_USBUMOUNT_END' \
      'BASE=$(cat /jffs/addons/goshacrash/base 2>/dev/null); test -x "$BASE/goshacrash.sh" && GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" service-stop >/dev/null 2>&1' || warn "Не удалось записать USB-unmount hook"
    test "$(nvram_get jffs2_scripts)" = 1 || nvram_set jffs2_scripts 1 || true
    nvram_commit || true
    case "$(nvram_get script_usbmount)" in
      *GOSHACRASH_USBMOUNT_BEGIN*) : ;;
      *) warn "ASUSWRT удалил script_usbmount из NVRAM; используется Download Master S99goshacrash.1" ;;
    esac
}



merge_ipkg_package_stanza(){
    src="$1"; dst="$2"; package="$3"
    test -f "$src" || return 1
    mkdir -p "$(dirname "$dst")" || return 1
    test -f "$dst" || : > "$dst"
    grep -q "^Package: $package\$" "$dst" 2>/dev/null && return 0

    awk -v pkg="$package" '
      BEGIN{keep=0}
      /^Package: / {keep=($2==pkg)}
      keep {print}
      keep && /^$/ {exit}
    ' "$src" >> "$dst"
}

install_stock_usb_mount_bridge(){
    case "${DM_ROOT##*/}" in
        asusware.arm|asusware.arm64|asusware) ;;
        *)
            fail "Неизвестный layout Download Master: ${DM_ROOT##*/}"
            return 1
            ;;
    esac
    mkdir -p "$DM_ROOT/etc/init.d" "$DM_ROOT/lib/ipkg/info" || return 1
    cat > "$DM_ROOT/etc/init.d/S50usb-mount-script" <<'HOOK'
#!/bin/sh
mount="$(df "$(readlink -f "$0")" | grep -v '^Filesystem' | head -n 1 | awk '{print $1, $6}')"
device="$(echo "$mount" | awk '{print $1}')"
mount="$(echo "$mount" | awk '{print $2}')"
case "$1" in
  start)
    if test -x /jffs/scripts/usb-mount-script; then
      /jffs/scripts/usb-mount-script "$device" "$mount" &
    fi
    {
      timeout=15
      while test "$(nvram get apps_state_autorun)" != "4" && test "$timeout" -ge 0; do
        sleep 1
        timeout=$((timeout-1))
      done
      for var in state_autorun state_install state_remove state_switch state_stop state_enable state_update state_upgrade state_cancel state_error state_action mounted_path dev; do
        nvram set "apps_$var="
      done
    } >/dev/null 2>&1 &
    ;;
  stop)
    test -x /jffs/scripts/usb-umount-script && /jffs/scripts/usb-umount-script "$device" "$mount" &
    ;;
esac
HOOK
    chmod 755 "$DM_ROOT/etc/init.d/S50usb-mount-script" || return 1
    if ! grep -q '^Package: usb-mount-script$' "$DM_ROOT/lib/ipkg/status" 2>/dev/null; then
        cat >> "$DM_ROOT/lib/ipkg/status" <<'EOF'

Package: usb-mount-script
Version: 1.0.0.0
Status: install user installed
Architecture: all
Installed-Time: 0

EOF
    fi
    cat > "$DM_ROOT/lib/ipkg/info/usb-mount-script.control" <<'EOF'
Package: usb-mount-script
Architecture: all
Priority: optional
Section: libs
Version: 1.0.0.0
Depends:
Suggests:
Conflicts:
Enabled: yes
Installed-Size: 1
EOF
    touch "$DM_ROOT/.asusrouter" 2>/dev/null || true
    ok "Stock ASUSWRT USB-mount bridge установлен"
}

remove_pre3712_autostart(){
    remove_legacy_hook_lines /jffs/scripts/services-start >/dev/null 2>&1 || true
    remove_legacy_hook_lines /jffs/scripts/firewall-start >/dev/null 2>&1 || true
    rm -f "$DM_ROOT/S99goshacrash.1" \
          "$DM_ROOT/etc/init.d/S99goshacrash" 2>/dev/null || true

    # Remove only old GoshaCrash blocks; unrelated NVRAM content is left alone.
    if find_nvram >/dev/null 2>&1; then
        for key in script_usbmount script_usbumount; do
            value="$(nvram_get "$key")"
            tmp="$TMP_ROOT/$key.clean.$$"
            printf '%s\n' "$value" | awk '
              /# GOSHACRASH_USBMOUNT_BEGIN/ {skip=1; next}
              /# GOSHACRASH_USBMOUNT_END/ {skip=0; next}
              /# GOSHACRASH_USBUMOUNT_BEGIN/ {skip=1; next}
              /# GOSHACRASH_USBUMOUNT_END/ {skip=0; next}
              !skip {print}
            ' > "$tmp" 2>/dev/null || true
            cleaned="$(cat "$tmp" 2>/dev/null)"
            test "$cleaned" = "$value" || nvram_set "$key" "$cleaned" >/dev/null 2>&1 || true
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
WAITED=0
BASE="$(cat "$BASE_FILE" 2>/dev/null)"
while test -z "$BASE" || test ! -x "$BASE/goshacrash.sh"; do
  test "$WAITED" -ge 300 && exit 0
  sleep 5
  WAITED=$((WAITED + 5))
  BASE="$(cat "$BASE_FILE" 2>/dev/null)"
done
mkdir -p "$BASE/run" "$BASE/state" 2>/dev/null || true
date '+%Y-%m-%d %H:%M:%S' > "$BASE/state/autostart-hook-ran" 2>/dev/null || true
if command -v nohup >/dev/null 2>&1; then
  GOSHACRASH_BASE="$BASE" nohup "$BASE/goshacrash.sh" boot </dev/null >/dev/null 2>&1 &
else
  GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" boot </dev/null >/dev/null 2>&1 &
fi
HOOK
    chmod 755 "$JFFS_DIR/start.sh" || return 1

    cat > /jffs/scripts/usb-mount-script <<'HOOK'
#!/bin/sh
MOUNT_POINT="$2"
BASE="$(cat /jffs/addons/goshacrash/base 2>/dev/null)"
test -n "$BASE" || exit 0
case "$BASE" in
  "$MOUNT_POINT"/*)
    DM=""
    for d in "$MOUNT_POINT/asusware.arm" "$MOUNT_POINT/asusware.arm64" "$MOUNT_POINT/asusware"; do
      test -d "$d" && { DM="$d"; break; }
    done
    if test -n "$DM" && test -d "$DM"; then
      if test -L /tmp/opt; then
        ln -snf "$DM" /tmp/opt 2>/dev/null || true
      elif test -d /tmp/opt; then
        if test ! -x /tmp/opt/bin/ipkg && test ! -x /tmp/opt/bin/opkg; then
          rmdir /tmp/opt 2>/dev/null && ln -s "$DM" /tmp/opt 2>/dev/null || true
        fi
      elif test ! -e /tmp/opt; then
        ln -s "$DM" /tmp/opt 2>/dev/null || true
      fi
      touch "$DM/.asusrouter" 2>/dev/null || true
    fi
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
test -n "$BASE" || exit 0
case "$BASE" in
  "$MOUNT_POINT"/*)
    test -x "$BASE/goshacrash.sh" && GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" service-stop >/dev/null 2>&1 || true
    ;;
esac
exit 0
HOOK
    chmod 755 /jffs/scripts/usb-umount-script || return 1

    rm -f /jffs/scripts/gc "$DM_ROOT/bin/gc" /opt/bin/gc 2>/dev/null || true
    write_test_wrapper /jffs/scripts/test || return 1
    write_bracket_wrapper /jffs/scripts/'[' || return 1
    write_command_wrapper /jffs/scripts/gc
    write_nano_wrapper /jffs/scripts/nano
    write_command_wrapper "$DM_ROOT/bin/gc"
    test -d /opt/bin && test -w /opt/bin && write_command_wrapper /opt/bin/gc 2>/dev/null || true
    add_once /jffs/configs/profile.add 'export PATH="/jffs/scripts:/opt/bin:/opt/sbin:/tmp/opt/bin:/tmp/opt/sbin:$PATH"'

    remove_pre3712_autostart
    install_stock_usb_mount_bridge || return 1
    rm -f "$BASE/logs/goshacrash.log" "$BASE/logs/watchdog.log" "$BASE/logs/boot.log" 2>/dev/null || true
    ok "Автозапуск установлен для stock ASUSWRT"
}

verify_shell_compat(){
    busybox="/bin/busybox"
    test_wrapper="/jffs/scripts/test"
    bracket_wrapper="/jffs/scripts/["

    "$busybox" test -x "$busybox" >/dev/null 2>&1 || {
        fail "Shell compatibility: /bin/busybox недоступен"
        return 1
    }

    "$busybox" test -x "$test_wrapper" >/dev/null 2>&1 || {
        fail "Shell compatibility: $test_wrapper не создан"
        return 1
    }
    "$busybox" test -x "$bracket_wrapper" >/dev/null 2>&1 || {
        fail "Shell compatibility: $bracket_wrapper не создан"
        return 1
    }

    "$busybox" test -n "goshacrash" >/dev/null 2>&1 || {
        fail "Shell compatibility: BusyBox test applet не работает"
        return 1
    }
    "$busybox" '[' -n "goshacrash" ']' >/dev/null 2>&1 || {
        fail "Shell compatibility: BusyBox [ applet не работает"
        return 1
    }
    "$test_wrapper" -n "goshacrash" >/dev/null 2>&1 || {
        fail "Shell compatibility: $test_wrapper не работает"
        return 1
    }
    "$bracket_wrapper" -n "goshacrash" ']' >/dev/null 2>&1 || {
        fail "Shell compatibility: $bracket_wrapper не работает"
        return 1
    }

    say "Shell compatibility: test + [ OK"
    return 0
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
    if test "$INSTALL_LOG" = "$TMP_LOG"; then
        cat "$TMP_LOG" >> "$BASE/logs/install.log" 2>/dev/null || true
        INSTALL_LOG="$BASE/logs/install.log"
    fi
}



normalize_legacy_optware_unzip() {
    # Old ASUS Download Master / Optware packages may install Info-ZIP as
    # /opt/bin/unzip-unzip and rely on an alternatives symlink that is absent
    # on some ASUSWRT builds. Create the compatibility symlink ourselves.
    if test ! -x /opt/bin/unzip && test -x /opt/bin/unzip-unzip; then
        ln -sf /opt/bin/unzip-unzip /opt/bin/unzip 2>/dev/null || true
    fi

    # Some installs expose /opt through the USB prefix only.
    if test -n "$DM_ROOT" && test -x "$DM_ROOT/bin/unzip-unzip" && test ! -x "$DM_ROOT/bin/unzip"; then
        ln -sf "$DM_ROOT/bin/unzip-unzip" "$DM_ROOT/bin/unzip" 2>/dev/null || true
    fi
}


main(){
    : > "$TMP_LOG"
    test "$#" -eq 0 || { fail "install.sh запускается без аргументов"; return 1; }
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
    model_name="$(nvram_get productid)"; test -n "$model_name" || model_name="$(hostname 2>/dev/null)"; test -n "$model_name" || model_name="ASUSWRT"
    say "Роутер: $model_name, архитектура $(uname -m 2>/dev/null), ядро $(uname -r 2>/dev/null)"
    say "Профиль: $PLATFORM; routing=$ROUTING_MODE; tun.stack=$TUN_STACK"

    prepare_path
    "$GC_BOOTSTRAP_BIN/test" -n "goshacrash" >/dev/null 2>&1 || {
        fail "Bootstrap test потерян из PATH/runtime"
        return 1
    }
    "$GC_BOOTSTRAP_BIN/[" -n "goshacrash" ']' >/dev/null 2>&1 || {
        fail "Bootstrap [ не работает"
        return 1
    }
    say "Shell bootstrap: test + [ OK"
    prepare_packages || return 1
    install_controller || return 1
    install_network_helper || return 1
    install_configs || return 1
    install_mihomo || return 1
    install_zashboard || return 1
    write_platform_state || return 1

    verify_persistent_optware || return 1
    install_hooks || return 1
    verify_shell_compat || return 1
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
