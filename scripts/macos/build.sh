#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
require_macos
exec > >(tee -a "$LOG_DIR/build-macos.txt") 2>&1
configure_brew
assert_source_snapshot
chmod +x "$PROJECT_ROOT/scripts/macos/pkg-config-homebrew.sh"
cmake -S "$PROJECT_ROOT/third_party/UxPlay" -B "$PROJECT_ROOT/build/native/macos-$(uname -m)" -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DNO_MARCH_NATIVE=ON -DUSE_DNS_SD=ON \
  -DCMAKE_C_COMPILER="$(xcrun --find clang)" -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
  -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" -DCMAKE_PREFIX_PATH="$HOMEBREW_PREFIX;$HOMEBREW_PREFIX/opt/openssl@3" \
  -DPKG_CONFIG_EXECUTABLE="$PROJECT_ROOT/scripts/macos/pkg-config-homebrew.sh"
cmake --build "$PROJECT_ROOT/build/native/macos-$(uname -m)" --parallel "$(sysctl -n hw.logicalcpu)"
test -x "$PROJECT_ROOT/build/native/macos-$(uname -m)/uxplay"
echo 'PASS macOS native build; WPF is built only on Windows.'
