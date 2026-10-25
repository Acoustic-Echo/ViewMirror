#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
require_macos
exec > >(tee -a "$LOG_DIR/setup-macos.txt") 2>&1
printf 'macOS: '; sw_vers
printf 'Architecture: '; uname -m
if ! xcode-select -p >/dev/null 2>&1; then
  echo 'Xcode Command Line Tools are missing. Opening the Apple installer; accept its license and rerun setup afterwards.'
  xcode-select --install
  exit 2
fi
xcrun --find clang
xcrun clang --version
if ! find_brew >/dev/null; then
  if [[ "${1:-}" != --bootstrap ]]; then
    echo 'Homebrew missing. setup.sh --bootstrap downloads the official installer; it may request sudo to create its prefix. Review https://docs.brew.sh/Installation first.' >&2
    exit 2
  fi
  echo 'Installing Homebrew: its official installer may use sudo for /opt/homebrew (Apple Silicon) or /usr/local (Intel). Existing software is retained.'
  mkdir -p "$PROJECT_ROOT/.tools/downloads"
  curl --fail --location --show-error https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$PROJECT_ROOT/.tools/downloads/homebrew-install.sh"
  shasum -a 256 "$PROJECT_ROOT/.tools/downloads/homebrew-install.sh" > "$LOG_DIR/homebrew-installer.sha256"
  /bin/bash "$PROJECT_ROOT/.tools/downloads/homebrew-install.sh"
fi
configure_brew
for formula in cmake ninja pkgconf openssl@3 libplist gstreamer; do
  if ! "$BREW" list --versions "$formula" >/dev/null 2>&1; then "$BREW" install "$formula"; else echo "Reusing $formula"; fi
done
if ! command -v python3 >/dev/null 2>&1; then "$BREW" install python; fi
if [[ "$(uname -m)" == arm64 && "$("$BREW" --prefix)" != /opt/homebrew ]]; then
  echo 'Apple Silicon is using a nonstandard/Rosetta Homebrew. Check that clang, dependencies and CMAKE_OSX_ARCHITECTURES match before building.' >&2
fi
assert_source_snapshot
"$BREW" list --versions > "$PROJECT_ROOT/artifacts/homebrew-versions-macos.txt"
"$BREW" info --json=v2 cmake ninja pkgconf openssl@3 libplist gstreamer > "$PROJECT_ROOT/artifacts/homebrew-formulae-macos.json"
pkg-config --modversion openssl libplist-2.0 gstreamer-1.0
gst-inspect-1.0 --version
echo 'Setup complete. Run bash scripts/macos/build.sh, then bash scripts/macos/verify.sh.'
