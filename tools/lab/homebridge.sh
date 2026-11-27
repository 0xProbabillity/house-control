#!/bin/bash
# Runs a real Homebridge with its web UI on this Mac, with pretend lamps, a plug, a switch, an
# AC, a thermostat and a thermometer (the plugin in tools/lab/homebridge), for testing House
# Control's Homebridge connection without hardware. The first run installs Homebridge and the
# Homebridge UI into tools/lab/.homebridge (about 150 MB, needs Node.js).
#
#   ./tools/lab/homebridge.sh                 → http://<this Mac>:8581, user lab / lab-lab-lab
#   HB_INSECURE=0 ./tools/lab/homebridge.sh   → accessory control switched off, as some installs have it
#   HB_AUTH=none ./tools/lab/homebridge.sh    → the UI without a sign-in
#
# Delete tools/lab/.homebridge to start from scratch.
set -euo pipefail
LAB="$(cd "$(dirname "$0")" && pwd)"
HB="${HB_HOME:-$LAB/.homebridge}"
PORT="${HB_PORT:-8581}"
command -v node >/dev/null || { echo "Install Node.js first: brew install node"; exit 1; }

if [ ! -x "$HB/app/node_modules/.bin/hb-service" ]; then
  echo "▸ Installing Homebridge and the Homebridge UI into $HB (first run only)"
  mkdir -p "$HB/app"
  (cd "$HB/app" && npm init -y >/dev/null && npm install --no-fund --no-audit homebridge homebridge-config-ui-x)
fi

STORAGE="$HB/storage"
mkdir -p "$STORAGE"
cat >"$STORAGE/config.json" <<EOF
{
  "bridge": { "name": "Homebridge Lab", "username": "0E:5C:A1:AB:00:02", "port": 51827, "pin": "031-45-155", "advertiser": "ciao" },
  "platforms": [
    { "platform": "config", "name": "Config", "port": $PORT, "auth": "${HB_AUTH:-form}" },
    { "platform": "HouseLab", "name": "House Lab" }
  ]
}
EOF

# The UI's sign-in: lab / lab-lab-lab, hashed the way the Homebridge UI does it.
if [ ! -f "$STORAGE/auth.json" ]; then
  node -e '
    const { pbkdf2Sync, randomBytes } = require("node:crypto");
    const salt = randomBytes(32).toString("hex");
    const hashedPassword = pbkdf2Sync("lab-lab-lab", salt, 210000, 64, "sha512").toString("hex");
    process.stdout.write(JSON.stringify([{ id: 1, username: "lab", name: "Lab", hashedPassword, salt,
      passwordIterations: 210000, sessionVersion: 0, admin: true }], null, 4));
  ' >"$STORAGE/auth.json"
fi

# hb-service starts Homebridge with -I (accessory control) unless told otherwise, like a real install.
if [ "${HB_INSECURE:-1}" = "0" ]; then
  echo '{ "insecureMode": false }' >"$STORAGE/.uix-hb-service-homebridge-startup.json"
else
  rm -f "$STORAGE/.uix-hb-service-homebridge-startup.json"
fi

HOST="$(scutil --get LocalHostName 2>/dev/null || echo localhost).local"
echo "▸ Homebridge UI: http://$HOST:$PORT  (user lab, password lab-lab-lab)"
echo "  In House Control: Connections → Homebridge, address $HOST:$PORT"
exec "$HB/app/node_modules/.bin/hb-service" run -U "$STORAGE" -P "$LAB/homebridge" --stdout
