#!/usr/bin/env bash
set -euo pipefail
: "${HOMEBREW_PREFIX:?Run from the viewMirror macOS build script.}"
# Upstream changes PKG_CONFIG_PATH internally. Enforce the selected Homebrew
# prefix at every query, including after those upstream assignments.
export PKG_CONFIG_PATH="$HOMEBREW_PREFIX/opt/openssl@3/lib/pkgconfig:$HOMEBREW_PREFIX/lib/pkgconfig:$HOMEBREW_PREFIX/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
exec "$HOMEBREW_PREFIX/bin/pkg-config" "$@"
