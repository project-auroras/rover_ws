#!/usr/bin/env python3
"""Ask ArduPilot for telemetry streams every time MAVROS (re)connects.

ArduPilot only streams to a GCS that requests it (or per its SRx_ params), so without this
most /mavros topics stay silent or slow. Started by mavros_rover.launch.py.
"""
import sys

import rclpy
from mavros_msgs.msg import State
from mavros_msgs.srv import StreamRate
from rclpy.node import Node


class RequestStreams(Node):
    def __init__(self, rate):
        super().__init__("request_streams")
        self.rate = rate
        self.connected = False
        self.cli = self.create_client(StreamRate, "/mavros/set_stream_rate")
        self.create_subscription(State, "/mavros/state", self.on_state, 10)

    def on_state(self, msg):
        if msg.connected and not self.connected:
            self.request()
        self.connected = msg.connected

    def request(self):
        if not self.cli.wait_for_service(timeout_sec=5.0):
            self.get_logger().warn("/mavros/set_stream_rate not available")
            return
        req = StreamRate.Request(stream_id=0, message_rate=self.rate, on_off=True)
        self.cli.call_async(req).add_done_callback(
            lambda _: self.get_logger().info(f"requested all streams at {self.rate} Hz"))


def main():
    rclpy.init(args=sys.argv)
    args = rclpy.utilities.remove_ros_args(sys.argv)
    rate = int(args[1]) if len(args) > 1 else 5
    rclpy.spin(RequestStreams(rate))


if __name__ == "__main__":
    main()
