#!/usr/bin/env bash
# =============================================================================
# 호스트 적합성 진단:  isaac-diag
#
# Isaac Sim GUI를 noVNC로 보려면 이 pod가 배정된 "호스트"가 조건을 만족해야 한다.
# 같은 RTX 4090이라도 호스트마다 드라이버·RAM·주입 라이브러리가 다르다.
# 조건 미달이면 디버깅에 시간(=돈) 쓰지 말고 terminate 후 다른 호스트로 재배포하는 게 싸다.
#
# 종료 코드: 0 = 통과, 1 = 치명적 문제(재배포 권장), 2 = 경고만
# =============================================================================
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1
MIN_DRIVER="${MIN_DRIVER:-595.58.03}"   # Isaac Sim 6.x 공식 최소 드라이버
MIN_RAM_GB="${MIN_RAM_GB:-32}"
X_DISPLAY="${X_DISPLAY:-:1}"
rc=0
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [WARN] $*"; [ $rc -eq 0 ] && rc=2; }
fail() { echo "  [FAIL] $*"; rc=1; }

echo "== Isaac Sim 호스트 진단 =="

# 1) GPU / 드라이버 ------------------------------------------------------------
if ! command -v nvidia-smi >/dev/null; then
    fail "nvidia-smi 없음 — GPU가 컨테이너에 연결되지 않음"
else
    read -r GPU DRV <<<"$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -1 | awk -F', ' '{gsub(/ /,"_",$1); print $1, $2}')"
    echo "  GPU=$GPU  driver=$DRV"
    if [ "$(printf '%s\n%s\n' "$MIN_DRIVER" "$DRV" | sort -V | head -1)" = "$MIN_DRIVER" ]; then
        ok "드라이버 $DRV ≥ $MIN_DRIVER"
    else
        fail "드라이버 $DRV < $MIN_DRIVER — Isaac Sim 6.x 최소 미달. 특히 580대는 Xvfb에 Vulkan 출력 실패 사례가 보고됨. 재배포 권장"
    fi
fi

# 2) Vulkan/GLX 유저랜드 라이브러리 주입 여부 -----------------------------------
#    NVIDIA_DRIVER_CAPABILITIES에 graphics가 반영되지 않은 호스트는 compute 라이브러리만 들어온다.
if ldconfig -p | grep -q libGLX_nvidia.so.0; then
    ok "libGLX_nvidia 존재 (graphics 라이브러리 주입됨)"
else
    fail "libGLX_nvidia 없음 — 이 호스트는 compute 전용 라이브러리만 주입. Vulkan 불가, 재배포 권장"
fi
if [ -f /usr/share/vulkan/icd.d/nvidia_icd.json ] || [ -f /etc/vulkan/icd.d/nvidia_icd.json ]; then
    ok "NVIDIA Vulkan ICD json 존재"
else
    warn "nvidia_icd.json을 표준 경로에서 못 찾음 (아래 vulkaninfo 결과로 최종 판단)"
fi

# 3) Vulkan이 Xvfb 화면에 '출력(present)'할 수 있는가 — GUI 성패의 핵심 ---------
if command -v vulkaninfo >/dev/null && xdpyinfo -display "$X_DISPLAY" >/dev/null 2>&1; then
    out=$(DISPLAY=$X_DISPLAY timeout 60 vulkaninfo 2>&1)
    if ! grep -q "NVIDIA" <<<"$out"; then
        fail "vulkaninfo가 NVIDIA GPU를 못 찾음"
    elif grep -qiE "vkGetPhysicalDeviceSurface.*(failed|error)|ERROR_INITIALIZATION_FAILED|ERROR_SURFACE_LOST" <<<"$out"; then
        fail "Vulkan이 X 디스플레이에 출력 불가 (surface 오류) — GUI가 검게 나옴. 재배포 권장"
    elif grep -q "Presentable Surfaces" <<<"$out"; then
        ok "Vulkan → $X_DISPLAY 출력 가능 (Presentable Surfaces 확인)"
    else
        warn "Presentable Surfaces 항목을 못 찾음 — 'DISPLAY=:1 vulkaninfo | less'로 직접 확인"
    fi
else
    warn "vulkaninfo 또는 X 디스플레이 없음 — 출력 점검 생략"
fi

# 4) 메모리 / 공유메모리 / 디스크 ---------------------------------------------
RAM_GB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
# 컨테이너 cgroup 메모리 제한이 /proc/meminfo보다 작을 수 있다
CG_LIMIT=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
if [[ "$CG_LIMIT" =~ ^[0-9]+$ ]] && [ "$CG_LIMIT" -lt $((RAM_GB*1024*1024*1024)) ]; then
    RAM_GB=$((CG_LIMIT/1024/1024/1024))
fi
if [ "$RAM_GB" -ge "$MIN_RAM_GB" ]; then ok "RAM ${RAM_GB}GB"; else warn "RAM ${RAM_GB}GB < 권장 ${MIN_RAM_GB}GB — 큰 씬에서 크래시 가능"; fi

SHM_MB=$(df -m /dev/shm 2>/dev/null | awk 'NR==2{print $2}')
if [ "${SHM_MB:-0}" -ge 1024 ]; then ok "/dev/shm ${SHM_MB}MB"; else warn "/dev/shm ${SHM_MB:-?}MB — 작으면 ROS2 Fast DDS 공유메모리 전송 실패 가능 (config/fastdds-udp.xml 사용)"; fi

FREE_GB=$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')
if [ "${FREE_GB:-0}" -ge 15 ]; then ok "컨테이너 디스크 여유 ${FREE_GB}GB"; else warn "디스크 여유 ${FREE_GB}GB — 캐시/에셋으로 부족해질 수 있음"; fi

echo "  CPU=$(nproc)코어  CUDA(호스트)=${CUDA_VERSION:-?}  pod=${RUNPOD_POD_ID:-?}"
case $rc in
    0) echo "== 결과: 통과 ==";;
    1) echo "== 결과: 치명적 문제 — 이 호스트는 terminate 후 재배포 권장 ==";;
    2) echo "== 결과: 경고 있음 — 진행 가능 ==";;
esac
exit $rc
