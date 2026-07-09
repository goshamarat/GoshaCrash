#!/bin/sh

APP_NAME="goshacrash"

# GitHub repo settings.
# Поменяй REPO_NAME на "goshacrash", если репозиторий у тебя в нижнем регистре.
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

  [ -n "$out" ] || die "download: output file is empty"
  [ -n "$url" ] || die "download: URL is empty"

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
    return
  fi

  if has_cmd opkg; then
    say "asus-entware"
    return
  fi

  if [ -d /jffs ] || [ -d /tmp/mnt ] || [ -d /opt/etc ]; then
    say "asus"
    return
  fi

  if grep -qi microsoft /proc/version 2>/dev/null; then
    say "wsl"
    return
  fi

  say "linux"
}

choose_install_dir() {
  target="$1"

  case "$target" in
    asus|asus-optware|asus-entware)
      if [ -d /opt/etc ] || [ -d /opt ]; then
        say "/opt/etc/goshacrash"
      elif [ -d /jffs ]; then
        say "/jffs/addons/goshacrash"
      else
        say "$HOME/.local/share/goshacrash"
      fi
      ;;
    *)
      say "$HOME/.local/share/goshacrash"
      ;;
  esac
}

choose_bin_dir() {
  target="$1"

  case "$target" in
    asus|asus-optware|asus-entware)
      if [ -d /opt/bin ]; then
        say "/opt/bin"
      else
        say "$HOME/.local/bin"
      fi
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
  say "          GoshaCrash Installer"
  say "========================================"
  say "Target:      $target"
  say "Repository:  $REPO_OWNER/$REPO_NAME@$REPO_BRANCH"
  say "Install dir: $install_dir"
  say "Bin dir:     $bin_dir"
  say "========================================"

  mkdir -p "$install_dir" \
           "$install_dir/custom" \
           "$install_dir/templates" \
           "$install_dir/runtime" \
           "$bin_dir" || die "cannot create directories"

  say "[1/5] Downloading main script..."
  download "$install_dir/goshacrash" "$RAW_BASE/goshacrash" || die "failed to download goshacrash"
  chmod +x "$install_dir/goshacrash"

  say "[2/5] Downloading templates..."
  download "$install_dir/templates/env.conf" "$RAW_BASE/templates/env.conf" || die "failed to download templates/env.conf"
  download "$install_dir/templates/dns.yaml" "$RAW_BASE/templates/dns.yaml" || die "failed to download templates/dns.yaml"
  download "$install_dir/templates/config.yaml" "$RAW_BASE/templates/config.yaml" || die "failed to download templates/config.yaml"

  say "[3/5] Creating custom files if missing..."
  [ -f "$install_dir/custom/env.conf" ] || cp "$install_dir/templates/env.conf" "$install_dir/custom/env.conf"
  [ -f "$install_dir/custom/dns.yaml" ] || cp "$install_dir/templates/dns.yaml" "$install_dir/custom/dns.yaml"
  [ -f "$install_dir/custom/config.yaml" ] || cp "$install_dir/templates/config.yaml" "$install_dir/custom/config.yaml"

  say "[4/5] Creating command wrapper..."
  cat > "$bin_dir/goshacrash" <<EOF_WRAPPER
#!/bin/sh
SCRIPT_DIR="$install_dir"
CUSTOM_DIR="$install_dir/custom"
BASE_DIR="\${BASE_DIR:-$install_dir/runtime}"
export CUSTOM_DIR BASE_DIR
exec "$install_dir/goshacrash" "\$@"
EOF_WRAPPER

  chmod +x "$bin_dir/goshacrash"

  say "[5/5] Initializing..."
  CUSTOM_DIR="$install_dir/custom" BASE_DIR="$install_dir/runtime" "$install_dir/goshacrash" init-custom >/dev/null 2>&1 || true

  say ""
  say "Installation complete."
  say ""
  say "Run:"
  say "  $bin_dir/goshacrash"
  say ""
  say "If command is not found, run:"
  say "  export PATH=\"$bin_dir:\$PATH\""
  say ""
}

main "$@"