#!/bin/sh
# GoshaCrash online bootstrap installer for legacy ASUSWRT routers.
# Installs everything from GitHub and uses Download Master/Optware for packages.

INSTALLER_VERSION="3.0.0-online"
REPO="${REPO:-goshamarat/GoshaCrash}"
BRANCH="${BRANCH:-main}"
ACTION="${1:-install}"

MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.28}"
MIHOMO_TAG="${MIHOMO_TAG:-mihomo-gvisor-armv5-$MIHOMO_VERSION}"
MIHOMO_ASSET="${MIHOMO_ASSET:-mihomo-linux-armv5-gvisor-$MIHOMO_VERSION.gz}"
MIHOMO_URL="${MIHOMO_URL:-https://github.com/$REPO/releases/download/$MIHOMO_TAG/$MIHOMO_ASSET}"
MIHOMO_SHA_URL="${MIHOMO_SHA_URL:-$MIHOMO_URL.sha256}"
ZASHBOARD_URL="${ZASHBOARD_URL:-https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip}"

TMP_ROOT="/tmp/goshacrash-install.$$"
TMP_LOG="/tmp/goshacrash-install.log"
INSTALL_LOG="$TMP_LOG"
USB_MOUNT=""
DM_ROOT=""
BASE=""
PKG=""

now(){ date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date; }
_emit(){ level="$1"; shift; line="[$(now)] [$level] [install] $*"; printf '%s\n' "$line"; printf '%s\n' "$line" >> "$INSTALL_LOG" 2>/dev/null || true; }
say(){ _emit INFO "$@"; }
ok(){ _emit OK "$@"; }
warn(){ _emit WARN "$@" >&2; }
fail(){ _emit ERROR "$@" >&2; return 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

cleanup(){ rm -rf "$TMP_ROOT" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM

usage(){
    cat <<'USAGE'
GoshaCrash online installer

Использование:
  sh install.sh                 полная установка
  sh install.sh install         полная установка
  sh install.sh repair          повторно скачать недостающие компоненты
  sh install.sh remove          удалить GoshaCrash, сохранив config.yaml

Переменные:
  INSTALL_ROOT=/tmp/mnt/МЕТКА
  INSTALL_DIR=/tmp/mnt/МЕТКА/goshacrash
  REPO=goshamarat/GoshaCrash
  BRANCH=main
  MIHOMO_URL=https://...
  ZASHBOARD_URL=https://...
USAGE
}

find_download_master(){
    if [ -n "${INSTALL_ROOT:-}" ]; then
        [ -d "$INSTALL_ROOT" ] || { fail "INSTALL_ROOT не существует: $INSTALL_ROOT"; return 1; }
        USB_MOUNT="$INSTALL_ROOT"
        for d in "$USB_MOUNT/asusware.arm" "$USB_MOUNT/asusware.arm64" "$USB_MOUNT/asusware"; do
            [ -d "$d" ] && { DM_ROOT="$d"; return 0; }
        done
        fail "Download Master не найден внутри $USB_MOUNT"
        return 1
    fi

    preferred=""
    if [ -L /opt ] && have readlink; then
        preferred="$(readlink /opt 2>/dev/null)"
    fi

    count=0
    found_mount=""
    found_dm=""
    for mount in /tmp/mnt/*; do
        [ -d "$mount" ] || continue
        [ -w "$mount" ] || continue
        for d in "$mount/asusware.arm" "$mount/asusware.arm64" "$mount/asusware"; do
            [ -d "$d" ] || continue
            case "$preferred" in
                "$d"|"$d"/*) USB_MOUNT="$mount"; DM_ROOT="$d"; return 0 ;;
            esac
            count=$((count + 1))
            found_mount="$mount"
            found_dm="$d"
            break
        done
    done

    if [ "$count" -eq 1 ]; then
        USB_MOUNT="$found_mount"
        DM_ROOT="$found_dm"
        return 0
    fi
    if [ "$count" -gt 1 ]; then
        fail "Найдено несколько установок Download Master. Запусти с INSTALL_ROOT=/tmp/mnt/МЕТКА"
    else
        fail "Download Master не найден. Сначала установи и запусти его в ASUSWRT"
    fi
    return 1
}

attach_opt(){
    [ -d "$DM_ROOT" ] || return 1
    if [ -L /opt ]; then
        [ -d /opt ] || { rm -f /opt 2>/dev/null || true; ln -s "$DM_ROOT" /opt 2>/dev/null || true; }
    elif [ ! -e /opt ]; then
        ln -s "$DM_ROOT" /opt 2>/dev/null || true
    fi
    PATH="$DM_ROOT/bin:$DM_ROOT/sbin:/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
    export PATH
}

find_pkg(){
    PKG=""
    for p in "$DM_ROOT/bin/ipkg" "$DM_ROOT/bin/opkg" /opt/bin/ipkg /opt/bin/opkg; do
        [ -x "$p" ] && { PKG="$p"; break; }
    done
    [ -n "$PKG" ]
}

pkg_install(){
    name="$1"
    [ -n "$PKG" ] || return 1
    "$PKG" install "$name" >> "$INSTALL_LOG" 2>&1
}

prepare_packages(){
    attach_opt
    if ! find_pkg; then
        warn "ipkg/opkg не найден. Download Master есть, но менеджер пакетов не готов"
        return 0
    fi
    say "Менеджер пакетов: $PKG"
    "$PKG" update >> "$INSTALL_LOG" 2>&1 || warn "Не удалось обновить индекс пакетов"

    have nano || pkg_install nano || warn "nano пока не установлен"
    have unzip || pkg_install unzip || warn "unzip пока не установлен"
    have wget || pkg_install wget || warn "wget пока не установлен"
    have gzip || pkg_install gzip || warn "gzip пока не установлен"

    have unzip || { fail "Нужен unzip; установка через Download Master не удалась"; return 1; }
    have gzip || { fail "Нужен gzip; установка через Download Master не удалась"; return 1; }
    have wget || have curl || { fail "Нужен wget или curl"; return 1; }
}

wget_fetch(){
    url="$1"; out="$2"
    for w in "$DM_ROOT/bin/wget" /opt/bin/wget /usr/sbin/wget /usr/bin/wget; do
        [ -x "$w" ] || continue
        "$w" -q --no-check-certificate -O "$out.part" "$url" >/dev/null 2>&1 && [ -s "$out.part" ] && { mv -f "$out.part" "$out"; return 0; }
        "$w" -q -O "$out.part" "$url" >/dev/null 2>&1 && [ -s "$out.part" ] && { mv -f "$out.part" "$out"; return 0; }
    done
    if have wget; then
        wget -q --no-check-certificate -O "$out.part" "$url" >/dev/null 2>&1 && [ -s "$out.part" ] && { mv -f "$out.part" "$out"; return 0; }
        wget -q -O "$out.part" "$url" >/dev/null 2>&1 && [ -s "$out.part" ] && { mv -f "$out.part" "$out"; return 0; }
    fi
    return 1
}

curl_fetch(){
    url="$1"; out="$2"
    for c in "$DM_ROOT/bin/curl" /opt/bin/curl /usr/bin/curl; do
        [ -x "$c" ] || continue
        "$c" -k -fL --connect-timeout 25 -o "$out.part" "$url" >/dev/null 2>&1 && [ -s "$out.part" ] && { mv -f "$out.part" "$out"; return 0; }
    done
    have curl && curl -k -fL --connect-timeout 25 -o "$out.part" "$url" >/dev/null 2>&1 && [ -s "$out.part" ] && { mv -f "$out.part" "$out"; return 0; }
    return 1
}

fetch(){
    url="$1"; out="$2"
    rm -f "$out" "$out.part"
    n=1
    while [ "$n" -le 3 ]; do
        wget_fetch "$url" "$out" && return 0
        curl_fetch "$url" "$out" && return 0
        sleep 2
        n=$((n + 1))
    done
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

sha256_one(){
    file="$1"
    if have sha256sum; then sha256sum "$file" 2>/dev/null | awk 'NR==1{print tolower($1);exit}'; return; fi
    if have busybox && busybox sha256sum "$file" >/dev/null 2>&1; then busybox sha256sum "$file" | awk 'NR==1{print tolower($1);exit}'; return; fi
    if have openssl; then openssl dgst -sha256 "$file" 2>/dev/null | sed 's/^.*= //' | tr 'A-F' 'a-f'; return; fi
    return 1
}

verify_mihomo_archive(){
    archive="$1"; sha_file="$2"
    gzip -t "$archive" >/dev/null 2>&1 || { fail "Архив Mihomo повреждён"; return 1; }
    if [ -s "$sha_file" ]; then
        expected="$(awk 'NR==1{print tolower($1);exit}' "$sha_file" | tr -d '\r')"
        actual="$(sha256_one "$archive" 2>/dev/null)"
        [ -n "$actual" ] || { warn "На роутере нет SHA-256; проверена только целостность gzip"; return 0; }
        [ "$actual" = "$expected" ] || { fail "SHA-256 Mihomo не совпал"; return 1; }
    else
        warn "Файл SHA-256 недоступен; проверена только целостность gzip"
    fi
}

make_secret(){
    if [ -r /dev/urandom ] && have od; then od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'; return; fi
    if [ -r /dev/urandom ] && have hexdump; then hexdump -n 16 -e '16/1 "%02x"' /dev/urandom 2>/dev/null; return; fi
    printf '%s' "$(nvram get et0macaddr 2>/dev/null)-$(date +%s 2>/dev/null)-$$" | tr -cd 'A-Za-z0-9' | head -c 32
}

prepare_config(){
    if [ ! -f "$BASE/config.yaml" ]; then
        cp "$BASE/config.example.yaml" "$BASE/config.yaml" || return 1
    fi
    if grep -Eq '^secret:[[:space:]]*"CHANGE_ME"[[:space:]]*$' "$BASE/config.yaml" 2>/dev/null; then
        secret="$(make_secret)"; [ -n "$secret" ] || secret="goshacrash$(date +%s 2>/dev/null)"
        sed "s/^secret:.*/secret: \"$secret\"/" "$BASE/config.yaml" > "$BASE/config.yaml.new" || return 1
        mv -f "$BASE/config.yaml.new" "$BASE/config.yaml" || return 1
    fi
    chmod 600 "$BASE/config.yaml" 2>/dev/null || true
}

install_controller(){
    tmp="$TMP_ROOT/goshacrash.sh"
    fetch_repo_file goshacrash.sh "$tmp" || { fail "Не удалось скачать goshacrash.sh"; return 1; }
    [ "$(sed -n '1p' "$tmp" 2>/dev/null)" = '#!/bin/sh' ] || { fail "Вместо goshacrash.sh загружен неверный файл"; return 1; }
    sh -n "$tmp" || { fail "Синтаксическая ошибка в goshacrash.sh"; return 1; }
    if [ -f "$BASE/goshacrash.sh" ]; then cp "$BASE/goshacrash.sh" "$BASE/backups/goshacrash.sh.previous" 2>/dev/null || true; fi
    mv -f "$tmp" "$BASE/goshacrash.sh" || return 1
    chmod 755 "$BASE/goshacrash.sh" || return 1
}

install_config_template(){
    tmp="$TMP_ROOT/config.example.yaml"
    fetch_repo_file config.example.yaml "$tmp" || { fail "Не удалось скачать config.example.yaml"; return 1; }
    mv -f "$tmp" "$BASE/config.example.yaml" || return 1
    prepare_config || { fail "Не удалось подготовить config.yaml"; return 1; }
}

install_mihomo(){
    archive="$TMP_ROOT/mihomo.gz"
    sha_file="$TMP_ROOT/mihomo.sha256"
    say "Скачиваю проверенную Mihomo $MIHOMO_VERSION ARMv5 + gVisor"
    fetch "$MIHOMO_URL" "$archive" || { fail "Не удалось скачать Mihomo: $MIHOMO_URL"; return 1; }
    fetch "$MIHOMO_SHA_URL" "$sha_file" || :
    verify_mihomo_archive "$archive" "$sha_file" || return 1
    gzip -dc "$archive" > "$BASE/bin/mihomo.new" || return 1
    chmod 755 "$BASE/bin/mihomo.new" || return 1
    out="$($BASE/bin/mihomo.new -v 2>&1)" || { printf '%s\n' "$out" >&2; fail "Mihomo не запускается на этом роутере"; return 1; }
    printf '%s\n' "$out" | grep -Fq 'Use tags: with_gvisor' || { printf '%s\n' "$out" >&2; fail "Mihomo собран без with_gvisor"; return 1; }
    printf '%s\n' "$out" | grep -Eqi 'linux (arm|arm32)' || { printf '%s\n' "$out" >&2; fail "Загружен не ARM-бинарник"; return 1; }
    [ -f "$BASE/bin/mihomo" ] && cp "$BASE/bin/mihomo" "$BASE/backups/mihomo.previous" 2>/dev/null || true
    mv -f "$BASE/bin/mihomo.new" "$BASE/bin/mihomo" || return 1
}

flatten_ui(){
    src="$1"; dst="$2"
    index="$(find "$src" -type f -name index.html 2>/dev/null | head -n 1)"
    [ -n "$index" ] || return 1
    root="$(dirname "$index")"
    rm -rf "$dst"
    mkdir -p "$dst" || return 1
    cp -R "$root"/. "$dst"/ || return 1
    [ -f "$dst/index.html" ]
}

install_zashboard(){
    archive="$TMP_ROOT/zashboard.zip"
    unpack="$TMP_ROOT/zashboard-unpack"
    ui_new="$BASE/ui.new"
    say "Скачиваю Zashboard"
    fetch "$ZASHBOARD_URL" "$archive" || { fail "Не удалось скачать Zashboard"; return 1; }
    rm -rf "$unpack" "$ui_new"
    mkdir -p "$unpack" || return 1
    unzip -oq "$archive" -d "$unpack" >> "$INSTALL_LOG" 2>&1 || { fail "Архив Zashboard не распаковался"; return 1; }
    flatten_ui "$unpack" "$ui_new" || { fail "В архиве Zashboard нет index.html"; return 1; }
    rm -rf "$BASE/ui.previous"
    [ -d "$BASE/ui" ] && mv "$BASE/ui" "$BASE/ui.previous" 2>/dev/null || true
    mv "$ui_new" "$BASE/ui" || { [ -d "$BASE/ui.previous" ] && mv "$BASE/ui.previous" "$BASE/ui"; return 1; }
}

save_install_log(){
    mkdir -p "$BASE/logs" 2>/dev/null || return 0
    if [ "$INSTALL_LOG" = "$TMP_LOG" ]; then
        cat "$TMP_LOG" >> "$BASE/logs/install.log" 2>/dev/null || true
        INSTALL_LOG="$BASE/logs/install.log"
    fi
}

remove_installation(){
    find_download_master || return 1
    BASE="${INSTALL_DIR:-$USB_MOUNT/goshacrash}"
    if [ -x "$BASE/goshacrash.sh" ]; then GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" stop >/dev/null 2>&1 || true; fi
    if [ -f "$BASE/config.yaml" ]; then cp "$BASE/config.yaml" "$USB_MOUNT/goshacrash-config.yaml" || return 1; fi
    rm -rf "$BASE"
    rm -f "$DM_ROOT/bin/goshacrash" /opt/bin/goshacrash 2>/dev/null || true
    rm -rf /jffs/addons/goshacrash 2>/dev/null || true
    say "Удалено. Конфиг сохранён как $USB_MOUNT/goshacrash-config.yaml"
}

main(){
    : > "$TMP_LOG"
    case "$ACTION" in
        help|-h|--help) usage; return 0 ;;
        remove|uninstall) remove_installation; return $? ;;
        install|repair) ;;
        *) usage; return 1 ;;
    esac

    find_download_master || return 1
    BASE="${INSTALL_DIR:-$USB_MOUNT/goshacrash}"
    mkdir -p "$TMP_ROOT" "$BASE/bin" "$BASE/ui" "$BASE/logs" "$BASE/run" "$BASE/state" "$BASE/backups" || return 1
    save_install_log

    say "GoshaCrash installer $INSTALLER_VERSION"
    say "USB: $USB_MOUNT"
    say "Download Master: $DM_ROOT"
    say "Каталог установки: $BASE"

    case "$(uname -m 2>/dev/null)" in arm*|ARM*) ;; *) fail "Эта сборка предназначена для ARM ASUSWRT"; return 1 ;; esac

    prepare_packages || return 1
    install_controller || return 1
    install_config_template || return 1
    install_mihomo || return 1
    install_zashboard || return 1

    GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" install-hooks || return 1
    GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" check || return 1
    GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" restart || {
        fail "Первый запуск не удался. Лог: $BASE/logs/mihomo.log"
        return 1
    }

    save_install_log
    ok "Установка завершена"
    echo
    GOSHACRASH_BASE="$BASE" "$BASE/goshacrash.sh" status
    echo
    echo "Управление: goshacrash"
    echo "Конфиг: $BASE/config.yaml"
}

main "$@"
