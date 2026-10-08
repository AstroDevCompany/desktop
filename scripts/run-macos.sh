#!/usr/bin/env bash
# Run Peppermint on macOS.
#
# Installs missing build tools, downloads the Firefox engine on a fresh
# checkout, builds once, then launches the browser. Later runs skip the
# build when an app is already present. Builds on an external MOZ_OBJDIR are
# ad-hoc re-signed before launch (needed after build / build:ui).
#
#   ./scripts/run-macos.sh
#   ./scripts/run-macos.sh --rebuild

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REBUILD=0
if [[ "${1:-}" == "--rebuild" ]]; then
  REBUILD=1
elif [[ -n "${1:-}" ]]; then
  echo "Usage: $0 [--rebuild]" >&2
  exit 1
fi

log() {
  printf '\n==> %s\n' "$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

if ! xcode-select -p >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "Full Xcode is required. Install it from the App Store, then run:" >&2
  echo "  sudo xcode-select --switch /Applications/Xcode.app" >&2
  echo "  sudo xcodebuild -license" >&2
  exit 1
fi

if ! need_cmd brew; then
  log "Installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

log "Checking Homebrew packages"
for pkg in git gnu-tar watchman yasm terminal-notifier sccache python@3.11 node@22; do
  if ! brew list --formula "$pkg" >/dev/null 2>&1; then
    brew install "$pkg"
  fi
done

export PATH="$(brew --prefix python@3.11)/libexec/bin:$(brew --prefix node@22)/bin:$PATH"

if ! need_cmd rustup; then
  log "Installing Rust"
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
fi
if [[ -f "$HOME/.cargo/env" ]]; then
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
fi
rustup toolchain install stable >/dev/null
rustup default stable >/dev/null

install_cbindgen=0
if ! need_cmd cbindgen; then
  install_cbindgen=1
else
  cbindgen_version="$(cbindgen --version | awk '{print $NF}')"
  if ! python3 - "$cbindgen_version" <<'PY'
import sys
parts = [int(piece) for piece in sys.argv[1].split(".")[:3]]
while len(parts) < 3:
    parts.append(0)
sys.exit(0 if tuple(parts) >= (0, 29, 4) else 1)
PY
  then
    install_cbindgen=1
  fi
fi
if [[ "$install_cbindgen" -eq 1 ]]; then
  log "Installing cbindgen"
  cargo install cbindgen --version 0.29.4 --locked
fi

free_gb="$(df -g "$ROOT" | awk 'NR==2 {print $4}')"
if [[ "${free_gb:-0}" -lt 30 ]]; then
  echo "Warning: only ${free_gb}GB free on this disk. A first build needs about 30GB." >&2
fi

log "Checking Node dependencies"
if [[ ! -x node_modules/.bin/surfer ]]; then
  npm ci
fi

find_browser() {
  local root candidate
  local roots=("$ROOT/engine")
  if [[ -f "$ROOT/mozconfig" ]]; then
    local obj
    obj="$(sed -n 's/^mk_add_options MOZ_OBJDIR=//p' "$ROOT/mozconfig" | tail -1 | tr -d '"')"
    if [[ -n "$obj" ]]; then
      roots+=("$obj")
    fi
  fi
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r candidate; do
      if [[ -n "$candidate" && -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done < <(find "$root" -maxdepth 6 -type f -name zen -path '*/MacOS/zen' 2>/dev/null)
  done
  return 1
}

# True when path lives on a different device than the boot volume (e.g. /Volumes/...).
path_on_external_disk() {
  local target="$1"
  [[ -e "$target" ]] || return 1
  local target_dev root_dev
  target_dev="$(stat -f %d "$target")"
  root_dev="$(stat -f %d /)"
  [[ "$target_dev" != "$root_dev" ]]
}

# Incremental builds on external volumes often leave XUL unsigned while macOS
# still expects a valid signature (SIGKILL / CODESIGNING Invalid Page).
resign_macos_app_if_needed() {
  local zen_bin="$1"
  local app_dir macos_dir binary signed=0 failed=0
  app_dir="$(cd "$(dirname "$zen_bin")/../.." && pwd)"
  macos_dir="$app_dir/Contents/MacOS"
  [[ -d "$macos_dir" ]] || return 0

  if ! path_on_external_disk "$macos_dir"; then
    return 0
  fi

  log "External build volume detected; re-signing dev binaries before launch"
  for binary in XUL zen libmozglue.dylib; do
    if [[ ! -f "$macos_dir/$binary" ]]; then
      continue
    fi
    if codesign -f -s - "$macos_dir/$binary"; then
      signed=$((signed + 1))
    else
      echo "Warning: could not re-sign $binary" >&2
      failed=$((failed + 1))
    fi
  done
  if [[ "$signed" -eq 0 ]]; then
    echo "Warning: no binaries were re-signed; the app may crash on launch." >&2
  elif [[ "$failed" -gt 0 ]]; then
    echo "Warning: some binaries failed to re-sign ($failed)." >&2
  fi
}

if [[ "$REBUILD" -eq 0 ]] && browser="$(find_browser)"; then
  resign_macos_app_if_needed "$browser"
  log "Launching $browser"
  exec npm start
fi

if [[ ! -f mozconfig ]]; then
  log "Writing a local mozconfig"
  cat > mozconfig <<'EOF'
# Created by scripts/run-macos.sh for a local development build.
ac_add_options --without-wasm-sandboxed-libraries
ac_add_options --disable-debug-symbols
EOF
fi

if [[ ! -f engine/mach ]]; then
  log "Downloading the Firefox engine"
  npm run download
fi

if [[ ! -f engine/browser/branding/release/locales/en-US/brand.ftl ]] || ! grep -q 'Peppermint' engine/browser/branding/release/locales/en-US/brand.ftl; then
  log "Importing Peppermint patches"
  npm run import
fi

python3 - <<'PY'
from pathlib import Path

linker = Path("engine/build/moz.configure/toolchain.configure")
text = linker.read_text()
old = '''            if retcode == 1 and "Logging ld64 options" in stderr:
                kind = "ld64"
'''
new = '''            if retcode == 1 and (
                "Logging ld64 options" in stderr
                or (
                    target.kernel == "Darwin"
                    and "unknown options: --version" in stderr
                )
            ):
                kind = "ld64"
'''
if "unknown options: --version" not in text and old in text:
    linker.write_text(text.replace(old, new, 1))
    print("Patched Xcode 27 linker detection")

vendor = Path("engine/browser/moz.configure")
vendor_text = vendor.read_text()
updated = vendor_text.replace(
    'imply_option("MOZ_APP_VENDOR", "Mozilla")',
    'imply_option("MOZ_APP_VENDOR", "MintFlow Technologies")',
)
if updated != vendor_text:
    vendor.write_text(updated)
    print("Set the application vendor to MintFlow Technologies")
PY

log "Selecting the Peppermint release brand"
npm run surfer -- set brand release

log "Bootstrapping the Firefox build environment"
(
  cd engine
  ./mach --no-interactive bootstrap --application-choice browser
)

log "Copying English language packs"
python3 ./scripts/update_en_US_packs.py

mem_bytes="$(sysctl -n hw.memsize)"
cpus="$(sysctl -n hw.ncpu)"
jobs=$(( mem_bytes / 1024 / 1024 / 1024 / 4 ))
if [[ "$jobs" -lt 2 ]]; then
  jobs=2
fi
if [[ "$jobs" -gt "$cpus" ]]; then
  jobs="$cpus"
fi

log "Building Peppermint ($jobs jobs). The first build can take a few hours."
npm run build -- --jobs "$jobs"

if browser="$(find_browser)"; then
  resign_macos_app_if_needed "$browser"
fi
log "Launching Peppermint"
exec npm start
