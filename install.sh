#!/bin/sh
# GoshaCrash online installer for real ASUSWRT routers.
# One copied file installs the controller, a matching Mihomo core, Zashboard,
# package tools through ASUS Download Master, configuration and autostart.

INSTALLER_VERSION="3.10.2-rc40-test2"
EXPECTED_CONTROLLER_BUILD_ID="2026-09-03-dynamic-usb-relative-state-no-secret-persistent-utf8-nano"

# Never let an old Optware/uClibc environment leak into stock ASUSWRT tools.
# Any Optware compatibility environment is applied only to the exact command
# that needs it via run_pkg/run_optware below.
unset LD_LIBRARY_PATH 2>/dev/null || true

REPO="${REPO:-goshamarat/GoshaCrash}"
BRANCH="${BRANCH:-main}"

LEGACY_MIHOMO_VERSION="${LEGACY_MIHOMO_VERSION:-v1.19.28}"
LEGACY_MIHOMO_TAG="${LEGACY_MIHOMO_TAG:-mihomo-gvisor-armv5-$LEGACY_MIHOMO_VERSION}"
OFFICIAL_MIHOMO_VERSION="${OFFICIAL_MIHOMO_VERSION:-v1.19.30}"
OFFICIAL_MIHOMO_FALLBACK="${OFFICIAL_MIHOMO_FALLBACK:-$OFFICIAL_MIHOMO_VERSION}"
ZASHBOARD_PRIMARY="${ZASHBOARD_URL:-https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip}"

TMP_ROOT="/tmp/goshacrash-install.$$"
TMP_LOG="/tmp/goshacrash-install.log"
INSTALL_LOG="$TMP_LOG"
USB_MOUNT=""
USB_DEVICE=""
USB_DISK=""
USB_NAME=""
USB_FS=""
DM_LAYOUT=""
INSTALLER_PATH=""
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
CONFIG_ROLLBACK_TMP=""
CONFIG_MIGRATION_PENDING="0"
RESET_CONFIG="0"

now(){ date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date; }
_emit(){ level="$1"; shift; line="[$(now)] [$level] [install] $*"; printf '%s\n' "$line"; printf '%s\n' "$line" >> "$INSTALL_LOG" 2>/dev/null || true; }
say(){ _emit INFO "$@"; }
ok(){ _emit OK "$@"; }
warn(){ _emit WARN "$@" >&2; }
fail(){ _emit ERROR "$@" >&2; return 1; }

cleanup(){
    # Existing user config is only committed after the new Mihomo validates it.
    # Until then the rollback copy lives only in /tmp and is restored on any
    # installer abort. No persistent backup directory is created.
    if test "$CONFIG_MIGRATION_PENDING" = 1 && test -n "$CONFIG_ROLLBACK_TMP" && test -f "$CONFIG_ROLLBACK_TMP" && test -n "$ACTIVE_CONFIG"; then
        cp -f "$CONFIG_ROLLBACK_TMP" "$ACTIVE_CONFIG" 2>/dev/null || true
    fi
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
    return 1
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


legacy_hw_detect(){
    machine="$(uname -m 2>/dev/null | tr 'A-Z' 'a-z')"
    kernel="$(uname -r 2>/dev/null)"
    model="$(nvram_get productid)"
    case "$machine:$kernel:$model" in
        armv7*:2.6.*:*|arm*:2.6.*:*|*:*:RT-AC68U*|*:*:RT-AC68P*|*:*:RT-AC1900*|*:*:RT-AC66U_B1*)
            return 0
            ;;
    esac
    return 1
}

# install.sh is intentionally executed from the root of the target USB mount.
# Device names and mount names are runtime facts: /dev/sdb1 may become
# /dev/sda1 after reboot, and a label may fall back to sda1. Never hardcode them.
detect_installer_usb(){
    self="$0"
    case "$self" in
        /*) : ;;
        *) self="$(pwd)/$self" ;;
    esac
    INSTALLER_PATH="$(CDPATH= cd "$(dirname "$self")" 2>/dev/null && pwd)/$(basename "$self")"

    test "$(basename "$INSTALLER_PATH")" = "install.sh" || {
        fail "Установщик должен называться строго install.sh"
        return 1
    }

    USB_MOUNT="$(dirname "$INSTALLER_PATH")"
    case "$USB_MOUNT" in
        /tmp/mnt/*) ;;
        *)
            fail "install.sh должен лежать в корне USB: /tmp/mnt/<mount>/install.sh"
            echo "Сейчас: $INSTALLER_PATH"
            return 1
            ;;
    esac

    USB_DEVICE="$(awk -v m="$USB_MOUNT" '$2==m && $1 ~ "^/dev/sd" {print $1; exit}' /proc/mounts 2>/dev/null)"
    if test -z "$USB_DEVICE"; then
        USB_DEVICE="$(df -P "$USB_MOUNT" 2>/dev/null | awk 'NR==2 && $1 ~ "^/dev/sd" {print $1; exit}')"
    fi
    case "$USB_DEVICE" in
        /dev/sd*[0-9]) ;;
        *)
            fail "Не удалось связать $USB_MOUNT с реальным USB-разделом /dev/sdXN"
            return 1
            ;;
    esac

    USB_DISK="$(printf '%s\n' "$USB_DEVICE" | sed 's/[0-9][0-9]*$//')"
    USB_NAME="${USB_MOUNT##*/}"
    USB_FS="$(awk -v d="$USB_DEVICE" '$1==d {print $3; exit}' /proc/mounts 2>/dev/null)"

    test -n "$USB_FS" || { fail "Не удалось определить filesystem для $USB_MOUNT"; return 1; }
    test -w "$USB_MOUNT" || { fail "USB mountpoint не доступен на запись: $USB_MOUNT"; return 1; }

    return 0
}

legacy_preflight_before_dm(){
    legacy_hw_detect || return 0

    fs="$USB_FS"
    case "$fs" in
        ext3)
            ok "USB filesystem: EXT3 ($USB_MOUNT)"
            return 0
            ;;
        *)
            echo
            warn "USB filesystem: $fs ($USB_MOUNT)"
            echo "Для RT-AC68U legacy-схема GoshaCrash + Download Master/Optware требует EXT3."
            echo "Форматирование выполняется отдельной программой; install.sh диски не форматирует."
            fail "Установка остановлена: для legacy требуется EXT3"
            return 1
            ;;
    esac
}

find_download_master(){
    test -n "$USB_MOUNT" && test -d "$USB_MOUNT" || return 1

    DM_ROOT=""
    DM_LAYOUT=""
    for d in "$USB_MOUNT/asusware.arm" "$USB_MOUNT/asusware.arm64" "$USB_MOUNT/asusware"; do
        test -d "$d" || continue
        DM_ROOT="$d"
        DM_LAYOUT="${d##*/}"
        return 0
    done

    fail "На выбранной флешке $USB_MOUNT не найден Download Master (asusware.arm/asusware.arm64/asusware)"
    echo "Сначала установи Download Master через веб-интерфейс ASUS именно на эту флешку."
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


OPT_NAMESPACE_STATE="/tmp/goshacrash-opt-bind.state"

find_system_mount(){
    for p in /bin/mount /sbin/mount /usr/bin/mount /usr/sbin/mount; do
        test -x "$p" && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

find_system_umount(){
    for p in /bin/umount /sbin/umount /usr/bin/umount /usr/sbin/umount; do
        test -x "$p" && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

opt_namespace_write_through(){
    test -n "$DM_ROOT" && test -d "$DM_ROOT" || return 1
    probe=".goshacrash-opt-probe.$$"
    rm -f "/opt/$probe" "$DM_ROOT/$probe" 2>/dev/null || true

    if ( : > "/opt/$probe" ) 2>/dev/null; then
        if test -e "$DM_ROOT/$probe"; then
            rm -f "/opt/$probe" "$DM_ROOT/$probe" 2>/dev/null || true
            return 0
        fi
        rm -f "/opt/$probe" 2>/dev/null || true
    fi
    return 1
}

usb_storage_sanity_check(){
    # A damaged ext filesystem can look mounted and writable while directory
    # metadata is already unreadable (for example: "Structure needs cleaning").
    # Refuse to touch Optware in that state: reinstalling packages cannot repair
    # filesystem metadata and only makes the failure harder to diagnose.
    for probe_dir in "$DM_ROOT" "$DM_ROOT/scripts" "$BASE/ui"; do
        test -d "$probe_dir" || continue
        if ! ls -la "$probe_dir" >/dev/null 2>> "$BASE/logs/packages.log"; then
            fail "USB filesystem повреждена или каталог нечитаем: $probe_dir"
            fail "Сначала останови Download Master, размонтируй USB и выполни offline fsck; затем повтори установку"
            return 1
        fi
    done
    return 0
}

preserve_stock_opt_payload(){
    # Preserve firmware-owned real files/directories that would otherwise be
    # hidden by the bind mount. Firmware symlinks to /tmp/opt need no copy.
    # Never hide cp/ls errors: on BT10 they are the primary signal of damaged
    # ext metadata and must remain visible in packages.log.
    for entry in /opt/*; do
        test -e "$entry" || continue
        test -L "$entry" && continue
        name="${entry##*/}"
        target="$DM_ROOT/$name"

        if test -d "$target"; then
            if ! ls -la "$target" >/dev/null 2>> "$BASE/logs/packages.log"; then
                fail "USB/Optware каталог $target повреждён или нечитаем; требуется offline fsck"
                return 1
            fi
        fi

        printf '[%s] OPT PRESERVE: %s -> %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$entry" "$target" >> "$BASE/logs/packages.log" 2>/dev/null || true

        if test -d "$entry"; then
            mkdir -p "$target" >> "$BASE/logs/packages.log" 2>&1 || return 1
            cp -R "$entry/." "$target/" >> "$BASE/logs/packages.log" 2>&1 || {
                fail "Не удалось сохранить штатный /opt/$name перед подготовкой Optware"
                fail "Подробность сохранена в $BASE/logs/packages.log; если есть 'Structure needs cleaning' — нужен offline fsck"
                return 1
            }
        elif test -f "$entry"; then
            cp -f "$entry" "$target" >> "$BASE/logs/packages.log" 2>&1 || {
                fail "Не удалось сохранить штатный файл /opt/$name; см. packages.log"
                return 1
            }
        fi
    done
    return 0
}

prepare_optware_topdirs(){
    # Stock BT10 firmware does not provide top-level /opt/libexec, /opt/man
    # or /opt/var in its read-only skeleton.  Once /opt is mapped to USB,
    # create the conventional Optware layout before any package extraction.
    mkdir -p \
        "$DM_ROOT/libexec" \
        "$DM_ROOT/man/man1" \
        "$DM_ROOT/var" || return 1
    return 0
}

prepare_optware_namespace(){
    ensure_optware_link || return 1

    # Legacy ASUSWRT already exposes the whole USB Optware tree as /opt.
    # Modern stock firmware can expose only a fixed set of read-only links
    # (/opt/bin, /opt/lib, /opt/share, ...).  In that layout ipkg cannot
    # create /opt/libexec, /opt/man, /opt/var and silently loses payload.
    if opt_namespace_write_through; then
        prepare_optware_topdirs || return 1
        if awk '$2=="/opt" {found=1} END {exit !found}' /proc/mounts 2>/dev/null; then
            printf '%s\n' "$DM_ROOT" > "$OPT_NAMESPACE_STATE" 2>/dev/null || true
        fi
        return 0
    fi

    mount_bin="$(find_system_mount 2>/dev/null)"
    test -n "$mount_bin" || {
        fail "Штатный mount не найден; невозможно подготовить writable /opt для ipkg"
        return 1
    }

    # If something else is already mounted on /opt, never cover it blindly.
    if awk '$2=="/opt" {found=1} END {exit !found}' /proc/mounts 2>/dev/null; then
        fail "/opt уже является отдельной файловой системой, но не ведёт на Download Master"
        return 1
    fi

    preserve_stock_opt_payload || return 1
    touch "$DM_ROOT/.goshacrash-opt-root" 2>/dev/null || true

    pkg_log "OPT NAMESPACE: bind $DM_ROOT -> /opt"
    "$mount_bin" -o bind "$DM_ROOT" /opt >> "$BASE/logs/packages.log" 2>&1 || \
      "$mount_bin" --bind "$DM_ROOT" /opt >> "$BASE/logs/packages.log" 2>&1 || {
        fail "Не удалось bind-mount Download Master на /opt; ipkg на этой прошивке не сможет ставить полный payload"
        return 1
      }

    if ! opt_namespace_write_through; then
        umount_bin="$(find_system_umount 2>/dev/null)"
        test -n "$umount_bin" && "$umount_bin" /opt >/dev/null 2>&1 || true
        fail "Проверка /opt -> USB после bind-mount не прошла"
        return 1
    fi

    prepare_optware_topdirs || {
        fail "Не удалось создать стандартные каталоги Optware: libexec/man/var"
        return 1
    }

    printf '%s\n' "$DM_ROOT" > "$OPT_NAMESPACE_STATE" 2>/dev/null || true
    say "Optware namespace: /opt -> $DM_ROOT (writable USB bind)"
    say "Optware layout: /opt/libexec + /opt/man/man1 + /opt/var готовы"
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

copy_alias_if_missing(){
    src="$1"
    dst="$2"

    test -f "$src" || return 1
    test -f "$dst" && return 0

    cp -f "$src" "$dst" 2>/dev/null || return 1
    chmod 755 "$dst" 2>/dev/null || true
    return 0
}

find_first_versioned(){
    pattern="$1"
    for f in $pattern; do
        test -f "$f" && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

OPTWARE_OVERLAY="/tmp/goshacrash-opt"
OPTWARE_OVERLAY_LIB="$OPTWARE_OVERLAY/lib"

build_optware_overlay(){
    test -n "$DM_ROOT" && test -d "$DM_ROOT/lib" || return 1

    rm -rf "$OPTWARE_OVERLAY" 2>/dev/null || true
    mkdir -p "$OPTWARE_OVERLAY_LIB" || return 1

    # FAT/TFAT keeps the real versioned library files.  Recreate only the
    # Unix SONAME links in tmpfs.  Nothing is installed/downloaded here.
    for src in "$DM_ROOT"/lib/lib*.so.[0-9]*.[0-9]*; do
        test -f "$src" || continue
        base="${src##*/}"
        prefix="${base%%.so.*}"
        ver="${base#*.so.}"
        major="${ver%%.*}"
        case "$major" in ''|*[!0-9]*) continue ;; esac
        ln -sf "$src" "$OPTWARE_OVERLAY_LIB/$prefix.so.$major" 2>/dev/null || true
    done

    # uClibc has historical filenames that do not follow libfoo.so.X.Y.
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

    # If a required SONAME already exists physically on USB, expose it too.
    for src in "$DM_ROOT"/lib/lib*.so.[0-9]; do
        test -f "$src" || continue
        ln -sf "$src" "$OPTWARE_OVERLAY_LIB/${src##*/}" 2>/dev/null || true
    done
    return 0
}

optware_env(){
    build_optware_overlay || return 1
    printf '%s\n' "$OPTWARE_OVERLAY_LIB:$DM_ROOT/lib:/lib:/usr/lib"
}

repair_generic_sonames(){
    test -n "$DM_ROOT" && test -d "$DM_ROOT/lib" || return 1

    # Recover major SONAME aliases lost on TFAT:
    #   libncurses.so.5.7   -> libncurses.so.5
    #   libstdc++.so.6.0.2  -> libstdc++.so.6
    #   libipkg.so.0.0.0    -> libipkg.so.0
    #
    # Keep the original versioned file and copy only when the major alias
    # is missing. Regular files are used deliberately instead of symlinks.
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

        say "Optware ABI: ${base} -> ${prefix}.so.${major}"
        copy_alias_if_missing "$src" "$dst" || return 1
    done

    return 0
}

repair_optware_abi(){
    test -n "$DM_ROOT" && test -d "$DM_ROOT/lib" || return 1
    build_optware_overlay
}

OPTWARE_RUNTIME_MODE=""

run_optware(){
    ldpath="$(optware_env)" || return 1
    LD_LIBRARY_PATH="$ldpath" "$@"
}

run_optware_clean(){
    # Critical on old stock ASUSWRT: Optware's uClibc must NOT leak into
    # firmware /bin/sh, wget, ls, etc.  A subshell keeps the caller clean too.
    (
        unset LD_LIBRARY_PATH
        "$@"
    )
}

run_pkg(){
    case "$OPTWARE_RUNTIME_MODE" in
        clean)
            run_optware_clean "$@"
            ;;
        overlay)
            run_optware "$@"
            ;;
        *)
            run_optware_clean "$@"
            ;;
    esac
}

verify_ipkg_natural(){
    ensure_optware_link >/dev/null 2>&1 || {
        fail "Download Master найден, но /tmp/opt не связан с $DM_ROOT"
        return 1
    }
    test -n "$PKG" || find_pkg || {
        fail "В Download Master не найден ipkg/opkg"
        return 1
    }

    err="$BASE/logs/ipkg-runtime.err"
    : > "$err"
    (
        unset LD_LIBRARY_PATH
        "$PKG" list_installed
    ) >/dev/null 2>"$err"
    rc=$?
    if test "$rc" -ne 0 || grep -Eq "can't (load library|resolve symbol)" "$err" 2>/dev/null; then
        fail "Download Master ipkg не запускается штатно. См. $err"
        return 1
    fi
    rm -f "$err" 2>/dev/null || true
    say "Download Master ipkg: штатный runtime OK"
    return 0
}

pkg_natural_update(){
    pkg_progress "ipkg update"
    pkg_log "RUN NATURAL: $PKG update"
    (
        unset LD_LIBRARY_PATH
        "$PKG" update
    ) >> "$BASE/logs/packages.log" 2>&1
}

pkg_natural_is_installed(){
    name="$1"
    (
        unset LD_LIBRARY_PATH
        "$PKG" list_installed
    ) 2>/dev/null | grep -q "^$name[[:space:]]*-"
}

pkg_natural_install(){
    name="$1"
    if pkg_natural_is_installed "$name"; then
        say "Download Master: $name уже установлен"
        return 0
    fi
    pkg_progress "ipkg install $name"
    pkg_log "RUN NATURAL: $PKG install $name"
    (
        unset LD_LIBRARY_PATH
        "$PKG" install "$name"
    ) >> "$BASE/logs/packages.log" 2>&1
}

verify_dm_payload_natural(){
    missing=0

    test -x "$DM_ROOT/bin/nano" || {
        warn "После ipkg install nano бинарник $DM_ROOT/bin/nano не найден"
        missing=1
    }

    if test ! -x "$DM_ROOT/bin/unzip" && test ! -x "$DM_ROOT/bin/unzip-unzip"; then
        warn "После ipkg install unzip бинарник в $DM_ROOT/bin не найден"
        missing=1
    fi

    sftp_bin="$(find_sftp_server 2>/dev/null)"
    test -n "$sftp_bin" || {
        warn "После ipkg install openssh-sftp-server бинарник sftp-server не найден"
        missing=1
    }

    test "$missing" -eq 0 || return 1

    mkdir -p "$BASE/state" 2>/dev/null || true
    printf '%s\n' "$sftp_bin" > "$BASE/state/sftp-server.path" 2>/dev/null || true

    say "Download Master payload: nano=$DM_ROOT/bin/nano"
    if test -x "$DM_ROOT/bin/unzip"; then
        say "Download Master payload: unzip=$DM_ROOT/bin/unzip"
    else
        say "Download Master payload: unzip=$DM_ROOT/bin/unzip-unzip"
    fi
    say "Download Master payload: sftp=$sftp_bin"
    return 0
}

verify_ipkg_runtime(){
    ensure_optware_link >/dev/null 2>&1 || return 1
    prepare_optware_namespace || return 1
    repair_optware_abi || return 1
    prepare_path
    test -n "$PKG" || find_pkg || return 1

    err="$BASE/logs/ipkg-runtime.err"
    : > "$err"

    # EXT3 keeps the real Optware symlinks, so first try ipkg with NO
    # LD_LIBRARY_PATH.  This is the safe mode because child /bin/sh and wget
    # then use the firmware libraries instead of ancient Optware uClibc.
    run_optware_clean "$PKG" list_installed >/dev/null 2>"$err"
    rc=$?
    if test "$rc" -eq 0 && ! grep -Eq "can't (load library|resolve symbol)" "$err" 2>/dev/null; then
        OPTWARE_RUNTIME_MODE="clean"
        rm -f "$err" 2>/dev/null || true
        say "Optware runtime: ipkg OK (clean environment)"
        return 0
    fi

    # Compatibility fallback for old/broken layouts where ipkg itself really
    # needs the temporary ABI overlay.  Package downloads may still be unsafe
    # in this mode, but a healthy EXT3 Download Master should select clean.
    : > "$err"
    run_optware "$PKG" list_installed >/dev/null 2>"$err"
    rc=$?
    if test "$rc" -eq 0 && ! grep -Eq "can't (load library|resolve symbol)" "$err" 2>/dev/null; then
        OPTWARE_RUNTIME_MODE="overlay"
        warn "Optware runtime: используется ABI overlay; clean runtime недоступен"
        return 0
    fi

    fail "Optware runtime повреждён; ipkg rc=$rc"
    cat "$err" >> "$BASE/logs/packages.log" 2>/dev/null || true
    return 1
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
    run_pkg "$PKG" update >> "$BASE/logs/packages.log" 2>&1 || return 1
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

    verify_ipkg_runtime || return 1
    pkg_progress "install $name (локальный индекс)"
    pkg_log "RUN: $PKG install $name"

    run_pkg "$PKG" install "$name" >> "$BASE/logs/packages.log" 2>&1 && {
        repair_optware_abi >/dev/null 2>&1 || true
        return 0
    }

    warn "install $name не удался с текущим индексом"
    pkg_update_index_once || true
    pkg_progress "повторный install $name"
    run_pkg "$PKG" install "$name" >> "$BASE/logs/packages.log" 2>&1
    rc=$?
    repair_optware_abi >/dev/null 2>&1 || true
    return "$rc"
}

pkg_is_installed(){
    run_pkg "$PKG" list_installed 2>/dev/null | grep -q "^$1[[:space:]]*-"
}

pkg_reinstall_one(){
    name="$1"
    test -n "$PKG" || return 1

    verify_ipkg_runtime || return 1

    pkg_progress "remove $name"
    pkg_log "REINSTALL: $name"
    run_pkg "$PKG" remove "$name" >> "$BASE/logs/packages.log" 2>&1 || true

    repair_optware_abi >/dev/null 2>&1 || true
    verify_ipkg_runtime || return 1

    pkg_progress "install $name (локальный индекс)"
    run_pkg "$PKG" install "$name" >> "$BASE/logs/packages.log" 2>&1 && {
        repair_optware_abi >/dev/null 2>&1 || true
        return 0
    }

    warn "reinstall $name не удался с текущим индексом"
    pkg_update_index_once || true
    pkg_progress "повторный install $name"
    run_pkg "$PKG" install "$name" >> "$BASE/logs/packages.log" 2>&1
    rc=$?
    repair_optware_abi >/dev/null 2>&1 || true
    return "$rc"
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
    return 1
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
    repair_optware_abi >/dev/null 2>&1 || true
    prepare_path

    if find_nano >/dev/null 2>&1; then
        nano_bin="$(find_nano 2>/dev/null)"
        run_optware "$nano_bin" --version >/dev/null 2>&1 && return 0
        warn "nano существует, но не запускается; восстанавливаю Optware ABI"
        repair_optware_abi || return 1
        run_optware "$nano_bin" --version >/dev/null 2>&1 && return 0
    fi

    if pkg_is_installed nano; then
        warn "nano отсутствует/не запускается; переустанавливаю пакет"
        pkg_reinstall_one nano || return 1
    else
        pkg_install_one nano || return 1
    fi

    repair_optware_abi || return 1
    prepare_path
    nano_bin="$(find_nano 2>/dev/null)"
    test -n "$nano_bin" || return 1
    run_optware "$nano_bin" --version >/dev/null 2>&1
}


terminfo_entry_present(){
    name="$1"
    test -n "$name" || return 1

    # Real BT10 BusyBox find has no -type/-path support.  Compiled terminfo
    # from Optware-NG uses the classic first-letter layout, so check the exact
    # files that were verified manually on stock BT10.
    case "$name" in
        xterm|xterm-256color)
            test -s "$DM_ROOT/share/terminfo/x/$name"
            ;;
        vt100)
            test -s "$DM_ROOT/share/terminfo/v/$name"
            ;;
        *)
            return 1
            ;;
    esac
}


terminfo_ready(){
    # Do not execute ncurses-base helper binaries here.  On modern BT10 the
    # ASUS 5.7-8 package can contain ARM binaries with a legacy ELF loader,
    # so an existing /opt/bin/infocmp may still fail with ENOENT.  Nano only
    # needs the compiled terminal descriptions themselves.
    terminfo_entry_present xterm || return 1
    terminfo_entry_present xterm-256color || return 1
    return 0
}

optware_ng_feed_url(){
    conf="$DM_ROOT/etc/ipkg.conf"
    test -f "$conf" || return 1
    awk '$1=="src/gz" && $2 ~ /armeabi-ng/ {print $3; exit}' "$conf" 2>/dev/null
}

optware_ng_package_filename(){
    package="$1"
    for list in "$DM_ROOT"/lib/ipkg/lists/*armeabi-ng*; do
        test -f "$list" || continue
        line="$(awk -v pkg="$package" '
          $1=="Package:" {inside=($2==pkg)}
          inside && $1=="Filename:" {print $2; exit}
        ' "$list" 2>/dev/null)"
        test -n "$line" && { printf '%s\n' "$line"; return 0; }
    done
    return 1
}

repair_terminfo_package(){
    terminfo_ready && {
        say "Optware terminfo: xterm + xterm-256color OK"
        return 0
    }

    warn "Optware terminfo отсутствует; извлекаю terminal database из ncurses-base Optware-NG"
    prepare_optware_namespace || return 1
    verify_ipkg_runtime || return 1
    refresh_tools

    filename="$(optware_ng_package_filename ncurses-base 2>/dev/null)"
    if test -z "$filename"; then
        pkg_update_index_once || return 1
        filename="$(optware_ng_package_filename ncurses-base 2>/dev/null)"
    fi
    test -n "$filename" || {
        fail "В индексе Optware-NG не найден Filename для ncurses-base"
        return 1
    }

    feed="$(optware_ng_feed_url 2>/dev/null)"
    test -n "$feed" || {
        fail "В ipkg.conf не найден feed Optware-NG armeabi-ng"
        return 1
    }

    case "$filename" in
        http://*|https://*) url="$filename" ;;
        *) url="${feed%/}/${filename#/}" ;;
    esac

    ipk="$TMP_ROOT/ncurses-base-optware-ng.ipk"
    stage="$TMP_ROOT/ncurses-base-offline"
    rm -rf "$stage" 2>/dev/null || true
    mkdir -p "$stage" || return 1

    say "Optware: загружаю штатный ncurses-base из Optware-NG"
    fetch "$url" "$ipk" || {
        fail "Не удалось скачать ncurses-base из Optware-NG"
        return 1
    }

    # Do NOT downgrade ASUS' installed ncurses-base 5.7-8 in-place.  That
    # package belongs to Download Master and its helper binaries may target a
    # legacy loader not provided by modern ASUSWRT.  ipkg 0.99.163 supports an
    # offline root, so use the same package manager to unpack the exact
    # Optware-NG package into a private staging root, then copy only compiled
    # terminfo data to the real USB tree.  This leaves the DM package database
    # and libraries untouched.
    # This is the exact sequence verified manually on stock BT10 with
    # ipkg 0.99.163.  -force-depends is required because the private offline
    # root intentionally does not contain the already-installed uclibc-opt.
    # ipkg may still print a dependency warning after successfully unpacking;
    # the physical payload below is authoritative.
    pkg_log "RUN OFFLINE: $PKG -o $stage -force-depends install $ipk"
    run_pkg "$PKG" -o "$stage" -force-depends install "$ipk" >> "$BASE/logs/packages.log" 2>&1 || \
      warn "offline ipkg вернул ненулевой код; проверяю фактически распакованный payload"

    staged_terminfo=""
    for d in \
        "$stage/opt/share/terminfo" \
        "$stage/share/terminfo" \
        "$stage/tmp/opt/share/terminfo"
    do
        if test -s "$d/x/xterm" && test -s "$d/x/xterm-256color"; then
            staged_terminfo="$d"
            break
        fi
    done

    test -n "$staged_terminfo" || {
        fail "ncurses-base Optware-NG не дал xterm/xterm-256color в offline root"
        return 1
    }

    say "Optware terminfo staging: xterm + xterm-256color найдены"

    mkdir -p "$DM_ROOT/share/terminfo" || return 1
    cp -R "$staged_terminfo/." "$DM_ROOT/share/terminfo/" >> "$BASE/logs/packages.log" 2>&1 || {
        fail "Не удалось сохранить terminfo на USB"
        return 1
    }

    prepare_path

    terminfo_ready || {
        fail "После offline extraction нет xterm/xterm-256color terminfo"
        return 1
    }

    printf '%s\n' "Optware-NG: ${filename##*/}" > "$BASE/state/terminfo-source.txt" 2>/dev/null || true
    ok "Optware terminfo восстановлен из Optware-NG без замены ASUS ncurses-base"
    return 0
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

    prepare_optware_namespace || return 1
    repair_optware_abi || return 1
    verify_ipkg_runtime || return 1

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

install_sftp_wrapper(){
    real="$DM_ROOT/libexec/sftp-server.real"
    current="$DM_ROOT/libexec/sftp-server"

    test -x "$current" || test -x "$real" || return 1

    # Preserve the real ELF once. FAT stores regular files safely.
    if test ! -f "$real"; then
        cp -f "$current" "$real" || return 1
        chmod 755 "$real" 2>/dev/null || true
    fi

    cat > "$current" <<'SFTPWRAP'
#!/bin/sh
DM_ROOT="$(readlink /tmp/opt 2>/dev/null)"
if test -z "$DM_ROOT"; then
  for d in /tmp/mnt/*/asusware.arm /tmp/mnt/*/asusware.arm64 /tmp/mnt/*/asusware; do
    test -d "$d" && { DM_ROOT="$d"; break; }
  done
fi
test -n "$DM_ROOT" || exit 1
OVERLAY=/tmp/goshacrash-opt/lib
LD_LIBRARY_PATH="$OVERLAY:$DM_ROOT/lib:/lib:/usr/lib" exec "$DM_ROOT/libexec/sftp-server.real" "$@"
SFTPWRAP
    chmod 755 "$current" || return 1
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
    install_sftp_wrapper >/dev/null 2>&1 || true

    return 0
}

detect_usb_fstype(){
    usb_mount="${USB_ROOT:-$DM_ROOT}"
    test -n "$usb_mount" || return 1

    # `mount` output: device on MOUNTPOINT type FSTYPE (...)
    # Several parent mounts can match the same path:
    #   /                  -> rootfs
    #   /tmp               -> tmpfs
    #   /tmp/mnt/<current> -> ext3/ext4
    # Always choose the longest matching mountpoint.
    mount 2>/dev/null | awk -v p="$usb_mount" '
        {
            m=$3
            if (p == m || index(p, m "/") == 1) {
                l=length(m)
                if (l > bestlen) {
                    bestlen=l
                    bestfs=$5
                }
            }
        }
        END {
            if (bestfs != "")
                print bestfs
        }
    '
}

check_usb_filesystem(){
    USB_FSTYPE="$(detect_usb_fstype 2>/dev/null)"
    case "$USB_FSTYPE" in
        ext2|ext3|ext4)
            say "USB filesystem: $USB_FSTYPE (Linux filesystem, рекомендовано)"
            return 0
            ;;
        tfat|vfat|fat|fat32|msdos|exfat)
            warn "USB filesystem: ${USB_FSTYPE:-unknown}. Для Download Master/Optware рекомендуется EXT3."
            warn "FAT/TFAT может терять Unix symlink/SONAME layout; включён compatibility ABI repair."
            return 0
            ;;
        *)
            warn "USB filesystem не определена или не Linux: ${USB_FSTYPE:-unknown}"
            if test "${LEGACY:-0}" = 1; then
                warn "Для legacy stock ASUSWRT + Download Master требуется EXT3."
            else
                warn "Modern profile продолжит работу; предпочтительна Linux filesystem (ext3/ext4)."
            fi
            return 0
            ;;
    esac
}

prepare_packages(){
    prepare_path
    check_usb_filesystem
    usb_storage_sanity_check || return 1
    prepare_optware_namespace || return 1
    find_pkg || { fail "В Download Master не найден ipkg/opkg"; return 1; }
    say "Менеджер пакетов ASUS: $PKG"

    ensure_optware_link >/dev/null 2>&1 || true
    repair_optware_abi || {
        fail "Не удалось восстановить ABI Optware"
        return 1
    }
    verify_ipkg_runtime || return 1

    refresh_tools
    normalize_legacy_optware_unzip

    if ! find_full_unzip >/dev/null 2>&1; then
        say "Готовлю Info-ZIP"
        repair_unzip_package || { fail "Не удалось получить полноценный unzip"; return 1; }
    else
        say "Info-ZIP уже есть на USB — пропускаю"
    fi

    if ! find_nano >/dev/null 2>&1; then
        say "Готовлю nano"
        repair_nano_package || { fail "Не удалось получить nano"; return 1; }
    else
        say "nano уже есть на USB — проверяю terminal database"
    fi

    repair_terminfo_package || { fail "Не удалось подготовить terminfo для nano"; return 1; }
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

    # Final physical persistence check on USB.
    verify_persistent_optware || return 1
    verify_ipkg_runtime || return 1

    say "Инструменты: nano=$NANO_BIN, unzip=$UNZIP_BIN, gzip=$GZIP_BIN, downloader=$DOWNLOADER"
}

wget_fetch(){
    url="$1"; out="$2"
    w=""
    for p in /usr/sbin/wget /usr/bin/wget "$DM_ROOT/bin/wget" /opt/bin/wget /tmp/opt/bin/wget; do
        test -x "$p" && { w="$p"; break; }
    done
    test -n "$w" || return 1

    echo "--- wget: $url" >&2
    WGET_HOME="/tmp/goshacrash-wget"
    mkdir -p "$WGET_HOME" 2>/dev/null || true
    chmod 700 "$WGET_HOME" 2>/dev/null || true
    : > "$WGET_HOME/.wget-hsts" 2>/dev/null || true
    chmod 600 "$WGET_HOME/.wget-hsts" 2>/dev/null || true
    HOME="$WGET_HOME" "$w" --no-check-certificate -O "$out.part" "$url" && test -s "$out.part" && {
        mv -f "$out.part" "$out"
        return 0
    }
    return 1
}

curl_fetch(){
    url="$1"; out="$2"
    c=""
    for p in /usr/sbin/curl /usr/bin/curl /sbin/curl /bin/curl "$DM_ROOT/bin/curl" /opt/bin/curl /tmp/opt/bin/curl; do
        test -x "$p" && { c="$p"; break; }
    done
    test -n "$c" || return 1

    echo "--- curl: $url" >&2
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
    MIHOMO_SOURCE="official-pinned"
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

    case "$model" in
        *BT10*)
            say "ZenWiFi BT10 detected: modern profile, machine=$machine, mihomo=$MIHOMO_TARGET"
            case "$machine" in
                armv7l|armv7|arm32v7)
                    say "BT10 architecture confirmed: ARMv7 -> Mihomo armv7"
                    ;;
                aarch64|arm64)
                    say "BT10 architecture: ARM64 -> Mihomo arm64"
                    ;;
                *)
                    warn "BT10 вернул неизвестную архитектуру uname -m=$machine; выбран core=$MIHOMO_TARGET"
                    ;;
            esac
            ;;
    esac
}

existing_routing_mode(){
    f="$BASE/state/platform.env"
    test -f "$f" || return 1
    mode="$( ( . "$f" 2>/dev/null; printf '%s\n' "${ROUTING_MODE:-}" ) 2>/dev/null )"
    case "$mode" in manual|auto) printf '%s\n' "$mode"; return 0;; esac
    return 1
}

modern_tun_preflight(){
    test "${LEGACY:-0}" = 1 && return 0

    # Do not depend on the caller's interactive PATH. ASUSWRT commonly keeps
    # modprobe/iptables in /sbin and /usr/sbin.
    MODPROBE_BIN=""
    for p in /sbin/modprobe /usr/sbin/modprobe /bin/modprobe /usr/bin/modprobe; do
        test -x "$p" && { MODPROBE_BIN="$p"; break; }
    done

    if test ! -c /dev/net/tun && test -n "$MODPROBE_BIN"; then
        "$MODPROBE_BIN" tun >/dev/null 2>&1 || true
        sleep 1
    fi

    if test ! -c /dev/net/tun; then
        fail "Modern profile: /dev/net/tun отсутствует; TUN routing не сможет работать"
        return 1
    fi

    say "Modern TUN: /dev/net/tun OK"

    NFT_BIN=""
    IPTABLES_BIN=""
    for p in /usr/sbin/nft /sbin/nft /usr/bin/nft /bin/nft; do
        test -x "$p" && { NFT_BIN="$p"; break; }
    done
    for p in /usr/sbin/iptables /sbin/iptables /usr/bin/iptables /bin/iptables; do
        test -x "$p" && { IPTABLES_BIN="$p"; break; }
    done

    if test -n "$NFT_BIN"; then
        say "Modern firewall backend: nft available ($NFT_BIN)"
    elif test -n "$IPTABLES_BIN"; then
        say "Modern firewall backend: iptables ($("$IPTABLES_BIN" --version 2>/dev/null | head -1))"
    else
        fail "Modern profile: не найден ни nft, ни iptables"
        return 1
    fi
    return 0
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

controller_file_matches(){
    file="$1"
    test -s "$file" || return 1
    test "$(sed -n '1p' "$file" 2>/dev/null)" = '#!/bin/sh' || return 1
    version="$(awk -F'"' '/^VERSION="/ {print $2; exit}' "$file" 2>/dev/null)"
    build_id="$(awk -F'"' '/^BUILD_ID="/ {print $2; exit}' "$file" 2>/dev/null)"
    test "$version" = "$INSTALLER_VERSION" || return 1
    test "$build_id" = "$EXPECTED_CONTROLLER_BUILD_ID"
}

fetch_matching_controller(){
    out="$1"
    for url in \
        "https://raw.githubusercontent.com/$REPO/refs/heads/$BRANCH/goshacrash.sh" \
        "https://github.com/$REPO/raw/refs/heads/$BRANCH/goshacrash.sh" \
        "https://testingcf.jsdelivr.net/gh/$REPO@$BRANCH/goshacrash.sh" \
        "https://cdn.jsdelivr.net/gh/$REPO@$BRANCH/goshacrash.sh"; do
        say "Скачиваю goshacrash.sh"
        rm -f "$out" "$out.part" 2>/dev/null || true
        if fetch "$url" "$out"; then
            if controller_file_matches "$out"; then
                return 0
            fi
            got="$(awk -F'"' '/^VERSION="/ {print $2; exit}' "$out" 2>/dev/null)"
            got_build="$(awk -F'"' '/^BUILD_ID="/ {print $2; exit}' "$out" 2>/dev/null)"
            warn "Источник отдал несовместимый goshacrash.sh: version=${got:-unknown}, build=${got_build:-unknown}"
            warn "Нужны version=$INSTALLER_VERSION, build=$EXPECTED_CONTROLLER_BUILD_ID"
        else
            warn "Источник недоступен: $url"
        fi
    done
    rm -f "$out" "$out.part" 2>/dev/null || true
    return 1
}

install_controller(){
    tmp="$TMP_ROOT/goshacrash.sh"
    rm -f "$tmp" 2>/dev/null || true

    # Extracted release archives are self-contained. For an online bootstrap,
    # every mirror is validated by VERSION so a stale GitHub/CDN cache cannot
    # silently mix two release candidates.
    self_dir="$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)"
    local_controller="$self_dir/goshacrash.sh"
    if controller_file_matches "$local_controller"; then
        cp -f "$local_controller" "$tmp" || return 1
        say "Использую goshacrash.sh из локальной сборки $INSTALLER_VERSION"
    else
        fetch_matching_controller "$tmp" || {
            fail "Не удалось получить goshacrash.sh версии $INSTALLER_VERSION"
            fail "Загрузи install.sh и goshacrash.sh из одной сборки либо дождись обновления main на GitHub"
            return 1
        }
    fi

    if /bin/sh -n /dev/null >/dev/null 2>&1; then
        /bin/sh -n "$tmp" || { fail "Синтаксическая ошибка в goshacrash.sh"; return 1; }
    else
        say "Firmware /bin/sh не поддерживает -n; syntax precheck пропущен"
    fi
    mv -f "$tmp" "$BASE/goshacrash.sh" || return 1
    chmod 755 "$BASE/goshacrash.sh" || return 1
}

install_network_helper(){
    if test "$MIHOMO_TARGET" != armv5; then
        GCNET_BIN=""
        return 0
    fi
    tmp="$TMP_ROOT/gcnet-armv5"
    self_dir="$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)"
    local_helper="$self_dir/assets/gcnet-armv5"
    if test -s "$local_helper"; then
        cp -f "$local_helper" "$tmp" || return 1
        say "Использую gcnet из локальной сборки"
    else
        fetch_repo_file assets/gcnet-armv5 "$tmp" || { fail "Не удалось скачать legacy network helper gcnet"; return 1; }
    fi
    test -s "$tmp" || { fail "gcnet скачан пустым"; return 1; }
    chmod 755 "$tmp" || return 1
    "$tmp" link-exists lo >/dev/null 2>&1 || { fail "gcnet не запускается на этом legacy-роутере"; return 1; }
    mv -f "$tmp" "$BASE/bin/gcnet" || return 1
    chmod 755 "$BASE/bin/gcnet" || return 1
    GCNET_BIN="$BASE/bin/gcnet"
    say "Установлен совместимый legacy network helper: $GCNET_BIN"
}

yaml_top_raw_install(){
    file="$1"; key="$2"
    LC_ALL=C awk -v key="$key" '
      $0 ~ "^" key ":[[:space:]]*" {
        line=$0
        sub("^" key ":[[:space:]]*", "", line)
        print line
        exit
      }
    ' "$file" 2>/dev/null
}

yaml_scalar_clean_install(){
    printf '%s\n' "$1" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//'
}

config_block_section_preflight(){
    file="$1"; section="$2"
    state="$(LC_ALL=C awk -v section="$section" '
      BEGIN{count=0; bad=0}
      $0 ~ "^" section ":" {
        count++
        line=$0
        sub("^" section ":[[:space:]]*", "", line)
        if (line !~ "^($|#)") bad=1
      }
      END{print count ":" bad}
    ' "$file" 2>/dev/null)"
    case "$state" in
      0:0|1:0) return 0;;
      *:1)
        fail "Секция $section должна быть обычным YAML-блоком ($section: с ключами ниже), flow-формат $section: {...} не поддерживается безопасной миграцией"
        return 1
        ;;
      *)
        fail "В config.yaml найдено несколько верхнеуровневых секций $section:. Убери дубликаты перед обновлением"
        return 1
        ;;
    esac
}


yaml_top_section_exists_install(){
    file="$1"; section="$2"
    LC_ALL=C awk -v section="$section" '$0 ~ "^" section ":[[:space:]]*($|#)" {found=1; exit} END{exit found ? 0 : 1}' "$file" >/dev/null 2>&1
}

append_default_dns_section(){
    file="$1"
    cat >> "$file" <<'EOF'

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
EOF
}

append_default_tun_section(){
    file="$1"
    if test "$ROUTING_MODE" = manual; then
        ar=false; ard=false; adi=false
    else
        ar=true; ard=true; adi=true
    fi
    cat >> "$file" <<EOF

tun:
  enable: true
  stack: $TUN_STACK
  device: tun0
  auto-route: $ar
  auto-redirect: $ard
  auto-detect-interface: $adi
  dns-hijack:
    - any:53
    - tcp://any:53
EOF
}

yaml_set_section_key(){
    file="$1"; section="$2"; key="$3"; value="$4"; tmp="$file.gc.$$"
    # Update an existing scalar key, add it to an existing block section, or
    # create the whole section when upgrading an older user config.
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

yaml_section_has_key_install(){
    file="$1"; section="$2"; key="$3"
    LC_ALL=C awk -v section="$section" -v key="$key" '
      $0 ~ "^" section ":[[:space:]]*($|#)" {inside=1; next}
      inside && /^[^[:space:]]/ {exit}
      inside && $0 ~ "^[[:space:]]+" key ":[[:space:]]*" {found=1; exit}
      END{exit found ? 0 : 1}
    ' "$file" >/dev/null 2>&1
}

yaml_ensure_tun_dns_hijack(){
    file="$1"
    yaml_section_has_key_install "$file" tun dns-hijack && return 0
    tmp="$file.gc.$$"
    LC_ALL=C awk '
      BEGIN{inside=0; inserted=0}
      $0 ~ "^tun:[[:space:]]*($|#)" {inside=1; print; next}
      inside && /^[^[:space:]]/ {
        print "  dns-hijack:"
        print "    - any:53"
        print "    - tcp://any:53"
        inserted=1
        inside=0
      }
      {print}
      END{
        if (inside && !inserted) {
          print "  dns-hijack:"
          print "    - any:53"
          print "    - tcp://any:53"
        }
      }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$file"
}

yaml_set_top_key(){
    file="$1"; key="$2"; value="$3"; tmp="$file.gc.$$"
    LC_ALL=C awk -v key="$key" -v value="$value" '
      BEGIN{done=0}
      $0 ~ "^" key ":[[:space:]]*" {if(!done){print key ": " value; done=1}; next}
      {print}
      END{if(!done) print key ": " value}
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$file"
}

yaml_remove_top_key(){
    file="$1"; key="$2"; tmp="$file.gc.$$"
    LC_ALL=C awk -v key="$key" '$0 !~ "^" key ":[[:space:]]*" {print}' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$file"
}

remove_dashboard_secret(){
    file="$1"
    yaml_remove_top_key "$file" secret
}

configure_routing_in_config(){
    file="$1"
    test -f "$file" || return 1

    # Safe shell migration only handles normal block-style tun:/dns: sections.
    # Refuse ambiguous duplicate/flow mappings instead of silently producing
    # duplicate YAML keys and damaging a user config.
    config_block_section_preflight "$file" tun || return 1
    config_block_section_preflight "$file" dns || return 1

    # If an old/imported config has no TUN or DNS section at all, create the
    # complete minimal GoshaCrash blocks instead of only two scalar keys.
    yaml_top_section_exists_install "$file" tun || append_default_tun_section "$file" || return 1
    yaml_top_section_exists_install "$file" dns || append_default_dns_section "$file" || return 1

    # GoshaCrash-owned API/UI fields. Zashboard is LAN-local and intentionally
    # has no Mihomo API secret in this project profile.
    yaml_set_top_key "$file" external-controller 0.0.0.0:9090 || return 1
    yaml_set_top_key "$file" external-ui ui || return 1
    yaml_set_top_key "$file" external-ui-url "\"$ZASHBOARD_PRIMARY\"" || return 1
    remove_dashboard_secret "$file" || return 1

    # Runtime-owned TUN/DNS fields. User proxies, groups, rules and DNS resolver
    # lists are intentionally preserved.
    yaml_set_section_key "$file" tun enable true || return 1
    yaml_set_section_key "$file" tun stack "$TUN_STACK" || return 1
    yaml_set_section_key "$file" tun device tun0 || return 1
    yaml_ensure_tun_dns_hijack "$file" || return 1
    yaml_set_section_key "$file" dns enable true || return 1
    yaml_set_section_key "$file" dns listen 127.0.0.1:1053 || return 1

    if test "$ROUTING_MODE" = manual; then
        yaml_set_section_key "$file" tun auto-route false || return 1
        yaml_set_section_key "$file" tun auto-redirect false || return 1
        yaml_set_section_key "$file" tun auto-detect-interface false || return 1
        yaml_set_top_key "$file" routing-mark 9012 || return 1
    else
        yaml_set_section_key "$file" tun auto-route true || return 1
        yaml_set_section_key "$file" tun auto-redirect true || return 1
        # Mihomo auto-redirect supports iptables or nftables on Linux.
        yaml_set_section_key "$file" tun auto-detect-interface true || return 1
        yaml_remove_top_key "$file" routing-mark || return 1
    fi
}

find_od_install(){
    for od_candidate in /usr/bin/od /bin/od /usr/sbin/od /sbin/od /bin/busybox; do
        test -x "$od_candidate" || continue
        if test "$od_candidate" = /bin/busybox; then
            "$od_candidate" od -An -tu1 -v /dev/null >/dev/null 2>&1 && { printf '%s\n' "$od_candidate od"; return 0; }
        else
            "$od_candidate" -An -tu1 -v /dev/null >/dev/null 2>&1 && { printf '%s\n' "$od_candidate"; return 0; }
        fi
    done
    return 1
}

utf8_validate_file_install(){
    uv_file="$1"
    uv_od_cmd="$(find_od_install 2>/dev/null)" || return 2
    if test "$uv_od_cmd" = "/bin/busybox od"; then
        /bin/busybox od -An -tu1 -v "$uv_file" 2>/dev/null
    else
        "$uv_od_cmd" -An -tu1 -v "$uv_file" 2>/dev/null
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

strip_whole_line_comments_install(){
    src="$1"; dst="$2"
    # Diagnostic helper only: build a temporary data-only copy when Mihomo
    # reports invalid UTF-8, so we can distinguish broken comments from broken
    # YAML data without modifying the user's real config.
    LC_ALL=C tr -d '\015' < "$src" | LC_ALL=C awk '!/^[[:space:]]*#/' > "$dst"
}

# Emit UTF-8 deterministically from an ASCII-only shell string. Non-ASCII
# bytes are stored as POSIX printf %b octal escapes (\0ddd), so generated
# config comments do not depend on locale, terminal encoding or awk/sed.
utf8_print_install(){
    printf '%b\n' "$1"
}

generate_base_config(){
    gbc_file="$1"
    file="$gbc_file"
    if test "$ROUTING_MODE" = manual; then cfg_auto_route=false; cfg_auto_redirect=false; cfg_auto_detect=false
    else cfg_auto_route=true; cfg_auto_redirect=true; cfg_auto_detect=true; fi
    : > "$file" || return 1
    utf8_print_install '# GoshaCrash \0342\0200\0224 \0320\0261\0320\0260\0320\0267\0320\0276\0320\0262\0320\0260\0321\0217 \0320\0272\0320\0276\0320\0275\0321\0204\0320\0270\0320\0263\0321\0203\0321\0200\0320\0260\0321\0206\0320\0270\0321\0217 Mihomo.' >> "$file" || return 1
    utf8_print_install '# \0320\0232\0320\0276\0320\0264\0320\0270\0321\0200\0320\0276\0320\0262\0320\0272\0320\0260 \0321\0204\0320\0260\0320\0271\0320\0273\0320\0260: UTF-8 \0320\0261\0320\0265\0320\0267 BOM.' >> "$file" || return 1
    utf8_print_install '# \0320\0255\0321\0202\0320\0276 \0320\0261\0320\0265\0320\0267\0320\0276\0320\0277\0320\0260\0321\0201\0320\0275\0320\0260\0321\0217 \0321\0201\0321\0202\0320\0260\0321\0200\0321\0202\0320\0276\0320\0262\0320\0260\0321\0217 \0320\0267\0320\0260\0320\0263\0320\0273\0321\0203\0321\0210\0320\0272\0320\0260: \0320\0277\0320\0276\0320\0272\0320\0260 \0320\0277\0321\0200\0320\0276\0320\0272\0321\0201\0320\0270 \0320\0275\0320\0265 \0320\0264\0320\0276\0320\0261\0320\0260\0320\0262\0320\0273\0320\0265\0320\0275\0321\0213, \0320\0262\0320\0265\0321\0201\0321\0214 \0321\0202\0321\0200\0320\0260\0321\0204\0320\0270\0320\0272 \0320\0270\0320\0264\0321\0221\0321\0202 DIRECT.' >> "$file" || return 1
    utf8_print_install '# \0320\0224\0320\0276\0320\0261\0320\0260\0320\0262\0321\0214 \0321\0201\0320\0262\0320\0276\0320\0270 proxies / proxy-groups / rules, \0321\0201\0320\0276\0321\0205\0321\0200\0320\0260\0320\0275\0320\0270 \0321\0204\0320\0260\0320\0271\0320\0273 \0320\0270 \0320\0277\0321\0200\0320\0276\0320\0262\0320\0265\0321\0200\0321\0214 \0320\0265\0320\0263\0320\0276 \0321\0207\0320\0265\0321\0200\0320\0265\0320\0267 gc check.' >> "$file" || return 1
    utf8_print_install '# \0320\0241\0320\0273\0321\0203\0320\0266\0320\0265\0320\0261\0320\0275\0321\0213\0320\0265 \0320\0277\0320\0260\0321\0200\0320\0260\0320\0274\0320\0265\0321\0202\0321\0200\0321\0213 TUN, DNS, API \0320\0270 Zashboard \0320\0277\0320\0276\0320\0264\0320\0264\0320\0265\0321\0200\0320\0266\0320\0270\0320\0262\0320\0260\0321\0216\0321\0202\0321\0201\0321\0217 GoshaCrash \0320\0260\0320\0262\0321\0202\0320\0276\0320\0274\0320\0260\0321\0202\0320\0270\0321\0207\0320\0265\0321\0201\0320\0272\0320\0270.' >> "$file" || return 1
    printf '\n' >> "$file" || return 1
    utf8_print_install '# API Mihomo \0320\0264\0320\0273\0321\0217 Zashboard. \0320\0224\0320\0276\0321\0201\0321\0202\0321\0203\0320\0277\0320\0265\0320\0275 \0320\0270\0320\0267 \0320\0273\0320\0276\0320\0272\0320\0260\0320\0273\0321\0214\0320\0275\0320\0276\0320\0271 \0321\0201\0320\0265\0321\0202\0320\0270 \0320\0270 \0320\0267\0320\0260\0321\0211\0320\0270\0321\0211\0321\0221\0320\0275 \0321\0203\0320\0275\0320\0270\0320\0272\0320\0260\0320\0273\0321\0214\0320\0275\0321\0213\0320\0274 secret.' >> "$file" || return 1
    cat >> "$file" <<EOF
external-controller: 0.0.0.0:9090
external-ui: ui
external-ui-url: "$ZASHBOARD_PRIMARY"

EOF
    utf8_print_install '# \0320\0241\0320\0276\0321\0205\0321\0200\0320\0260\0320\0275\0321\0217\0321\0202\0321\0214 \0320\0262\0321\0213\0320\0261\0321\0200\0320\0260\0320\0275\0320\0275\0321\0213\0320\0265 \0320\0277\0321\0200\0320\0276\0320\0272\0321\0201\0320\0270 \0320\0270 \0321\0202\0320\0260\0320\0261\0320\0273\0320\0270\0321\0206\0321\0203 Fake-IP \0320\0274\0320\0265\0320\0266\0320\0264\0321\0203 \0320\0277\0320\0265\0321\0200\0320\0265\0320\0267\0320\0260\0320\0277\0321\0203\0321\0201\0320\0272\0320\0260\0320\0274\0320\0270 Mihomo.' >> "$file" || return 1
    cat >> "$file" <<'EOF'
profile:
  store-selected: true
  store-fake-ip: true

EOF
    utf8_print_install '# \0320\0233\0320\0276\0320\0272\0320\0260\0320\0273\0321\0214\0320\0275\0321\0213\0320\0271 mixed-\0320\0277\0320\0276\0321\0200\0321\0202 (HTTP/SOCKS) \0320\0270 \0320\0276\0321\0201\0320\0275\0320\0276\0320\0262\0320\0275\0321\0213\0320\0265 \0320\0277\0320\0260\0321\0200\0320\0260\0320\0274\0320\0265\0321\0202\0321\0200\0321\0213 Mihomo.' >> "$file" || return 1
    cat >> "$file" <<'EOF'
mixed-port: 7892
allow-lan: true
bind-address: "*"
mode: rule
log-level: info
ipv6: false
find-process-mode: "off"

EOF
    utf8_print_install '# DNS Mihomo. Fake-IP \0320\0270\0321\0201\0320\0277\0320\0276\0320\0273\0321\0214\0320\0267\0321\0203\0320\0265\0321\0202\0321\0201\0321\0217 \0320\0264\0320\0273\0321\0217 \0320\0277\0321\0200\0320\0276\0320\0267\0321\0200\0320\0260\0321\0207\0320\0275\0320\0276\0320\0271 \0320\0274\0320\0260\0321\0200\0321\0210\0321\0200\0321\0203\0321\0202\0320\0270\0320\0267\0320\0260\0321\0206\0320\0270\0320\0270 \0320\0272\0320\0273\0320\0270\0320\0265\0320\0275\0321\0202\0320\0276\0320\0262.' >> "$file" || return 1
    cat >> "$file" <<'EOF'
dns:
  enable: true
  listen: 127.0.0.1:1053
  ipv6: false

EOF
    utf8_print_install '  # Fake-IP \0320\0277\0320\0276\0320\0267\0320\0262\0320\0276\0320\0273\0321\0217\0320\0265\0321\0202 Mihomo \0320\0277\0321\0200\0320\0276\0320\0267\0321\0200\0320\0260\0321\0207\0320\0275\0320\0276 \0321\0201\0320\0276\0320\0277\0320\0276\0321\0201\0321\0202\0320\0260\0320\0262\0320\0273\0321\0217\0321\0202\0321\0214 DNS-\0320\0276\0321\0202\0320\0262\0320\0265\0321\0202\0321\0213 \0321\0201 \0321\0201\0320\0276\0320\0265\0320\0264\0320\0270\0320\0275\0320\0265\0320\0275\0320\0270\0321\0217\0320\0274\0320\0270.' >> "$file" || return 1
    cat >> "$file" <<'EOF'
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16

EOF
    utf8_print_install '  # DNS \0320\0264\0320\0273\0321\0217 \0320\0275\0320\0260\0321\0207\0320\0260\0320\0273\0321\0214\0320\0275\0320\0276\0320\0263\0320\0276 \0321\0200\0320\0260\0320\0267\0321\0200\0320\0265\0321\0210\0320\0265\0320\0275\0320\0270\0321\0217 \0320\0270\0320\0274\0321\0221\0320\0275 \0320\0264\0320\0276 \0320\0267\0320\0260\0320\0277\0321\0203\0321\0201\0320\0272\0320\0260 \0320\0276\0321\0201\0320\0275\0320\0276\0320\0262\0320\0275\0320\0276\0320\0271 DNS-\0320\0273\0320\0276\0320\0263\0320\0270\0320\0272\0320\0270.' >> "$file" || return 1
    cat >> "$file" <<'EOF'
  default-nameserver:
    - 1.1.1.1
    - 8.8.8.8

EOF
    utf8_print_install '  # \0320\0236\0321\0201\0320\0275\0320\0276\0320\0262\0320\0275\0321\0213\0320\0265 DNS-\0321\0201\0320\0265\0321\0200\0320\0262\0320\0265\0321\0200\0321\0213.' >> "$file" || return 1
    cat >> "$file" <<'EOF'
  nameserver:
    - 1.1.1.1
    - 8.8.8.8

EOF
    utf8_print_install '# \0320\0222\0320\0270\0321\0200\0321\0202\0321\0203\0320\0260\0320\0273\0321\0214\0320\0275\0321\0213\0320\0271 TUN-\0320\0270\0320\0275\0321\0202\0320\0265\0321\0200\0321\0204\0320\0265\0320\0271\0321\0201. \0320\0255\0321\0202\0320\0270 \0320\0277\0320\0260\0321\0200\0320\0260\0320\0274\0320\0265\0321\0202\0321\0200\0321\0213 \0320\0272\0320\0276\0320\0275\0321\0202\0321\0200\0320\0276\0320\0273\0320\0270\0321\0200\0321\0203\0320\0265\0321\0202 GoshaCrash.' >> "$file" || return 1
    cat >> "$file" <<EOF
tun:
  enable: true
  stack: $TUN_STACK
  device: tun0

EOF
    utf8_print_install '  # \0320\0220\0320\0262\0321\0202\0320\0276\0320\0274\0320\0260\0321\0202\0320\0270\0321\0207\0320\0265\0321\0201\0320\0272\0320\0270 \0321\0201\0320\0276\0320\0267\0320\0264\0320\0260\0320\0262\0320\0260\0321\0202\0321\0214 \0321\0201\0320\0270\0321\0201\0321\0202\0320\0265\0320\0274\0320\0275\0321\0213\0320\0265 \0320\0274\0320\0260\0321\0200\0321\0210\0321\0200\0321\0203\0321\0202\0321\0213 \0320\0264\0320\0273\0321\0217 TUN.' >> "$file" || return 1
    printf '  auto-route: %s\n\n' "$cfg_auto_route" >> "$file" || return 1
    utf8_print_install '  # \0320\0220\0320\0262\0321\0202\0320\0276\0320\0274\0320\0260\0321\0202\0320\0270\0321\0207\0320\0265\0321\0201\0320\0272\0320\0270 \0320\0275\0320\0260\0321\0201\0321\0202\0321\0200\0320\0260\0320\0270\0320\0262\0320\0260\0321\0202\0321\0214 \0320\0277\0321\0200\0320\0276\0320\0267\0321\0200\0320\0260\0321\0207\0320\0275\0321\0213\0320\0271 TCP/UDP-\0320\0277\0320\0265\0321\0200\0320\0265\0321\0205\0320\0262\0320\0260\0321\0202 \0320\0275\0320\0260 Linux.' >> "$file" || return 1
    printf '  auto-redirect: %s\n\n' "$cfg_auto_redirect" >> "$file" || return 1
    utf8_print_install '  # \0320\0220\0320\0262\0321\0202\0320\0276\0320\0274\0320\0260\0321\0202\0320\0270\0321\0207\0320\0265\0321\0201\0320\0272\0320\0270 \0320\0276\0320\0277\0321\0200\0320\0265\0320\0264\0320\0265\0320\0273\0321\0217\0321\0202\0321\0214 \0321\0204\0320\0270\0320\0267\0320\0270\0321\0207\0320\0265\0321\0201\0320\0272\0320\0270\0320\0271 \0320\0270\0320\0275\0321\0202\0320\0265\0321\0200\0321\0204\0320\0265\0320\0271\0321\0201 \0320\0262\0321\0213\0321\0205\0320\0276\0320\0264\0320\0260 \0320\0262 \0320\0270\0320\0275\0321\0202\0320\0265\0321\0200\0320\0275\0320\0265\0321\0202.' >> "$file" || return 1
    printf '  auto-detect-interface: %s\n\n' "$cfg_auto_detect" >> "$file" || return 1
    utf8_print_install '  # \0320\0237\0320\0265\0321\0200\0320\0265\0321\0205\0320\0262\0320\0260\0321\0202\0321\0213\0320\0262\0320\0260\0321\0202\0321\0214 \0320\0276\0320\0261\0321\0213\0321\0207\0320\0275\0321\0213\0320\0265 DNS-\0320\0267\0320\0260\0320\0277\0321\0200\0320\0276\0321\0201\0321\0213 \0320\0272\0320\0273\0320\0270\0320\0265\0320\0275\0321\0202\0320\0276\0320\0262 \0321\0207\0320\0265\0321\0200\0320\0265\0320\0267 TUN.' >> "$file" || return 1
    cat >> "$file" <<'EOF'
  dns-hijack:
    - any:53
    - tcp://any:53

EOF
    utf8_print_install '# \0320\0241\0321\0202\0320\0260\0321\0200\0321\0202\0320\0276\0320\0262\0320\0276\0320\0265 \0320\0277\0321\0200\0320\0260\0320\0262\0320\0270\0320\0273\0320\0276-\0320\0267\0320\0260\0320\0263\0320\0273\0321\0203\0321\0210\0320\0272\0320\0260: \0320\0264\0320\0276 \0320\0264\0320\0276\0320\0261\0320\0260\0320\0262\0320\0273\0320\0265\0320\0275\0320\0270\0321\0217 \0320\0277\0321\0200\0320\0276\0320\0272\0321\0201\0320\0270 \0320\0262\0320\0265\0321\0201\0321\0214 \0321\0202\0321\0200\0320\0260\0321\0204\0320\0270\0320\0272 \0320\0270\0320\0264\0321\0221\0321\0202 \0320\0275\0320\0260\0320\0277\0321\0200\0321\0217\0320\0274\0321\0203\0321\0216.' >> "$file" || return 1
    cat >> "$file" <<'EOF'
rules:
  - MATCH,DIRECT
EOF
    if test "$ROUTING_MODE" = manual; then
        printf '\n' >> "$file" || return 1
        printf 'routing-mark: 9012\n' >> "$file" || return 1
    fi

    # Keep the generated UTF-8 comments intact.  The nano wrapper and gc edit
    # always run nano with a real UTF-8 locale on the tested ASUSWRT/Optware
    # stack, so Cyrillic comments no longer need to be stripped or rewritten.
    yaml_remove_top_key "$gbc_file" secret || return 1
    chmod 600 "$gbc_file" 2>/dev/null || true
    return 0
}

install_configs(){
    test -n "$ACTIVE_CONFIG" || ACTIVE_CONFIG="$BASE/config.yaml"

    if test "$RESET_CONFIG" = 1; then
        old_config=""
        if test -f "$ACTIVE_CONFIG"; then
            old_config="$ACTIVE_CONFIG"
        elif test -f "$BASE/config-legacy.yaml"; then
            old_config="$BASE/config-legacy.yaml"
        fi
        if test -n "$old_config"; then
            CONFIG_ROLLBACK_TMP="$TMP_ROOT/config-before-reset.yaml"
            cp -f "$old_config" "$CONFIG_ROLLBACK_TMP" || return 1
            CONFIG_MIGRATION_PENDING="1"
        fi
        rm -f "$ACTIVE_CONFIG" "$BASE/config-legacy.yaml" 2>/dev/null || true
        generate_base_config "$ACTIVE_CONFIG" || { fail "Не удалось сгенерировать новый config.yaml"; return 1; }
        chmod 600 "$ACTIVE_CONFIG" 2>/dev/null || true
        mkdir -p "$BASE/state" 2>/dev/null || true
        printf '%s\n' generated-stub > "$BASE/state/config-origin" 2>/dev/null || true
        say "config.yaml сброшен явно: создана новая UTF-8 заглушка (старый файл хранится только временно до успешной проверки)"
        return 0
    fi

    # Migration from GoshaCrash <= 3.5.x: move the old active config to the
    # unified name instead of creating a second persistent copy.
    if test ! -f "$ACTIVE_CONFIG" && test -f "$BASE/config-legacy.yaml"; then
        mv -f "$BASE/config-legacy.yaml" "$ACTIVE_CONFIG" || return 1
        say "Legacy-конфиг перенесён в единый $ACTIVE_CONFIG"
    fi

    if test ! -f "$ACTIVE_CONFIG"; then
        generate_base_config "$ACTIVE_CONFIG" || { fail "Не удалось сгенерировать базовый config.yaml"; return 1; }
        utf8_validate_file_install "$ACTIVE_CONFIG"
        utf8_rc=$?
        if test "$utf8_rc" = 1; then
            fail "Внутренняя ошибка: только что созданный config.yaml не является корректным UTF-8"
            return 1
        fi
        mkdir -p "$BASE/state" 2>/dev/null || true
        printf '%s\n' generated-stub > "$BASE/state/config-origin" 2>/dev/null || true
        say "Базовый config.yaml создан install.sh для $PLATFORM (routing=$ROUTING_MODE, tun.stack=$TUN_STACK)"
        warn "VPN ещё не настроен: добавь свои proxy/rules и выполни gc restart"
    else
        CONFIG_ROLLBACK_TMP="$TMP_ROOT/config-before-migration.yaml"
        cp -f "$ACTIVE_CONFIG" "$CONFIG_ROLLBACK_TMP" || return 1
        CONFIG_MIGRATION_PENDING="1"
        say "Существующий $ACTIVE_CONFIG сохранён; UTF-8 комментарии и YAML-данные пользователя сохраняются"

        # Normalize only Windows CRLF -> LF.  Do not remove or rewrite UTF-8
        # comments: nano is launched with LANG/LC_ALL=en_US.UTF-8.
        normalized="$TMP_ROOT/config-normalized.$$"
        if ! LC_ALL=C tr -d '\015' < "$ACTIVE_CONFIG" > "$normalized"; then
            cp -f "$CONFIG_ROLLBACK_TMP" "$ACTIVE_CONFIG" 2>/dev/null || true
            CONFIG_MIGRATION_PENDING="0"
            rm -f "$normalized" 2>/dev/null || true
            fail "Не удалось нормализовать окончания строк config.yaml"
            return 1
        fi
        mv -f "$normalized" "$ACTIVE_CONFIG" || return 1

        if ! configure_routing_in_config "$ACTIVE_CONFIG"; then
            cp -f "$CONFIG_ROLLBACK_TMP" "$ACTIVE_CONFIG" 2>/dev/null || true
            CONFIG_MIGRATION_PENDING="0"
            fail "Не удалось безопасно нормализовать config.yaml"
            return 1
        fi

        chmod 600 "$ACTIVE_CONFIG" 2>/dev/null || true
    fi
}

mihomo_config_test_install(){
    mct_file="$1"
    mct_log="$2"
    test -x "$BASE/bin/mihomo" || return 2
    "$BASE/bin/mihomo" -t -d "$BASE" -f "$mct_file" >"$mct_log" 2>&1
}

config_test_has_utf8_error_install(){
    ctu_log="$1"
    grep -Eiq 'invalid[^[:cntrl:]]*UTF-8|UTF-8[^[:cntrl:]]*invalid|invalid trailing UTF-8 octet|invalid UTF-8|invalid utf-8' "$ctu_log" 2>/dev/null
}

config_has_user_payload_install(){
    chp_file="$1"
    if LC_ALL=C awk '
      /^[[:space:]]*(proxies|proxy-groups|proxy-providers|rule-providers):[[:space:]]*/ {found=1; exit}
      END{exit found ? 0 : 1}
    ' "$chp_file" >/dev/null 2>&1; then return 0; fi
    LC_ALL=C awk '
      BEGIN{inrules=0; user=0}
      /^rules:[[:space:]]*($|#)/ {inrules=1; next}
      inrules && /^[^[:space:]]/ {inrules=0}
      inrules && /^[[:space:]]*-[[:space:]]*/ {
        line=$0; sub(/^[[:space:]]*-[[:space:]]*/, "", line); sub(/[[:space:]]*#.*/, "", line); gsub(/[[:space:]]/, "", line)
        if (line != "MATCH,DIRECT" && line != "") user=1
      }
      END{exit user ? 0 : 1}
    ' "$chp_file" >/dev/null 2>&1
}

config_looks_like_factory_stub_install(){
    cls_file="$1"
    config_has_user_payload_install "$cls_file" && return 1
    LC_ALL=C grep -q 'MATCH,DIRECT' "$cls_file" 2>/dev/null && return 0
    LC_ALL=C grep -q 'GoshaCrash' "$cls_file" 2>/dev/null && return 0
    return 1
}

rebuild_factory_stub_install(){
    rfs_tmp="$TMP_ROOT/config-factory-clean.$$"
    rfs_log="$TMP_ROOT/config-factory-clean.log.$$"
    rm -f "$rfs_tmp" "$rfs_log" 2>/dev/null || true
    generate_base_config "$rfs_tmp" || return 1
    if ! mihomo_config_test_install "$rfs_tmp" "$rfs_log"; then
        cat "$rfs_log" >&2 2>/dev/null || true
        rm -f "$rfs_tmp" "$rfs_log" 2>/dev/null || true
        fail "Внутренняя ошибка: новая стартовая заглушка не проходит mihomo -t"
        return 1
    fi
    mv -f "$rfs_tmp" "$ACTIVE_CONFIG" || return 1
    chmod 600 "$ACTIVE_CONFIG" 2>/dev/null || true
    mkdir -p "$BASE/state" 2>/dev/null || true
    printf '%s\n' generated-stub > "$BASE/state/config-origin" 2>/dev/null || true
    CONFIG_MIGRATION_PENDING="0"
    test -n "$CONFIG_ROLLBACK_TMP" && rm -f "$CONFIG_ROLLBACK_TMP" 2>/dev/null || true
    rm -f "$rfs_log" 2>/dev/null || true
    ok "Повреждённая стартовая заглушка автоматически создана заново в UTF-8"
    return 0
}

authoritative_config_preflight(){
    acp_log="$TMP_ROOT/config-mihomo-preflight.$$"
    if mihomo_config_test_install "$ACTIVE_CONFIG" "$acp_log"; then
        rm -f "$acp_log" 2>/dev/null || true
        return 0
    fi

    if config_test_has_utf8_error_install "$acp_log"; then
        # A broken factory DIRECT placeholder has no user VPN payload, so repair
        # it automatically. Real proxies/groups/providers/custom rules are never overwritten.
        if config_looks_like_factory_stub_install "$ACTIVE_CONFIG"; then
            warn "Стартовая заглушка повреждена; создаю чистый config.yaml заново"
            rm -f "$acp_log" 2>/dev/null || true
            rebuild_factory_stub_install && return 0
            return 1
        fi
        data_only="$TMP_ROOT/config-data-only-test.$$"
        data_log="$acp_log.data"
        strip_whole_line_comments_install "$ACTIVE_CONFIG" "$data_only" || true
        if test -s "$data_only"; then
            if mihomo_config_test_install "$data_only" "$data_log"; then
                cat "$acp_log" >&2 2>/dev/null || true
                rm -f "$acp_log" "$data_log" "$data_only" 2>/dev/null || true
                fail "Внутренняя ошибка: YAML без комментариев валиден, но русские комментарии в итоговом config.yaml повреждены"
                fail "Установка остановлена: комментарии должны оставаться нормальным UTF-8"
                return 1
            fi
            if config_test_has_utf8_error_install "$data_log"; then
                cat "$acp_log" >&2 2>/dev/null || true
                rm -f "$acp_log" "$data_log" "$data_only" 2>/dev/null || true
                fail "config.yaml действительно содержит невалидный UTF-8 внутри YAML-данных"
                fail "Повреждены пользовательские YAML-данные; автоматическая замена отключена, чтобы не потерять настройки"
                return 1
            fi
            # Do not mislabel a second, unrelated Mihomo validation failure as
            # bad UTF-8.  Surface the real parser/semantic error instead.
            cat "$data_log" >&2 2>/dev/null || true
            rm -f "$acp_log" "$data_log" "$data_only" 2>/dev/null || true
            fail "После удаления комментариев Mihomo отклонил YAML уже по другой причине; смотри ошибку выше"
            return 1
        fi
        cat "$acp_log" >&2 2>/dev/null || true
        rm -f "$acp_log" "$data_log" "$data_only" 2>/dev/null || true
        fail "Не удалось построить временный config.yaml без комментариев для UTF-8 диагностики"
        return 1
    fi

    cat "$acp_log" >&2 2>/dev/null || true
    rm -f "$acp_log" 2>/dev/null || true
    fail "Mihomo отклонил config.yaml"
    return 1
}

json_asset_urls(){
    file="$1"
    grep '"browser_download_url"' "$file" 2>/dev/null |
        sed -n 's#.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*#\1#p' |
        tr -d '\r'
}

pinned_official_mihomo_url(){
    # rc40-test2 deliberately pins the modern core. A router install must not silently
    # switch CPU binary just because GitHub "latest" changed between runs.
    MIHOMO_VERSION_SELECTED="$OFFICIAL_MIHOMO_VERSION"
    printf '%s\n' "https://github.com/MetaCubeX/mihomo/releases/download/$OFFICIAL_MIHOMO_VERSION/mihomo-linux-$MIHOMO_TARGET-$OFFICIAL_MIHOMO_VERSION.gz"
}

legacy_mihomo_urls(){
    # The legacy build is pinned and stored in the project release. Avoid the
    # GitHub API here: direct asset URLs are faster and predictable on ASUSWRT.
    printf '%s\n' \
        "https://github.com/$REPO/releases/download/$LEGACY_MIHOMO_TAG/mihomo-linux-armv5-gvisor-$LEGACY_MIHOMO_VERSION.gz" \
        "https://github.com/$REPO/releases/download/$LEGACY_MIHOMO_TAG/mihomo-linux-armv5-with_gvisor.gz" \
        "https://github.com/$REPO/releases/download/$LEGACY_MIHOMO_TAG/mihomo-linux-armv5-with-gvisor.gz"
}



mihomo_elf_header(){
    file="$1"
    od_bin=""
    dd_bin=""
    for p in /usr/bin/od /bin/od /usr/sbin/od /sbin/od "$DM_ROOT/bin/od" /opt/bin/od /tmp/opt/bin/od; do
        test -x "$p" && { od_bin="$p"; break; }
    done
    for p in /bin/dd /usr/bin/dd /sbin/dd /usr/sbin/dd "$DM_ROOT/bin/dd" /opt/bin/dd /tmp/opt/bin/dd; do
        test -x "$p" && { dd_bin="$p"; break; }
    done
    test -n "$od_bin" && test -n "$dd_bin" || return 2
    "$dd_bin" if="$file" bs=1 count=20 2>/dev/null | "$od_bin" -An -tx1 2>/dev/null | tr -d ' \n\r'
}

validate_mihomo_elf_target(){
    file="$1"
    hex="$(mihomo_elf_header "$file")"
    rc=$?
    # The runtime execution check below is still authoritative if this very old
    # BusyBox lacks od/dd. Do not introduce a new hard dependency just for ELF inspection.
    test "$rc" -eq 2 && return 0
    test "$rc" -eq 0 || { fail "Не удалось прочитать ELF-заголовок Mihomo"; return 1; }

    magic="$(printf '%s' "$hex" | cut -c 1-8)"
    class="$(printf '%s' "$hex" | cut -c 9-10)"
    machine="$(printf '%s' "$hex" | cut -c 37-40)"
    test "$magic" = 7f454c46 || {
        fail "Скачанный Mihomo не ELF-файл (header=${hex:-empty})"
        return 1
    }

    case "$MIHOMO_TARGET" in
        armv5|armv7)
            test "$class" = 01 && test "$machine" = 2800 || {
                fail "Mihomo architecture mismatch: нужен 32-bit ARM ($MIHOMO_TARGET), ELF class=$class machine=$machine"
                return 1
            }
            ;;
        arm64|aarch64)
            test "$class" = 02 && test "$machine" = b700 || {
                fail "Mihomo architecture mismatch: нужен ARM64, ELF class=$class machine=$machine"
                return 1
            }
            ;;
        amd64|amd64-compatible|x86_64)
            test "$class" = 02 && test "$machine" = 3e00 || {
                fail "Mihomo architecture mismatch: нужен x86_64, ELF class=$class machine=$machine"
                return 1
            }
            ;;
    esac
    return 0
}

validate_downloaded_mihomo(){
    archive="$1"; newbin="$2"
    "$GZIP_BIN" -t "$archive" >/dev/null 2>&1 || { fail "Архив Mihomo повреждён"; return 1; }
    "$GZIP_BIN" -dc "$archive" > "$newbin" || { fail "Не удалось распаковать Mihomo"; return 1; }
    validate_mihomo_elf_target "$newbin" || { rm -f "$newbin"; return 1; }
    chmod 755 "$newbin" || return 1
    out="$("$newbin" -v 2>&1)" || { printf '%s\n' "$out" >&2; fail "Mihomo не запускается на этой архитектуре"; rm -f "$newbin"; return 1; }
    printf '%s\n' "$out" | grep -qi 'mihomo' || { printf '%s\n' "$out" >&2; fail "Скачанный файл не похож на Mihomo"; return 1; }
    if test "$MIHOMO_TARGET" = armv5; then
        printf '%s\n' "$out" | grep -Fq 'Use tags: with_gvisor' || { printf '%s\n' "$out" >&2; fail "Legacy-профилю нужна сборка Mihomo with_gvisor"; return 1; }
    fi
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
        MIHOMO_URL_SELECTED="$(pinned_official_mihomo_url)" || return 1
        MIHOMO_VERSION_SELECTED="$(printf '%s\n' "$MIHOMO_URL_SELECTED" | sed -n 's#.*/download/\([^/]*\)/.*#\1#p')"
        test -n "$MIHOMO_VERSION_SELECTED" || MIHOMO_VERSION_SELECTED="$OFFICIAL_MIHOMO_FALLBACK"
        say "Скачиваю официальный Mihomo $MIHOMO_VERSION_SELECTED для $MIHOMO_TARGET"
        fetch "$MIHOMO_URL_SELECTED" "$archive" || { fail "Не удалось скачать $MIHOMO_URL_SELECTED"; return 1; }
        validate_downloaded_mihomo "$archive" "$newbin" || return 1
    fi

    if test -x "$BASE/bin/mihomo"; then
        existing_out="$("$BASE/bin/mihomo" -v 2>&1)"
        if ! printf '%s\n' "$existing_out" | grep -qi 'mihomo'; then
            warn "Старый Mihomo повреждён/несовместим; новый бинарник уже проверен и заменит его"
        fi
    fi
    mv -f "$newbin" "$BASE/bin/mihomo" || return 1
    chmod 755 "$BASE/bin/mihomo" || return 1
    installed_out="$("$BASE/bin/mihomo" -v 2>&1)" || {
        fail "Установленный Mihomo не запускается после активации"
        return 1
    }
    printf '%s\n' "$installed_out" > "$BASE/state/mihomo-version.txt" || return 1
}

find_ui_root(){
    unpack="$1"
    for p in "$unpack/index.html" "$unpack"/*/index.html "$unpack"/*/*/index.html; do
        test -f "$p" && { dirname "$p"; return 0; }
    done
    p="$(find "$unpack" -name index.html -print 2>/dev/null | head -n 1)"
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
    ui_new="$BASE/.ui-new.$$"
    ui_old="$BASE/.ui-old.$$"
    selected=""
    last_url=""

    # rc27/rc28 could leave project-owned staging/previous UI directories.
    # Recover an interrupted atomic swap first, then remove obsolete residue.
    if test ! -s "$BASE/ui/index.html"; then
        for old in "$BASE"/.ui-old.*; do
            test -s "$old/index.html" || continue
            rm -rf "$BASE/ui"
            mv "$old" "$BASE/ui" 2>/dev/null && break
        done
    fi
    for old in "$BASE"/.ui-old.*; do
        test -d "$old" && rm -rf "$old"
    done
    for staged in "$BASE"/.ui-new.*; do
        test -d "$staged" && rm -rf "$staged"
    done
    rm -rf "$BASE/ui.previous" "$BASE/ui.new" "$ui_new" "$ui_old"

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

    if test -d "$BASE/ui"; then
        mv "$BASE/ui" "$ui_old" || {
            rm -rf "$ui_new"
            fail "Не удалось подготовить замену Zashboard"
            return 1
        }
    fi
    if ! mv "$ui_new" "$BASE/ui"; then
        test -d "$ui_old" && mv "$ui_old" "$BASE/ui" 2>/dev/null || true
        rm -rf "$ui_new"
        fail "Не удалось активировать Zashboard"
        return 1
    fi
    rm -rf "$ui_old" "$unpack" "$archive"
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
resolve_gc_base(){
  if /bin/busybox test -s /tmp/goshacrash-base; then
    b="$(cat /tmp/goshacrash-base 2>/dev/null)"
    /bin/busybox test -x "$b/goshacrash.sh" && { printf '%s\n' "$b"; return 0; }
  fi
  count=0
  found=""
  for b in /tmp/mnt/*/goshacrash; do
    /bin/busybox test -x "$b/goshacrash.sh" || continue
    count=$((count + 1))
    found="$b"
  done
  /bin/busybox test "$count" -eq 1 || return 1
  printf '%s\n' "$found"
}
BASE="$(resolve_gc_base)" || { echo "GoshaCrash: не удалось однозначно найти USB" >&2; exit 1; }
printf '%s\n' "$BASE" > /tmp/goshacrash-base 2>/dev/null || true
GOSHACRASH_BASE="$BASE"
export GOSHACRASH_BASE
exec /bin/sh "$BASE/goshacrash.sh" "$@"
WRAP
    chmod 755 "$dst"
}

write_nano_wrapper(){
    dst="$1"
    cat > "$dst" <<'WRAP'
#!/bin/sh
resolve_gc_base(){
  if /bin/busybox test -s /tmp/goshacrash-base; then
    b="$(cat /tmp/goshacrash-base 2>/dev/null)"
    /bin/busybox test -x "$b/goshacrash.sh" && { printf '%s\n' "$b"; return 0; }
  fi
  count=0; found=""
  for b in /tmp/mnt/*/goshacrash; do
    /bin/busybox test -x "$b/goshacrash.sh" || continue
    count=$((count + 1)); found="$b"
  done
  /bin/busybox test "$count" -eq 1 || return 1
  printf '%s\n' "$found"
}
BASE="$(resolve_gc_base)" || { echo "nano: GoshaCrash USB не найден" >&2; exit 1; }
USB_MOUNT="$(dirname "$BASE")"
DM_ROOT=""
for d in "$USB_MOUNT/asusware.arm" "$USB_MOUNT/asusware.arm64" "$USB_MOUNT/asusware"; do
  /bin/busybox test -d "$d" && { DM_ROOT="$d"; break; }
done
/bin/busybox test -n "$DM_ROOT" || { echo "nano: Download Master не найден на $USB_MOUNT" >&2; exit 1; }

# Tested fix for Optware nano 3.1 on BT10: keep the editor in a UTF-8 locale.
# These values are also persisted by install_hooks(), but the wrapper exports
# them explicitly so nano works immediately and independently of SSH profile loading.
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
TERM=${GOSHACRASH_EDITOR_TERM:-${TERM:-xterm-256color}}
LD_LIBRARY_PATH="/tmp/goshacrash-opt/lib:$DM_ROOT/lib:/lib:/usr/lib"
export LANG LC_ALL TERM LD_LIBRARY_PATH
for p in "$DM_ROOT/bin/nano" "$DM_ROOT/sbin/nano" /tmp/opt/bin/nano /opt/bin/nano; do
  /bin/busybox test -x "$p" && exec "$p" "$@"
done
echo "nano не найден. Установи nano через пакетный менеджер Download Master" >&2
exit 1
WRAP
    chmod 755 "$dst"
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
# GoshaCrash Download Master bridge 3.10.2-rc40-test2
unset LD_LIBRARY_PATH 2>/dev/null || true
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
mount="$(df "$(readlink -f "$0")" | grep -v '^Filesystem' | head -n 1 | awk '{print $1, $6}')"
device="$(echo "$mount" | awk '{print $1}')"
mount="$(echo "$mount" | awk '{print $2}')"
case "$1" in
  start)
    printf '[%s] [dm-bridge pid=%s] start device=%s mount=%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$$" "$device" "$mount" >> /tmp/goshacrash-coldboot.log 2>/dev/null || true
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
    # USB shutdown must be synchronous.  Returning before GoshaCrash has
    # stopped Mihomo/watchdog and released /opt creates a race with ASUS fsck
    # and physical unmount of the same device.
    if test -x /jffs/scripts/usb-umount-script; then
      /jffs/scripts/usb-umount-script "$device" "$mount"
      exit $?
    fi
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
    # Keep GoshaCrash-owned persistent data inside $BASE. Outside it we leave
    # only the standard ASUS hook/wrapper files that firmware actually calls.
    mkdir -p /jffs/scripts /jffs/configs /jffs/etc "$DM_ROOT/bin" "$DM_ROOT/etc/init.d" || return 1

    cat > /jffs/scripts/usb-mount-script <<'HOOK'
#!/bin/sh
# GoshaCrash USB hook 3.10.2-rc40-test2
unset LD_LIBRARY_PATH 2>/dev/null || true
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
MOUNT_POINT="$2"
BASE="$MOUNT_POINT/goshacrash"
TRACE="$BASE/logs/coldboot.log"
TMP_TRACE=/tmp/goshacrash-coldboot.log
WAITED=0

trace(){
  printf '[%s] [usb-mount pid=%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$$" "$*" >> "$TRACE" 2>/dev/null || true
}

test -x "$BASE/goshacrash.sh" || exit 0
printf '%s\n' "$BASE" > /tmp/goshacrash-base 2>/dev/null || true

mkdir -p "$BASE/logs" "$BASE/run" "$BASE/state" 2>/dev/null || true
if test -s "$TMP_TRACE"; then
  cat "$TMP_TRACE" >> "$TRACE" 2>/dev/null || true
  : > "$TMP_TRACE" 2>/dev/null || true
fi

# Keep the persistent trace bounded.
if test -f "$TRACE"; then
  TRACE_SIZE="$(wc -c < "$TRACE" 2>/dev/null)"
  case "$TRACE_SIZE" in ''|*[!0-9]*) TRACE_SIZE=0;; esac
  if test "$TRACE_SIZE" -gt 131072; then
    tail -n 200 "$TRACE" > "$TRACE.tmp.$$" 2>/dev/null && mv -f "$TRACE.tmp.$$" "$TRACE" 2>/dev/null || true
    rm -f "$TRACE.tmp.$$" 2>/dev/null || true
  fi
fi

trace "entered device=$1 mount=$MOUNT_POINT"

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

while test ! -x "$BASE/goshacrash.sh"; do
  if test "$WAITED" -ge 300; then
    trace "timeout waiting for controller"
    exit 0
  fi
  sleep 5
  WAITED=$((WAITED + 5))
done

BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
UPTIME="$(cat /proc/uptime 2>/dev/null)"
trace "controller ready after ${WAITED}s dm=${DM:-none} boot_id=${BOOT_ID:-unknown} uptime=${UPTIME:-unknown}"
date '+%Y-%m-%d %H:%M:%S' > "$BASE/state/autostart-hook-ran" 2>/dev/null || true
printf '[%s] autostart hook rc40-test2: USB/controller ready; launching boot\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" >> "$BASE/logs/boot.log" 2>/dev/null || true

NOHUP=""
for p in /usr/bin/nohup /bin/nohup /usr/sbin/nohup /sbin/nohup; do
  test -x "$p" && { NOHUP="$p"; break; }
done
if test -n "$NOHUP"; then
  GOSHACRASH_BASE="$BASE" "$NOHUP" /bin/sh "$BASE/goshacrash.sh" boot </dev/null >> "$BASE/logs/boot.log" 2>&1 &
else
  GOSHACRASH_BASE="$BASE" /bin/sh "$BASE/goshacrash.sh" boot </dev/null >> "$BASE/logs/boot.log" 2>&1 &
fi
trace "boot worker launched pid=$!"
exit 0
HOOK
    chmod 755 /jffs/scripts/usb-mount-script || return 1

    cat > /jffs/scripts/usb-umount-script <<'HOOK'
#!/bin/sh
# GoshaCrash USB unmount hook 3.10.2-rc40-test2
unset LD_LIBRARY_PATH 2>/dev/null || true
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
MOUNT_POINT="$2"
BASE="$MOUNT_POINT/goshacrash"
TRACE=/tmp/goshacrash-coldboot.log
RC=0
trace(){
  printf '[%s] [usb-umount pid=%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$$" "$*" >> "$TRACE" 2>/dev/null || true
}

if test -x "$BASE/goshacrash.sh"; then
  trace "entered device=$1 mount=$MOUNT_POINT"
  GOSHACRASH_BASE="$BASE" /bin/sh "$BASE/goshacrash.sh" service-stop >/dev/null 2>&1 || {
    trace "service-stop returned nonzero"
    RC=1
  }
fi

if test -f /tmp/goshacrash-opt-bind.state; then
  OPTDM="$(cat /tmp/goshacrash-opt-bind.state 2>/dev/null)"
  case "$OPTDM" in
    "$MOUNT_POINT"/*)
      UNMOUNTED=0
      for u in /bin/umount /sbin/umount /usr/bin/umount /usr/sbin/umount; do
        test -x "$u" || continue
        if "$u" /opt >/dev/null 2>&1; then
          UNMOUNTED=1
          trace "/opt released"
        else
          trace "ERROR: /opt is still busy; refusing lazy unmount"
          RC=1
        fi
        break
      done
      if test "$UNMOUNTED" = 1; then
        rm -f /tmp/goshacrash-opt-bind.state 2>/dev/null || true
      fi
      ;;
  esac
fi

rm -f /tmp/goshacrash-base 2>/dev/null || true
exit "$RC"
HOOK
    chmod 755 /jffs/scripts/usb-umount-script || return 1

    rm -f /jffs/scripts/gc /jffs/scripts/nano "$DM_ROOT/bin/gc" /opt/bin/gc 2>/dev/null || true
    write_command_wrapper /jffs/scripts/gc
    write_nano_wrapper /jffs/scripts/nano
    write_command_wrapper "$DM_ROOT/bin/gc"
    test -d /opt/bin && test -w /opt/bin && write_command_wrapper /opt/bin/gc 2>/dev/null || true

    # Old rc23-rc26 used a custom /jffs/addons/goshacrash directory only to
    # store base/start/trace. rc40-test2 no longer needs it; remove our own residue.
    rm -rf /jffs/addons/goshacrash 2>/dev/null || true
    grep -Fq 'exec /bin/busybox test "$@"' /jffs/scripts/test 2>/dev/null && rm -f /jffs/scripts/test 2>/dev/null || true
    grep -Fq "exec /bin/busybox '['" /jffs/scripts/'[' 2>/dev/null && rm -f /jffs/scripts/'[' 2>/dev/null || true

    add_once /jffs/etc/profile 'export PATH="/jffs/scripts:/opt/bin:/opt/sbin:/tmp/opt/bin:/tmp/opt/sbin:$PATH"'
    add_once /jffs/configs/profile.add 'export PATH="/jffs/scripts:/opt/bin:/opt/sbin:/tmp/opt/bin:/tmp/opt/sbin:$PATH"'

    # Persist the locale across reboot/new SSH sessions.  Both locations are
    # maintained because ASUSWRT variants source different profile hooks.
    add_once /jffs/etc/profile 'export LANG=en_US.UTF-8'
    add_once /jffs/etc/profile 'export LC_ALL=en_US.UTF-8'
    add_once /jffs/configs/profile.add 'export LANG=en_US.UTF-8'
    add_once /jffs/configs/profile.add 'export LC_ALL=en_US.UTF-8'

    remove_pre3712_autostart
    install_stock_usb_mount_bridge || return 1
    # Do not erase runtime/boot logs during an upgrade.  They are the only
    # evidence of cold-boot failures on the router and runtime rotates them.
    ok "Автозапуск установлен для stock ASUSWRT; служебные данные остаются внутри $BASE"
}

verify_shell_compat(){
    busybox="/bin/busybox"

    "$busybox" test -x "$busybox" >/dev/null 2>&1 || {
        fail "Shell compatibility: /bin/busybox недоступен"
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
    "$busybox" test -x /jffs/scripts/gc >/dev/null 2>&1 || {
        fail "Shell compatibility: /jffs/scripts/gc не создан"
        return 1
    }
    GOSHACRASH_BASE="$BASE" /bin/sh "$BASE/goshacrash.sh" version >/dev/null 2>&1 || {
        fail "Shell compatibility: controller не запускается через /bin/sh"
        return 1
    }

    say "Shell compatibility: BusyBox test/[ + controller OK"
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
CONFIG_REL='config.yaml'
GCNET_REL='bin/gcnet'
DM_LAYOUT='${DM_ROOT##*/}'
ROUTER_MODEL='$(nvram_get productid)'
ROUTER_ARCH='$(uname -m 2>/dev/null)'
ROUTER_KERNEL='$(uname -r 2>/dev/null)'
INSTALLED_BY='$INSTALLER_VERSION'
EOF
    chmod 600 "$BASE/state/platform.env" 2>/dev/null || true

    # Human-readable last-known identity only; runtime never trusts it after reboot.
    cat > "$BASE/state/storage.last" <<EOF
USB_DEVICE=$USB_DEVICE
USB_DISK=$USB_DISK
USB_MOUNT=$USB_MOUNT
USB_NAME=$USB_NAME
USB_FS=$USB_FS
DM_ROOT=$DM_ROOT
INSTALLER_PATH=$INSTALLER_PATH
EOF
    chmod 600 "$BASE/state/storage.last" 2>/dev/null || true
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

    case "${1:-}" in
        --help|-h)
            echo "GoshaCrash installer $INSTALLER_VERSION"
            echo
            echo "Использование:"
            echo "  /bin/sh /tmp/mnt/<mount>/install.sh                 установить/обновить GoshaCrash"
            echo "  /bin/sh /tmp/mnt/<mount>/install.sh --reset-config  сбросить config.yaml"
            echo "  /bin/sh /tmp/mnt/<mount>/install.sh --help          эта справка"
            echo
            echo "Форматирование USB удалено из install.sh и выполняется отдельной программой."
            return 0
            ;;
        --reset-config)
            test "$#" -eq 1 || { fail "Использование: /bin/sh install.sh --reset-config"; return 1; }
            RESET_CONFIG="1"
            ;;
        '')
            ;;
        *)
            fail "Неизвестный аргумент: $1. Используй --help"
            return 1
            ;;
    esac

    if test "$RESET_CONFIG" = 1; then
        test "$#" -eq 1 || return 1
    else
        test "$#" -eq 0 || return 1
    fi
    acquire_lock || return 1

    verify_asuswrt || return 1
    detect_installer_usb || return 1
    legacy_preflight_before_dm || return 1
    find_download_master || return 1
    BASE="$USB_MOUNT/goshacrash"
    mkdir -p "$TMP_ROOT" "$BASE/bin" "$BASE/logs" "$BASE/run" "$BASE/state" || return 1
    # Keep the persistent tree minimal. Remove only empty legacy directories;
    # never delete existing user files automatically.
    rmdir "$BASE/rulesets" "$BASE/proxies" "$BASE/backups" 2>/dev/null || true
    save_install_log

    say "GoshaCrash installer $INSTALLER_VERSION"
    say "USB device: $USB_DEVICE"
    say "USB disk: $USB_DISK"
    say "USB mount: $USB_MOUNT"
    say "USB name: $USB_NAME"
    say "USB filesystem: $USB_FS"
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
    modern_tun_preflight || return 1
    if test "${LEGACY:-0}" = 1; then
        "$GC_BOOTSTRAP_BIN/test" -n "goshacrash" >/dev/null 2>&1 || {
            fail "Bootstrap test потерян из PATH/runtime"
            return 1
        }
        "$GC_BOOTSTRAP_BIN/[" -n "goshacrash" ']' >/dev/null 2>&1 || {
            fail "Bootstrap [ не работает"
            return 1
        }
        say "Legacy shell bootstrap: test + [ OK"
    fi
    prepare_packages || return 1
    install_controller || return 1
    install_network_helper || return 1
    install_configs || return 1
    install_mihomo || return 1
    install_zashboard || return 1
    # Mihomo itself is the authority for UTF-8/YAML. This catches BT10 builds
    # where the tiny BusyBox userland has no usable od for our preflight.
    authoritative_config_preflight || return 1
    write_platform_state || return 1

    if test "${LEGACY:-0}" = 1; then
        verify_persistent_optware || return 1
    fi
    install_hooks || return 1
    if test "${LEGACY:-0}" = 1; then verify_shell_compat || return 1; fi
    if ! GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" check; then
        fail "Новый config.yaml не прошёл встроенную проверку Mihomo; исходный пользовательский конфиг будет восстановлен"
        return 1
    fi
    # Syntax/semantic validation succeeded. Commit the in-place migration now;
    # a later runtime failure must not roll back a syntactically valid config.
    CONFIG_MIGRATION_PENDING="0"
    test -n "$CONFIG_ROLLBACK_TMP" && rm -f "$CONFIG_ROLLBACK_TMP" 2>/dev/null || true

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
