#!/bin/sh
# BUILD: 2026-07-13-network-ifs-fixed-066
# GoshaCrash bootstrap installer for stock ASUSWRT.
# Installs the controller to USB storage, then installs Mihomo, Zashboard,
# DNS integration, TUN routing and Download Master autostart.

INSTALLER_VERSION="0.6.6"
BUILD_ID="2026-07-13-network-ifs-fixed-066"
REPO="${REPO:-goshamarat/GoshaCrash}"
BRANCH="${BRANCH:-main}"
ACTION="${1:-install}"
EXPECTED_CONTROLLER_VERSION="0.6.6-stock-asuswrt"

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
    errors="/tmp/goshacrash-fetch-errors.$$"
    rm -f "$part" "$output" "$errors"

    # ASUSWRT has several unrelated wget binaries. The firmware GNU wget at
    # /usr/sbin/wget is known to work on RT-AC68U, so try it first. Never call
    # `busybox wget` blindly: many ASUS BusyBox builds do not include that applet.
    if [ -n "${GOSHACRASH_WGET_CANDIDATES:-}" ]; then
        saved_ifs="$IFS"
        IFS=' '
        set -- $GOSHACRASH_WGET_CANDIDATES
        IFS="$saved_ifs"
    else
        detected_wget="$(command -v wget 2>/dev/null)"
        set -- /usr/sbin/wget "$detected_wget" /opt/bin/wget /usr/bin/wget /bin/wget /sbin/wget
    fi

    tried=" "
    for wget_bin do
        [ -n "$wget_bin" ] || continue
        [ -x "$wget_bin" ] || continue
        case "$tried" in *" $wget_bin "*) continue;; esac
        tried="$tried$wget_bin "

        for tls_mode in insecure normal; do
            rm -f "$part"
            attempt="/tmp/goshacrash-fetch-attempt.$$"
            rm -f "$attempt"
            say "Загрузчик: $wget_bin ($tls_mode)"

            if [ "$tls_mode" = insecure ]; then
                "$wget_bin" --no-check-certificate -O "$part" "$url" >"$attempt" 2>&1
            else
                "$wget_bin" -O "$part" "$url" >"$attempt" 2>&1
            fi
            rc=$?

            if [ "$rc" -eq 0 ] && [ -s "$part" ]; then
                mv -f "$part" "$output"
                rm -f "$attempt" "$errors"
                return 0
            fi

            {
                printf '%s
' "--- $wget_bin ($tls_mode), code=$rc ---"
                [ -s "$attempt" ] && cat "$attempt" || printf '%s
' '(нет текста ошибки)'
            } >> "$errors"
            rm -f "$part" "$attempt"
        done
    done

    if [ -n "${GOSHACRASH_CURL_CANDIDATES:-}" ]; then
        saved_ifs="$IFS"
        IFS=' '
        set -- $GOSHACRASH_CURL_CANDIDATES
        IFS="$saved_ifs"
    else
        detected_curl="$(command -v curl 2>/dev/null)"
        set -- "$detected_curl" /opt/bin/curl /usr/bin/curl /bin/curl
    fi

    tried=" "
    for curl_bin do
        [ -n "$curl_bin" ] || continue
        [ -x "$curl_bin" ] || continue
        case "$tried" in *" $curl_bin "*) continue;; esac
        tried="$tried$curl_bin "

        attempt="/tmp/goshacrash-fetch-attempt.$$"
        rm -f "$part" "$attempt"
        say "Загрузчик: $curl_bin"
        "$curl_bin" -k -f -L -o "$part" "$url" >"$attempt" 2>&1
        rc=$?

        if [ "$rc" -eq 0 ] && [ -s "$part" ]; then
            mv -f "$part" "$output"
            rm -f "$attempt" "$errors"
            return 0
        fi

        {
            printf '%s
' "--- $curl_bin, code=$rc ---"
            [ -s "$attempt" ] && cat "$attempt" || printf '%s
' '(нет текста ошибки)'
        } >> "$errors"
        rm -f "$part" "$attempt"
    done

    warn "Не удалось скачать $url"
    if [ -s "$errors" ]; then
        warn "Ошибки всех доступных загрузчиков:"
        cat "$errors" >&2
    else
        warn "Не найден рабочий wget или curl"
    fi

    rm -f "$part" "$output" "$errors"
    return 1
}

fetch_controller() {
    output="$1"
    urls=""

    nonce="${BUILD_ID}-$$"
    defaults="https://raw.githubusercontent.com/$REPO/$BRANCH/goshacrash?build=$nonce
https://github.com/$REPO/raw/refs/heads/$BRANCH/goshacrash?build=$nonce
https://testingcf.jsdelivr.net/gh/$REPO@$BRANCH/goshacrash?build=$nonce
https://cdn.jsdelivr.net/gh/$REPO@$BRANCH/goshacrash?build=$nonce"

    if [ -n "${GOSHACRASH_URL:-}" ]; then
        urls="$GOSHACRASH_URL
$defaults"
    else
        urls="$defaults"
    fi

    while IFS= read -r url; do
        [ -n "$url" ] || continue
        say "Скачиваю $url"
        if fetch "$url" "$output"; then
            sed -i 's/\r$//' "$output" 2>/dev/null || true
            first_line="$(sed -n '1p' "$output" 2>/dev/null)"
            got_version="$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$output" 2>/dev/null | head -n 1)"
            if [ "$first_line" = '#!/bin/sh' ] && sh -n "$output" >/dev/null 2>&1 && [ "$got_version" = "$EXPECTED_CONTROLLER_VERSION" ]; then
                return 0
            fi
            warn "Отклонён контроллер: версия '${got_version:-не определена}', ожидалась '$EXPECTED_CONTROLLER_VERSION'"
        fi
        rm -f "$output"
    done <<URLS_EOF
$urls
URLS_EOF
    return 1
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
            say "Установлен только контроллер; компоненты не запускались"
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
  sh install.sh controller-only  установить только контроллер
  sh install.sh update           обновить Mihomo и Zashboard
  sh install.sh remove           удалить GoshaCrash

Переменные:
  INSTALL_ROOT=/tmp/mnt/GOSHACRASH
  INSTALL_DIR=/tmp/mnt/GOSHACRASH/goshacrash
  REPO=goshamarat/GoshaCrash
  BRANCH=main
  GOSHACRASH_URL=https://.../goshacrash
  KEEP_CONFIG=1

Все компоненты полной установки загружаются по сети:
контроллер — из этого репозитория, Mihomo и Zashboard — контроллером.
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