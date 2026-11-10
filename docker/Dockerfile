# ROS 2 Humble + MAVROS + MAVProxy to drive the ArduPilot rover from ROS.
# Humble (Ubuntu 22.04 base): the host is Ubuntu 24.04 without ROS, everything ROS runs here.
FROM ros:humble-ros-base

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ros-humble-mavros ros-humble-mavros-extras ros-humble-mavros-msgs \
      ros-humble-teleop-twist-keyboard \
      python3-pip python3-serial sudo bash-completion less vim \
    && /opt/ros/humble/lib/mavros/install_geographiclib_datasets.sh \
    && pip3 install --no-cache-dir "pymavlink>=2.4.41" "MAVProxy>=1.8.70" \
    && rm -rf /var/lib/apt/lists/*

# dialout: access to /dev/ttyUSB* and /dev/ttyACM*
RUN groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -G dialout -m -s /bin/bash ${USERNAME} \
    && echo "${USERNAME} ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME} \
    && echo 'source /opt/ros/humble/setup.bash' >> /home/${USERNAME}/.bashrc

USER ${USERNAME}
WORKDIR /ws
CMD ["bash"]
