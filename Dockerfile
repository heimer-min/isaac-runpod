# syntax=docker/dockerfile:1
# =============================================================================
# Isaac Sim + 브라우저 GUI(noVNC) 이미지 — RunPod용
#
#   브라우저 → RunPod HTTPS 프록시(:6080) → websockify/noVNC → x11vnc(:5901, localhost)
#            → Xvfb(:1) ← Isaac Sim GUI (Vulkan, NVIDIA GPU)
#
# 왜 커스텀 이미지인가:
#   - RunPod pod는 그 자체가 컨테이너라서 pod 안에서 `docker run`을 못 한다.
#   - 공식 Isaac Sim 5.x/6.x 이미지는 비루트(uid 1234)로 실행되고 sudo가 없어서
#     pod에 들어가서 apt로 Xvfb 등을 설치할 수 없다.
#   → 빌드 시점에 root로 GUI 스택을 미리 깔아 둔 이미지를 만들어 레지스트리에 올린다.
#
# 빌드 예 (Mac이면 반드시 --platform linux/amd64):
#   docker buildx build --platform linux/amd64 \
#     -t <dockerhub-id>/isaac-sim-novnc:6.1.0-v1 --push .
# =============================================================================
ARG ISAAC_SIM_VERSION=6.1.0
FROM nvcr.io/nvidia/isaac-sim:${ISAAC_SIM_VERSION}

# 공식 이미지는 USER 1234로 끝난다. 패키지 설치와 런타임(sshd, Xvfb) 모두 root가 필요.
USER root

ENV DEBIAN_FRONTEND=noninteractive \
    # 컨테이너 런타임이 Vulkan/GLX(graphics)·NVENC(video) 유저랜드 라이브러리까지
    # 주입하게 한다. compute만 주입되면 Isaac Sim GUI가 뜨지 않는다.
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=all \
    # root로 Kit을 띄우려면 필요 (isaac-sim.sh --allow-root 와 같은 효과)
    OMNI_KIT_ALLOW_ROOT=1

# --- 1) 데스크톱 스택 + 진단 도구 + SSH ---------------------------------------
#   xvfb        : 가상 X 디스플레이
#   x11vnc      : X 화면을 VNC로 송출
#   novnc/websockify : VNC ↔ WebSocket 변환 + 브라우저 클라이언트
#   fluxbox     : 가벼운 창 관리자 (창 이동/최대화, 우클릭 메뉴에서 xterm)
#   xdotool, x11-utils : 창 제어·디스플레이 확인(xdpyinfo, xmessage)
#   vulkan-tools: vulkaninfo — "이 호스트가 Xvfb에 Vulkan을 그릴 수 있나" 사전 점검
#   mesa-utils  : glxinfo — rviz2(OpenGL)가 Xvfb에서 도는지 점검
RUN apt-get update && apt-get install -y --no-install-recommends \
        xvfb x11vnc novnc websockify fluxbox xterm \
        xdotool x11-utils vulkan-tools mesa-utils \
        openssh-server ca-certificates curl gnupg lsb-release \
        procps iproute2 less nano htop git tmux \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/run/sshd

# --- 2) (선택) ROS 2 — 같은 컨테이너 안에서 ros2 CLI / rviz2로 확인하기 위함 ---
#   Isaac Sim은 자체 내장 ROS 2 라이브러리로 브리지를 돌린다(시스템 ROS 불필요).
#   여기서 까는 건 "받는 쪽"(ros2 topic, rviz2)이다. Ubuntu 버전에 맞춰 배포판 자동 선택.
ARG INSTALL_ROS=1
RUN if [ "$INSTALL_ROS" = "1" ]; then \
        . /etc/os-release; \
        case "$VERSION_CODENAME" in \
            noble) ROS_DISTRO=jazzy ;; \
            jammy) ROS_DISTRO=humble ;; \
            *) echo "지원하지 않는 Ubuntu: $VERSION_CODENAME — ROS 설치 생략"; exit 0 ;; \
        esac; \
        ROS_APT_SOURCE_VERSION=$(curl -fsSL https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest \
            | grep -F '"tag_name"' | awk -F'"' '{print $4}'); \
        curl -fsSL -o /tmp/ros2-apt-source.deb \
            "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-apt-source_${ROS_APT_SOURCE_VERSION}.${VERSION_CODENAME}_all.deb"; \
        dpkg -i /tmp/ros2-apt-source.deb && rm /tmp/ros2-apt-source.deb; \
        apt-get update && apt-get install -y --no-install-recommends \
            ros-${ROS_DISTRO}-ros-base ros-${ROS_DISTRO}-rviz2 \
            ros-${ROS_DISTRO}-rmw-fastrtps-cpp; \
        rm -rf /var/lib/apt/lists/*; \
        echo "$ROS_DISTRO" > /etc/ros_distro; \
    fi

# --- 3) noVNC 첫 화면: 루트 URL로 들어오면 바로 접속 화면으로 ------------------
RUN printf '%s\n' \
      '<!doctype html><meta charset="utf-8">' \
      '<meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=1&resize=scale&reconnect=1">' \
      '<a href="vnc.html?autoconnect=1&resize=scale&reconnect=1">noVNC 열기</a>' \
      > /usr/share/novnc/index.html

# --- 4) 런타임 스크립트 --------------------------------------------------------
COPY scripts/ /opt/isaac-runpod/
COPY config/  /opt/isaac-runpod/config/
RUN chmod +x /opt/isaac-runpod/*.sh \
    && ln -sf /opt/isaac-runpod/isaac-gui.sh /usr/local/bin/isaac-gui \
    && ln -sf /opt/isaac-runpod/diag.sh      /usr/local/bin/isaac-diag \
    && echo '[ -f /opt/isaac-runpod/shell-env.sh ] && . /opt/isaac-runpod/shell-env.sh' >> /root/.bashrc

# 6080: noVNC(HTTP) / 22: SSH
EXPOSE 6080 22

WORKDIR /root
# 공식 이미지의 ENTRYPOINT(헤드리스 스트리밍 실행)를 덮어쓴다.
ENTRYPOINT ["/opt/isaac-runpod/start.sh"]
