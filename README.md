# Isaac Sim on RunPod (noVNC GUI)

RunPod Community Cloud의 RTX 4090에서 Isaac Sim을 띄우고, 내 PC 브라우저로 GUI를 보며 실습하는 환경입니다.
조사 기준일은 2026-10-06입니다.

```
브라우저 ──HTTPS──▶ RunPod 프록시 (https://<pod-id>-6080.proxy.runpod.net)
                       │
                  websockify + noVNC (:6080, 0.0.0.0)
                       │ VNC
                  x11vnc (:5901, localhost 전용, 비밀번호)
                       │
                  Xvfb :1 (가상 화면)  ◀── Isaac Sim GUI (Vulkan, RTX 4090)
```

## 확정 구성 (조사 결과 요약)

| 항목 | 결론 |
|---|---|
| Isaac Sim 버전 | **6.1.0** (`nvcr.io/nvidia/isaac-sim:6.1.0`, 2026-09-09 공개, 압축 약 9.9GB) |
| 최소 드라이버 | **595.58.03** (Isaac Sim 6.x 공식). RunPod에서는 **CUDA 13.2 이상** 호스트로 필터링(R595 = CUDA 13.2) |
| 이미지 방식 | **커스텀 이미지 필수.** pod 안에서 `docker run` 불가 + 공식 이미지는 비루트(uid 1234)라 pod에서 apt 설치 불가 |
| NGC 로그인 | **불필요.** 6.x 이미지는 NGC 공개 이미지. API 키 없이 pull 가능 |
| EULA | 컨테이너 환경변수 `ACCEPT_EULA=Y`로 동의. 이 이미지는 Y를 박아두지 않으니 **직접 읽고 템플릿에 넣어야** 함 |
| 렌더링 | **Xvfb로 충분합니다. VirtualGL·headless Xorg는 필요 없습니다.** Vulkan이 GPU에서 렌더하고 결과만 Xvfb 창에 복사합니다. 다만 **드라이버 580 호스트에서는 Vulkan이 Xvfb에 출력하지 못하는 사례**가 보고되어 있어, 부팅 때 `isaac-diag`로 미리 거릅니다 |
| 저장소 | **네트워크 볼륨은 Secure Cloud 전용**입니다(공식 문서). Community + 네트워크 볼륨 조합은 불가하므로 기본은 **볼륨 없이 매번 terminate**하고 작업물은 git으로 보존합니다 |
| 예상 월 비용 | 약 **$20 ≈ 2.8만 원**(55시간, 부팅 오버헤드 포함). 계산은 [docs/04-cost-routine.md](docs/04-cost-routine.md) |

### 계획에서 바뀐 점 두 가지

1. **"네트워크 볼륨 + Community Cloud" 조합은 쓸 수 없습니다.** 네트워크 볼륨은 Secure Cloud 전용이고, Secure Cloud 4090은 $0.74/hr라 월 6만 원을 넘깁니다. 그래서 Community에서 볼륨 없이 쓰고 매번 terminate하는 운영을 기본으로 잡았습니다. 캐시를 날리는 대가로 첫 실행 셰이더 컴파일 몇 분이 매번 붙는데, 돈으로 치면 회당 $0.03 수준입니다.
2. **같은 4090이라도 호스트를 골라야 합니다.** 드라이버 595 미만 호스트에서는 Isaac Sim 6.x 공식 요구사항을 못 맞추고 GUI가 검게 뜰 수 있습니다. 배포할 때 CUDA 버전 필터를 걸고, 부팅 로그의 진단 결과가 FAIL이면 고치려 들지 말고 바로 다른 호스트로 재배포하세요. 그쪽이 쌉니다.

## 파일 구성

| 파일 | 역할 |
|---|---|
| [Dockerfile](Dockerfile) | Isaac Sim 6.1 + Xvfb/x11vnc/noVNC/websockify/fluxbox + SSH + (선택) ROS 2 |
| [scripts/start.sh](scripts/start.sh) | ENTRYPOINT. 데스크톱 스택 기동, 진단, Isaac 자동 실행, 자동 종료 타이머 |
| [scripts/isaac-gui.sh](scripts/isaac-gui.sh) | `isaac-gui start/stop/restart/status/log` |
| [scripts/diag.sh](scripts/diag.sh) | `isaac-diag`: 드라이버·Vulkan 출력·RAM·shm 점검 |
| [scripts/shell-env.sh](scripts/shell-env.sh) | 셸 함수 `ros`(시스템 ROS 2 활성화), `ros_udp` |
| [config/fastdds-udp.xml](config/fastdds-udp.xml) | /dev/shm 문제 시 Fast DDS UDP 전용 프로파일 |

## 진행 순서

1. [docs/01-build-and-push.md](docs/01-build-and-push.md): 내 PC에서 이미지 빌드, private 레지스트리에 push
2. [docs/02-runpod-setup.md](docs/02-runpod-setup.md): 템플릿 생성 → pod 배포 → noVNC 접속 (보안 포함)
3. [docs/03-first-lab.md](docs/03-first-lab.md): 개념 → 로봇 임포트 → LiDAR → ROS 2 브리지 → rviz2
4. [docs/04-cost-routine.md](docs/04-cost-routine.md): 비용 계산과 세션 루틴
5. [docs/05-troubleshooting.md](docs/05-troubleshooting.md): 증상별 디버깅

## 근거 자료

- Isaac Sim 요구사항(6.x, 드라이버 595.58.03): https://docs.isaacsim.omniverse.nvidia.com/latest/installation/requirements.html
- Isaac Sim 컨테이너 설치(ACCEPT_EULA, uid 1234, 캐시 경로): https://docs.isaacsim.omniverse.nvidia.com/6.0.1/installation/install_container.html
- NGC 이미지 태그·크기·공개 여부: https://catalog.ngc.nvidia.com/orgs/nvidia/containers/isaac-sim/tags
- CUDA ↔ 드라이버 브랜치(13.2 = R595): https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html
- RunPod 네트워크 볼륨(Secure 전용): https://docs.runpod.io/storage/network-volumes
- RunPod 요금·스토리지 과금: https://docs.runpod.io/pods/pricing , https://www.runpod.io/pricing
- RunPod 포트 노출(프록시 URL, 0.0.0.0 바인딩): https://docs.runpod.io/pods/configuration/expose-ports
- RunPod pod 환경변수(RUNPOD_API_KEY 등): https://docs.runpod.io/pods/references/environment-variables
- RunPod Secrets: https://docs.runpod.io/pods/templates/secrets
- RunPod noVNC 실증·WebRTC 실패 분석(Isaac 4.0 기준): https://github.com/Sa3d-99/runpod_noVNC_isaac_sim
- Isaac 6.1 + Xvfb + noVNC 실증, 드라이버 580 Vulkan present 실패 기록: https://github.com/romoya-robotics/isaac-cloud
- ROS 2 설치·내장 라이브러리: https://docs.isaacsim.omniverse.nvidia.com/latest/installation/install_ros.html
- RTX LiDAR ROS 2 튜토리얼: https://docs.isaacsim.omniverse.nvidia.com/latest/ros2_tutorials/tutorial_series/tutorial_ros2_rtx_lidar.html
