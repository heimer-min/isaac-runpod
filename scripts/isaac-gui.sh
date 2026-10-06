#!/usr/bin/env bash
# =============================================================================
# Isaac Sim GUI 제어:  isaac-gui {start|stop|restart|status|log}  [추가 Kit 인자...]
#
# - Xvfb(:1) 위에 Isaac Sim 데스크톱 앱을 띄운다. 브라우저 noVNC 화면에 나타난다.
# - ROS 2 브리지는 Isaac 내장 라이브러리를 쓰도록, 시스템 ROS를 source 하지 않은
#   깨끗한 환경에서 실행한다 (Isaac 문서의 internal ROS libraries 방식).
# - setsid로 띄우므로 SSH/웹터미널이 끊겨도 Isaac은 계속 돈다.
# =============================================================================
set -uo pipefail

LOG_DIR=/var/log/isaac-runpod
KIT_LOG="$LOG_DIR/isaac-gui.log"
X_DISPLAY=:1
ISAAC_ROOT="${ISAAC_ROOT:-/isaac-sim}"
WINDOW_TIMEOUT="${WINDOW_TIMEOUT:-300}"   # 첫 실행은 셰이더 컴파일로 수 분 걸릴 수 있음

log() { echo "[isaac-gui $(date +%H:%M:%S)] $*"; }
kit_pids() { pgrep -f "[k]it/kit" ; }
gui_window() { DISPLAY=$X_DISPLAY xdotool search --onlyvisible --name "Isaac Sim" 2>/dev/null | head -1; }

ros_internal_env() {
    # 이미지에 깔린 시스템 ROS 배포판과 같은 이름의 내장 라이브러리를 사용
    local distro
    distro=$(cat /etc/ros_distro 2>/dev/null || echo jazzy)
    echo "ROS_DISTRO=$distro RMW_IMPLEMENTATION=rmw_fastrtps_cpp ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-0}"
}

start() {
    if [ -n "$(kit_pids)" ]; then log "이미 실행 중 (pid $(kit_pids | tr '\n' ' '))"; return 0; fi
    if ! xdpyinfo -display "$X_DISPLAY" >/dev/null 2>&1; then
        log "Xvfb($X_DISPLAY)가 없습니다. start.sh가 정상 부팅됐는지 확인하세요."; return 1
    fi
    # 시스템 ROS를 source한 셸에서 띄우면 Isaac이 내장 대신 시스템 ROS 라이브러리를 잡는다.
    # 첫 실습은 내장 라이브러리로 고정하기 위해 막는다.
    if [ -n "${AMENT_PREFIX_PATH:-}" ]; then
        log "이 셸은 ROS가 source 되어 있습니다. ROS를 source하지 않은 새 터미널에서 실행하세요."
        return 1
    fi
    [ -f "$KIT_LOG" ] && mv -f "$KIT_LOG" "$KIT_LOG.prev"
    log "Isaac Sim 시작 → 로그: $KIT_LOG"
    # SSH 셸에서 실행해도 EULA 등 pod 환경변수가 넘어가도록
    [ -f /etc/runpod.env ] && . /etc/runpod.env
    setsid env DISPLAY="$X_DISPLAY" OMNI_KIT_ALLOW_ROOT=1 \
        ACCEPT_EULA="${ACCEPT_EULA:-}" PRIVACY_CONSENT="${PRIVACY_CONSENT:-}" \
        $(ros_internal_env) \
        "$ISAAC_ROOT/isaac-sim.sh" --allow-root "$@" </dev/null >"$KIT_LOG" 2>&1 &

    log "창이 뜰 때까지 대기 (최대 ${WINDOW_TIMEOUT}s)..."
    local t=0 w=""
    while [ $t -lt "$WINDOW_TIMEOUT" ]; do
        w=$(gui_window)
        [ -n "$w" ] && break
        if [ -z "$(kit_pids)" ]; then log "Isaac이 종료됨 — 'isaac-gui log'로 원인 확인"; return 1; fi
        sleep 5; t=$((t+5))
    done
    if [ -z "$w" ]; then
        log "창이 아직 안 보입니다. 'isaac-gui log' 확인 (backbuffers/swapchain 오류면 드라이버 문제)"
        return 1
    fi
    # 가상 화면 전체로 최대화
    local geo; geo=$(DISPLAY=$X_DISPLAY xdpyinfo | awk '/dimensions:/{print $2}')
    DISPLAY=$X_DISPLAY xdotool windowmove "$w" 0 0 windowsize "$w" "${geo%x*}" "${geo#*x}" 2>/dev/null
    log "Isaac Sim 창 표시됨 (window $w, ${t}s)"
}

stop() {
    [ -z "$(kit_pids)" ] && { log "실행 중 아님"; return 0; }
    log "Isaac Sim 종료 중..."
    pkill -f "[k]it/kit"
    for _ in $(seq 1 20); do [ -z "$(kit_pids)" ] && { log "종료됨"; return 0; }; sleep 1; done
    pkill -9 -f "[k]it/kit"; log "강제 종료함"
}

status() {
    if [ -n "$(kit_pids)" ]; then
        log "실행 중 (pid $(kit_pids | tr '\n' ' ')), 창: $(gui_window || true)"
    else
        log "실행 중 아님"
    fi
    nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader
}

cmd="${1:-status}"; shift || true
case "$cmd" in
    start)   start "$@" ;;
    stop)    stop ;;
    restart) stop; start "$@" ;;
    status)  status ;;
    log)     tail -n 80 "$KIT_LOG" ;;
    *) echo "usage: isaac-gui {start|stop|restart|status|log} [kit args...]"; exit 64 ;;
esac
