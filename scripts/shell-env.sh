# 대화형 셸(SSH, 데스크톱 xterm) 공통 환경. /root/.bashrc 에서 source 된다.
# ROS는 자동으로 source 하지 않는다 — Isaac Sim 실행 셸과 ROS 셸을 분리하기 위해서.

[ -f /etc/runpod.env ] && . /etc/runpod.env
export DISPLAY=:1
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"

# ros : 이 셸에 시스템 ROS 2를 올린다 (ros2 CLI, rviz2 용)
ros() {
    local distro; distro=$(cat /etc/ros_distro 2>/dev/null) || { echo "ROS 미설치 이미지"; return 1; }
    . "/opt/ros/$distro/setup.bash"
    export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
    echo "ROS 2 $distro 활성화 (DOMAIN_ID=$ROS_DOMAIN_ID). 이 셸에서는 isaac-gui 를 실행하지 마세요."
}

# ros_udp : /dev/shm 문제로 토픽이 안 보일 때 Fast DDS를 UDP 전용으로
ros_udp() { export FASTRTPS_DEFAULT_PROFILES_FILE=/opt/isaac-runpod/config/fastdds-udp.xml; echo "Fast DDS UDP 전용 프로파일 적용"; }

alias isaac-log='tail -f /var/log/isaac-runpod/isaac-gui.log'
alias isaac-python='/isaac-sim/python.sh'
