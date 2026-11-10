#!/usr/bin/env bash
# Run on the host PC. Connects the ArduPilot rover (telemetry radio / USB) to Mission Planner and ROS 2 (MAVROS).
#   rover.sh build            build the docker image rover:humble (ROS 2 Humble + MAVROS + MAVProxy)
#   rover.sh probe [port..]   find port/baud of the rover and show its state (nothing else may use the port)
#   rover.sh link             MAVLink router: serial -> UDP $MP_UDP_PORT (Mission Planner) + UDP $MAVROS_UDP_PORT (MAVROS)
#   rover.sh mavros           MAVROS on UDP $MAVROS_UDP_PORT (needs `link`, or SITL sending there)
#   rover.sh mavros-direct    MAVROS straight on the serial port (no MAVProxy), forwards to Mission Planner
#   rover.sh status           one-shot check from ROS: /mavros/state, GPS, battery
#   rover.sh shell            bash in the container with ROS sourced (ros2 topic list, teleop...)
#   rover.sh down             stop the container
#   rover.sh build-sitl       build the docker image rover-sitl (ArduPilot Rover SITL, same version as the rover)
#   rover.sh sitl [args]      simulated rover instead of the real one (instead of `link`): UDP 14550 + 14555
# Settings in config/rover.env.
set -euo pipefail

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROVER_ENV:-$WS/config/rover.env}"
IMAGE="${IMAGE:-rover:humble}"
CONTAINER="${CONTAINER:-rover}"
SITL_IMAGE="${SITL_IMAGE:-rover-sitl:4.7.1}"
SITL_LOCATION="${SITL_LOCATION:-42.6135,-5.5605,838,0}"   # lat,lon,alt,heading (ULE campus, León)
ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-7}"   # set in config/rover.env

die() { echo "$*" >&2; exit 1; }

port_users() { fuser "$(readlink -f "$ROVER_PORT")" 2>/dev/null || true; }

check_port_free() {
  [ -e "$ROVER_PORT" ] || die "$ROVER_PORT not found: radio/USB unplugged? (ls /dev/serial/by-id). Then: $0 probe"
  local pids
  pids=$(port_users)
  [ -z "$pids" ] || die "$ROVER_PORT already in use by: $(ps -o comm= -p "$(echo $pids | tr " " ",")" | tr '\n' ' ')(Mission Planner on serial? another link?)"
}

# One long-lived container; every command runs in it with docker exec.
# /dev is bind-mounted with cgroup rules for ttyUSB (188) and ttyACM (166), so replugging the radio works
# without restarting the container.
up() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 || die "image $IMAGE missing: $0 build"
  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ]; then
    # recreate if the image was rebuilt
    [ "$(docker inspect -f '{{.Image}}' "$CONTAINER")" = "$(docker image inspect -f '{{.Id}}' "$IMAGE")" ] && return
    docker rm -f "$CONTAINER" >/dev/null
  fi
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$CONTAINER" --network host --ipc host \
    -e ROS_DOMAIN_ID="$ROS_DOMAIN_ID" -e DISPLAY="${DISPLAY:-:0}" \
    -v "$WS:/ws" -v /dev:/dev -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
    --device-cgroup-rule='c 188:* rmw' --device-cgroup-rule='c 166:* rmw' \
    "$IMAGE" sleep infinity >/dev/null
}

# docker exec with ROS sourced; -it only when there is a terminal
rexec() {
  local tty=()
  [ -t 0 ] && tty=(-it)
  docker exec "${tty[@]}" -e ROS_DOMAIN_ID="$ROS_DOMAIN_ID" "$CONTAINER" bash -c 'source /opt/ros/humble/setup.bash && exec "$@"' rexec "$@"
}

cmd_build() { docker build -t "$IMAGE" -f "$WS/docker/Dockerfile" "$WS/docker"; }

cmd_probe() {
  up
  if [ $# -eq 0 ]; then
    local pids; pids=$(port_users)
    [ -z "$pids" ] || die "$ROVER_PORT in use by $(ps -o comm= -p "$(echo $pids | tr " " ",")" | tr '\n' ' '), close it first"
  fi
  rexec python3 /ws/scripts/mav_probe.py "$@"
  echo "If port/baud/sysid differ from config/rover.env, update it."
}

cmd_link() {
  check_port_free
  up
  # MAVProxy interactive console: `mode guided`, `arm throttle`, `param show SR1*`... Ctrl+D or `exit` to quit.
  # MAVROS binds $MAVROS_UDP_PORT; Mission Planner listens on $MP_UDP_PORT (UDP connect, port 14550).
  rexec bash -c 'cd /tmp && exec mavproxy.py "$@"' mavproxy \
    --master="$ROVER_PORT" --baudrate="$ROVER_BAUD" \
    --out="udp:127.0.0.1:$MP_UDP_PORT" --out="udp:127.0.0.1:$MAVROS_UDP_PORT" \
    --source-system=255 --streamrate="$STREAM_RATE" --state-basedir=/tmp "$@"
}

launch_mavros() {
  local args=(fcu_url:="$1" tgt_system:="$ROVER_SYSID" stream_rate:="$STREAM_RATE")
  [ -n "${2:-}" ] && args+=(gcs_url:="$2")   # ros2 launch rejects an empty value
  up
  rexec ros2 launch /ws/launch/mavros_rover.launch.py "${args[@]}"
}

cmd_mavros() {
  ss -lun | grep -q ":$MAVROS_UDP_PORT " && die "UDP $MAVROS_UDP_PORT already bound: is MAVROS already running?"
  launch_mavros "udp://:$MAVROS_UDP_PORT@"
}

cmd_mavros_direct() {
  check_port_free
  # gcs_url: MAVROS forwards everything to Mission Planner on UDP $MP_UDP_PORT
  launch_mavros "$ROVER_PORT:$ROVER_BAUD" "udp://:14556@127.0.0.1:$MP_UDP_PORT"
}

cmd_status() {
  up
  rexec bash -c '
    t=8
    echo "--- /mavros/state";            timeout $t ros2 topic echo --once /mavros/state || echo "no data (is mavros running?)"
    echo "--- /mavros/gpsstatus/gps1/raw"; timeout $t ros2 topic echo --once --field fix_type /mavros/gpsstatus/gps1/raw 2>/dev/null || true
    echo "--- /mavros/battery (voltage)";  timeout $t ros2 topic echo --once --field voltage /mavros/battery 2>/dev/null || true'
}

cmd_shell() { up; rexec bash; }

cmd_down() { docker rm -f "$CONTAINER" >/dev/null 2>&1 && echo "container $CONTAINER removed" || true; }

cmd_build_sitl() { docker build -t "$SITL_IMAGE" -f "$WS/docker/Dockerfile.sitl" "$WS/docker"; }

cmd_sitl() {
  docker image inspect "$SITL_IMAGE" >/dev/null 2>&1 || die "image $SITL_IMAGE missing: $0 build-sitl"
  ss -lun | grep -q ":$MAVROS_UDP_PORT " && pgrep -f 'mavproxy.py --master=/dev' >/dev/null \
    && die "rover.sh link is running (real rover): stop it first, both would send to the same UDP ports"
  xhost +local: >/dev/null 2>&1 || true   # MAVProxy console/map windows (X11)
  local tty=(); [ -t 0 ] && tty=(-it)
  # sim_vehicle.py already sends to udp:127.0.0.1:14550 (Mission Planner); --out adds MAVROS.
  # Fresh simulated vehicle on every run (--rm): parameters are not kept.
  docker run --rm "${tty[@]}" --name rover-sitl --network host \
    -e DISPLAY="${DISPLAY:-:0}" -v /tmp/.X11-unix:/tmp/.X11-unix:rw "$SITL_IMAGE" \
    Tools/autotest/sim_vehicle.py -v Rover --no-rebuild --console --map -l "$SITL_LOCATION" \
    --out="udp:127.0.0.1:$MAVROS_UDP_PORT" "$@"
}

case "${1:-}" in
  build) cmd_build ;;
  probe) shift; cmd_probe "$@" ;;
  link) shift; cmd_link "$@" ;;
  mavros) cmd_mavros ;;
  mavros-direct) cmd_mavros_direct ;;
  status) cmd_status ;;
  shell) cmd_shell ;;
  down) cmd_down ;;
  build-sitl) cmd_build_sitl ;;
  sitl) shift; cmd_sitl "$@" ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
