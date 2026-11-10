# Mission Planner + NTRIP (RTK)

Cómo usar Mission Planner en el PC (Ubuntu) con el rover (real o simulado) y las correcciones RTK del caster NTRIP de ITACyL.

```
PC (Ubuntu)
┌──────────────────────────────┐   UDP 14550   ┌────────────────────────────────────────────┐
│ Mission Planner (Mono)       │◄──────────────│ rover real:  scripts/rover.sh link (radio) │
│   └─ RTK/GPS Inject (NTRIP)  │               │ simulado:    scripts/rover.sh sitl         │
└──────────────┬───────────────┘               └────────────────────────────────────────────┘
               │ TCP 2101
               ▼
   Caster NTRIP ITACyL (52.164.213.26:2101/leon3m)
```

- Mission Planner va **en el host**, no en Docker. Los contenedores usan la red del host, así que lo que envían a `127.0.0.1:14550` le llega sin abrir puertos.
- La conexión con el rover (real o simulado) se explica en [README.md](README.md). Aquí solo Mission Planner y NTRIP:

| Comando | Qué hace |
|---|---|
| `scripts/missionplanner.sh install` | Instala Mono y Mission Planner en `~/rover_ws/MissionPlanner`, y da permisos de puerto serie |
| `scripts/missionplanner.sh ntrip-test` | Comprueba usuario, contraseña y mountpoint contra el caster |
| `scripts/missionplanner.sh ntrip-config` | Escribe la URL NTRIP en la configuración de Mission Planner |
| `scripts/missionplanner.sh start` | `ntrip-config` y abre Mission Planner |

## 1. Una sola vez

### Mission Planner

```bash
cd ~/rover_ws
scripts/missionplanner.sh install
```

Instala `mono-complete`, descarga `MissionPlanner-latest.zip` en `~/rover_ws/MissionPlanner`, añade tu usuario al grupo `dialout` y desactiva ModemManager. Estos dos últimos pasos solo hacen falta para conectar una controladora por USB o radio. Si te añade a `dialout`, **cierra sesión y vuelve a entrar**.

Ábrelo una vez y ciérralo para que cree su configuración (`~/.local/share/Mission Planner/config.xml`):

```bash
scripts/missionplanner.sh start
```

En el primer arranque sale el aviso *"Restart Mission Planner to enable Drone ID Tab"*. Es normal: pulsa OK. Si no quieres esa pestaña, desactiva el plugin con Ctrl+P.

### Credenciales NTRIP

```bash
cp config/ntrip.env.example config/ntrip.env
nano config/ntrip.env      # NTRIP_USER, NTRIP_PASS, NTRIP_MOUNT
chmod 600 config/ntrip.env
```

`config/ntrip.env` está en `.gitignore`: **la contraseña no se sube al repo**. Escríbela tal cual, aunque lleve `@`. El script la codifica para la URL (`@` → `%40`), y Mission Planner la decodifica antes de enviarla.

Las cuentas se piden en https://gnss.itacyl.es/inscripcion (gratis). **Cada usuario admite una sola conexión a la vez**: si otra persona o dispositivo está usando la misma cuenta, el caster responde `401`. Para conectaros varios a la vez, pedid un usuario por persona (pueden ir con el mismo email). Para cambiar o recuperar la contraseña: https://gnss.itacyl.es/web/redgnss/registro/resetpassword

## 2. Simulador (SITL)

Para probar sin el rover real hay un rover simulado con **el mismo firmware** (ArduRover 4.7.1), en la imagen `rover-sitl:4.7.1`:

```bash
scripts/rover.sh build-sitl     # una sola vez (~15 min: compila ArduPilot)
scripts/rover.sh sitl           # en lugar de `rover.sh link`; déjalo abierto
```

- Aparece en el campus de la ULE (León). Otra posición: `SITL_LOCATION=lat,lon,alt,rumbo scripts/rover.sh sitl`.
- Envía MAVLink a UDP 14550 (Mission Planner) y 14555 (MAVROS), como `rover.sh link` con el rover real. No se pueden usar los dos a la vez.
- Admite más argumentos de `sim_vehicle.py`, por ejemplo `scripts/rover.sh sitl --speedup 2`.
- Cada arranque es un rover nuevo: los parámetros que cambies no se guardan.
- Está listo cuando la consola de MAVProxy muestra el modo (`MANUAL`, `HOLD`…).

## 3. Conectar Mission Planner

En otra terminal del host:

```bash
scripts/missionplanner.sh start
```

1. Maximiza la ventana. Con Mono, si es estrecha, se corta la barra superior.
2. **Arriba a la derecha** de la ventana principal: desplegable de puerto → **UDP** (la velocidad da igual) → botón **CONNECT** (icono de los dos enchufes).
3. Puerto: **14550** → OK.
4. Se descargan los parámetros y el rover aparece en el mapa de **DATA**. El botón cambia a **DISCONNECT**.

Esa conexión vale para todas las pestañas (DATA, PLAN, SETUP, CONFIG). **No hay que volver a conectar en SETUP.** Los botones *Connect* que hay dentro de algunas pantallas de SETUP son para otras cosas: el de *RTK/GPS Inject* es para el NTRIP, y *Install Firmware* solo vale para una controladora física por USB.

## 4. Conectar el NTRIP (correcciones RTK)

Antes, comprueba la cuenta (opcional):

```bash
scripts/missionplanner.sh ntrip-test     # debe decir OK (200)
```

Esta prueba ocupa la sesión de la cuenta unos segundos. Si justo después Mission Planner da `401`, espera un poco y vuelve a intentarlo.

`scripts/missionplanner.sh start` ya ha escrito la URL en Mission Planner (si lo tenías abierto, ciérralo y usa `ntrip-config`, porque Mission Planner sobrescribe su configuración al cerrarse). Después:

1. **SETUP → Optional Hardware → RTK/GPS Inject**.
2. En el desplegable de puerto de esa pantalla: **NTRIP**.
3. **"Send NTRIP protocol v1.0?"**: desmarcado (usa NTRIP v2).
4. **Connect** (el de esa pantalla). Si pregunta la URL, ya viene rellenada: `http://usuario:contraseña@52.164.213.26:2101/leon3m`.
5. Deben ir subiendo los bytes y los mensajes RTCM (1005, 1074, 1084…) en la tabla de la derecha.

Para comprobarlo desde la terminal: `ss -tnp | grep 52.164.213.26` muestra una línea `ESTAB` mientras Mission Planner está conectado.

**Mountpoint**: `leon3m` es la estación de León (RTCM 3.2, GPS+GLONASS+Galileo+BeiDou) y no necesita enviar posición. `VRS3M` (red VRS) sí necesita la posición del vehículo (GGA), y el vehículo tiene que estar en Castilla y León. La lista completa:

```bash
curl -s -H 'Ntrip-Version: Ntrip/2.0' http://52.164.213.26:2101/ | grep '^STR'
```

**Con SITL, las correcciones no cambian nada**: el GPS simulado ya es perfecto. Solo sirve para comprobar la conexión. Las correcciones tienen efecto con un GPS RTK real (u-blox F9P, etc.) en el rover. Con `rover.sh link`, Mission Planner sigue conectado por UDP 14550 y MAVProxy reenvía las correcciones al rover por la radio (`GPS_RTCM_DATA`). Una radio de 57600 va justa con RTCM + telemetría: si el fix RTK no llega, bajar `STREAM_RATE` en `config/rover.env`.

## Problemas frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| Mission Planner se queda "Connecting…" con UDP | No corre ni `rover.sh link` ni `rover.sh sitl` | Arrancar uno de los dos y esperar a los parámetros |
| `Bad ntrip Response` + `401 Unauthorized` | Contraseña mal, o la cuenta ya está conectada en otro sitio (1 conexión por usuario) | `ntrip-test`. Desconectar los otros equipos, esperar 1–2 min, conectar **una** vez |
| `Bad ntrip Response` + `404 Not Found` | Mountpoint inexistente | Revisar `NTRIP_MOUNT` con la lista de arriba |
| "if using com0com please rename the ports to COM??" | Texto genérico de Mission Planner en cualquier error | Ignorarlo y leer la línea `HTTP/1.1 ...` |
| `ntrip-config`: "close Mission Planner first" | Mission Planner abierto sobrescribiría el cambio | Cerrarlo y repetir |
| No se ve el botón CONNECT | Ventana estrecha con Mono | Maximizar |
| No abre el puerto USB | Falta `dialout` o ModemManager lo coge | `scripts/missionplanner.sh install`, cerrar sesión y entrar |
