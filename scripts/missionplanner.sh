#!/usr/bin/env bash
# Run on the host PC: Mission Planner + NTRIP (RTK corrections). The simulated rover is `rover.sh sitl`.
#   missionplanner.sh install       Mono, Mission Planner in rover_ws/MissionPlanner, serial port permissions
#   missionplanner.sh ntrip-test    check the NTRIP credentials against the caster
#   missionplanner.sh ntrip-config  write the NTRIP URL into Mission Planner's config
#   missionplanner.sh start         ntrip-config + open Mission Planner
# NTRIP credentials come from config/ntrip.env (not in git, copy config/ntrip.env.example).
set -euo pipefail

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MP_DIR="${MP_DIR:-$WS/MissionPlanner}"
MP_CONFIG="${MP_CONFIG:-$HOME/.local/share/Mission Planner/config.xml}"
MP_ZIP_URL="https://firmware.ardupilot.org/Tools/MissionPlanner/MissionPlanner-latest.zip"
NTRIP_ENV="${NTRIP_ENV:-$WS/config/ntrip.env}"

die() { echo "$*" >&2; exit 1; }

mp_running() { pgrep -f 'MissionPlanner\.exe' >/dev/null; }

load_ntrip() {
  [ -f "$NTRIP_ENV" ] || die "missing $NTRIP_ENV: cp config/ntrip.env.example config/ntrip.env and fill it in"
  # shellcheck source=/dev/null
  source "$NTRIP_ENV"
  : "${NTRIP_USER:?not set in $NTRIP_ENV}" "${NTRIP_PASS:?not set in $NTRIP_ENV}" "${NTRIP_MOUNT:?not set in $NTRIP_ENV}"
  NTRIP_HOST="${NTRIP_HOST:-52.164.213.26}"
  NTRIP_PORT="${NTRIP_PORT:-2101}"
}

# URL with user and password percent-encoded ('@' in the password -> %40); Mission Planner decodes it
ntrip_url() {
  python3 -I -c 'import sys, urllib.parse as u
user, pw, host, port, mount = sys.argv[1:]
print(f"http://{u.quote(user, safe=str())}:{u.quote(pw, safe=str())}@{host}:{port}/{mount}")' \
    "$NTRIP_USER" "$NTRIP_PASS" "$NTRIP_HOST" "$NTRIP_PORT" "$NTRIP_MOUNT"
}

cmd_install() {
  sudo apt-get update
  sudo apt-get install -y mono-complete mono-runtime libmono-system-windows-forms4.0-cil \
    libmono-system-core4.0-cil libmono-system-management4.0-cil libmono-system-xml-linq4.0-cil \
    unzip curl
  if [ -f "$MP_DIR/MissionPlanner.exe" ]; then
    echo "Mission Planner already in $MP_DIR (delete the folder to reinstall)"
  else
    local tmp
    tmp=$(mktemp -d)
    curl -fL -o "$tmp/mp.zip" "$MP_ZIP_URL"
    mkdir -p "$MP_DIR"
    unzip -q "$tmp/mp.zip" -d "$MP_DIR"
    rm -rf "$tmp"
  fi
  # USB / telemetry radios: serial port access, and ModemManager must not grab the port
  if ! id -nG | grep -qw dialout; then
    sudo usermod -aG dialout "$USER"
    echo "Added $USER to dialout: log out and back in"
  fi
  if systemctl is-active --quiet ModemManager; then
    sudo systemctl disable --now ModemManager
  fi
  echo "Done. Open Mission Planner once (missionplanner.sh start) so it creates its config."
}

cmd_ntrip_test() {
  load_ntrip
  local code
  # -m: a caster stream never ends, so curl stops on the timeout (exit 28) after the headers
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -u "$NTRIP_USER:$NTRIP_PASS" \
    -H 'Ntrip-Version: Ntrip/2.0' -A 'NTRIP rover-test' \
    "http://$NTRIP_HOST:$NTRIP_PORT/$NTRIP_MOUNT" || true)
  case "$code" in
    200) echo "OK (200): credentials and mountpoint $NTRIP_MOUNT accepted" ;;
    401) die "401 Unauthorized: wrong user/password, or the account is already connected somewhere else (1 connection per user)" ;;
    404) die "404 Not Found: mountpoint $NTRIP_MOUNT does not exist (list: curl -s -H 'Ntrip-Version: Ntrip/2.0' http://$NTRIP_HOST:$NTRIP_PORT/)" ;;
    000) die "no answer from $NTRIP_HOST:$NTRIP_PORT (network?)" ;;
    *) die "unexpected HTTP $code" ;;
  esac
  echo "The caster may need a few seconds to free this test session before Mission Planner connects."
}

cmd_ntrip_config() {
  load_ntrip
  [ -f "$MP_CONFIG" ] || die "no $MP_CONFIG yet: open Mission Planner once and close it"
  # Mission Planner rewrites its config when it closes, it would undo the change
  mp_running && die "close Mission Planner first"
  python3 -I -c 'import sys, xml.etree.ElementTree as ET
path, url = sys.argv[1:]
tree = ET.parse(path)
root = tree.getroot()
for key, value in (("NTRIP_url", url), ("SerialInjectGPS_port", "NTRIP")):
    node = root.find(key)
    if node is None:
        node = ET.SubElement(root, key)
    node.text = value
tree.write(path, encoding="utf-8", xml_declaration=True)' "$MP_CONFIG" "$(ntrip_url)"
  echo "NTRIP in Mission Planner: http://$NTRIP_USER:****@$NTRIP_HOST:$NTRIP_PORT/$NTRIP_MOUNT"
}

cmd_start() {
  [ -f "$MP_DIR/MissionPlanner.exe" ] || die "Mission Planner not found in $MP_DIR: run $0 install"
  mp_running && die "Mission Planner is already open"
  if [ -f "$MP_CONFIG" ] && [ -f "$NTRIP_ENV" ]; then
    cmd_ntrip_config
  fi
  cd "$MP_DIR"
  exec mono MissionPlanner.exe
}

case "${1:-}" in
  install) cmd_install ;;
  ntrip-test) cmd_ntrip_test ;;
  ntrip-config) cmd_ntrip_config ;;
  start) cmd_start ;;
  *) die "usage: $0 install|ntrip-test|ntrip-config|start" ;;
esac
