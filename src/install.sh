#!/bin/sh
# GoshaCrash local installer. No downloads are performed on the router.

INSTALLER_VERSION="1.2.0-local"

say(){ printf '%s\n' "[GoshaCrash installer] $*"; }
warn(){ printf '%s\n' "[GoshaCrash installer:WARN] $*" >&2; }
fail(){ printf '%s\n' "[GoshaCrash installer:ERROR] $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)"
BASE="${GOSHACRASH_BASE:-$SCRIPT_DIR}"

case "$BASE" in
    /tmp/mnt/*/*) USB_MOUNT="$(printf '%s\n' "$BASE" | awk -F/ '{print "/tmp/mnt/" $4}')" ;;
    *) fail "Папка должна находиться на флешке внутри /tmp/mnt/<МЕТКА>/" ;;
esac

[ -d "$USB_MOUNT/asusware.arm" ] || fail "Не найден Download Master: $USB_MOUNT/asusware.arm"
[ -w "$BASE" ] || fail "Нет прав записи в $BASE"

case "$(uname -m 2>/dev/null)" in
    arm*|ARM*) ;;
    *) fail "Эта сборка предназначена для ARM-роутера" ;;
esac

sha256_one(){
    file="$1"
    if have sha256sum; then sha256sum "$file" 2>/dev/null | awk 'NR==1{print $1;exit}'; return; fi
    if have busybox && busybox sha256sum "$file" >/dev/null 2>&1; then busybox sha256sum "$file" | awk 'NR==1{print $1;exit}'; return; fi
    if have openssl; then openssl dgst -sha256 "$file" 2>/dev/null | sed 's/^.*= //'; return; fi
    return 1
}

verify_manifest(){
    manifest="$BASE/MANIFEST.sha256"
    [ -f "$manifest" ] || fail "Нет MANIFEST.sha256"
    say "Проверяю целостность локального пакета"
    while read expected rel; do
        [ -n "$expected" ] || continue
        rel="${rel#\*}"
        [ -f "$BASE/$rel" ] || fail "В пакете отсутствует: $rel"
        actual="$(sha256_one "$BASE/$rel")" || fail "На роутере нет SHA-256 инструмента"
        [ "$actual" = "$expected" ] || fail "Повреждён файл: $rel"
    done < "$manifest"
}

make_secret(){
    if [ -r /dev/urandom ] && have od; then
        od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
        return
    fi
    if [ -r /dev/urandom ] && have hexdump; then
        hexdump -n 16 -e '16/1 "%02x"' /dev/urandom 2>/dev/null
        return
    fi
    printf '%s' "$(nvram get et0macaddr 2>/dev/null)-$(date +%s 2>/dev/null)-$$" | tr -cd 'A-Za-z0-9' | head -c 32
}

prepare_config(){
    if [ ! -f "$BASE/config.yaml" ]; then
        [ -f "$BASE/config.example.yaml" ] || fail "Нет config.example.yaml"
        cp "$BASE/config.example.yaml" "$BASE/config.yaml" || fail "Не удалось создать config.yaml"
    fi

    if grep -Eq '^secret:[[:space:]]*"CHANGE_ME"[[:space:]]*$' "$BASE/config.yaml" 2>/dev/null; then
        secret="$(make_secret)"
        [ -n "$secret" ] || secret="goshacrash$(date +%s 2>/dev/null)"
        sed "s/^secret:.*/secret: \"$secret\"/" "$BASE/config.yaml" > "$BASE/config.yaml.new" || fail "Не удалось создать secret"
        mv -f "$BASE/config.yaml.new" "$BASE/config.yaml" || fail "Не удалось сохранить secret"
    fi
    chmod 600 "$BASE/config.yaml" 2>/dev/null || true
}

verify_manifest

for f in goshacrash goshacrash-route install.sh bin/mihomo; do
    [ -f "$BASE/$f" ] || fail "Нет обязательного файла: $f"
done
[ -f "$BASE/ui/index.html" ] || fail "В ui отсутствует index.html"

chmod 755 "$BASE/goshacrash" "$BASE/goshacrash-route" "$BASE/bin/mihomo" || fail "Не удалось выставить права"
sh -n "$BASE/goshacrash" || fail "Синтаксическая ошибка goshacrash"
sh -n "$BASE/goshacrash-route" || fail "Синтаксическая ошибка goshacrash-route"

version="$($BASE/bin/mihomo -v 2>&1)" || { printf '%s\n' "$version" >&2; fail "Mihomo не запускается на роутере"; }
printf '%s\n' "$version" | grep -Fq 'Use tags: with_gvisor' || { printf '%s\n' "$version" >&2; fail "Mihomo собран без with_gvisor"; }
printf '%s\n' "$version" | grep -qi 'linux arm' || { printf '%s\n' "$version" >&2; fail "Mihomo не является Linux ARM-сборкой"; }

prepare_config

mkdir -p "$BASE/run" "$BASE/logs" "$BASE/state" "$BASE/backups" || fail "Не удалось создать рабочие каталоги"
rm -rf "$BASE/run/start.lock" 2>/dev/null || true
rm -f "$BASE/run/boot.pid" 2>/dev/null || true
touch "$BASE/.goshacrash-root" 2>/dev/null || true

say "Проверяю единственный config.yaml"
GOSHACRASH_BASE="$BASE" "$BASE/goshacrash" check || fail "config.yaml не прошёл проверку"

say "Устанавливаю автозапуск"
GOSHACRASH_BASE="$BASE" "$BASE/goshacrash" install-hooks || fail "Автозапуск не установлен"

say "Запускаю Mihomo и маршрутизацию"
GOSHACRASH_BASE="$BASE" "$BASE/goshacrash" restart || fail "Первый запуск не удался; смотри: $BASE/logs/mihomo.log"

say "Установка завершена"
GOSHACRASH_BASE="$BASE" "$BASE/goshacrash" status
printf '\nКоманда управления:\n  %s/goshacrash\n' "$BASE"
