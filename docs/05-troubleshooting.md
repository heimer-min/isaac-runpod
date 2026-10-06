# 5. 증상별 디버깅

원칙: **호스트 문제(드라이버, 라이브러리 주입, RAM)는 고치지 말고 재배포합니다.** 고칠 대상은 이미지와 스크립트 문제뿐입니다.

로그 위치(pod 안): `/var/log/isaac-runpod/` — `start.log`, `diag.txt`, `xvfb.log`, `x11vnc.log`, `websockify.log`, `isaac-gui.log`

| # | 증상 | 확인할 것 | 대처 |
|---|---|---|---|
| 1 | pod가 `Waiting for logs`/이미지 pull에서 멈춤 | 콘솔 이벤트에 `unauthorized`/`pull access denied`가 있는지 | 템플릿의 Container Registry Credentials, 이미지 태그 오타, Docker Hub 토큰 권한 확인 |
| 2 | 프록시 URL이 502/연결 불가 | `grep noVNC /var/log/isaac-runpod/start.log` | 부팅이 덜 끝났으면 1~2분 대기. websockify 실패면 `websockify.log` 확인. 템플릿 HTTP 포트가 6080인지 확인 |
| 3 | noVNC 비밀번호 거부 | 로그의 무작위 비밀번호, Secret 값 길이 | 8자를 넘는 부분은 무시됩니다. 앞 8자로 다시 시도 |
| 4 | noVNC는 되는데 **Isaac 창이 검거나 안 뜸** | `isaac-diag`, `isaac-gui log`에서 `vkCreateSwapchainKHR`/`backbuffers are not initialized` 검색 | **swapchain 오류면 호스트(드라이버) 문제이므로 재배포합니다.** `backbuffers`는 X보다 Kit이 먼저 뜬 경우라 `isaac-gui restart` |
| 5 | Isaac이 몇 분 뒤 갑자기 종료 | `dmesg` 접근 불가 시 `isaac-gui log` 끝부분, `free -g` | RAM 부족(OOM) 가능성. 씬을 줄이거나 RAM 큰 호스트로 재배포 |
| 6 | `ros2 topic list`엔 보이는데 `hz`가 0 | `df -h /dev/shm` (`isaac-diag`에도 표시) | 공유메모리가 작아서 생기는 문제입니다. Isaac 쪽과 ROS 쪽 **양쪽에 UDP 프로파일**을 적용합니다. 아래 6번 절차 참고 |
| 7 | `/point_cloud`가 아예 안 보임 | Play를 눌렀는지, Action Graph 연결, `ROS_DOMAIN_ID` | 그래프 노드 연결과 cameraPrim 경로를 다시 확인합니다. `isaac-gui log`에서 `ros2` 검색 |
| 8 | `isaac-gui start`가 "ROS가 source 되어 있습니다"라며 거부 | — | 의도된 동작입니다. `ros`를 실행하지 않은 새 xterm/SSH 셸에서 실행 |
| 9 | 화면이 끊기고 느림 | 브라우저 ↔ 프록시 지연 | noVNC Settings에서 Quality↓·Compression↑. `RESOLUTION=1600x900`. SSH 터널 방식(02 문서)이 더 빠를 수 있음 |
| 10 | SSH 접속 거부 | Connect 메뉴에 TCP 22 매핑이 있는지 | RunPod Settings에 공개키 등록 후 **새로** 배포해야 반영됩니다. 공인 IP 없는 호스트는 직접 TCP가 없음 |
| 11 | 자동 terminate가 안 됨 | `grep 자동 /var/log/isaac-runpod/start.log` | pod 전용 `RUNPOD_API_KEY`에 삭제 권한이 없을 수 있습니다. 그러면 타이머는 경고 용도로만 쓰고 terminate는 수동으로 합니다 |

## 6번 절차: Fast DDS를 UDP 전용으로

Isaac 쪽 (ROS를 source하지 않은 셸):
```bash
export FASTRTPS_DEFAULT_PROFILES_FILE=/opt/isaac-runpod/config/fastdds-udp.xml
```
이 셸에서 실행하는 프로세스가 공유메모리 대신 UDP 루프백으로 통신하게 합니다.
```bash
isaac-gui restart
```
환경변수는 실행 시점에 읽히므로 Isaac을 다시 띄워야 적용됩니다.

ROS 쪽 셸:
```bash
ros && ros_udp
```
ROS를 올리고 같은 프로파일을 적용합니다. 그다음 `ros2 daemon stop`으로 옛 설정을 쥔 데몬을 내린 뒤 `ros2 topic hz /point_cloud`를 다시 봅니다.

## 대안: 6.1이 맞는 호스트가 계속 안 잡힐 때

CUDA 13.2+ 4090 호스트가 며칠씩 없다면 선택지는 두 가지입니다.
1. Isaac Sim **5.1.0**으로 빌드합니다(`--build-arg ISAAC_SIM_VERSION=5.1.0`). 5.x의 드라이버 요구사항을 해당 버전 문서에서 확인하고 `MIN_DRIVER` 환경변수를 그에 맞춥니다. 단 **드라이버 580 호스트에서는 Isaac 버전과 무관하게 Xvfb Vulkan 출력이 실패한 실측 기록**이 있으니, 진단의 Vulkan 항목이 OK인지는 똑같이 확인해야 합니다.
2. 같은 이미지로 다른 GPU(3090/A5000/L40S)에서 CUDA 13.2+ 호스트를 찾습니다(04 문서의 GPU 실험 참고).

## 막히면 이렇게 공유해 주세요

아래 세 가지를 붙여 주시면 원인을 좁히기가 빠릅니다.
```bash
cat /var/log/isaac-runpod/diag.txt
```
```bash
tail -n 60 /var/log/isaac-runpod/start.log
```
```bash
isaac-gui log
```
