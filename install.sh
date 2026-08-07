#!/bin/sh
# GoshaCrash online installer for real ASUSWRT routers.
# One copied file installs the controller, a matching Mihomo core, Zashboard,
# package tools through ASUS Download Master, configuration and autostart.

INSTALLER_VERSION="3.4.3-download-fix"
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
ROUTING_MODE=""
TUN_STACK=""
MIHOMO_TARGET=""
MIHOMO_SOURCE=""
MIHOMO_VERSION_SELECTED=""
MIHOMO_URL_SELECTED=""
CONFIG_TEMPLATE=""
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

verify_asuswrt(){
    [ -d /jffs ] || { fail "/jffs не найден: это не поддерживаемая ASUSWRT-среда"; return 1; }
    [ -d /tmp/mnt ] || { fail "/tmp/mnt не найден: USB-подсистема ASUSWRT не готова"; return 1; }
    [ -r /proc/version ] || { fail "/proc/version не найден: среда Linux не готова"; return 1; }
    find_nvram || warn "Утилита nvram не найдена; модель роутера будет определена по архитектуре и ядру"
}

tool_path(){
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

refresh_tools(){
    hash -r 2>/dev/null || true
    UNZIP_BIN="$(tool_path unzip 2>/dev/null)"
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

prepare_packages(){
    prepare_path
    find_pkg || { fail "В Download Master не найден ipkg/opkg"; return 1; }
    say "Менеджер пакетов ASUS: $PKG"

    missing=""
    for name in nano unzip wget gzip; do
        have "$name" || missing="$missing $name"
    done

    if [ -n "$missing" ]; then
        say "Не хватает пакетов:$missing"
        pkg_update_index || warn "Не удалось обновить индекс ipkg/opkg; пробую доступные пакеты"
        for name in $missing; do
            say "Устанавливаю $name через $(basename "$PKG")"
            pkg_install_one "$name" || warn "Пакет $name не установился"
            prepare_path
            refresh_tools
        done
    else
        say "Все необходимые пакеты Download Master уже установлены; обновление индекса пропущено"
    fi

    prepare_path
    refresh_tools
    [ -x "$UNZIP_BIN" ] || { fail "unzip не найден после установки через Download Master"; return 1; }
    [ -x "$GZIP_BIN" ] || { fail "gzip не найден после установки через Download Master"; return 1; }
    [ -n "$DOWNLOADER" ] || { fail "Не найден wget или curl"; return 1; }
    have nano || warn "nano не найден; GoshaCrash сможет повторить установку позже командой goshacrash pkg install nano"
    say "Инструменты: unzip=$UNZIP_BIN, gzip=$GZIP_BIN, downloader=$DOWNLOADER"
}

wget_fetch(){
    url="$1"; out="$2"
    w=""
    for p in /usr/sbin/wget /usr/bin/wget "$DM_ROOT/bin/wget" /opt/bin/wget /tmp/opt/bin/wget; do
        [ -x "$p" ] && { w="$p"; break; }
    done
    [ -n "$w" ] || return 1

    echo "--- wget: $url"
    "$w" --no-check-certificate -O "$out.part" "$url" && [ -s "$out.part" ] && {
        mv -f "$out.part" "$out"
        return 0
    }
    return 1
}

curl_fetch(){
    url="$1"; out="$2"
    c=""
    for p in "$DM_ROOT/bin/curl" /opt/bin/curl /tmp/opt/bin/curl /usr/bin/curl; do
        [ -x "$p" ] && { c="$p"; break; }
    done
    [ -n "$c" ] || return 1

    echo "--- curl: $url"
    # No connect timeout and no overall max-time: the transfer may continue as
    # long as the connection is alive. The progress bar remains visible.
    "$c" -k -fL --retry 3 --retry-delay 3 -# \
        -A "GoshaCrash/$INSTALLER_VERSION" -o "$out.part" "$url" && [ -s "$out.part" ] && {
        mv -f "$out.part" "$out"
        return 0
    }
    return 1
}

fetch(){
    url="$1"; out="$2"
    rm -f "$out" "$out.part"

    if [ "$DOWNLOADER" = "wget" ]; then
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
            ROUTING_MODE="manual"
            TUN_STACK="gvisor"
            MIHOMO_TARGET="armv5"
            MIHOMO_SOURCE="project-legacy-release"
            MIHOMO_VERSION_SELECTED="$LEGACY_MIHOMO_VERSION"
            CONFIG_TEMPLATE="config-legacy.yaml"
            return 0
            ;;
    esac

    LEGACY="0"
    ROUTING_MODE="auto"
    TUN_STACK="system"
    MIHOMO_SOURCE="official-latest"
    CONFIG_TEMPLATE="config.yaml"

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
    PLATFORM="modern-$MIHOMO_TARGET"
}

install_controller(){
    tmp="$TMP_ROOT/goshacrash.sh"
    fetch_repo_file goshacrash.sh "$tmp" || { fail "Не удалось скачать goshacrash.sh"; return 1; }
    [ "$(sed -n '1p' "$tmp" 2>/dev/null)" = '#!/bin/sh' ] || { fail "goshacrash.sh скачан неверно"; return 1; }
    sh -n "$tmp" || { fail "Синтаксическая ошибка в goshacrash.sh"; return 1; }
    [ -f "$BASE/goshacrash.sh" ] && cp -f "$BASE/goshacrash.sh" "$BASE/backups/goshacrash.sh.previous" 2>/dev/null || true
    mv -f "$tmp" "$BASE/goshacrash.sh" || return 1
    chmod 755 "$BASE/goshacrash.sh" || return 1
}

install_network_helper(){
    if [ "$LEGACY" != 1 ]; then
        GCNET_BIN=""
        return 0
    fi
    tmp="$TMP_ROOT/gcnet-armv5"
    fetch_repo_file assets/gcnet-armv5 "$tmp" || { fail "Не удалось скачать legacy network helper gcnet"; return 1; }
    [ -s "$tmp" ] || { fail "gcnet скачан пустым"; return 1; }
    chmod 755 "$tmp" || return 1
    "$tmp" link-exists lo >/dev/null 2>&1 || { fail "gcnet не запускается на этом legacy-роутере"; return 1; }
    mv -f "$tmp" "$BASE/bin/gcnet" || return 1
    chmod 755 "$BASE/bin/gcnet" || return 1
    GCNET_BIN="$BASE/bin/gcnet"
    say "Установлен совместимый legacy network helper: $GCNET_BIN"
}

install_configs(){
    tmp="$TMP_ROOT/$CONFIG_TEMPLATE"
    fetch_repo_file "$CONFIG_TEMPLATE" "$tmp" || { fail "Не удалось скачать $CONFIG_TEMPLATE"; return 1; }

    if [ ! -f "$BASE/config.yaml" ]; then
        mv -f "$tmp" "$BASE/config.yaml" || return 1
        say "Установлен config.yaml для профиля $PLATFORM"
    else
        say "Существующий config.yaml сохранён"
        rm -f "$tmp"
    fi
    chmod 600 "$BASE/config.yaml" 2>/dev/null || true
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
        if [ -n "$url" ]; then
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
    if [ "$LEGACY" = 1 ]; then
        printf '%s\n' "$out" | grep -Fq 'Use tags: with_gvisor' || { printf '%s\n' "$out" >&2; fail "Legacy-профилю нужна сборка Mihomo with_gvisor"; return 1; }
    fi
    printf '%s\n' "$out" > "$BASE/state/mihomo-version.txt"
}

install_mihomo(){
    archive="$TMP_ROOT/mihomo.gz"
    newbin="$BASE/bin/mihomo.new"
    rm -f "$archive" "$newbin"

    if [ "$LEGACY" = 1 ] && [ "${FORCE_CORE_REINSTALL:-0}" != 1 ] && [ -x "$BASE/bin/mihomo" ]; then
        existing_out="$("$BASE/bin/mihomo" -v 2>&1)"
        if printf '%s\n' "$existing_out" | grep -qi 'mihomo' && \
           printf '%s\n' "$existing_out" | grep -Fq 'Use tags: with_gvisor'; then
            printf '%s\n' "$existing_out" > "$BASE/state/mihomo-version.txt"
            say "Совместимый legacy Mihomo уже установлен; повторная загрузка ядра пропущена"
            return 0
        fi
    fi

    if [ "$LEGACY" = 1 ]; then
        success=0
        legacy_mihomo_urls | while IFS= read -r url; do
            [ -n "$url" ] || continue
            printf '%s\n' "$url"
        done > "$TMP_ROOT/legacy-urls.txt"
        while IFS= read -r url; do
            [ -n "$url" ] || continue
            say "Скачиваю проверенный legacy Mihomo: $url"
            if fetch "$url" "$archive" && validate_downloaded_mihomo "$archive" "$newbin"; then
                MIHOMO_URL_SELECTED="$url"
                success=1
                break
            fi
            rm -f "$archive" "$newbin"
        done < "$TMP_ROOT/legacy-urls.txt"
        [ "$success" -eq 1 ] || { fail "Не удалось скачать совместимый ARMv5+gVisor Mihomo из Releases проекта"; return 1; }
    else
        MIHOMO_URL_SELECTED="$(latest_official_mihomo_url)" || return 1
        MIHOMO_VERSION_SELECTED="$(printf '%s\n' "$MIHOMO_URL_SELECTED" | sed -n 's#.*/download/\([^/]*\)/.*#\1#p')"
        [ -n "$MIHOMO_VERSION_SELECTED" ] || MIHOMO_VERSION_SELECTED="$OFFICIAL_MIHOMO_FALLBACK"
        say "Скачиваю официальный Mihomo $MIHOMO_VERSION_SELECTED для $MIHOMO_TARGET"
        fetch "$MIHOMO_URL_SELECTED" "$archive" || { fail "Не удалось скачать $MIHOMO_URL_SELECTED"; return 1; }
        validate_downloaded_mihomo "$archive" "$newbin" || return 1
    fi

    [ -f "$BASE/bin/mihomo" ] && cp -f "$BASE/bin/mihomo" "$BASE/backups/mihomo.previous" 2>/dev/null || true
    mv -f "$newbin" "$BASE/bin/mihomo" || return 1
    chmod 755 "$BASE/bin/mihomo" || return 1
}

find_ui_root(){
    unpack="$1"
    for p in "$unpack/index.html" "$unpack"/*/index.html "$unpack"/*/*/index.html; do
        [ -f "$p" ] && { dirname "$p"; return 0; }
    done
    p="$(find "$unpack" -type f -name index.html 2>/dev/null | head -n 1)"
    [ -n "$p" ] && { dirname "$p"; return 0; }
    return 1
}

unpack_ui(){
    archive="$1"; unpack="$2"; dst="$3"
    "$UNZIP_BIN" -tqq "$archive" >/dev/null 2>&1 || return 1
    rm -rf "$unpack" "$dst"
    mkdir -p "$unpack" "$dst" || return 1
    "$UNZIP_BIN" -oq "$archive" -d "$unpack" >> "$INSTALL_LOG" 2>&1 || return 1
    src="$(find_ui_root "$unpack")" || return 1
    [ -s "$src/index.html" ] || return 1
    cp -R "$src"/. "$dst"/ || return 1
    [ -s "$dst/index.html" ]
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
        [ -n "$url" ] || continue
        [ "$url" = "$last_url" ] && continue
        last_url="$url"
        say "Скачиваю Zashboard: $url"
        if fetch "$url" "$archive" && unpack_ui "$archive" "$unpack" "$ui_new"; then
            selected="$url"
            break
        fi
        warn "Архив Zashboard не подошёл: $url"
        rm -rf "$unpack" "$ui_new" "$archive"
    done
    [ -n "$selected" ] || { fail "Не удалось скачать и распаковать Zashboard"; return 1; }

    rm -rf "$BASE/ui.previous"
    [ -d "$BASE/ui" ] && mv "$BASE/ui" "$BASE/ui.previous" 2>/dev/null || true
    mv "$ui_new" "$BASE/ui" || {
        [ -d "$BASE/ui.previous" ] && mv "$BASE/ui.previous" "$BASE/ui" 2>/dev/null || true
        fail "Не удалось активировать Zashboard"
        return 1
    }
    printf '%s\n' "$selected" > "$BASE/state/zashboard-source.txt"
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
CONFIG_FILE='$BASE/config.yaml'
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

    GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" install-hooks || return 1
    GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" check || return 1
    GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" restart || {
        fail "Первый запуск не удался. Проверь $BASE/logs/mihomo.log и команду goshacrash doctor"
        return 1
    }

    save_install_log
    ok "Установка завершена"
    echo
    GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" status
    echo
    echo "Справка: goshacrash help"
    echo "Zashboard: $(GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" dashboard)"
    echo "Обновление Zashboard: кнопка в панели"
}

main "$@"
