#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$PROJECT_ROOT/artifacts/logs"
mkdir -p "$LOG_DIR"
trap 'printf "ERROR %s:%s: %s\n" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR
require_macos() {
  if [[ "$(uname -s)" != Darwin ]]; then echo 'This script requires a macOS host; no macOS result can be verified on Windows.' >&2; exit 2; fi
}
find_brew() {
  if command -v brew >/dev/null 2>&1; then command -v brew
  elif [[ "$(uname -m)" == arm64 && -x /opt/homebrew/bin/brew ]]; then echo /opt/homebrew/bin/brew
  elif [[ -x /usr/local/bin/brew ]]; then echo /usr/local/bin/brew
  else return 1; fi
}
configure_brew() {
  BREW="$(find_brew)" || { echo 'Homebrew not found. Run setup.sh --bootstrap.' >&2; exit 2; }
  eval "$("$BREW" shellenv)"
  export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
  # UxPlay prioritizes Framework .pc files itself. Refuse an installed Framework
  # rather than silently mix it with Homebrew or modify the upstream source.
  if [[ -d /Library/Frameworks/GStreamer.framework || -d /Library/FrameWorks/GStreamer.framework ]]; then
    echo 'Official GStreamer Framework detected. Preserved; use a clean Homebrew-only build environment to avoid mixing binaries.' >&2
    exit 2
  fi
  export PATH="$HOMEBREW_PREFIX/opt/openssl@3/bin:$HOMEBREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export PKG_CONFIG_LIBDIR="$HOMEBREW_PREFIX/opt/openssl@3/lib/pkgconfig:$HOMEBREW_PREFIX/lib/pkgconfig:$HOMEBREW_PREFIX/share/pkgconfig"
  export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
  export GST_PLUGIN_SYSTEM_PATH_1_0="$HOMEBREW_PREFIX/lib/gstreamer-1.0"
  export GST_REGISTRY_1_0="$PROJECT_ROOT/artifacts/gstreamer-registry-macos.bin"
  unset GST_PLUGIN_PATH GST_PLUGIN_PATH_1_0 GST_PLUGIN_SCANNER_1_0 GSTREAMER_ROOT_DIR CC CXX CMAKE_PREFIX_PATH || true
  if [[ -x "$HOMEBREW_PREFIX/libexec/gstreamer-1.0/gst-plugin-scanner" ]]; then
    export GST_PLUGIN_SCANNER_1_0="$HOMEBREW_PREFIX/libexec/gstreamer-1.0/gst-plugin-scanner"
  fi
}
assert_source_snapshot() {
  local manifest="$PROJECT_ROOT/docs/versions/uxplay-source.sha256"
  [[ -s "$manifest" ]] || { echo 'Bundled UxPlay source manifest missing; restore the standalone snapshot.' >&2; exit 1; }
  (cd "$PROJECT_ROOT/third_party/UxPlay" && shasum -a 256 -c "$manifest") > "$LOG_DIR/uxplay-source-check.txt"
  echo 'PASS bundled UxPlay source SHA-256 checks.'
}
