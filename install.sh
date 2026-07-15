#!/bin/sh
# BUILD: 2026-07-16-pure-tun-gvisor-installer-090rc61
# GoshaCrash 0.9.0-rc6.1 installer: pure TUN with ARMv5 gVisor Mihomo.

INSTALLER_VERSION="0.9.0-rc6.1"
EXPECTED_CONTROLLER_VERSION="0.9.0-rc6.1"
EXPECTED_CONTROLLER_BUILD="2026-07-16-pure-tun-gvisor-sha256-fallback-090rc61"
EXPECTED_ROUTE_VERSION="0.9.0-rc6.1"
EXPECTED_ROUTE_BUILD="2026-07-16-pure-tun-gvisor-routing-helper-090rc61"

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

validate_script(){
    file="$1"
    expected_version="$2"
    expected_build="$3"
    label="$4"

    [ "$(sed -n '1p' "$file" 2>/dev/null)" = '#!/bin/sh' ] || {
        fail "$label: получен не shell-скрипт"
        return 1
    }

    tr -d '\r' < "$file" > "$file.lf" || return 1
    mv -f "$file.lf" "$file" || return 1

    sh -n "$file" || {
        fail "$label: синтаксическая ошибка"
        return 1
    }

    version="$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$file" | head -n 1)"
    build="$(sed -n 's/^BUILD_ID="\([^"]*\)".*/\1/p' "$file" | head -n 1)"

    [ "$version" = "$expected_version" ] || {
        fail "$label: версия ${version:-unknown}, ожидалась $expected_version"
        return 1
    }
    [ "$build" = "$expected_build" ] || {
        fail "$label: сборка ${build:-unknown}, ожидалась $expected_build"
        return 1
    }
}

fetch_valid(){
    output="$1"
    expected_version="$2"
    expected_build="$3"
    filename="$4"
    label="$5"
    nonce="$(date '+%s' 2>/dev/null)-$$"

    for url in \
      "https://raw.githubusercontent.com/$REPO/$BRANCH/$filename?v=$expected_build-$nonce" \
      "https://github.com/$REPO/raw/refs/heads/$BRANCH/$filename?v=$expected_build-$nonce" \
      "https://testingcf.jsdelivr.net/gh/$REPO@$BRANCH/$filename?v=$expected_build-$nonce" \
      "https://cdn.jsdelivr.net/gh/$REPO@$BRANCH/$filename?v=$expected_build-$nonce"; do
        say "Пробую $label: $url"
        rm -f "$output"
        if fetch "$url" "$output" &&
           validate_script "$output" "$expected_version" "$expected_build" "$label"; then
            return 0
        fi
        warn "$label: источник не подошёл; пробую следующий"
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

write_wrappers(){
    mount="$1"
    base="$2"
    dir="$mount/asusware.arm/bin"
    mkdir -p "$dir" || return 1

    cat > "$dir/goshacrash" <<WRAP
#!/bin/sh
BASE_FILE="/jffs/addons/goshacrash/base"
BASE="$base"
[ -f "\$BASE_FILE" ] && {
    x="\$(cat "\$BASE_FILE" 2>/dev/null)"
    [ -n "\$x" ] && BASE="\$x"
}
exec "\$BASE/goshacrash" "\$@"
WRAP
    chmod 755 "$dir/goshacrash" || return 1

    cat > "$dir/goshacrash-route" <<WRAP
#!/bin/sh
BASE_FILE="/jffs/addons/goshacrash/base"
BASE="$base"
[ -f "\$BASE_FILE" ] && {
    x="\$(cat "\$BASE_FILE" 2>/dev/null)"
    [ -n "\$x" ] && BASE="\$x"
}
exec "\$BASE/goshacrash-route" "\$@"
WRAP
    chmod 755 "$dir/goshacrash-route" || return 1

    [ -d /opt/bin ] && {
        ln -sf "$dir/goshacrash" /opt/bin/goshacrash 2>/dev/null || true
        ln -sf "$dir/goshacrash-route" /opt/bin/goshacrash-route 2>/dev/null || true
    }
}

install_files(){
    mount="$1"
    base="${INSTALL_DIR:-$mount/goshacrash}"
    ctl="$base/goshacrash"
    route="$base/goshacrash-route"
    ctl_tmp="/tmp/goshacrash.new.$$"
    route_tmp="/tmp/goshacrash-route.new.$$"

    mkdir -p "$base" "$base/backups" "$base/run" "$base/logs" "$base/state" || return 1

    if [ -n "${CONTROLLER_FILE:-}" ]; then
        cp "$CONTROLLER_FILE" "$ctl_tmp" || return 1
        validate_script "$ctl_tmp" "$EXPECTED_CONTROLLER_VERSION" "$EXPECTED_CONTROLLER_BUILD" controller || return 1
    else
        fetch_valid "$ctl_tmp" "$EXPECTED_CONTROLLER_VERSION" "$EXPECTED_CONTROLLER_BUILD" goshacrash controller || return 1
    fi

    if [ -n "${ROUTE_FILE:-}" ]; then
        cp "$ROUTE_FILE" "$route_tmp" || return 1
        validate_script "$route_tmp" "$EXPECTED_ROUTE_VERSION" "$EXPECTED_ROUTE_BUILD" routing-helper || return 1
    else
        fetch_valid "$route_tmp" "$EXPECTED_ROUTE_VERSION" "$EXPECTED_ROUTE_BUILD" goshacrash-route routing-helper || return 1
    fi

    stamp="$(date '+%Y%m%d-%H%M%S' 2>/dev/null)"
    [ -n "$stamp" ] || stamp=backup
    backup="$base/backups/controller-$stamp"
    mkdir -p "$backup" || return 1

    [ -f "$ctl" ] && cp "$ctl" "$backup/goshacrash" || true
    [ -f "$route" ] && cp "$route" "$backup/goshacrash-route" || true
    [ -f "$base/config.yaml" ] && cp "$base/config.yaml" "$backup/config.yaml" || true

    [ -x "$ctl" ] && GOSHACRASH_BASE="$base" "$ctl" stop >/dev/null 2>&1 || true

    chmod 755 "$ctl_tmp" "$route_tmp" || return 1
    mv -f "$ctl_tmp" "$ctl" || return 1
    mv -f "$route_tmp" "$route" || return 1
    chmod 755 "$ctl" "$route" || return 1

    mkdir -p /jffs/addons/goshacrash || return 1
    printf '%s\n' "$base" > /jffs/addons/goshacrash/base || return 1
    write_wrappers "$mount" "$base" || return 1

    say "Контроллер: $EXPECTED_CONTROLLER_BUILD"
    say "Routing helper: $EXPECTED_ROUTE_BUILD"
    say "Резервная копия: $backup"

    case "$ACTION" in
        install)
            GOSHACRASH_BASE="$base" "$ctl" install
            ;;
        controller-only)
            say "Скрипты заменены без применения config.yaml"
            ;;
        update)
            GOSHACRASH_BASE="$base" "$ctl" update
            ;;
    esac
}

remove_installation(){
    mount="$(find_usb_mount)" || return 1
    base="${INSTALL_DIR:-$mount/goshacrash}"

    [ -x "$base/goshacrash" ] &&
        GOSHACRASH_BASE="$base" "$base/goshacrash" uninstall-hooks >/dev/null 2>&1 || true

    rm -f "$mount/asusware.arm/bin/goshacrash" \
          "$mount/asusware.arm/bin/goshacrash-route" \
          /opt/bin/goshacrash /opt/bin/goshacrash-route

    [ "${KEEP_CONFIG:-0}" = 1 ] && [ -f "$base/config.yaml" ] &&
        cp "$base/config.yaml" "$mount/goshacrash-config.yaml"

    rm -rf "$base"
    say "Удалено: $base"
}

case "$ACTION" in
    help|-h|--help)
        cat <<'HELP'
Использование:
  sh install.sh install
  sh install.sh controller-only
  sh install.sh update
  sh install.sh remove

Локальная установка файлов:
  CONTROLLER_FILE=/tmp/goshacrash ROUTE_FILE=/tmp/goshacrash-route \
    sh install.sh controller-only
HELP
        exit 0
        ;;
    remove|uninstall)
        remove_installation
        exit $?
        ;;
    install|controller-only|update) ;;
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

say "Версия: $INSTALLER_VERSION"
say "Флешка: $mount"
install_files "$mount" || {
    fail "Установка не завершена"
    exit 1
}

base="${INSTALL_DIR:-$mount/goshacrash}"
echo
GOSHACRASH_BASE="$base" "$base/goshacrash" status || true
