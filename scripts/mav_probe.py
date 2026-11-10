#!/usr/bin/env python3
"""Find the serial port and baud rate where an ArduPilot vehicle is talking MAVLink.

Usage: mav_probe.py [PORT ...] [--baud B ...]   (default: /dev/serial/by-id/*, ttyUSB*, ttyACM*)
Prints the vehicle info and a line `RESULT port baud sysid` for scripts.
"""
import argparse
import glob
import sys
import time

from pymavlink import mavutil

BAUDS = [57600, 115200, 921600]
MAV_TYPE_GCS = mavutil.mavlink.MAV_TYPE_GCS


def candidates():
    ports = sorted(glob.glob("/dev/serial/by-id/*"))
    if ports:
        return ports
    return sorted(glob.glob("/dev/ttyUSB*") + glob.glob("/dev/ttyACM*"))


def try_port(port, baud, timeout=4.0):
    try:
        m = mavutil.mavlink_connection(port, baud=baud, autoreconnect=False)
    except Exception as e:  # busy port, no permission...
        print(f"  {port} @ {baud}: {e}")
        return None
    deadline = time.time() + timeout
    while time.time() < deadline:
        hb = m.recv_match(type="HEARTBEAT", blocking=True, timeout=0.5)
        if hb is not None and hb.type != MAV_TYPE_GCS:
            return m, hb
    m.close()
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ports", nargs="*")
    ap.add_argument("--baud", type=int, action="append")
    args = ap.parse_args()
    ports = args.ports or candidates()
    bauds = args.baud or BAUDS
    if not ports:
        sys.exit("no serial ports found (is the radio / USB cable plugged in?)")

    for port in ports:
        for baud in bauds:
            print(f"trying {port} @ {baud} ...", flush=True)
            res = try_port(port, baud)
            if not res:
                continue
            m, hb = res
            sysid, compid = hb.get_srcSystem(), hb.get_srcComponent()
            mode = mavutil.mode_string_v10(hb)
            armed = bool(hb.base_mode & mavutil.mavlink.MAV_MODE_FLAG_SAFETY_ARMED)
            vtype = mavutil.mavlink.enums["MAV_TYPE"][hb.type].name
            print(f"\nFOUND  {port} @ {baud}")
            print(f"  MAVLink v{2 if m.WIRE_PROTOCOL_VERSION == '2.0' else 1}  sysid={sysid} compid={compid}")
            print(f"  type={vtype}  mode={mode}  armed={armed}")
            m.mav.request_data_stream_send(sysid, compid, mavutil.mavlink.MAV_DATA_STREAM_ALL, 2, 1)
            gps = m.recv_match(type="GPS_RAW_INT", blocking=True, timeout=4)
            if gps:
                print(f"  GPS fix_type={gps.fix_type} sats={gps.satellites_visible} (6 = RTK fixed, 5 = RTK float)")
            bat = m.recv_match(type="SYS_STATUS", blocking=True, timeout=3)
            if bat and bat.voltage_battery not in (0, 65535):
                print(f"  battery={bat.voltage_battery / 1000:.2f} V")
            m.close()
            print(f"RESULT {port} {baud} {sysid}")
            return
    sys.exit("no MAVLink heartbeat on any port/baud (vehicle powered? radio paired? port in use by Mission Planner/MAVProxy?)")


if __name__ == "__main__":
    main()
