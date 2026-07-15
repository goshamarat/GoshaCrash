#!/bin/sh
# BUILD: 2026-07-15-preserve-user-tun-runtime-flexible-auto-redirect-installer-090rc1
# GoshaCrash 0.9.0-rc1 installer.
# Public runtime consists of two shell files: install.sh and goshacrash.

INSTALLER_VERSION="0.9.0-rc1"
EXPECTED_CONTROLLER_VERSION="0.9.0-rc1"
EXPECTED_CONTROLLER_BUILD="2026-07-15-preserve-user-tun-runtime-package4-090rc1"

REPO="${REPO:-goshamarat/GoshaCrash}"
BRANCH="${BRANCH:-main}"
ACTION="${1:-install}"

say(){ printf '%s\n' "[GoshaCrash installer] $*"; }
warn(){ printf '%s\n' "[GoshaCrash installer:WARN] $*" >&2; }
fail(){ printf '%s\n' "[GoshaCrash installer:ERROR] $*" >&2; return 1; }
have(){ which "$1" >/dev/null 2>&1; }

fetch(){
    url="$1"
    output="$2"
    part="$output.part.$$"
    log="/tmp/goshacrash-fetch.$$"

    rm -f "$part" "$log"

    if [ -x /usr/sbin/wget ]; then
        downloader=/usr/sbin/wget
        kind=wget
    elif have wget; then
        downloader="$(which wget)"
        kind=wget
    elif have curl; then
        downloader="$(which curl)"
        kind=curl
    else
        fail "Не найден wget или curl"
        return 1
    fi

    if [ "$kind" = wget ]; then
        HOME=/tmp "$downloader" --no-check-certificate -O "$part" "$url" >"$log" 2>&1
        rc=$?
        if [ "$rc" -ne 0 ] || [ ! -s "$part" ]; then
            rm -f "$part"
            HOME=/tmp "$downloader" -O "$part" "$url" >>"$log" 2>&1
            rc=$?
        fi
    else
        HOME=/tmp "$downloader" -k -f -L -o "$part" "$url" >"$log" 2>&1
        rc=$?
    fi

    if [ "$rc" -eq 0 ] && [ -s "$part" ]; then
        mv -f "$part" "$output"
        rm -f "$log"
        return 0
    fi

    warn "Не удалось скачать $url"
    [ -s "$log" ] && cat "$log" >&2
    rm -f "$part" "$log"
    return 1
}

validate_controller(){
    file="$1"

    [ "$(sed -n '1p' "$file" 2>/dev/null)" = '#!/bin/sh' ] || {
        fail "Получен не shell-скрипт"
        return 1
    }

    sed -i 's/\r$//' "$file" 2>/dev/null || true

    sh -n "$file" || {
        fail "Синтаксическая ошибка в goshacrash"
        return 1
    }

    version="$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$file" | head -n 1)"
    build="$(sed -n 's/^BUILD_ID="\([^"]*\)".*/\1/p' "$file" | head -n 1)"

    [ "$version" = "$EXPECTED_CONTROLLER_VERSION" ] || {
        fail "Получена версия ${version:-unknown}, ожидалась $EXPECTED_CONTROLLER_VERSION"
        return 1
    }

    [ "$build" = "$EXPECTED_CONTROLLER_BUILD" ] || {
        fail "Получена сборка ${build:-unknown}, ожидалась $EXPECTED_CONTROLLER_BUILD"
        return 1
    }

    return 0
}

fetch_valid_controller(){
    output="$1"
    shift

    for url in "$@"; do
        [ -n "$url" ] || continue
        say "Пробую контроллер: $url"
        rm -f "$output"

        if fetch "$url" "$output"; then
            if validate_controller "$output"; then
                return 0
            fi
            warn "Источник вернул старую или неподходящую сборку; пробую следующий"
        fi
    done

    rm -f "$output"
    return 1
}

find_usb_mount(){
    if [ -n "${INSTALL_ROOT:-}" ]; then
        [ -d "$INSTALL_ROOT" ] || {
            fail "Нет $INSTALL_ROOT"
            return 1
        }
        echo "$INSTALL_ROOT"
        return 0
    fi

    [ -d /tmp/mnt/GOSHACRASH/asusware.arm ] && {
        echo /tmp/mnt/GOSHACRASH
        return 0
    }

    found=""
    count=0
    for candidate in /tmp/mnt/*; do
        [ -d "$candidate/asusware.arm" ] || continue
        [ -w "$candidate" ] || continue
        found="$candidate"
        count=$((count + 1))
    done

    if [ "$count" -eq 1 ]; then
        echo "$found"
        return 0
    fi

    if [ "$count" -gt 1 ]; then
        fail "Найдено несколько флешек; укажи INSTALL_ROOT=/tmp/mnt/МЕТКА"
    else
        fail "Не найдена флешка Download Master"
    fi
    return 1
}

write_command_wrapper(){
    mount="$1"
    base="$2"
    dir="$mount/asusware.arm/bin"
    target="$dir/goshacrash"

    mkdir -p "$dir" || return 1

    cat > "$target" <<WRAP
#!/bin/sh
BASE_FILE="/jffs/addons/goshacrash/base"
BASE="$base"
[ -f "\$BASE_FILE" ] && {
    x="\$(cat "\$BASE_FILE" 2>/dev/null)"
    [ -n "\$x" ] && BASE="\$x"
}
exec "\$BASE/goshacrash" "\$@"
WRAP

    chmod 755 "$target" || return 1
    [ -d /opt/bin ] && ln -sf "$target" /opt/bin/goshacrash 2>/dev/null || true
}

install_controller(){
    mount="$1"
    base="${INSTALL_DIR:-$mount/goshacrash}"
    target="$base/goshacrash"
    tmp="/tmp/goshacrash.new.$$"

    mkdir -p "$base" "$base/backups" "$base/run" "$base/logs" "$base/state" || return 1

    if [ -n "${CONTROLLER_FILE:-}" ]; then
        cp "$CONTROLLER_FILE" "$tmp" || return 1
        validate_controller "$tmp" || {
            rm -f "$tmp"
            return 1
        }
    elif [ -n "${GOSHACRASH_URL:-}" ]; then
        fetch "$GOSHACRASH_URL" "$tmp" || return 1
        validate_controller "$tmp" || {
            rm -f "$tmp"
            return 1
        }
    else
        nonce="$(date '+%s' 2>/dev/null)-$$"
        [ -n "$nonce" ] || nonce="$$"

        # raw.githubusercontent.com идёт первым, чтобы не получить старый
        # контроллер из CDN-кэша. Каждый источник проверяется по BUILD_ID.
        fetch_valid_controller "$tmp" \
          "https://raw.githubusercontent.com/$REPO/$BRANCH/goshacrash?v=$EXPECTED_CONTROLLER_BUILD-$nonce" \
          "https://github.com/$REPO/raw/refs/heads/$BRANCH/goshacrash?v=$EXPECTED_CONTROLLER_BUILD-$nonce" \
          "https://testingcf.jsdelivr.net/gh/$REPO@$BRANCH/goshacrash?v=$EXPECTED_CONTROLLER_BUILD-$nonce" \
          "https://cdn.jsdelivr.net/gh/$REPO@$BRANCH/goshacrash?v=$EXPECTED_CONTROLLER_BUILD-$nonce" || {
              fail "Не удалось получить требуемую сборку контроллера"
              return 1
          }
    fi

    stamp="$(date '+%Y%m%d-%H%M%S' 2>/dev/null)"
    [ -n "$stamp" ] || stamp=backup
    backup="$base/backups/controller-$stamp"
    mkdir -p "$backup" || return 1

    [ -f "$target" ] && cp "$target" "$backup/goshacrash" || true
    [ -f "$base/goshacrash.core" ] && cp "$base/goshacrash.core" "$backup/goshacrash.core" || true
    [ -f "$base/config.yaml" ] && cp "$base/config.yaml" "$backup/config.yaml" || true

    [ -x "$target" ] &&
        GOSHACRASH_BASE="$base" "$target" stop >/dev/null 2>&1 || true

    chmod 755 "$tmp" || return 1
    mv -f "$tmp" "$target" || return 1
    chmod 755 "$target" || return 1

    rm -f "$base/goshacrash.core"

    mkdir -p /jffs/addons/goshacrash || return 1
    printf '%s\n' "$base" > /jffs/addons/goshacrash/base || return 1
    write_command_wrapper "$mount" "$base" || return 1

    say "Установлен контроллер: $target"
    say "BUILD_ID: $EXPECTED_CONTROLLER_BUILD"
    say "Резервная копия: $backup"

    case "$ACTION" in
        install)
            GOSHACRASH_BASE="$base" "$target" install
            ;;
        controller-only)
            say "Контроллер заменён без применения config.yaml"
            say "Дальше: скопируй личный config.yaml, затем выполни goshacrash check и goshacrash apply"
            ;;
        update)
            GOSHACRASH_BASE="$base" "$target" update
            ;;
    esac
}

remove_installation(){
    mount="$(find_usb_mount)" || return 1
    base="${INSTALL_DIR:-$mount/goshacrash}"

    [ -x "$base/goshacrash" ] &&
        GOSHACRASH_BASE="$base" "$base/goshacrash" uninstall-hooks >/dev/null 2>&1 || true

    rm -f "$mount/asusware.arm/bin/goshacrash" /opt/bin/goshacrash

    if [ "${KEEP_CONFIG:-0}" = 1 ] && [ -f "$base/config.yaml" ]; then
        cp "$base/config.yaml" "$mount/goshacrash-config.yaml" || return 1
    fi

    rm -rf "$base"
    say "Удалено: $base"
}

case "$ACTION" in
    help|-h|--help)
        cat <<'HELP'
Использование:
  sh install.sh install
  sh install.sh controller-only   # заменить только контроллер, не применять конфиг
  sh install.sh update
  sh install.sh remove

Переменные:
  INSTALL_ROOT=/tmp/mnt/GOSHACRASH
  INSTALL_DIR=/tmp/mnt/GOSHACRASH/goshacrash
  REPO=goshamarat/GoshaCrash
  BRANCH=main
  CONTROLLER_FILE=/локальный/путь/goshacrash
  GOSHACRASH_URL=https://.../goshacrash
  KEEP_CONFIG=1
HELP
        exit 0
        ;;
    remove|uninstall)
        remove_installation
        exit $?
        ;;
    install|controller-only|update)
        ;;
    *)
        fail "Неизвестное действие: $ACTION"
        exit 1
        ;;
esac

mount="$(find_usb_mount)" || exit 1
[ -d "$mount/asusware.arm" ] || {
    fail "Download Master не найден"
    exit 1
}

say "Версия установщика: $INSTALLER_VERSION"
say "Ожидаемая сборка: $EXPECTED_CONTROLLER_BUILD"
say "Флешка: $mount"

install_controller "$mount" || {
    fail "Установка не завершена"
    exit 1
}

base="${INSTALL_DIR:-$mount/goshacrash}"
echo
GOSHACRASH_BASE="$base" "$base/goshacrash" status || true