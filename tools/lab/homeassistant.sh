#!/bin/bash
# Runs a Home Assistant full of pretend devices on this Mac, for testing House Control's
# Home Assistant connection without hardware. The first run installs Home Assistant into
# tools/lab/.ha (about 1 GB, a few minutes; needs uv: brew install uv).
#
#   ./tools/lab/homeassistant.sh        → http://<this Mac>:8123, prints a token for House Control
#
# Sign in to the web UI as lab / lab-lab-lab. Delete tools/lab/.ha to start from scratch.
# To try your real devices too, add their integration in the web UI (Settings → Devices &
# services): "Tuya" signs in to Smart Life with the same QR code as House Control does.
set -euo pipefail
LAB="$(cd "$(dirname "$0")" && pwd)"
HA="${HA_HOME:-$LAB/.ha}"
PORT=8123
command -v uv >/dev/null || { echo "Install uv first: brew install uv"; exit 1; }

if [ ! -x "$HA/venv/bin/hass" ]; then
  echo "▸ Installing Home Assistant into $HA (first run only)"
  uv venv --quiet --python 3.13 "$HA/venv"
  VIRTUAL_ENV="$HA/venv" uv pip install --quiet homeassistant numpy av PyTurboJPEG
fi

mkdir -p "$HA/config"
cp "$LAB/homeassistant/configuration.yaml" "$HA/config/"
rm -rf "$HA/config/custom_components"
cp -R "$LAB/homeassistant/custom_components" "$HA/config/"

echo "▸ Starting Home Assistant (log: $HA/hass.log)"
"$HA/venv/bin/hass" -c "$HA/config" >"$HA/hass.log" 2>&1 &
HASS=$!
trap 'kill $HASS 2>/dev/null' EXIT
until curl -fs "http://127.0.0.1:$PORT/api/onboarding" >/dev/null 2>&1; do
  kill -0 $HASS 2>/dev/null || { echo "Home Assistant stopped; see $HA/hass.log"; exit 1; }
  sleep 1
done
TOKEN="$("$HA/venv/bin/python" "$LAB/homeassistant/onboard.py" --url "http://127.0.0.1:$PORT" --out "$HA/token")"

HOST="$(scutil --get LocalHostName 2>/dev/null || echo localhost).local"
# Home Assistant announces itself with Bonjour, but run as a plain process on macOS its own
# announcer cannot share the port with the system's: announce it the same way through dns-sd.
VERSION="$("$HA/venv/bin/python" -c 'from homeassistant.const import __version__; print(__version__)')"
dns-sd -R "House Control Lab" _home-assistant._tcp local $PORT location_name="House Control Lab" \
  internal_url="http://$HOST:$PORT" base_url="http://$HOST:$PORT" version="$VERSION" requires_api_password=True >/dev/null &
ANNOUNCE=$!
trap 'kill $HASS $ANNOUNCE 2>/dev/null' EXIT
cat <<EOF

Home Assistant is running with pretend lights, heat pumps and sensors.
  Web UI   http://$HOST:$PORT   (lab / lab-lab-lab)

In House Control: Edit Home… → Connections → Home Assistant
  Address  http://$HOST:$PORT
  Token    $TOKEN

Ctrl-C stops it.
EOF
wait $HASS
