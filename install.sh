#!/bin/sh
# BUILD: 2026-07-13-slim-menu-070
# GoshaCrash bootstrap installer for stock ASUSWRT.
# Installs the controller to USB storage, then installs Mihomo, Zashboard,
# DNS integration, TUN routing and Download Master autostart.

INSTALLER_VERSION="0.7.0"
BUILD_ID="2026-07-13-slim-menu-070"
REPO="${REPO:-goshamarat/GoshaCrash}"
BRANCH="${BRANCH:-main}"
ACTION="${1:-install}"
EXPECTED_CONTROLLER_VERSION="0.7.0-stock-asuswrt"

say() {
    printf '%s\n' "[GoshaCrash installer] $*"
}

warn() {
    printf '%s\n' "[GoshaCrash installer:WARN] $*" >&2
}

fail() {
    printf '%s\n' "[GoshaCrash installer:ERROR] $*" >&2
    return 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

fetch() {
    url="$1"
    output="$2"
    part="$output.part.$$"
    log="/tmp/goshacrash-fetch.$$"
    rm -f "$part" "$output" "$log"

    if [ -x /usr/sbin/wget ]; then
        downloader=/usr/sbin/wget
        kind=wget
    elif have wget; then
        downloader="$(command -v wget)"
        kind=wget
    elif have curl; then
        downloader="$(command -v curl)"
        kind=curl
    else
        fail "Не найден wget или curl"
        return 1
    fi

    say "Загрузчик: $downloader"
    if [ "$kind" = wget ]; then
        "$downloader" --no-check-certificate -O "$part" "$url" >"$log" 2>&1
    else
        "$downloader" -k -f -L -o "$part" "$url" >"$log" 2>&1
    fi
    rc=$?

    if [ "$rc" -eq 0 ] && [ -s "$part" ]; then
        mv -f "$part" "$output"
        rm -f "$log"
        return 0
    fi

    warn "Не удалось скачать $url"
    [ -s "$log" ] && cat "$log" >&2
    rm -f "$part" "$output" "$log"
    return 1
}

fetch_controller() {
    output="$1"
    nonce="${BUILD_ID}-$$"
    url="${GOSHACRASH_URL:-https://raw.githubusercontent.com/$REPO/$BRANCH/goshacrash?build=$nonce}"

    say "Скачиваю $url"
    fetch "$url" "$output" || return 1

    sed -i 's/\r$//' "$output" 2>/dev/null || true
    first_line="$(sed -n '1p' "$output" 2>/dev/null)"
    got_version="$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$output" 2>/dev/null | head -n 1)"

    [ "$first_line" = '#!/bin/sh' ] || {
        warn "Загружен не shell-скрипт"
        rm -f "$output"
        return 1
    }
    sh -n "$output" >/dev/null 2>&1 || {
        warn "Загруженный контроллер содержит синтаксическую ошибку"
        rm -f "$output"
        return 1
    }
    [ "$got_version" = "$EXPECTED_CONTROLLER_VERSION" ] || {
        warn "Получена версия '${got_version:-не определена}', ожидалась '$EXPECTED_CONTROLLER_VERSION'"
        rm -f "$output"
        return 1
    }
    return 0
}

find_usb_mount() {
    if [ -n "${INSTALL_ROOT:-}" ]; then
        [ -d "$INSTALL_ROOT" ] || {
            fail "INSTALL_ROOT не существует: $INSTALL_ROOT"
            return 1
        }

        printf '%s\n' "$INSTALL_ROOT"
        return 0
    fi

    if [ -d /tmp/mnt/GOSHACRASH/asusware.arm ]; then
        printf '%s\n' /tmp/mnt/GOSHACRASH
        return 0
    fi

    found=""
    count=0

    for candidate in /tmp/mnt/*; do
        [ -d "$candidate" ] || continue
        [ -d "$candidate/asusware.arm" ] || continue
        [ -w "$candidate" ] || continue

        found="$candidate"
        count=$((count + 1))
    done

    if [ "$count" -eq 1 ]; then
        printf '%s\n' "$found"
        return 0
    fi

    if [ "$count" -gt 1 ]; then
        fail "Найдено несколько флешек Download Master. Укажи INSTALL_ROOT=/tmp/mnt/ИМЯ"
        return 1
    fi

    fail "Не найдена флешка с Download Master (/tmp/mnt/*/asusware.arm)"
    return 1
}

write_wrapper() {
    mount="$1"
    base="$2"
    wrapper_dir="$mount/asusware.arm/bin"
    wrapper="$wrapper_dir/goshacrash"

    mkdir -p "$wrapper_dir" || return 1

    cat > "$wrapper" <<WRAPPER_EOF
#!/bin/sh
BASE_FILE="/jffs/addons/goshacrash/base"
BASE="$base"

if [ -f "\$BASE_FILE" ]; then
    saved_base="\$(cat "\$BASE_FILE" 2>/dev/null)"
    [ -n "\$saved_base" ] && BASE="\$saved_base"
fi

exec "\$BASE/goshacrash" "\$@"
WRAPPER_EOF

    chmod 755 "$wrapper" || return 1

    if [ -d /opt/bin ]; then
        ln -sf "$wrapper" /opt/bin/goshacrash 2>/dev/null || true
    fi

    say "Команда управления установлена: $wrapper"
}

install_controller() {
    mount="$1"
    base="${INSTALL_DIR:-$mount/goshacrash}"
    target="$base/goshacrash"
    temporary="/tmp/goshacrash.controller.$$"
    backup="$base/goshacrash.previous"

    mkdir -p "$base" "$base/run" "$base/logs" "$base/state" || return 1

    fetch_controller "$temporary" || {
        rm -f "$temporary"
        fail "Не удалось получить goshacrash"
        return 1
    }

    sed -i 's/\r$//' "$temporary" 2>/dev/null || true
    first_line="$(sed -n '1p' "$temporary" 2>/dev/null)"
    [ "$first_line" = '#!/bin/sh' ] || {
        rm -f "$temporary"
        fail "Вместо shell-скрипта загружен неверный файл"
        return 1
    }

    sh -n "$temporary" || {
        rm -f "$temporary"
        fail "Контроллер содержит синтаксическую ошибку"
        return 1
    }

    chmod 755 "$temporary" || return 1

    if [ -f "$target" ]; then
        cp "$target" "$backup" || return 1
    fi

    mv -f "$temporary" "$target" || return 1
    chmod 755 "$target" || return 1

    printf '%s\n' "$base" > /tmp/goshacrash-install-base
    installed_version="$("$target" version 2>/dev/null)"
    [ "$installed_version" = "$EXPECTED_CONTROLLER_VERSION" ] || {
        fail "После установки получена неверная версия контроллера: ${installed_version:-не определена}"
        [ -f "$backup" ] && mv -f "$backup" "$target"
        return 1
    }
    say "Контроллер установлен: $target"
    say "Версия контроллера: $installed_version"

    write_wrapper "$mount" "$base" || return 1

    case "$ACTION" in
        install)
            GOSHACRASH_BASE="$base" "$target" install
            ;;

        controller-only)
            GOSHACRASH_BASE="$base" "$target" install-editor || return 1
            say "Контроллер и nano установлены; Mihomo/TUN не перезапускались"
            ;;

        update)
            GOSHACRASH_BASE="$base" "$target" update
            ;;

        *)
            fail "Неизвестное действие: $ACTION"
            return 1
            ;;
    esac
}

remove_installation() {
    mount="$(find_usb_mount)" || return 1
    base="${INSTALL_DIR:-$mount/goshacrash}"
    controller="$base/goshacrash"

    if [ -x "$controller" ]; then
        GOSHACRASH_BASE="$base" "$controller" stop >/dev/null 2>&1 || true
        GOSHACRASH_BASE="$base" "$controller" uninstall-hooks >/dev/null 2>&1 || true
    fi

    rm -f \
        "$mount/asusware.arm/bin/goshacrash" \
        /opt/bin/goshacrash

    if [ "${KEEP_CONFIG:-0}" = 1 ] && [ -f "$base/config.yaml" ]; then
        saved="$mount/goshacrash-config.yaml"
        cp "$base/config.yaml" "$saved" || return 1
        say "config.yaml сохранён: $saved"
    fi

    rm -rf "$base"
    say "GoshaCrash удалён: $base"
}

main() {
    case "$ACTION" in
        remove|uninstall)
            remove_installation
            return $?
            ;;

        install|controller-only|update)
            ;;

        help|-h|--help)
            cat <<'HELP_EOF'
Использование:
  sh install.sh install          полная установка
  sh install.sh controller-only  обновить контроллер и установить nano без перезапуска Mihomo
  sh install.sh update           установить nano и обновить Mihomo/Zashboard
  sh install.sh remove           удалить GoshaCrash

Переменные:
  INSTALL_ROOT=/tmp/mnt/GOSHACRASH
  INSTALL_DIR=/tmp/mnt/GOSHACRASH/goshacrash
  REPO=goshamarat/GoshaCrash
  BRANCH=main
  GOSHACRASH_URL=https://.../goshacrash
  KEEP_CONFIG=1

Все компоненты загружаются по сети из одного основного источника каждый:
контроллер — GitHub GoshaCrash, Mihomo и Zashboard — репозиторий ShellCrash.
HELP_EOF
            return 0
            ;;

        *)
            fail "Неизвестное действие: $ACTION"
            return 1
            ;;
    esac

    [ -w /jffs ] ||
        warn "Нет прав записи в /jffs; запускай из SSH-пользователя admin"

    mount="$(find_usb_mount)" || return 1

    [ -d "$mount/asusware.arm" ] || {
        fail "Download Master не найден: $mount/asusware.arm"
        return 1
    }

    say "Версия инсталлятора: $INSTALLER_VERSION"
    say "Build ID: $BUILD_ID"
    say "Флешка: $mount"
    say "Действие: $ACTION"

    install_controller "$mount" || {
        fail "Установка не завершена"
        return 1
    }

    base="${INSTALL_DIR:-$mount/goshacrash}"
    controller="$base/goshacrash"

    if [ "$ACTION" != controller-only ]; then
        echo
        GOSHACRASH_BASE="$base" "$controller" status || true
        echo
        say "Диагностика: goshacrash doctor"
        say "Конфиг: $base/config.yaml"
        say "Панель: http://$(nvram get lan_ipaddr 2>/dev/null):9090/ui/"
    fi
}

main "$@"