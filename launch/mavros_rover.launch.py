"""MAVROS for the ArduPilot rover: stock apm.launch plus config/mavros_rover.yaml on top.

ros2 launch /ws/launch/mavros_rover.launch.py fcu_url:=udp://:14555@ tgt_system:=1
(normally started by scripts/rover.sh mavros)
"""
import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, ExecuteProcess
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node

WS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def generate_launch_description():
    share = get_package_share_directory("mavros")
    lc = LaunchConfiguration
    args = [
        DeclareLaunchArgument("fcu_url", default_value="udp://:14555@"),
        DeclareLaunchArgument("gcs_url", default_value=""),
        DeclareLaunchArgument("tgt_system", default_value="1"),
        DeclareLaunchArgument("tgt_component", default_value="1"),
        DeclareLaunchArgument("stream_rate", default_value="5"),
    ]
    mavros = Node(
        package="mavros",
        executable="mavros_node",
        output="screen",
        respawn=True,
        parameters=[
            os.path.join(share, "launch", "apm_pluginlists.yaml"),
            os.path.join(share, "launch", "apm_config.yaml"),
            os.path.join(WS, "config", "mavros_rover.yaml"),
            {
                "fcu_url": lc("fcu_url"),
                "gcs_url": lc("gcs_url"),
                "tgt_system": lc("tgt_system"),
                "tgt_component": lc("tgt_component"),
                "fcu_protocol": "v2.0",
            },
        ],
    )
    # ArduPilot does not stream telemetry to a new GCS until asked: request all streams on each (re)connect.
    streams = ExecuteProcess(
        cmd=["python3", os.path.join(WS, "launch", "request_streams.py"), lc("stream_rate")],
        output="screen",
    )
    return LaunchDescription(args + [mavros, streams])
