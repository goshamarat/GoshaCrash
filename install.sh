#!/bin/sh

# GoshaCrash installer for ASUSWRT/Asuswrt-Merlin and Linux test systems.
# Repository can be overridden, for example:
#   REPO=someone/GoshaCrash BRANCH=dev sh install.sh

REPO="${REPO:-goshamarat/GoshaCrash}"
BRANCH="${BRANCH:-main}"
MIHOMO_VERSION="${MIHOMO_VERSION:-1.19.28}"
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
        [ -x "$directory/$program" ] && {
            printf '%s\n' "$directory/$program"
            IFS="$old_ifs"
            return 0
        }
    done

    IFS="$old_ifs"
    return 1
}

fetch() {
    url="$1"
    output="$2"

    curl_bin="$(find_program curl 2>/dev/null)"
    wget_bin="$(find_program wget 2>/dev/null)"

    if [ -n "$curl_bin" ]; then
        "$curl_bin" -fL --connect-timeout 20 -o "$output" "$url"
        return $?
    fi

    if [ -n "$wget_bin" ]; then
        "$wget_bin" --no-check-certificate -O "$output" "$url"
        return $?
    fi

    fail "Не найден ни curl, ни wget"
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

install_mihomo() {
    gzip_bin="$(find_program gzip 2>/dev/null)"
    [ -n "$gzip_bin" ] || fail "Не найден gzip"

    candidates="$(arch_candidates)" || fail "Неподдерживаемая архитектура: $(uname -m 2>/dev/null)"

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
            mv -f "$candidate" "$BIN_DIR/mihomo"
            chmod 755 "$BIN_DIR/mihomo" 2>/dev/null || true
            say "Mihomo установлен: ${arch}"
            return 0
        fi

        warn "Сборка ${arch} не запускается, пробую совместимую"
    done

    fail "Не удалось подобрать рабочую сборку Mihomo"
}

install_zashboard() {
    tar_bin="$(find_program tar 2>/dev/null)"
    [ -n "$tar_bin" ] || fail "Не найден tar"

    archive="$TMP_DIR/zashboard.tar.gz"
    unpacked="$TMP_DIR/zashboard"

    rm -rf "$archive" "$unpacked"
    mkdir -p "$unpacked"

    say "Скачиваю Zashboard без встроенных шрифтов"
    fetch "$ZASHBOARD_URL" "$archive" || fail "Не удалось скачать Zashboard"
    "$tar_bin" -xzf "$archive" -C "$unpacked" || fail "Не удалось распаковать Zashboard"

    source_dir=""
    for directory in "$unpacked"/*; do
        [ -d "$directory" ] || continue
        source_dir="$directory"
        break
    done

    [ -n "$source_dir" ] || fail "В архиве Zashboard не найден каталог интерфейса"

    rm -rf "$UI_DIR.new"
    mkdir -p "$UI_DIR.new"
    cp -R "$source_dir"/. "$UI_DIR.new"/ || fail "Не удалось скопировать Zashboard"
    rm -rf "$UI_DIR"
    mv "$UI_DIR.new" "$UI_DIR"
}

install_repository_files() {
    say "Устанавливаю управляющий скрипт"
    fetch "$RAW_BASE/goshacrash" "$BASE/goshacrash.new" || fail "Не удалось скачать goshacrash"
    chmod 755 "$BASE/goshacrash.new" 2>/dev/null || true
    mv -f "$BASE/goshacrash.new" "$BASE/goshacrash"

    if [ -f "$CONFIG" ]; then
        say "Существующий config.yaml сохранён без изменений"
    else
        say "Устанавливаю стартовый config.yaml"
        fetch "$RAW_BASE/templates/config.yaml" "$CONFIG.new" || fail "Не удалось скачать шаблон config.yaml"
        mv -f "$CONFIG.new" "$CONFIG"
    fi
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
        warn "opkg/ipkg не найден: nano пока не установлен"
        return 0
    fi

    say "Пакетный менеджер: $package_manager"
    "$package_manager" update || warn "Не удалось обновить список пакетов"

    case "$package_manager" in
        *opkg)
            "$package_manager" install nano ca-certificates curl wget-ssl unzip || \
                warn "Часть дополнительных пакетов не установилась"
            ;;
        *ipkg)
            "$package_manager" install nano curl wget unzip || \
                warn "Часть дополнительных пакетов не установилась"
            ;;
    esac
}

USB_MOUNT="$(find_usb_mount)" || fail "Не найдена доступная USB-флешка в /tmp/mnt"
BASE="$USB_MOUNT/goshacrash"
BIN_DIR="$BASE/bin"
UI_DIR="$BASE/ui"
RUN_DIR="$BASE/run"
LOG_DIR="$BASE/logs"
RULESET_DIR="$BASE/rulesets"
CONFIG="$BASE/config.yaml"
TMP_DIR="$BASE/.install-tmp"

PATH="/opt/bin:/opt/sbin:$USB_MOUNT/asusware.arm/bin:$USB_MOUNT/asusware.arm/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

say "Флешка: $USB_MOUNT"
say "Каталог установки: $BASE"

mkdir -p "$BIN_DIR" "$RUN_DIR" "$LOG_DIR" "$RULESET_DIR" "$TMP_DIR" || \
    fail "Не удалось создать каталоги установки"

install_repository_files
install_mihomo
install_zashboard
install_optional_tools

rm -rf "$TMP_DIR"

say "Проверяю конфигурацию"
"$BASE/goshacrash" check || fail "config.yaml не прошёл проверку Mihomo"

say "Запускаю Mihomo"
"$BASE/goshacrash" restart || fail "Mihomo не запустился"

LAN_IP="$(nvram get lan_ipaddr 2>/dev/null)"
[ -n "$LAN_IP" ] || LAN_IP="127.0.0.1"

printf '\n%s\n' "============================================================"
printf '%s\n' " GoshaCrash установлен"
printf '%s\n' " Каталог:  $BASE"
printf '%s\n' " Конфиг:  $CONFIG"
printf '%s\n' " Zashboard: http://$LAN_IP:9090/ui/"
printf '%s\n' " API secret: 3665"
printf '%s\n' " Управление: $BASE/goshacrash status"
printf '%s\n' "============================================================"
