#!/bin/sh
# Установка файлов из распакованного архива поверх существующего GoshaCrash.
# config.yaml, bin/mihomo, ui и rulesets не удаляются и не заменяются.

SOURCE="$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)"
TARGET="${GOSHACRASH_BASE:-/tmp/mnt/GOSHACRASH/goshacrash}"

say() { printf '%s\n' "[GoshaCrash local] $*"; }
fail() { printf '%s\n' "[GoshaCrash local:ERROR] $*" >&2; exit 1; }

mkdir -p "$TARGET" "$TARGET/templates" || fail "Не удалось создать $TARGET"

if [ "$SOURCE" != "$TARGET" ]; then
    for file in goshacrash dns-test.sh restore-dns.sh; do
        cp "$SOURCE/$file" "$TARGET/$file" || fail "Не удалось скопировать $file"
    done

    [ -f "$SOURCE/README.md" ] && cp "$SOURCE/README.md" "$TARGET/README.md"
    [ -f "$SOURCE/templates/config.yaml" ] &&
        cp "$SOURCE/templates/config.yaml" "$TARGET/templates/config.yaml"
fi

for file in goshacrash dns-test.sh restore-dns.sh; do
    chmod 755 "$TARGET/$file" 2>/dev/null || true
done

if [ ! -f "$TARGET/config.yaml" ] && [ -f "$TARGET/templates/config.yaml" ]; then
    cp "$TARGET/templates/config.yaml" "$TARGET/config.yaml"
    say "Создан новый безопасный config.yaml"
else
    say "Существующий личный config.yaml сохранён"
fi

mkdir -p "$TARGET/state" "$TARGET/backups" "$TARGET/logs" "$TARGET/run" || true

if [ -x "$TARGET/goshacrash" ]; then
    "$TARGET/goshacrash" install-hooks >/dev/null 2>&1 || true
fi

say "Файлы установлены в $TARGET"
printf '%s\n' "Запуск DNS-теста: sh $TARGET/dns-test.sh"
