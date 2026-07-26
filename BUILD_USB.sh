#!/bin/sh
# Builds a complete USB folder on WSL/Linux. The router performs no downloads.
set -eu

ROOT="$(CDPATH= cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
DIST="$ROOT/dist"
PKG="$DIST/GoshaCrash-USB"
WORK="$DIST/.build"

MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.28}"
MIHOMO_TAG="${MIHOMO_TAG:-mihomo-gvisor-armv5-$MIHOMO_VERSION}"
MIHOMO_ASSET="${MIHOMO_ASSET:-mihomo-linux-armv5-gvisor-$MIHOMO_VERSION.gz}"
MIHOMO_URL="${MIHOMO_URL:-https://github.com/goshamarat/GoshaCrash/releases/download/$MIHOMO_TAG/$MIHOMO_ASSET}"
MIHOMO_SHA_URL="${MIHOMO_SHA_URL:-$MIHOMO_URL.sha256}"
ZASHBOARD_URL="${ZASHBOARD_URL:-https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip}"

say(){ printf '%s\n' "[BUILD] $*"; }
die(){ printf '%s\n' "[BUILD:ERROR] $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

for c in gzip sha256sum tar python3; do have "$c" || die "Не установлена команда $c"; done

fetch(){
    url="$1"; out="$2"
    rm -f "$out.part"
    if have curl; then
        curl -4 -fL --retry 4 --retry-delay 2 --connect-timeout 20 -o "$out.part" "$url"
    elif have wget; then
        wget -4 --no-check-certificate -O "$out.part" "$url"
    else
        die "Нужен curl или wget"
    fi
    [ -s "$out.part" ] || die "Пустой файл: $url"
    mv -f "$out.part" "$out"
}

rm -rf "$DIST"
mkdir -p "$PKG/bin" "$PKG/ui" "$WORK"

say "Копирую минимальные скрипты"
cp "$SRC/goshacrash" "$SRC/goshacrash-route" "$SRC/install.sh" "$SRC/config.example.yaml" "$PKG/"
chmod 755 "$PKG/goshacrash" "$PKG/goshacrash-route" "$PKG/install.sh"
sh -n "$PKG/goshacrash"
sh -n "$PKG/goshacrash-route"
sh -n "$PKG/install.sh"

say "Скачиваю Mihomo ARMv5 + with_gvisor"
fetch "$MIHOMO_URL" "$WORK/mihomo.gz"
fetch "$MIHOMO_SHA_URL" "$WORK/mihomo.sha256"
expected="$(awk 'NR==1{print tolower($1);exit}' "$WORK/mihomo.sha256" | tr -d '\r')"
actual="$(sha256sum "$WORK/mihomo.gz" | awk '{print tolower($1)}')"
[ -n "$expected" ] && [ "$actual" = "$expected" ] || die "SHA-256 Mihomo не совпал"
gzip -t "$WORK/mihomo.gz" || die "Повреждён архив Mihomo"
gzip -dc "$WORK/mihomo.gz" > "$PKG/bin/mihomo"
chmod 755 "$PKG/bin/mihomo"

if have file; then
    file "$PKG/bin/mihomo" | grep -qi 'ARM' || die "Mihomo не является ARM ELF"
fi
if have strings; then
    strings "$PKG/bin/mihomo" | grep -Fq 'with_gvisor' || say "WARN: strings не увидел with_gvisor; роутер выполнит окончательную проверку через mihomo -v"
fi

say "Скачиваю локальный Zashboard"
fetch "$ZASHBOARD_URL" "$WORK/zashboard.zip"
python3 - "$WORK/zashboard.zip" "$WORK/ui" <<'PY'
import pathlib, shutil, sys, zipfile
archive = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
shutil.rmtree(out, ignore_errors=True)
out.mkdir(parents=True)
with zipfile.ZipFile(archive) as z:
    bad = z.testzip()
    if bad:
        raise SystemExit(f"Повреждён файл в Zashboard: {bad}")
    z.extractall(out)
indexes = list(out.rglob("index.html"))
if not indexes:
    raise SystemExit("В Zashboard нет index.html")
root = indexes[0].parent
dst = pathlib.Path(sys.argv[2] + "-flat")
shutil.rmtree(dst, ignore_errors=True)
shutil.copytree(root, dst)
PY
cp -R "$WORK/ui-flat"/. "$PKG/ui"/
[ -f "$PKG/ui/index.html" ] || die "Zashboard не распакован"

say "Создаю контрольные суммы"
(
    cd "$PKG"
    find . -type f ! -name MANIFEST.sha256 | sed 's#^./##' | LC_ALL=C sort | while IFS= read -r f; do
        sha256sum "$f"
    done > MANIFEST.sha256
)

#say "Проверяю, что используется только config.yaml и установщик не ходит в сеть"
legacy_name="runtime"".""yaml"
if grep -RIn "$legacy_name" "$PKG"; then die "В пакет попал запрещённый дополнительный конфиг"; fi
if grep -EIn 'https?://|curl|wget' "$PKG/install.sh"; then die "install.sh содержит сетевую загрузку"; fi

say "Создаю архив"
(
    cd "$DIST"
    tar -czf GoshaCrash-USB.tar.gz GoshaCrash-USB
)
sha256sum "$DIST/GoshaCrash-USB.tar.gz" > "$DIST/GoshaCrash-USB.tar.gz.sha256"

say "ГОТОВО"
printf '%s\n' "$PKG" "$DIST/GoshaCrash-USB.tar.gz"
