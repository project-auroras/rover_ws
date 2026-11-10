


# rover_ws — Rover ArduPilot + Mission Planner + ROS 2 (MAVROS)

Conexión al rover con ArduPilot desde el PC (Ubuntu 24.04), para verlo en Mission Planner y manejarlo desde ROS 2 a través de MAVROS.

```
 Rover (ArduPilot)                         PC (Ubuntu 24.04)
┌──────────────────┐  radio 433/915 MHz   ┌──────────────────────────────────────────────────────────┐
│ controladora     │◄────────────────────►│ radio USB FTDI  /dev/ttyUSB0  57600 baudios              │
│ SYSID_THISMAV=1  │   MAVLink 2          │        │                                                 │
└──────────────────┘                      │        ▼                                                 │
                                          │  ┌─────────── contenedor `rover` (ROS 2 Humble) ───────┐ │
                                          │  │ MAVProxy (router) ── UDP 14555 ──► MAVROS ──► ROS 2 │ │
                                          │  └──────┬──────────────────────────────────────────────┘ │
                                          │         └── UDP 14550 ──► Mission Planner (Mono)         │
                                          └──────────────────────────────────────────────────────────┘
```

- El puerto serie solo puede abrirlo **un programa**. MAVProxy lo abre y reparte MAVLink a Mission Planner y a MAVROS por UDP, así funcionan los dos a la vez.
- ROS 2 va en Docker (Humble). El contenedor usa la red del host (`--network host`), así que los topics `/mavros/*` se ven desde cualquier máquina ROS 2 con el mismo `ROS_DOMAIN_ID`. El rover usa el **dominio 7** (`config/rover.env`), para no mezclarse con otros robots en el 0: en otra máquina, `export ROS_DOMAIN_ID=7` antes de usar `ros2`.

## Estructura

| Ruta | Qué es |
|---|---|
| `scripts/rover.sh` | Todo lo del rover real: imagen, detección, router, MAVROS |
| `scripts/mav_probe.py` | Busca puerto y baudios donde habla el rover y muestra su estado |
| `scripts/missionplanner.sh` | Instalar/abrir Mission Planner y NTRIP (ver [MISSIONPLANNER.md](MISSIONPLANNER.md)) |
| `config/rover.env` | Puerto, baudios, sysid, puertos UDP |
| `config/mavros_rover.yaml` | Parámetros de MAVROS para el rover |
| `launch/mavros_rover.launch.py` | Launch de MAVROS (APM + `mavros_rover.yaml`) |
| `launch/request_streams.py` | Pide la telemetría a ArduPilot cada vez que MAVROS conecta |
| `docker/Dockerfile` | Imagen `rover:humble`: ROS 2 Humble, MAVROS, MAVProxy, pymavlink, teleop |
| `docker/Dockerfile.sitl` | Imagen `rover-sitl:4.7.1`: rover simulado (ArduPilot SITL) |
| `config/ntrip.env` | Credenciales NTRIP (no compartir; plantilla en `ntrip.env.example`) |
| `MissionPlanner/` | Mission Planner (se ejecuta con Mono) |

## 1. Una sola vez

```bash
cd ~/rover_ws
scripts/rover.sh build                 # imagen rover:humble (~10 min la primera vez)
sudo usermod -aG dialout $USER         # acceso a /dev/ttyUSB*; cerrar sesión y volver a entrar
sudo systemctl disable --now ModemManager   # ModemManager se apodera de los puertos serie USB
```

(`scripts/missionplanner.sh install` hace también lo de `dialout` y ModemManager.)

## 2. Comprobar el enlace con el rover

Enciende el rover, enchufa la radio y:

```bash
scripts/rover.sh probe
```

```
FOUND  /dev/serial/by-id/usb-FTDI_FT231X_USB_UART_DU0ENGAS-if00-port0 @ 57600
  MAVLink v2  sysid=1 compid=1
  type=GROUND_ROVER  mode=HOLD  armed=False
  GPS fix_type=6 sats=24 (6 = RTK fixed, 5 = RTK float)
```

Si el puerto, los baudios o el `sysid` no coinciden con `config/rover.env`, corrígelo ahí. Con cable USB directo a la controladora el puerto será `/dev/serial/by-id/usb-ArduPilot_...` (o `/dev/ttyACM0`) a 115200.

`probe` necesita el puerto libre: cierra antes Mission Planner (si está conectado por serie) y `rover.sh link`.

## 3. Uso normal: 3 terminales

```bash
# Terminal 1: router MAVLink (déjalo abierto; también es una consola MAVProxy)
scripts/rover.sh link

# Terminal 2: MAVROS
scripts/rover.sh mavros

# Terminal 3 (opcional): Mission Planner → UDP → puerto 14550 → CONNECT
scripts/missionplanner.sh start
```

En la consola de MAVProxy (terminal 1) puedes escribir comandos: `mode guided`, `mode hold`, `arm throttle`, `disarm`, `param show SR1*`, `status`.

Al arrancar, MAVProxy y MAVROS descargan los ~880 parámetros por la radio: durante los **primeros ~30 s** la telemetría va lenta (IMU a ~1 Hz en vez de 5). Es normal.

Comprobar que MAVROS está conectado:

```bash
scripts/rover.sh status        # /mavros/state debe decir connected: true
```

### Alternativa sin MAVProxy

```bash
scripts/rover.sh mavros-direct
```

MAVROS abre el puerto serie directamente y reenvía todo a Mission Planner (UDP 14550). Un proceso menos, pero Mission Planner solo funciona mientras MAVROS está arrancado.

### Con el simulador en lugar del rover real

Rover simulado (SITL) con el mismo firmware que el real, ArduRover 4.7.1:

```bash
scripts/rover.sh build-sitl     # una sola vez (~15 min)
scripts/rover.sh sitl           # terminal 1, en lugar de `rover.sh link`
scripts/rover.sh mavros         # terminal 2, igual que con el rover real
```

Más detalles en [MISSIONPLANNER.md](MISSIONPLANNER.md#2-simulador-sitl).

## 4. Manejar el rover desde ROS 2

Todo dentro de `scripts/rover.sh shell` (o desde otra máquina ROS 2 Humble en la misma red y `export ROS_DOMAIN_ID=7`).

> ⚠️ **Con el rover real: ruedas en el aire o espacio despejado, y alguien con la emisora RC listo para pasar a HOLD/MANUAL.**

### Topics y servicios principales

| Nombre | Tipo | Para qué |
|---|---|---|
| `/mavros/state` | `mavros_msgs/State` | conectado, armado, modo |
| `/mavros/global_position/global` | `sensor_msgs/NavSatFix` | posición GPS (filtrada por EKF) |
| `/mavros/gpsstatus/gps1/raw` | `mavros_msgs/GPSRAW` | fix (6 = RTK fixed), satélites |
| `/mavros/local_position/odom` | `nav_msgs/Odometry` | odometría local ENU |
| `/mavros/imu/data` | `sensor_msgs/Imu` | IMU |
| `/mavros/battery` | `sensor_msgs/BatteryState` | batería |
| `/mavros/setpoint_velocity/cmd_vel_unstamped` | `geometry_msgs/Twist` | velocidad: `linear.x` m/s, `angular.z` rad/s (GUIDED) |
| `/mavros/setpoint_position/global` | `geographic_msgs/GeoPoseStamped` | ir a un punto GPS (GUIDED) |
| `/mavros/rc/override` | `mavros_msgs/OverrideRCIn` | simular la emisora RC |
| `/mavros/set_mode` | `mavros_msgs/srv/SetMode` | cambiar modo (`MANUAL`, `HOLD`, `GUIDED`, `AUTO`…) |
| `/mavros/cmd/arming` | `mavros_msgs/srv/CommandBool` | armar / desarmar |
| `/mavros/mission/push`, `/mavros/mission/pull` | `mavros_msgs/srv/WaypointPush` | misiones (modo AUTO) |
| `/mavros/param/...` | — | leer/escribir parámetros (`ros2 run mavros mav param get ...`) |

### Mover el rover por velocidad (GUIDED)

```bash
ros2 service call /mavros/set_mode mavros_msgs/srv/SetMode "{custom_mode: 'GUIDED'}"
ros2 service call /mavros/cmd/arming mavros_msgs/srv/CommandBool "{value: true}"

# 0.5 m/s hacia delante girando despacio a la izquierda; hay que publicar continuamente (>2 Hz),
# si deja de llegar el rover se para a los ~3 s
ros2 topic pub -r 10 /mavros/setpoint_velocity/cmd_vel_unstamped geometry_msgs/msg/Twist \
  "{linear: {x: 0.5}, angular: {z: 0.2}}"

ros2 service call /mavros/set_mode mavros_msgs/srv/SetMode "{custom_mode: 'HOLD'}"
ros2 service call /mavros/cmd/arming mavros_msgs/srv/CommandBool "{value: false}"
```

Con teclado (`i` adelante, `,` atrás, `j`/`l` girar, `k` parar):

```bash
ros2 run teleop_twist_keyboard teleop_twist_keyboard --ros-args \
  -r cmd_vel:=/mavros/setpoint_velocity/cmd_vel_unstamped
```

`config/mavros_rover.yaml` pone `mav_frame: BODY_NED`, así que `cmd_vel` es en ejes del robot (`x` delante, `z` giro positivo a la izquierda), como cualquier base móvil de ROS. Así se puede conectar directamente la salida de Nav2 u otro nodo que publique `cmd_vel`.

### Ir a un punto GPS

```bash
ros2 topic pub --once /mavros/setpoint_position/global geographic_msgs/msg/GeoPoseStamped \
  "{pose: {position: {latitude: 42.6136, longitude: -5.5600, altitude: 0}}}"
```

## Parámetros de ArduPilot que conviene revisar

En Mission Planner (CONFIG → Full Parameter List) o en MAVProxy (`param set NOMBRE valor`):

| Parámetro | Valor | Por qué |
|---|---|---|
| `SERIAL1_BAUD` | `57` | 57600 en el puerto TELEM1, el de la radio |
| `SERIAL1_PROTOCOL` | `2` | MAVLink 2 |
| `SR1_*` | 2–5 | Frecuencia de telemetría por la radio. Más satura una radio de 57600 |
| `FS_GCS_ENABLE` | `1` | Si se pierde la telemetría, pasa a HOLD/RTL (`FS_ACTION`) |
| `FS_TIMEOUT` | `5` | Segundos sin GCS antes del failsafe |
| `SYSID_MYGCS` | `255` | MAVProxy/Mission Planner. Si usas `/mavros/rc/override`, pon `1` (el `system_id` de MAVROS) |
| `GPS_INJECT_TO` | `127` | Las correcciones RTK que manda Mission Planner van a todos los GPS |

## Problemas frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| `probe`: no heartbeat | Rover apagado, radios sin emparejar o en otro canal, baudios distintos | LEDs de la radio en verde fijo = emparejadas. `scripts/rover.sh probe --baud 115200` |
| `... already in use by: mono` | Mission Planner abierto conectado por serie | En Mission Planner, DISCONNECT, y conectar por UDP 14550 |
| `Permission denied: /dev/ttyUSB0` | Usuario fuera de `dialout` | `sudo usermod -aG dialout $USER` y reiniciar sesión |
| `/mavros/state` `connected: false` | No llega MAVLink a UDP 14555 | ¿Está `rover.sh link` (o SITL con `--out` a 14555)? |
| Conectado pero topics sin datos | ArduPilot no envía streams a la nueva GCS | El launch ya los pide; repetir: `ros2 service call /mavros/set_stream_rate mavros_msgs/srv/StreamRate "{stream_id: 0, message_rate: 5, on_off: true}"` |
| `set_mode`/`arming` devuelven `success: false` | Prearm checks (GPS, EKF, RC, batería) | Mirar los mensajes en la consola MAVProxy o en Mission Planner (DATA → Messages) |
| El rover no se mueve con `cmd_vel` | No está en GUIDED, no armado, o se publica `--once` | Ver `/mavros/state`; publicar a ≥ 5 Hz |
| Telemetría lenta o a saltos | Radio de 57600 saturada | Bajar `STREAM_RATE` en `config/rover.env` y los `SR1_*` |
| `PreArm: Radio failsafe on` | La emisora RC está apagada o sin enlazar | Encender la emisora. No armar sin ella |
| No se ven los topics desde otra máquina | `ROS_DOMAIN_ID` distinto o otra red | En esa máquina `export ROS_DOMAIN_ID=7`. Para cambiar el dominio del rover, editar `config/rover.env` |
