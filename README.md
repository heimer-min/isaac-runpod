# Isaac Sim GUI on Cloud GPU (RunPod + noVNC)

로컬 GPU 없이 클라우드 RTX 4090에서 **NVIDIA Isaac Sim 6.1**을 돌리고, 그 GUI를 **브라우저로** 조작하는 환경을 직접 구축한 프로젝트입니다.
Isaac Sim의 공식 원격 화면(WebRTC)은 UDP가 필요한데 RunPod은 TCP/HTTP만 지원합니다. 그래서 컨테이너 안에 가상 디스플레이와 VNC 스택을 얹은 커스텀 이미지로 이 제약을 우회했습니다.

![브라우저 안에서 동작하는 Isaac Sim 6.1](docs/images/isaac-gui-in-browser.png)

> **프로젝트 리포트**: 결정 근거, 트러블슈팅, 측정값, 비용, 한계까지 전체 과정 → [docs/00-project-report.md](docs/00-project-report.md)

## 현재 상태 (2026-10-09)

| | |
|---|---|
| ✅ 동작 확인 | 브라우저에서 Isaac Sim 6.1 GUI (RTX Real-Time, 서버 측 73~79 FPS), 물리 시뮬레이션, SSH 키 인증, 부팅 시 호스트 자동 진단 |
| ✅ 부팅 속도 | 컨테이너 시작 → Isaac 창 표시 **25초** |
| ⚠️ 한계 | 한국에서 유럽 서버에 접속하면 **조작 지연이 커서** GUI 위주 학습에는 부적합. 화질 조정·프록시 우회로도 개선되지 않음 (원인: 거리 + VNC의 CPU 압축 방식) |
| ⚠️ 비용 | 2026-10-09 기준 RunPod 4090 요금이 $0.89/hr (조사 당시 Community $0.34). Community에는 드라이버 조건(CUDA 13.2+)을 만족하는 호스트를 확보하지 못함 |
| ➡️ 다음 | GPU 인코딩 스트리밍(WebRTC)과 가까운 지역을 쓸 수 있는 플랫폼(NVIDIA Brev 공식 Isaac Launchable 등)으로 재평가 |

## 아키텍처

```
브라우저 ──HTTPS──▶ RunPod 프록시 (https://<pod-id>-6080.proxy.runpod.net)  또는 SSH 터널
                       │
                  websockify + noVNC (:6080, 외부에 열린 유일한 웹 포트)
                       │ VNC
                  x11vnc (:5901, localhost 전용, pod별 무작위 비밀번호)
                       │
                  Xvfb :1 (가상 화면)  ◀── Isaac Sim GUI (Vulkan, RTX 4090)
```

## 하이라이트

- **Xvfb segfault 원인 분석**: backtrace로 GLVND가 NVIDIA EGL을 골라 Xvfb의 GLX 초기화가 충돌하는 것을 찾아냄 → Xvfb에만 Mesa EGL을 지정해 해결. 재빌드 전에 실환경에서 먼저 검증함
- **드라이버 조건 자동화**: Isaac 6.x 최소 드라이버(595.58.03)를 CUDA 버전 필터(13.2~13.4)로 템플릿에 강제하고, 부팅 시 "Vulkan이 가상 화면에 출력 가능한지"까지 진단
- **비용·보안 안전장치**: 실패 경로에서도 동작하는 자동 terminate 타이머, 용도별 최소 권한 토큰, 노출 포트 1개, 키 인증 SSH, private 이미지
- **지연 원인 분리**: 화질 / 프록시 / 서버 위치를 하나씩 바꿔 병목을 "거리 + VNC 방식"으로 특정

자세한 내용은 [프로젝트 리포트](docs/00-project-report.md)의 §6 트러블슈팅을 참고하세요.

## 확정 사항 (조사 + 검증)

| 항목 | 내용 |
|---|---|
| Isaac Sim | **6.1.0** (`nvcr.io/nvidia/isaac-sim:6.1.0`, NGC 공개 이미지, 로그인 불필요) |
| 드라이버 | 최소 **595.58.03**. 검증 호스트는 595.91.07 |
| 이미지 | **커스텀 이미지 필수**: pod 안에서 `docker run` 불가, 공식 이미지는 비루트(uid 1234)라 pod에서 apt 설치 불가 |
| EULA | `ACCEPT_EULA=Y`를 사용자가 직접 템플릿에 넣음 (이미지에 박아 두지 않음) |
| 렌더링 | Xvfb로 충분. 단 Xvfb에는 Mesa EGL을 지정해야 함 (NVIDIA EGL을 고르면 segfault) |
| 저장소 | 네트워크 볼륨은 Secure Cloud 전용 → 볼륨 없이 매번 terminate, 작업물은 scp로 회수 |
| SSH | RunPod은 커스텀 이미지에 공개키를 환경변수로 넘겨주지 않음 → 템플릿에 `PUBLIC_KEY` 직접 지정 |
| 배포 시 주의 | RunPod 배포 화면의 Cloud type 기본값이 **Secure**임. 배포 직전 시간당 가격을 확인할 것 |

## 파일 구성

| 파일 | 역할 |
|---|---|
| [Dockerfile](Dockerfile) | Isaac Sim 6.1 + Xvfb/x11vnc/noVNC/websockify/fluxbox + SSH + ROS 2 (Ubuntu 버전에 맞춰 자동 선택) |
| [scripts/start.sh](scripts/start.sh) | ENTRYPOINT. 자동 종료 타이머 → SSH → 데스크톱 스택 → 진단 → Isaac 자동 실행 |
| [scripts/isaac-gui.sh](scripts/isaac-gui.sh) | `isaac-gui start/stop/restart/status/log` |
| [scripts/diag.sh](scripts/diag.sh) | `isaac-diag`: 드라이버·Vulkan 출력·RAM·shm 점검 |
| [scripts/shell-env.sh](scripts/shell-env.sh) | 셸 함수 `ros`(시스템 ROS 2 활성화), `ros_udp` |
| [config/fastdds-udp.xml](config/fastdds-udp.xml) | /dev/shm 문제 시 Fast DDS UDP 전용 프로파일 |

## 문서

| 문서 | 내용 |
|---|---|
| [00 프로젝트 리포트](docs/00-project-report.md) | 전체 과정 정리 (포트폴리오) |
| [01 빌드와 push](docs/01-build-and-push.md) | Mac에서 amd64 이미지 빌드, private 레지스트리 |
| [02 RunPod 설정](docs/02-runpod-setup.md) | 템플릿 → 배포 → noVNC 접속, 보안 |
| [03 첫 실습](docs/03-first-lab.md) | 개념 → 로봇 임포트 → LiDAR → ROS 2 브리지 → rviz2 |
| [04 비용 루틴](docs/04-cost-routine.md) | 비용 계산과 세션 루틴 |
| [05 트러블슈팅](docs/05-troubleshooting.md) | 증상별 디버깅 |

> 02·04는 검증 전에 작성한 가이드라서 일부 전제(Community $0.34, `PUBLIC_KEY` 자동 주입)가 실제와 다릅니다. 검증으로 바뀐 내용은 위 "확정 사항"과 리포트가 기준입니다.

## 근거 자료

- Isaac Sim 요구사항(6.x, 드라이버 595.58.03): https://docs.isaacsim.omniverse.nvidia.com/latest/installation/requirements.html
- Isaac Sim 컨테이너 설치(ACCEPT_EULA, uid 1234, 캐시 경로): https://docs.isaacsim.omniverse.nvidia.com/6.0.1/installation/install_container.html
- NGC 이미지 태그·크기·공개 여부: https://catalog.ngc.nvidia.com/orgs/nvidia/containers/isaac-sim/tags
- CUDA ↔ 드라이버 브랜치(13.2 = R595): https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html
- RunPod 네트워크 볼륨(Secure 전용): https://docs.runpod.io/storage/network-volumes
- RunPod 요금·스토리지 과금: https://docs.runpod.io/pods/pricing , https://www.runpod.io/pricing
- RunPod 포트 노출(프록시 URL, 0.0.0.0 바인딩): https://docs.runpod.io/pods/configuration/expose-ports
- RunPod SSH(기본 SSH vs 공인 IP TCP): https://docs.runpod.io/pods/configuration/use-ssh
- RunPod pod 환경변수(RUNPOD_API_KEY 등): https://docs.runpod.io/pods/references/environment-variables
- RunPod Secrets: https://docs.runpod.io/pods/templates/secrets
- RunPod noVNC 실증·WebRTC 실패 분석(Isaac 4.0 기준): https://github.com/Sa3d-99/runpod_noVNC_isaac_sim
- Isaac 6.1 + Xvfb + noVNC 실증, 드라이버 580 Vulkan present 실패 기록: https://github.com/romoya-robotics/isaac-cloud
- Isaac Sim Brev 배포 / Isaac Launchable: https://docs.isaacsim.omniverse.nvidia.com/6.1.0/installation/install_advanced_cloud_setup_brev.html , https://github.com/isaac-sim/isaac-launchable
- ROS 2 설치·내장 라이브러리: https://docs.isaacsim.omniverse.nvidia.com/latest/installation/install_ros.html
- RTX LiDAR ROS 2 튜토리얼: https://docs.isaacsim.omniverse.nvidia.com/latest/ros2_tutorials/tutorial_series/tutorial_ros2_rtx_lidar.html
