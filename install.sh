#!/bin/sh
# GoshaCrash installer for ASUSWRT / Asuswrt-Merlin.
# Installs Mihomo, Zashboard, controller and persistent JFFS hooks.
# The user's private config.yaml is never overwritten.

REPO="${REPO:-goshamarat/GoshaCrash}"
BRANCH="${BRANCH:-main}"
MIHOMO_VERSION="${MIHOMO_VERSION:-1.19.28}"
GOSHACRASH_VERSION="0.3.0-dns-test"

RAW_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
ZASHBOARD_URL="https://codeload.github.com/Zephyruso/zashboard/tar.gz/refs/heads/gh-pages-no-fonts"

say() {
    printf '%s\n' "[GoshaCrash] $*"
}

warn() {
    printf '%s\n' "[GoshaCrash:WARN] $*" >&2
}

fail() {
    printf '%s\n' "[GoshaCrash:ERROR] $*" >&2
    exit 1
}

find_program() {
    program="$1"
    old_ifs="$IFS"
    IFS=:

    for directory in $PATH; do
        if [ -x "$directory/$program" ]; then
            printf '%s\n' "$directory/$program"
            IFS="$old_ifs"
            return 0
        fi
    done

    IFS="$old_ifs"
    return 1
}

# Prefer wget: the legacy Download Master curl on ASUS often has a broken CA path.
fetch() {
    url="$1"
    output="$2"

    rm -f "$output"

    # Always prefer firmware utilities. Old Download Master /opt binaries
    # can shadow them and may have broken TLS options or CA paths.
    for wget_bin in \
        /usr/bin/wget \
        /bin/wget \
        /usr/sbin/wget \
        /sbin/wget
    do
        [ -x "$wget_bin" ] || continue

        if "$wget_bin" --help 2>&1 | grep -q -- '--no-check-certificate'; then
            "$wget_bin" --no-check-certificate -O "$output" "$url" &&
                return 0
        else
            "$wget_bin" -O "$output" "$url" &&
                return 0
        fi

        rm -f "$output"
    done

    if [ -x /bin/busybox ]; then
        if /bin/busybox wget --help 2>&1 | grep -q -- '--no-check-certificate'; then
            /bin/busybox wget --no-check-certificate -O "$output" "$url" &&
                return 0
        else
            /bin/busybox wget -O "$output" "$url" &&
                return 0
        fi

        rm -f "$output"
    fi

    # Last resort: optional userland tools.
    for wget_bin in \
        /opt/bin/wget \
        "$USB_MOUNT/asusware.arm/bin/wget"
    do
        [ -x "$wget_bin" ] || continue

        if "$wget_bin" --help 2>&1 | grep -q -- '--no-check-certificate'; then
            "$wget_bin" --no-check-certificate -O "$output" "$url" &&
                return 0
        else
            "$wget_bin" -O "$output" "$url" &&
                return 0
        fi

        rm -f "$output"
    done

    for curl_bin in \
        /usr/bin/curl \
        /bin/curl \
        /opt/bin/curl \
        "$USB_MOUNT/asusware.arm/bin/curl"
    do
        [ -x "$curl_bin" ] || continue

        "$curl_bin" -k -fL \
            --connect-timeout 20 \
            --max-time 180 \
            -o "$output" "$url" &&
            return 0

        rm -f "$output"
    done

    return 1
}

find_usb_mount() {
    if [ -n "${INSTALL_ROOT:-}" ]; then
        [ -d "$INSTALL_ROOT" ] || fail "INSTALL_ROOT не существует: $INSTALL_ROOT"
        printf '%s\n' "$INSTALL_ROOT"
        return 0
    fi

    if [ -d /tmp/mnt/GOSHACRASH ] && [ -w /tmp/mnt/GOSHACRASH ]; then
        printf '%s\n' /tmp/mnt/GOSHACRASH
        return 0
    fi

    for mountpoint in /tmp/mnt/*; do
        [ -d "$mountpoint" ] || continue
        [ -w "$mountpoint" ] || continue
        printf '%s\n' "$mountpoint"
        return 0
    done

    return 1
}

arch_candidates() {
    machine="$(uname -m 2>/dev/null)"

    case "$machine" in
        armv7*|armv8l)
            # Some older Broadcom ASUS kernels report armv7 but need armv5.
            printf '%s\n' armv7 armv5
            ;;
        armv6*)
            printf '%s\n' armv6 armv5
            ;;
        armv5*)
            printf '%s\n' armv5
            ;;
        aarch64|arm64)
            printf '%s\n' arm64
            ;;
        x86_64|amd64)
            printf '%s\n' amd64
            ;;
        i386|i486|i586|i686)
            printf '%s\n' 386
            ;;
        *)
            return 1
            ;;
    esac
}

install_repository_files() {
    say "Устанавливаю управляющий скрипт"

    fetch "$RAW_BASE/goshacrash" "$BASE/goshacrash.new" ||
        fail "Не удалось скачать goshacrash"

    chmod 755 "$BASE/goshacrash.new" 2>/dev/null || true
    mv -f "$BASE/goshacrash.new" "$BASE/goshacrash" ||
        fail "Не удалось установить управляющий скрипт"

    if [ -f "$SOURCE_CONFIG" ]; then
        say "Личный config.yaml сохранён без изменений"
    else
        say "Создаю безопасный стартовый config.yaml"

        fetch "$RAW_BASE/templates/config.yaml" "$SOURCE_CONFIG.new" ||
            fail "Не удалось скачать templates/config.yaml"

        mv -f "$SOURCE_CONFIG.new" "$SOURCE_CONFIG" ||
            fail "Не удалось установить стартовый config.yaml"
    fi
}

install_mihomo() {
    if [ "${FORCE_MIHOMO_UPDATE:-0}" != "1" ] &&
       [ -x "$BIN_DIR/mihomo" ] &&
       "$BIN_DIR/mihomo" -v >/dev/null 2>&1
    then
        say "Использую уже установленный рабочий Mihomo"
        return 0
    fi

    gzip_bin="$(find_program gzip 2>/dev/null)"
    [ -n "$gzip_bin" ] || fail "Не найден gzip"

    candidates="$(arch_candidates)" ||
        fail "Неподдерживаемая архитектура: $(uname -m 2>/dev/null)"

    for arch in $candidates; do
        archive="$TMP_DIR/mihomo-${arch}.gz"
        candidate="$TMP_DIR/mihomo-${arch}"
        url="https://github.com/MetaCubeX/mihomo/releases/download/v${MIHOMO_VERSION}/mihomo-linux-${arch}-v${MIHOMO_VERSION}.gz"

        say "Пробую Mihomo v${MIHOMO_VERSION} для ${arch}"

        rm -f "$archive" "$candidate"

        if ! fetch "$url" "$archive"; then
            warn "Не удалось скачать сборку ${arch}"
            continue
        fi

        if ! "$gzip_bin" -dc "$archive" > "$candidate"; then
            warn "Не удалось распаковать сборку ${arch}"
            continue
        fi

        chmod 755 "$candidate" 2>/dev/null || true

        if "$candidate" -v >/dev/null 2>&1; then
            mv -f "$candidate" "$BIN_DIR/mihomo" ||
                fail "Не удалось установить Mihomo"
            chmod 755 "$BIN_DIR/mihomo" 2>/dev/null || true
            say "Mihomo установлен: ${arch}"
            return 0
        fi

        warn "Сборка ${arch} не запускается, пробую следующую"
    done

    fail "Не удалось подобрать рабочую сборку Mihomo"
}

install_zashboard() {
    tar_bin="$(find_program tar 2>/dev/null)"
    [ -n "$tar_bin" ] || fail "Не найден tar"

    archive="$TMP_DIR/zashboard.tar.gz"
    unpacked="$TMP_DIR/zashboard"

    rm -rf "$archive" "$unpacked" "$UI_DIR.new"
    mkdir -p "$unpacked" "$UI_DIR.new" ||
        fail "Не удалось создать временные каталоги"

    say "Скачиваю Zashboard без встроенных шрифтов"

    fetch "$ZASHBOARD_URL" "$archive" ||
        fail "Не удалось скачать Zashboard"

    "$tar_bin" -xzf "$archive" -C "$unpacked" ||
        fail "Не удалось распаковать Zashboard"

    source_dir=""

    for directory in "$unpacked"/*; do
        [ -d "$directory" ] || continue
        source_dir="$directory"
        break
    done

    [ -n "$source_dir" ] ||
        fail "В архиве Zashboard не найден каталог интерфейса"

    cp -R "$source_dir"/. "$UI_DIR.new"/ ||
        fail "Не удалось скопировать Zashboard"

    rm -rf "$UI_DIR"
    mv "$UI_DIR.new" "$UI_DIR" ||
        fail "Не удалось установить Zashboard"
}

install_optional_tools() {
    package_manager=""

    for candidate in \
        /opt/bin/opkg \
        /opt/bin/ipkg \
        "$USB_MOUNT/asusware.arm/bin/opkg" \
        "$USB_MOUNT/asusware.arm/bin/ipkg"
    do
        if [ -x "$candidate" ]; then
            package_manager="$candidate"
            break
        fi
    done

    if [ -z "$package_manager" ]; then
        warn "opkg/ipkg не найден: nano не установлен"
        warn "Mihomo и Zashboard от этого не зависят"
        return 0
    fi

    say "Пакетный менеджер: $package_manager"
    "$package_manager" update ||
        warn "Не удалось обновить список пакетов"

    case "$package_manager" in
        *opkg)
            "$package_manager" install nano unzip ca-certificates ||
                warn "Часть дополнительных пакетов не установилась"
            ;;
        *ipkg)
            "$package_manager" install nano unzip ||
                warn "Часть дополнительных пакетов не установилась"
            ;;
    esac
}

install_command_wrappers() {
    mkdir -p /jffs/scripts 2>/dev/null || true

    cat > /jffs/scripts/goshacrash <<EOF
#!/bin/sh
exec "$BASE/goshacrash" "\$@"
EOF
    chmod 755 /jffs/scripts/goshacrash 2>/dev/null || true

    if [ -d /opt/bin ] && [ -w /opt/bin ]; then
        cat > /opt/bin/goshacrash <<EOF
#!/bin/sh
exec "$BASE/goshacrash" "\$@"
EOF
        chmod 755 /opt/bin/goshacrash 2>/dev/null || true
    fi
}

USB_MOUNT="$(find_usb_mount)" ||
    fail "Не найдена доступная USB-флешка в /tmp/mnt"

BASE="$USB_MOUNT/goshacrash"
BIN_DIR="$BASE/bin"
UI_DIR="$BASE/ui"
RUN_DIR="$BASE/run"
LOG_DIR="$BASE/logs"
RULESET_DIR="$BASE/rulesets"
BACKUP_DIR="$BASE/backups"
STATE_DIR="$BASE/state"
SOURCE_CONFIG="$BASE/config.yaml"
TMP_DIR="$BASE/.install-tmp"

PATH="/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin:/opt/sbin:$USB_MOUNT/asusware.arm/bin:$USB_MOUNT/asusware.arm/sbin"
export PATH

say "GoshaCrash ${GOSHACRASH_VERSION}"
say "Флешка: $USB_MOUNT"
say "Каталог установки: $BASE"

mkdir -p \
    "$BIN_DIR" \
    "$RUN_DIR" \
    "$LOG_DIR" \
    "$RULESET_DIR" \
    "$BACKUP_DIR" \
    "$STATE_DIR" \
    "$TMP_DIR" ||
    fail "Не удалось создать каталоги установки"

install_repository_files
install_mihomo
install_zashboard
install_optional_tools
install_command_wrappers

rm -rf "$TMP_DIR"

say "Устанавливаю JFFS-хуки"
GOSHACRASH_BASE="$BASE" "$BASE/goshacrash" install-hooks ||
    fail "Не удалось установить хуки"

if [ -f "$BASE/runtime.yaml" ]; then
    say "Перезапускаю ранее применённую конфигурацию"
    GOSHACRASH_BASE="$BASE" "$BASE/goshacrash" restart ||
        warn "Старую runtime-конфигурацию не удалось запустить"
else
    say "Применяю безопасный стартовый конфиг"
    GOSHACRASH_BASE="$BASE" "$BASE/goshacrash" apply ||
        fail "Стартовый config.yaml не удалось применить"
fi

LAN_IP="$(nvram get lan_ipaddr 2>/dev/null)"
[ -n "$LAN_IP" ] || LAN_IP="IP_РОУТЕРА"

printf '\n%s\n' "============================================================"
printf '%s\n' " GoshaCrash установлен"
printf '%s\n' " Каталог: $BASE"
printf '%s\n' " Личный конфиг: $SOURCE_CONFIG"
printf '%s\n' " Zashboard: http://$LAN_IP:9090/ui/"
printf '%s\n' ""
printf '%s\n' " После вставки своего config.yaml:"
printf '%s\n' "   goshacrash apply"
printf '%s\n' ""
printf '%s\n' " Проверка:"
printf '%s\n' "   goshacrash doctor"
printf '%s\n' "============================================================"
