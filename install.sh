#!/bin/sh

APP_NAME="goshacrash"

REPO_OWNER="${REPO_OWNER:-goshamarat}"
REPO_NAME="${REPO_NAME:-GoshaCrash}"
REPO_BRANCH="${REPO_BRANCH:-main}"

RAW_BASE="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$REPO_BRANCH"

say() {
  printf '%s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

download() {
  out="$1"
  url="$2"

  if has_cmd curl; then
    curl -fsSL -o "$out" "$url"
  elif has_cmd wget; then
    wget -q --no-check-certificate -O "$out" "$url"
  else
    die "curl or wget is required"
  fi
}

detect_target() {
  if has_cmd ipkg; then
    say "asus-optware"
  elif has_cmd opkg; then
    say "asus-entware"
  elif grep -qi microsoft /proc/version 2>/dev/null; then
    say "wsl"
  else
    say "linux"
  fi
}

choose_install_dir() {
  target="$1"

  case "$target" in
    asus-optware|asus-entware)
      say "/opt/etc/goshacrash"
      ;;
    *)
      say "$HOME/.goshacrash"
      ;;
  esac
}

choose_bin_dir() {
  target="$1"

  case "$target" in
    asus-optware|asus-entware)
      say "/opt/bin"
      ;;
    *)
      say "$HOME/.local/bin"
      ;;
  esac
}

main() {
  target="$(detect_target)"
  install_dir="${INSTALL_DIR:-$(choose_install_dir "$target")}"
  bin_dir="${BIN_DIR:-$(choose_bin_dir "$target")}"

  say "========================================"
  say "        GoshaCrash installer"
  say "========================================"
  say "Target:      $target"
  say "Repository:  $REPO_OWNER/$REPO_NAME@$REPO_BRANCH"
  say "Install dir: $install_dir"
  say "Bin dir:     $bin_dir"
  say "========================================"

  mkdir -p "$install_dir" "$install_dir/templates" "$bin_dir" || die "cannot create directories"

  say "[1/4] Downloading main script..."
  download "$install_dir/goshacrash" "$RAW_BASE/goshacrash" || die "failed to download goshacrash"
  chmod +x "$install_dir/goshacrash"

  say "[2/4] Downloading templates..."
  download "$install_dir/templates/env.conf" "$RAW_BASE/templates/env.conf" || die "failed to download env.conf"
  download "$install_dir/templates/dns.yaml" "$RAW_BASE/templates/dns.yaml" || die "failed to download dns.yaml"
  download "$install_dir/templates/profile.yaml" "$RAW_BASE/templates/profile.yaml" || die "failed to download profile.yaml"

  say "[3/4] Creating command..."
  cat > "$bin_dir/goshacrash" <<EOF_WRAPPER
#!/bin/sh
GC_HOME="$install_dir"
export GC_HOME
exec "$install_dir/goshacrash" "\$@"
EOF_WRAPPER

  chmod +x "$bin_dir/goshacrash"

  say "[4/4] Initializing user files..."
  GC_HOME="$install_dir" "$install_dir/goshacrash" init >/dev/null 2>&1 || true

  say ""
  say "Done."
  say ""
  say "Run:"
  say "  $bin_dir/goshacrash"
  say ""
  say "If command is not found:"
  say "  export PATH=\"$bin_dir:\$PATH\""
}

main "$@"
