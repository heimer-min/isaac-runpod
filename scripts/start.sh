#!/usr/bin/env bash
# =============================================================================
# 컨테이너 시작 스크립트 (ENTRYPOINT, PID 1)
#
# 순서: EULA 확인 → 캐시 영속화(볼륨 있을 때만) → sshd → Xvfb → fluxbox
#       → x11vnc(감시 루프) → websockify/noVNC → 사전 진단 → (선택) Isaac 자동 실행
#       → (선택) 세션 시간 초과 시 pod 자동 종료 → 대기
#
# 주의: 이 스크립트가 PID 1이다. 이게 죽으면 컨테이너(pod)가 멈춘다.
#       Isaac Sim은 별도 프로세스로 띄우므로 Isaac을 kill 해도 pod는 살아 있다.
#
# 환경변수 (RunPod 템플릿에서 설정):
#   ACCEPT_EULA=Y          필수. NVIDIA Isaac Sim 라이선스 동의 (직접 읽고 Y로 설정)
#   VNC_PASSWORD           noVNC 접속 비밀번호. 비우면 매 부팅마다 무작위 생성해 로그에 출력
#   NOVNC_PORT=6080        RunPod에 HTTP 포트로 노출할 포트
#   NOVNC_BIND=0.0.0.0     SSH 터널로만 쓰려면 127.0.0.1
#   RESOLUTION=1920x1080   가상 화면 해상도
#   AUTOSTART_ISAAC=1      부팅 시 Isaac Sim GUI 자동 실행 (0이면 수동: isaac-gui start)
#   MAX_SESSION_HOURS=0    0보다 크면 그 시간 뒤 pod를 스스로 terminate (과금 사고 방지)
#   PERSIST_DIR=/workspace 이 경로가 마운트된 볼륨이면 셰이더/에셋 캐시를 여기에 저장
#   PUBLIC_KEY             (RunPod가 자동 주입) SSH 공개키
# =============================================================================
set -uo pipefail

LOG_DIR=/var/log/isaac-runpod
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/start.log") 2>&1   # RunPod 콘솔 Logs 탭 + 파일 양쪽에 남김

NOVNC_PORT="${NOVNC_PORT:-6080}"
NOVNC_BIND="${NOVNC_BIND:-0.0.0.0}"
VNC_PORT=5901
X_DISPLAY=:1
RESOLUTION="${RESOLUTION:-1920x1080}"
AUTOSTART_ISAAC="${AUTOSTART_ISAAC:-1}"
MAX_SESSION_HOURS="${MAX_SESSION_HOURS:-0}"
PERSIST_DIR="${PERSIST_DIR:-/workspace}"

log() { echo "[start $(date +%H:%M:%S)] $*"; }

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# ---------------------------------------------------------------------------
# 0. EULA — 사용자가 직접 동의해야 한다 (이미지에 Y를 박아두지 않음)
# ---------------------------------------------------------------------------
if [ "${ACCEPT_EULA:-}" != "Y" ]; then
    log "ACCEPT_EULA=Y 가 없습니다. NVIDIA Isaac Sim 라이선스를 읽고 템플릿 환경변수에 ACCEPT_EULA=Y 를 넣으세요."
    log "데스크톱은 띄우되 Isaac Sim 자동 실행은 하지 않습니다."
    AUTOSTART_ISAAC=0
fi

# ---------------------------------------------------------------------------
# 1. 캐시 영속화 — PERSIST_DIR가 '실제 마운트된 볼륨'일 때만
#    (terminate 운영이면 볼륨이 없으므로 이 단계는 건너뛴다)
# ---------------------------------------------------------------------------
if mountpoint -q "$PERSIST_DIR" 2>/dev/null; then
    log "볼륨 감지: $PERSIST_DIR — Isaac 캐시를 볼륨으로 연결"
    for rel in .cache/ov .nv/ComputeCache .local/share/ov/data .nvidia-omniverse/logs; do
        src="$HOME/$rel"; dst="$PERSIST_DIR/isaac-cache/$rel"
        mkdir -p "$dst" "$(dirname "$src")"
        if [ -d "$src" ] && [ ! -L "$src" ]; then cp -a "$src/." "$dst/" 2>/dev/null; rm -rf "$src"; fi
        ln -sfn "$dst" "$src"
    done
else
    log "영속 볼륨 없음 — 캐시는 이번 pod 수명 동안만 유지됩니다 (terminate 운영 기본값)"
fi
mkdir -p /root/work

# ---------------------------------------------------------------------------
# 2. SSH — RunPod가 주입하는 PUBLIC_KEY로 키 인증만 허용
# ---------------------------------------------------------------------------
if [ -n "${PUBLIC_KEY:-}" ]; then
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    echo "$PUBLIC_KEY" > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
    [ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -A >/dev/null
    /usr/sbin/sshd -o PasswordAuthentication=no -o PermitRootLogin=prohibit-password \
        && log "sshd 시작 (키 인증만)"
else
    log "PUBLIC_KEY 없음 — sshd 생략 (RunPod 설정에 SSH 공개키를 등록하면 활성화)"
fi
# SSH 세션은 PID 1의 환경변수를 물려받지 않는다 → RunPod 변수와 EULA 값을 파일로 저장
env | grep -E '^(RUNPOD_|ACCEPT_EULA=|PRIVACY_CONSENT=|ROS_DOMAIN_ID=)' \
    | sed -E "s/^([^=]+)=(.*)$/export \1='\2'/" > /etc/runpod.env
chmod 600 /etc/runpod.env

# ---------------------------------------------------------------------------
# 3. Xvfb — 가상 디스플레이 :1
# ---------------------------------------------------------------------------
rm -f "/tmp/.X${X_DISPLAY#:}-lock" "/tmp/.X11-unix/X${X_DISPLAY#:}"
setsid Xvfb "$X_DISPLAY" -screen 0 "${RESOLUTION}x24" +extension GLX +render -noreset \
    </dev/null >"$LOG_DIR/xvfb.log" 2>&1 &
for _ in $(seq 1 20); do xdpyinfo -display "$X_DISPLAY" >/dev/null 2>&1 && break; sleep 1; done
if ! xdpyinfo -display "$X_DISPLAY" >/dev/null 2>&1; then
    log "Xvfb 시작 실패 — $LOG_DIR/xvfb.log 확인. 디버깅을 위해 컨테이너는 살려 둡니다."
    exec sleep infinity
fi
export DISPLAY="$X_DISPLAY"
log "Xvfb $X_DISPLAY ${RESOLUTION} 시작"

setsid fluxbox </dev/null >"$LOG_DIR/fluxbox.log" 2>&1 &

# ---------------------------------------------------------------------------
# 4. x11vnc — 비밀번호 + localhost 전용 + 감시 루프
#    VNC 비밀번호는 프로토콜 한계로 앞 8자만 쓰인다.
# ---------------------------------------------------------------------------
if [ -z "${VNC_PASSWORD:-}" ]; then
    VNC_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8)
    log "VNC_PASSWORD 미설정 → 이번 pod용 무작위 비밀번호 생성: $VNC_PASSWORD"
    echo "$VNC_PASSWORD" > /root/vnc_password.txt && chmod 600 /root/vnc_password.txt
elif [ "${#VNC_PASSWORD}" -gt 8 ]; then
    log "경고: VNC 비밀번호는 앞 8자만 유효합니다 (현재 ${#VNC_PASSWORD}자)"
fi
mkdir -p /root/.vnc
x11vnc -storepasswd "$VNC_PASSWORD" /root/.vnc/passwd >/dev/null 2>&1
unset VNC_PASSWORD

# x11vnc는 X 오류(XIO) 한 번에 죽는 경우가 있어 무한 재시작 루프로 감싼다.
cat > /opt/isaac-runpod/x11vnc-loop.sh <<EOF
#!/usr/bin/env bash
while true; do
    x11vnc -display $X_DISPLAY -rfbport $VNC_PORT -localhost -rfbauth /root/.vnc/passwd \\
        -forever -shared -noxdamage -quiet >>$LOG_DIR/x11vnc.log 2>&1
    sleep 2
done
EOF
chmod +x /opt/isaac-runpod/x11vnc-loop.sh
setsid /opt/isaac-runpod/x11vnc-loop.sh </dev/null >/dev/null 2>&1 &
for _ in $(seq 1 15); do port_open "$VNC_PORT" && break; sleep 1; done
port_open "$VNC_PORT" && log "x11vnc :$VNC_PORT (localhost 전용)" || log "x11vnc 시작 실패 — $LOG_DIR/x11vnc.log"

# ---------------------------------------------------------------------------
# 5. websockify + noVNC — RunPod HTTP 프록시가 붙는 유일한 포트
# ---------------------------------------------------------------------------
setsid websockify --web /usr/share/novnc "${NOVNC_BIND}:${NOVNC_PORT}" "localhost:${VNC_PORT}" \
    </dev/null >"$LOG_DIR/websockify.log" 2>&1 &
for _ in $(seq 1 15); do port_open "$NOVNC_PORT" && break; sleep 1; done
if port_open "$NOVNC_PORT"; then
    log "noVNC 준비: https://${RUNPOD_POD_ID:-<pod-id>}-${NOVNC_PORT}.proxy.runpod.net/"
else
    log "websockify 시작 실패 — $LOG_DIR/websockify.log"
fi

# ---------------------------------------------------------------------------
# 6. 사전 진단 — 드라이버/Vulkan/메모리. 실패해도 멈추지 않고 경고만.
# ---------------------------------------------------------------------------
/opt/isaac-runpod/diag.sh --quiet | tee "$LOG_DIR/diag.txt"
DIAG_RC=${PIPESTATUS[0]}

# ---------------------------------------------------------------------------
# 7. Isaac Sim GUI 자동 실행
# ---------------------------------------------------------------------------
if [ "$AUTOSTART_ISAAC" = "1" ]; then
    if [ "$DIAG_RC" -ne 0 ]; then
        log "진단 경고가 있습니다(위 로그). 그래도 Isaac 실행을 시도합니다."
    fi
    /opt/isaac-runpod/isaac-gui.sh start
else
    log "Isaac 자동 실행 꺼짐 — 데스크톱 xterm 또는 SSH에서 'isaac-gui start'"
fi

# ---------------------------------------------------------------------------
# 8. 안전장치 — 세션 시간 초과 시 pod 자동 terminate
#    RunPod가 pod마다 주입하는 RUNPOD_API_KEY(해당 pod 한정 권한)를 사용.
# ---------------------------------------------------------------------------
MAX_H="${MAX_SESSION_HOURS%.*}"   # 정수 시간만 지원 (2.5 → 2)
if [ "$MAX_H" -gt 0 ] 2>/dev/null; then
    (
        total=$(( MAX_H * 3600 ))
        sleep $(( total - 600 ))
        DISPLAY=$X_DISPLAY xmessage -center "10분 뒤 pod가 자동 terminate 됩니다. 작업을 git push 하세요." &
        log "자동 종료 10분 전"
        sleep 600
        log "MAX_SESSION_HOURS=${MAX_SESSION_HOURS} 도달 — pod terminate 요청"
        curl -fsS -X DELETE "https://rest.runpod.io/v1/pods/${RUNPOD_POD_ID}" \
            -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
            || log "자동 terminate 실패 — 콘솔에서 직접 terminate 하세요!"
    ) &
    log "자동 terminate 타이머: ${MAX_SESSION_HOURS}시간"
fi

log "부팅 완료. 로그: $LOG_DIR/"
# PID 1 유지. 자식 프로세스 종료 시그널을 받아도 컨테이너가 죽지 않게 대기.
trap 'log "종료 시그널 수신"; exit 0' TERM INT
sleep infinity &
wait $!
