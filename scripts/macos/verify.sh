#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
require_macos
exec > >(tee -a "$LOG_DIR/verify-macos.txt") 2>&1
configure_brew
assert_source_snapshot
receiver="$PROJECT_ROOT/build/native/macos-$(uname -m)/uxplay"
test -x "$receiver"
"$receiver" -v
gst-inspect-1.0 --version
for plugin in appsrc h264parse avdec_h264 avdec_aac avdec_alac osxaudiosink; do
  gst-inspect-1.0 "$plugin" > "$LOG_DIR/gst-macos-${plugin}.txt"
done
videosink=glimagesink
if gst-inspect-1.0 osxvideosink >/dev/null 2>&1; then videosink=osxvideosink; fi
gst-inspect-1.0 "$videosink" > "$LOG_DIR/gst-macos-video.txt"
otool -L "$receiver" | tee "$LOG_DIR/uxplay-libraries-macos.txt"
if grep -qi '/Library/Frameworks/GStreamer' "$LOG_DIR/uxplay-libraries-macos.txt"; then echo 'Unexpected Framework linkage' >&2; exit 1; fi
gst-launch-1.0 -q videotestsrc num-buffers=12 ! video/x-raw,format=I420,width=320,height=180 ! x264enc ! h264parse ! avdec_h264 ! fakesink
gst-launch-1.0 -q videotestsrc num-buffers=12 ! videoconvert ! "$videosink" sync=false
gst-launch-1.0 -q audiotestsrc num-buffers=8 volume=0.01 ! audioconvert ! audioresample ! osxaudiosink
if lsof -nP -iTCP:7000-7002 -sTCP:LISTEN | tail -n +2 | grep -q .; then echo 'TCP 7000-7002 already used; existing processes preserved.' >&2; exit 1; fi
config="$PROJECT_ROOT/artifacts/uxplay-macos.rc"
echo '# Explicit empty config for viewMirror verification.' > "$config"
"$receiver" -rc "$config" -n ViewMirror-Mac -nh -p 7000 -vs "$videosink" -as osxaudiosink -vsync no -d 1 > "$LOG_DIR/receiver-macos.txt" 2>&1 &
receiver_pid=$!
cleanup() { kill -INT "$receiver_pid" 2>/dev/null || true; wait "$receiver_pid" 2>/dev/null || true; }
trap cleanup EXIT
sleep 3
kill -0 "$receiver_pid"
lsof -nP -a -p "$receiver_pid" -iTCP -sTCP:LISTEN > "$LOG_DIR/receiver-listeners-macos.txt"
interface="$(route -n get default | awk '/interface:/{print $2; exit}')"
address="$(ipconfig getifaddr "$interface")"
python3 "$PROJECT_ROOT/scripts/mdns_probe.py" --interface "$address" --name ViewMirror-Mac --port 7001 --output "$LOG_DIR/mdns-macos.json"
echo 'PASS receiver wait and local mDNS query response. iPad connection remains unverified.'
if [[ "${1:-}" == --receive ]]; then
  echo 'iPad: Control Center > Screen Mirroring > ViewMirror-Mac. Stop with Ctrl+C. Logs: artifacts/logs/receiver-macos.txt'
  wait "$receiver_pid"
fi
