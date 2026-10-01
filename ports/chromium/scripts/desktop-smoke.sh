#!/usr/bin/env bash
# Virtual-display validation for an isolated Linux cloud container only.
# Production desktop startup is `npm start`, with the OS sandbox enabled.
set -euo pipefail
cd "$(dirname "$0")/.."
runtime=$(mktemp -d /tmp/search-desktop-smoke.XXXXXX)
xorg_pid=''
cleanup() {
  if [[ -n "$xorg_pid" ]]; then
    kill "$xorg_pid" 2>/dev/null || true
    wait "$xorg_pid" 2>/dev/null || true
  fi
  rm -rf "$runtime"
}
trap cleanup EXIT
if [[ ! -x /usr/lib/xorg/Xorg ]]; then
  echo 'Desktop smoke needs Xorg and its dummy video driver (cloud image prerequisites).' >&2
  exit 1
fi
cat > "$runtime/dummy.conf" <<'CONFIG'
Section "ServerFlags"
 Option "AutoAddDevices" "false"
 Option "AutoEnableDevices" "false"
EndSection
Section "Device"
 Identifier "Dummy"
 Driver "dummy"
 VideoRam 256000
EndSection
Section "Monitor"
 Identifier "Monitor"
 HorizSync 30-90
 VertRefresh 50-90
 Modeline "1280x800" 83.50 1280 1352 1480 1680 800 803 809 831
EndSection
Section "Screen"
 Identifier "Screen"
 Device "Dummy"
 Monitor "Monitor"
 DefaultDepth 24
 SubSection "Display"
  Depth 24
  Modes "1280x800"
 EndSubSection
EndSection
CONFIG
display_number=$((100 + BASHPID % 10000))
/usr/lib/xorg/Xorg ":$display_number" -config "$runtime/dummy.conf" -logfile "$runtime/xorg.log" -noreset -nolisten tcp > "$runtime/xorg-output.log" 2>&1 &
xorg_pid=$!
for attempt in $(seq 1 50); do
  if [[ -S "/tmp/.X11-unix/X$display_number" ]]; then break; fi
  if ! kill -0 "$xorg_pid" 2>/dev/null; then cat "$runtime/xorg-output.log" >&2; exit 1; fi
  sleep 0.1
done
if [[ ! -S "/tmp/.X11-unix/X$display_number" ]]; then echo 'Virtual display did not become ready' >&2; exit 1; fi
if [[ -n "${SEARCH_SMOKE_EXECUTABLE:-}" ]]; then
  DISPLAY=":$display_number" SEARCH_PROFILE="$runtime/profile" XDG_CONFIG_HOME="$runtime/config" XDG_CACHE_HOME="$runtime/cache" "$SEARCH_SMOKE_EXECUTABLE" --smoke --no-sandbox
else
  DISPLAY=":$display_number" SEARCH_PROFILE="$runtime/profile" XDG_CONFIG_HOME="$runtime/config" XDG_CACHE_HOME="$runtime/cache" node_modules/.bin/electron . --smoke --no-sandbox
fi
