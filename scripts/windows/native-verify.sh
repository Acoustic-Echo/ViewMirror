#!/usr/bin/env bash
set -euo pipefail
cd "$viewMirror_ROOT"
test "$MSYSTEM" = UCRT64
test "$(command -v gcc)" = /ucrt64/bin/gcc
gcc --version | head -n 1
cmake --version | head -n 1
ninja --version
pkg-config --version
openssl version
pkg-config --modversion openssl libplist-2.0 gstreamer-1.0 gstreamer-video-1.0 gstreamer-audio-1.0
gst-inspect-1.0 --version
for plugin in appsrc h264parse decodebin avdec_h264 h265parse avdec_h265 avdec_aac avdec_alac d3d11videosink wasapisink udpsrc rtpjitterbuffer rtph264pay rtph264depay rtph265pay rtph265depay; do
  gst-inspect-1.0 "$plugin" > "artifacts/logs/gst-${plugin}.txt"
  printf 'PASS plugin %s\n' "$plugin"
done
gst-inspect-1.0 -b > artifacts/logs/gst-blacklist.txt
ldd build/native/windows-ucrt64/uxplay.exe > artifacts/logs/uxplay-dlls.txt
if grep -q 'not found' artifacts/logs/uxplay-dlls.txt; then
  cat artifacts/logs/uxplay-dlls.txt
  echo 'Missing runtime DLL(s)' >&2
  exit 1
fi
build/native/windows-ucrt64/uxplay.exe -h > artifacts/logs/uxplay-help.txt
build/native/windows-ucrt64/uxplay.exe -v | tee artifacts/logs/uxplay-version.txt
# Real H.264 encode/decode without needing an iPad.
gst-launch-1.0 -q videotestsrc num-buffers=12 ! video/x-raw,format=I420,width=320,height=180,framerate=30/1 ! openh264enc ! h264parse ! avdec_h264 ! fakesink
gst-launch-1.0 -q videotestsrc num-buffers=12 ! video/x-raw,width=320,height=180 ! d3d11videosink sync=false
gst-launch-1.0 -q audiotestsrc num-buffers=8 volume=0.01 ! audioconvert ! audioresample ! wasapisink
printf 'PASS native DLL loading, H.264 round trip, D3D11 video and WASAPI audio pipeline\n'
