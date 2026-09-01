#!/bin/sh
# GoshaCrash online installer for real ASUSWRT routers.
# One copied file installs the controller, a matching Mihomo core, Zashboard,
# package tools through ASUS Download Master, configuration and autostart.

INSTALLER_VERSION="3.10.2-rc30"

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


find_tool_basic(){
    name="$1"
    for p in "/usr/sbin/$name" "/usr/bin/$name" "/sbin/$name" "/bin/$name"; do
        test -x "$p" && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

usb_disk_size_mb(){
    dev="$1"
    name="${dev#/dev/}"
    blocks="$(awk -v n="$name" '$4==n {print $3; exit}' /proc/partitions 2>/dev/null)"
    case "$blocks" in
        ''|*[!0-9]*) echo "?"; return 0 ;;
    esac
    echo $((blocks / 1024))
}

usb_disk_model(){
    dev="$1"
    name="${dev#/dev/}"
    model="$(cat "/sys/block/$name/device/model" 2>/dev/null)"
    vendor="$(cat "/sys/block/$name/device/vendor" 2>/dev/null)"
    model="$(printf '%s %s' "$vendor" "$model" | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')"
    test -n "$model" && printf '%s\n' "$model" || printf '%s\n' "USB disk"
}

usb_disk_is_mounted(){
    dev="$1"
    grep -q "^${dev}[0-9]* " /proc/mounts 2>/dev/null
}

usb_list_disks(){
    found=0
    for sys in /sys/block/sd*; do
        test -d "$sys" || continue
        name="${sys##*/}"
        dev="/dev/$name"
        test -b "$dev" || continue
        found=$((found + 1))
        size_mb="$(usb_disk_size_mb "$dev")"
        model="$(usb_disk_model "$dev")"
        mounted="нет"
        usb_disk_is_mounted "$dev" && mounted="да"
        printf ' [%s] %s | %s | %s MB | mounted: %s\n' "$found" "$dev" "$model" "$size_mb" "$mounted"
        eval "GC_USB_DEV_$found='$dev'"
    done
    GC_USB_COUNT="$found"
}

usb_wait_partition(){
    part="$1"
    n=0
    while test "$n" -lt 15; do
        test -b "$part" && return 0
        sleep 1
        n=$((n + 1))
    done
    return 1
}

usb_symlink_test(){
    mountpoint="$1"
    testdir="$mountpoint/.goshacrash-symlink-test.$$"
    rm -rf "$testdir" 2>/dev/null || true
    mkdir -p "$testdir" || return 1
    : > "$testdir/target" || { rm -rf "$testdir"; return 1; }
    ln -s target "$testdir/link" 2>/dev/null || { rm -rf "$testdir"; return 1; }
    test -L "$testdir/link" || { rm -rf "$testdir"; return 1; }
    rm -rf "$testdir" 2>/dev/null || true
    return 0
}


mount_fs_for_path(){
    target="$1"
    best_mp=""
    best_fs=""
    while read dev mp fs rest; do
        case "$target" in
            "$mp"|"$mp"/*)
                if test ${#mp} -gt ${#best_mp}; then
                    best_mp="$mp"
                    best_fs="$fs"
                fi
                ;;
        esac
    done < /proc/mounts
    test -n "$best_mp" || return 1
    printf '%s|%s\n' "$best_mp" "$best_fs"
}

legacy_usb_fs_check(){
    # DM_ROOT is already known here, so inspect the actual filesystem that
    # backs Download Master/Optware rather than guessing from a device name.
    candidate="${DM_ROOT:-${USB_MOUNT:-}}"
    test -n "$candidate" || return 0

    info="$(mount_fs_for_path "$candidate" 2>/dev/null)" || {
        warn "Не удалось определить filesystem для $candidate"
        return 0
    }

    mp="${info%%|*}"
    fs="${info#*|}"

    case "$fs" in
        ext3)
            ok "USB filesystem: EXT3 ($mp)"
            return 0
            ;;
        *)
            echo
            warn "USB filesystem: $fs"
            warn "Mount: $mp"
            echo
            echo "Для legacy RT-AC68U + Download Master/Optware нужна EXT3."
            echo "Текущая файловая система '$fs' не подходит для проверенной legacy-схемы."
            echo
            echo "Почему:"
            echo "  Optware использует Unix symlink, например:"
            echo "  libipkg.so.0 -> libipkg.so.0.0.0"
            echo "  На TFAT/FAT такие ссылки не создаются; в результате ломаются ipkg, nano и SFTP."
            echo
            echo "Подготовить флешку можно этим же установщиком:"
            echo
            echo "  /bin/sh install.sh --prepare-usb"
            echo
            echo "После форматирования:"
            echo "  1. переподключи флешку;"
            echo "  2. установи Download Master на неё заново;"
            echo "  3. снова запусти: /bin/sh install.sh"
            echo
            fail "Установка остановлена до внесения изменений: требуется EXT3"
            return 1
            ;;
    esac
}

fdisk_blocks_number(){
    # BusyBox fdisk may print rounded block counts as e.g. "7566583+".
    # Geometry comparisons must use digits only.
    printf '%s\n' "$1" | sed 's/[^0-9].*$//'
}

prepare_usb_wizard(){
    verify_asuswrt || return 1

    FDISK_BIN="$(find_tool_basic fdisk 2>/dev/null)"
    MKFS_BIN="$(find_tool_basic mkfs.ext3 2>/dev/null)"
    test -n "$FDISK_BIN" || { fail "fdisk не найден в прошивке"; return 1; }
    test -n "$MKFS_BIN" || { fail "mkfs.ext3 не найден в прошивке"; return 1; }

    echo
    echo "GoshaCrash — подготовка USB в EXT3"
    echo "=================================="
    echo
    echo "Найдены USB-диски:"
    usb_list_disks
    test "${GC_USB_COUNT:-0}" -gt 0 || { fail "USB-диски /dev/sdX не найдены"; return 1; }

    echo
    echo " [0] Отмена"
    printf 'Выберите диск [0-%s]: ' "$GC_USB_COUNT"
    IFS= read -r choice
    case "$choice" in
        0|'') say "Форматирование отменено"; return 0 ;;
        *[!0-9]*) fail "Некорректный выбор"; return 1 ;;
    esac
    test "$choice" -ge 1 2>/dev/null && test "$choice" -le "$GC_USB_COUNT" 2>/dev/null || {
        fail "Некорректный номер диска"
        return 1
    }

    eval "USB_DEV=\${GC_USB_DEV_$choice}"
    test -b "$USB_DEV" || { fail "Устройство исчезло: $USB_DEV"; return 1; }

    devname="${USB_DEV#/dev/}"
    target_part="${USB_DEV}1"
    model="$(usb_disk_model "$USB_DEV")"
    size_mb="$(usb_disk_size_mb "$USB_DEV")"

    echo
    echo "ВНИМАНИЕ: ВСЕ ДАННЫЕ НА ВЫБРАННОЙ ФЛЕШКЕ БУДУТ УДАЛЕНЫ."
    echo "Устройство: $USB_DEV"
    echo "Модель:     $model"
    echo "Размер:     $size_mb MB"
    echo
    echo "Целевая схема:"
    echo "  DOS/MBR -> один primary-раздел $target_part -> EXT3 label=SANDISK"
    echo
    printf 'Для продолжения введите точно: FORMAT %s\n> ' "$USB_DEV"
    IFS= read -r confirm
    test "$confirm" = "FORMAT $USB_DEV" || { say "Форматирование отменено"; return 0; }

    say "[1/5] Остановка USB-приложений и размонтирование $USB_DEV"

    for mp in $(awk -v d="$USB_DEV" '$1 ~ ("^" d "[0-9]+$") {print $2}' /proc/mounts 2>/dev/null); do
        if test -x "$mp/goshacrash/goshacrash.sh"; then
            GOSHACRASH_BASE="$mp/goshacrash" "$mp/goshacrash/goshacrash.sh" stop >/dev/null 2>&1 || true
        fi
        for dmstop in \
            "$mp/asusware.arm/S50downloadmaster.1" \
            "$mp/asusware.arm/etc/init.d/S50downloadmaster" \
            "$mp/asusware.arm64/S50downloadmaster.1" \
            "$mp/asusware/S50downloadmaster.1"; do
            test -x "$dmstop" && "$dmstop" stop >/dev/null 2>&1 || true
        done
    done

    sync
    sleep 1

    tries=0
    while test "$tries" -lt 8; do
        mounted_now=0
        for mp in $(awk -v d="$USB_DEV" '$1 ~ ("^" d "[0-9]+$") {print $2}' /proc/mounts 2>/dev/null); do
            mounted_now=1
            umount "$mp" >/dev/null 2>&1 || true
        done
        if test "$mounted_now" -eq 0; then
            break
        fi
        sync
        sleep 1
        tries=$((tries + 1))
    done

    if awk -v d="$USB_DEV" '$1 ~ ("^" d "[0-9]+$") {found=1} END {exit found?0:1}' /proc/mounts 2>/dev/null; then
        echo
        fail "ASUSWRT всё ещё держит раздел флешки смонтированным. Ничего destructive не выполнено."
        echo "В веб-интерфейсе ASUS нажми «Отсоединить» для USB-диска, не вынимай его физически,"
        echo "и снова запусти:"
        echo "  повторно запусти этот installer с аргументом --prepare-usb"
        return 1
    fi

    say "[2/5] Проверка текущей MBR-разметки / resume после reboot"

    disk_blocks="$(awk -v n="$devname" '$4==n {print $3; exit}' /proc/partitions 2>/dev/null)"
    fdisk_line="$("$FDISK_BIN" -l "$USB_DEV" 2>/dev/null | awk -v p="$target_part" '$1==p {print; exit}')"
    fdisk_blocks="$(printf '%s\n' "$fdisk_line" | awk '{print $4}')"
    fdisk_type="$(printf '%s\n' "$fdisk_line" | awk '{print $(NF-1)}')"
    kernel_blocks="$(awk -v n="${target_part#/dev/}" '$4==n {print $3; exit}' /proc/partitions 2>/dev/null)"
    part_count="$(awk -v d="$devname" '$4 ~ ("^" d "[0-9]+$") {c++} END {print c+0}' /proc/partitions 2>/dev/null)"

    resume_ready=0
    if test "$part_count" -eq 1 \
       && test -b "$target_part" \
       && test -n "$disk_blocks" \
       && test -n "$fdisk_blocks" \
       && test -n "$kernel_blocks" \
       && test "$fdisk_blocks" = "$kernel_blocks" \
       && test "$fdisk_type" = "83"; then
        # BusyBox ash on this 32-bit ASUSWRT can overflow on:
        #   disk_blocks * 98
        # for a 120M-block USB disk. Compare in MiB-sized units instead.
        disk_mb=$((disk_blocks / 1024))
        kernel_mb=$((kernel_blocks / 1024))
        min_mb=$((disk_mb * 98 / 100))
        if test "$kernel_mb" -ge "$min_mb" 2>/dev/null; then
            resume_ready=1
        fi
    fi

    say "Resume check: parts=$part_count type=${fdisk_type:-?} fdisk_blocks=${fdisk_blocks:-?} kernel_blocks=${kernel_blocks:-?}"

    if test "$resume_ready" -eq 1; then
        ok "MBR уже готова после reboot: $target_part, type 83, ${kernel_blocks} blocks"
        say "[3/5] fdisk пропущен — продолжаем с mkfs.ext3"
    else
        say "[3/5] Создание новой DOS/MBR разметки и одного primary-раздела"

        {
            echo o
            echo n
            echo p
            echo 1
            echo
            echo
            echo w
        } | "$FDISK_BIN" "$USB_DEV" >> "$TMP_LOG" 2>&1
        sync

        if ! "$FDISK_BIN" -l "$USB_DEV" 2>/dev/null | grep -q "^${target_part}[[:space:]]"; then
            fail "Новая MBR-разметка не подтверждается через fdisk -l. См. $TMP_LOG"
            return 1
        fi

        n=0
        while test "$n" -lt 5; do
            test -b "$target_part" && break
            sleep 1
            n=$((n + 1))
        done

        if ! test -b "$target_part"; then
            echo
            warn "MBR записан, но старое ядро ASUSWRT ещё не создало $target_part."
            echo "Сделай reboot, снова скачай install.sh и повтори --prepare-usb."
            echo "Установщик распознает готовую MBR и fdisk повторно запускать не будет."
            return 2
        fi

        fdisk_blocks_raw="$("$FDISK_BIN" -l "$USB_DEV" 2>/dev/null | awk -v p="$target_part" '$1==p {print $4; exit}')"
        fdisk_blocks="$(fdisk_blocks_number "$fdisk_blocks_raw")"
        kernel_blocks="$(awk -v n="${target_part#/dev/}" '$4==n {print $3; exit}' /proc/partitions 2>/dev/null)"

        if test -n "$fdisk_blocks" && test -n "$kernel_blocks" && test "$fdisk_blocks" != "$kernel_blocks"; then
            echo
            warn "MBR записан, но kernel всё ещё показывает старую геометрию $target_part."
            echo "mkfs НЕ запускается на stale mapping."
            echo
            echo "Сейчас:"
            echo "  reboot"
            echo
            echo "После загрузки снова:"
            echo "  повторно запусти этот installer с аргументом --prepare-usb"
            echo
            echo "Установщик увидит совпавшую геометрию и ПРОПУСТИТ fdisk."
            return 2
        fi
    fi

    fdisk_blocks_raw="$("$FDISK_BIN" -l "$USB_DEV" 2>/dev/null | awk -v p="$target_part" '$1==p {print $4; exit}')"
    fdisk_blocks="$(fdisk_blocks_number "$fdisk_blocks_raw")"
    kernel_blocks="$(awk -v n="${target_part#/dev/}" '$4==n {print $3; exit}' /proc/partitions 2>/dev/null)"
    if test -z "$fdisk_blocks" || test -z "$kernel_blocks" || test "$fdisk_blocks" != "$kernel_blocks"; then
        fail "Перед mkfs геометрия $target_part не подтверждена. mkfs НЕ запускается."
        return 1
    fi

    if grep -q "^$target_part " /proc/mounts 2>/dev/null; then
        fail "$target_part снова смонтирован ASUSWRT; mkfs не запускаю"
        return 1
    fi

    say "[4/5] Форматирование $target_part в EXT3 (label=SANDISK)"
    "$MKFS_BIN" -L SANDISK "$target_part" >> "$TMP_LOG" 2>&1 || {
        fail "mkfs.ext3 завершился с ошибкой. См. $TMP_LOG"
        return 1
    }
    sync

    say "[5/5] EXT3 записан. Финальное монтирование оставляем штатному ASUSWRT"

    echo
    ok "USB подготовлен: DOS/MBR + $target_part + EXT3 label=SANDISK"
    echo
    echo "Не вынимай/вставляй флешку."
    echo "Сделай один reboot:"
    echo "  reboot"
    echo
    echo "После загрузки проверь:"
    echo "  mount | grep '/dev/sd'"
    echo "  df -h | grep '/tmp/mnt'"
    echo
    echo "Ожидается:"
    echo "  $target_part on /tmp/mnt/SANDISK type ext3 (...)"
    echo
    echo "Затем установи Download Master через веб-интерфейс ASUS"
    echo "и запусти обычную установку GoshaCrash:"
    echo "  повторно запусти обычную установку тем же способом"
    echo
    return 0
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

mounted_usb_count(){
    awk '$2 ~ "^/tmp/mnt/" {c++} END {print c+0}' /proc/mounts 2>/dev/null
}

first_usb_mount(){
    awk '$2 ~ "^/tmp/mnt/" {print $2; exit}' /proc/mounts 2>/dev/null
}

fs_for_mountpoint(){
    mp="$1"
    awk -v m="$mp" '$2==m {print $3; exit}' /proc/mounts 2>/dev/null
}

legacy_preflight_before_dm(){
    legacy_hw_detect || return 0

    if test -n "${INSTALL_ROOT:-}"; then
        mp="$INSTALL_ROOT"
    else
        count="$(mounted_usb_count)"
        case "$count" in
            0)
                warn "USB-флешка не смонтирована в /tmp/mnt"
                echo "Подключи USB-флешку и повтори установку."
                return 1
                ;;
            1)
                mp="$(first_usb_mount)"
                ;;
            *)
                fail "Найдено несколько USB mountpoint. Укажи INSTALL_ROOT=/tmp/mnt/МЕТКА"
                return 1
                ;;
        esac
    fi

    fs="$(fs_for_mountpoint "$mp")"
    test -n "$fs" || {
        warn "Не удалось определить filesystem для $mp"
        return 1
    }

    case "$fs" in
        ext3)
            ok "USB filesystem: EXT3 ($mp)"
            return 0
            ;;
        *)
            echo
            warn "USB filesystem: $fs ($mp)"
            echo
            echo "Для RT-AC68U legacy-схема GoshaCrash + Download Master/Optware"
            echo "требует EXT3. Текущая файловая система будет ломать Unix symlink."
            echo
            echo "Подготовить эту флешку можно самим install.sh:"
            echo
            echo "  повторно запусти этот installer с аргументом --prepare-usb"
            echo
            echo "ВНИМАНИЕ: форматирование удалит ВСЕ данные и Download Master."
            echo "После EXT3 установи Download Master через ASUS заново,"
            echo "а затем снова запусти обычный install.sh."
            echo
            fail "Установка остановлена: сначала нужна EXT3"
            return 1
            ;;
    esac
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

preserve_stock_opt_payload(){
    # Preserve firmware-owned real files/directories that would otherwise be
    # hidden by the bind mount. Firmware symlinks to /tmp/opt need no copy.
    for entry in /opt/*; do
        test -e "$entry" || continue
        test -L "$entry" && continue
        name="${entry##*/}"
        if test -d "$entry"; then
            mkdir -p "$DM_ROOT/$name" || return 1
            cp -R "$entry/." "$DM_ROOT/$name/" 2>/dev/null || {
                fail "Не удалось сохранить штатный /opt/$name перед подготовкой Optware"
                return 1
            }
        elif test -f "$entry"; then
            cp -f "$entry" "$DM_ROOT/$name" 2>/dev/null || return 1
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
test -n "$DM_ROOT" || DM_ROOT=/tmp/mnt/SANDISK/asusware.arm
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
    #   /tmp/mnt/SANDISK   -> ext3
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
    test "$version" = "$INSTALLER_VERSION"
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
            warn "Источник отдал другую версию goshacrash.sh: ${got:-unknown}; нужен $INSTALLER_VERSION"
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

generate_dashboard_secret(){
    secret=""
    if test -r /dev/urandom; then
        od_bin=""
        for p in /usr/bin/od /bin/od /usr/sbin/od /sbin/od; do
            test -x "$p" && { od_bin="$p"; break; }
        done
        hex_bin=""
        for p in /usr/bin/hexdump /bin/hexdump /usr/sbin/hexdump /sbin/hexdump; do
            test -x "$p" && { hex_bin="$p"; break; }
        done
        if test -n "$od_bin"; then
            secret="$("$od_bin" -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
        elif test -n "$hex_bin"; then
            secret="$("$hex_bin" -n 16 -e '16/1 "%02x"' /dev/urandom 2>/dev/null)"
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
        # Mihomo auto-redirect supports iptables or nftables on Linux.
        # auto-detect-interface itself does not require nft.
        yaml_set_section_key "$file" tun auto-detect-interface true || return 1
        yaml_remove_top_key "$file" routing-mark || return 1
    fi
}

generate_base_config(){
    file="$1"
    secret="$(generate_dashboard_secret)"
    test -n "$secret" || { fail "Не удалось создать secret для Zashboard"; return 1; }

    cat > "$file" <<EOF
# Базовая конфигурация GoshaCrash. Кодировка файла: UTF-8 без BOM.
# Сгенерирована install.sh под текущую архитектуру и режим маршрутизации роутера.
# По умолчанию трафик идёт напрямую (DIRECT). Добавь свои proxy / proxy-groups / rules.

# Веб-интерфейс Zashboard и локальный API Mihomo.
external-controller: 0.0.0.0:9090
secret: "$secret"
external-ui: ui
external-ui-url: "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip"

# Сохранять выбранные прокси и Fake-IP между перезапусками Mihomo.
profile:
  store-selected: true
  store-fake-ip: true

# Локальный mixed HTTP/SOCKS порт Mihomo.
mixed-port: 7892
allow-lan: true
bind-address: "*"
mode: rule
log-level: info
ipv6: false

# DNS Mihomo. Fake-IP используется для прозрачной маршрутизации клиентов.
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

# TUN-интерфейс. auto-route / auto-redirect ниже выставляет сам GoshaCrash.
tun:
  enable: true
  stack: $TUN_STACK
  device: tun0
  dns-hijack:
    - any:53
    - tcp://any:53

# Без пользовательских правил весь трафик остаётся DIRECT.
rules:
  - MATCH,DIRECT
EOF

    configure_routing_in_config "$file" || return 1
    chmod 600 "$file" 2>/dev/null || true
    return 0
}

install_configs(){
    test -n "$ACTIVE_CONFIG" || ACTIVE_CONFIG="$BASE/config.yaml"

    # Migration from GoshaCrash <= 3.5.x: move the old active config to the
    # unified name instead of creating a second persistent copy.
    if test ! -f "$ACTIVE_CONFIG" && test -f "$BASE/config-legacy.yaml"; then
        mv -f "$BASE/config-legacy.yaml" "$ACTIVE_CONFIG" || return 1
        say "Legacy-конфиг перенесён в единый $ACTIVE_CONFIG"
    fi

    if test ! -f "$ACTIVE_CONFIG"; then
        generate_base_config "$ACTIVE_CONFIG" || { fail "Не удалось сгенерировать базовый config.yaml"; return 1; }
        say "Базовый config.yaml создан install.sh для $PLATFORM (routing=$ROUTING_MODE, tun.stack=$TUN_STACK)"
        warn "VPN ещё не настроен: добавь свои proxy/rules и выполни gc restart"
    else
        config_tmp="$TMP_ROOT/config-before-routing.yaml"
        cp -f "$ACTIVE_CONFIG" "$config_tmp" || return 1
        say "Существующий $ACTIVE_CONFIG сохранён; меняются только параметры выбранной маршрутизации"
        if ! configure_routing_in_config "$ACTIVE_CONFIG"; then
            cp -f "$config_tmp" "$ACTIVE_CONFIG" 2>/dev/null || true
            fail "Не удалось применить routing=$ROUTING_MODE к конфигу"
            return 1
        fi
        rm -f "$config_tmp" 2>/dev/null || true
        chmod 600 "$ACTIVE_CONFIG" 2>/dev/null || true
    fi
}


json_asset_urls(){
    file="$1"
    grep '"browser_download_url"' "$file" 2>/dev/null |
        sed -n 's#.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*#\1#p' |
        tr -d '\r'
}

pinned_official_mihomo_url(){
    # rc30 deliberately pins the modern core. A router install must not silently
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
    cat > "$dst" <<WRAP
#!/bin/sh
BASE='$BASE'
/bin/busybox test -x "\$BASE/goshacrash.sh" || { echo "GoshaCrash не найден на USB" >&2; exit 1; }
GOSHACRASH_BASE="\$BASE"
export GOSHACRASH_BASE
exec /bin/sh "\$BASE/goshacrash.sh" "\$@"
WRAP
    chmod 755 "$dst"
}

write_nano_wrapper(){
    dst="$1"
    cat > "$dst" <<WRAP
#!/bin/sh
BASE='$BASE'
DM_ROOT=""
unset LC_ALL 2>/dev/null || true
case "\${LC_CTYPE:-\${LANG:-}}" in
  *UTF-8*|*utf8*|*UTF8*) : ;;
  *) LANG=en_US.UTF-8; LC_CTYPE=en_US.UTF-8; export LANG LC_CTYPE ;;
esac
/bin/busybox test -f "\$BASE/state/platform.env" && . "\$BASE/state/platform.env"
for p in /opt/bin/nano /tmp/opt/bin/nano "\$DM_ROOT/bin/nano" "\$DM_ROOT/sbin/nano"; do
  /bin/busybox test -x "\$p" && exec "\$p" "\$@"
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
# GoshaCrash Download Master bridge 3.10.2-rc30
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
    # Keep GoshaCrash-owned persistent data inside $BASE. Outside it we leave
    # only the standard ASUS hook/wrapper files that firmware actually calls.
    mkdir -p /jffs/scripts /jffs/configs /jffs/etc "$DM_ROOT/bin" "$DM_ROOT/etc/init.d" || return 1

    cat > /jffs/scripts/usb-mount-script <<'HOOK'
#!/bin/sh
# GoshaCrash USB hook 3.10.2-rc30
unset LD_LIBRARY_PATH 2>/dev/null || true
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
BASE="__GC_BASE__"
MOUNT_POINT="$2"
TRACE="$BASE/logs/coldboot.log"
TMP_TRACE=/tmp/goshacrash-coldboot.log
WAITED=0

trace(){
  printf '[%s] [usb-mount pid=%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$$" "$*" >> "$TRACE" 2>/dev/null || true
}

case "$BASE" in
  "$MOUNT_POINT"/*) ;;
  *) exit 0 ;;
esac

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
printf '[%s] autostart hook rc30: USB/controller ready; launching boot\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" >> "$BASE/logs/boot.log" 2>/dev/null || true

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
    hook_base_esc="$(printf '%s' "$BASE" | sed 's/[\\&#]/\\&/g')"
    sed -i "s#__GC_BASE__#$hook_base_esc#g" /jffs/scripts/usb-mount-script || return 1
    chmod 755 /jffs/scripts/usb-mount-script || return 1

    cat > /jffs/scripts/usb-umount-script <<'HOOK'
#!/bin/sh
# GoshaCrash USB unmount hook 3.10.2-rc30
unset LD_LIBRARY_PATH 2>/dev/null || true
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
BASE="__GC_BASE__"
MOUNT_POINT="$2"
case "$BASE" in
  "$MOUNT_POINT"/*)
    test -x "$BASE/goshacrash.sh" && GOSHACRASH_BASE="$BASE" /bin/sh "$BASE/goshacrash.sh" service-stop >/dev/null 2>&1 || true
    if test -f /tmp/goshacrash-opt-bind.state; then
      OPTDM="$(cat /tmp/goshacrash-opt-bind.state 2>/dev/null)"
      case "$OPTDM" in
        "$MOUNT_POINT"/*)
          for u in /bin/umount /sbin/umount /usr/bin/umount /usr/sbin/umount; do
            test -x "$u" || continue
            "$u" /opt >/dev/null 2>&1 || "$u" -l /opt >/dev/null 2>&1 || true
            break
          done
          rm -f /tmp/goshacrash-opt-bind.state 2>/dev/null || true
          ;;
      esac
    fi
    ;;
esac
exit 0
HOOK
    sed -i "s#__GC_BASE__#$hook_base_esc#g" /jffs/scripts/usb-umount-script || return 1
    chmod 755 /jffs/scripts/usb-umount-script || return 1

    rm -f /jffs/scripts/gc /jffs/scripts/nano "$DM_ROOT/bin/gc" /opt/bin/gc 2>/dev/null || true
    write_command_wrapper /jffs/scripts/gc
    write_nano_wrapper /jffs/scripts/nano
    write_command_wrapper "$DM_ROOT/bin/gc"
    test -d /opt/bin && test -w /opt/bin && write_command_wrapper /opt/bin/gc 2>/dev/null || true

    # Old rc23-rc26 used a custom /jffs/addons/goshacrash directory only to
    # store base/start/trace. rc30 no longer needs it; remove our own residue.
    rm -rf /jffs/addons/goshacrash 2>/dev/null || true
    grep -Fq 'exec /bin/busybox test "$@"' /jffs/scripts/test 2>/dev/null && rm -f /jffs/scripts/test 2>/dev/null || true
    grep -Fq "exec /bin/busybox '['" /jffs/scripts/'[' 2>/dev/null && rm -f /jffs/scripts/'[' 2>/dev/null || true

    add_once /jffs/etc/profile 'export PATH="/jffs/scripts:/opt/bin:/opt/sbin:/tmp/opt/bin:/tmp/opt/sbin:$PATH"'
    add_once /jffs/configs/profile.add 'export PATH="/jffs/scripts:/opt/bin:/opt/sbin:/tmp/opt/bin:/tmp/opt/sbin:$PATH"'

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

    case "${1:-}" in
        --prepare-usb)
            test "$#" -eq 1 || { fail "Использование: /bin/sh install.sh --prepare-usb"; return 1; }
            acquire_lock || return 1
            prepare_usb_wizard
            return $?
            ;;
        --help|-h)
            echo "GoshaCrash installer $INSTALLER_VERSION"
            echo
            echo "Использование:"
            echo "  /bin/sh install.sh                установить GoshaCrash"
            echo "  /bin/sh install.sh --prepare-usb  безопасный мастер подготовки USB в EXT3"
            echo "  /bin/sh install.sh --help         эта справка"
            return 0
            ;;
        '')
            ;;
        *)
            fail "Неизвестный аргумент: $1. Используй --help"
            return 1
            ;;
    esac

    test "$#" -eq 0 || return 1
    acquire_lock || return 1

    verify_asuswrt || return 1
    legacy_preflight_before_dm || return 1
    find_download_master || {
        if legacy_hw_detect; then
            echo
            echo "EXT3 уже подходит, но Download Master не найден."
            echo "Установи Download Master через веб-интерфейс ASUS на эту флешку,"
            echo "затем снова запусти обычную установку тем же способом"
        fi
        return 1
    }
    BASE="${INSTALL_DIR:-$USB_MOUNT/goshacrash}"
    mkdir -p "$TMP_ROOT" "$BASE/bin" "$BASE/logs" "$BASE/run" "$BASE/state" || return 1
    # Keep the persistent tree minimal. Remove only empty legacy directories;
    # never delete existing user files automatically.
    rmdir "$BASE/rulesets" "$BASE/proxies" "$BASE/backups" 2>/dev/null || true
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
    write_platform_state || return 1

    if test "${LEGACY:-0}" = 1; then
        verify_persistent_optware || return 1
    fi
    install_hooks || return 1
    if test "${LEGACY:-0}" = 1; then verify_shell_compat || return 1; fi
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
