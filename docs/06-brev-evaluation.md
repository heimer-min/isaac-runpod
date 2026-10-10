# 06. NVIDIA Brev 재평가 (2026-10-10)

RunPod에서 막힌 원격 화면 지연과 비용 문제를 Brev로 풀 수 있는지 확인한 기록이다. 결론부터: **서울 리전에서는 지연이 확실히 개선됐고, Isaac Sim 6.0.1 ↔ ROS 2 Jazzy 연동까지 확인했다.** 다만 16GiB RAM 인스턴스는 GUI에 빠듯하다.

## 1. 결론

| 질문 | 답 |
|---|---|
| 지연이 RunPod(유럽)보다 나은가 | 예. 서울 AWS에서 noVNC 조작이 쾌적했다 (주관 평가, 수치 측정은 안 함). 원인이 "거리"였다는 T6 가설이 맞았다 |
| Isaac Sim이 GPU 렌더링으로 도는가 | 예. L4, RTX Real-Time 2.0, 빈 장면~간단한 물리 장면에서 32~45 FPS |
| ROS 2 연동이 되는가 | 예. OmniGraph로 `/clock`을 발행하고 컨테이너 안 `ros2 topic echo /clock`으로 수신 ([scripts/ros_clock_test.py](../scripts/ros_clock_test.py)) |
| 16GiB RAM이면 충분한가 | 아니오. GUI 기동 후 여유가 약 1.2~1.7GiB. 로봇·센서를 올리면 종료될 위험이 크다. 32GiB(`g6.2xlarge`) 권장 |

## 2. 사용한 구성

- Launchable: "Isaac Lab 3.0.0-beta2.patch1, Sim 6.0.1, ROS 2 Jazzy" (제3자 제작, 비공식, VM Mode)
- 인스턴스: AWS `g6.xlarge` (L4 24GB, 4 vCPU, 16GiB), 서울 `ap-northeast-2`, 디스크 256GiB
- 요금: 화면 표시 $1.23~1.24/hr (GPU $0.97 + 디스크). 약 1시간 반 사용, **실제 청구 $1.12** (Brev Billing 확인)
- 드라이버 595.91.07 (Brev 기본 이미지, 재부팅 없음)

## 3. 선택 과정에서 알게 된 것

### 지역별 왕복 지연 (Mac → AWS EC2 엔드포인트, TCP connect)

| 리전 | 시간 |
|---|---|
| 도쿄 | 0.049s |
| 싱가포르 | 0.086s |
| 유럽(아일랜드) | 0.410s |
| 미국 서부 | 0.553s |
| 서울 | 1.049s (일시적 이상값으로 판단, 실제 접속은 쾌적) |

인스턴스를 만들기 전에 `curl -w "%{time_connect}"`로 잴 수 있어 비용이 들지 않는다.

### GPU·provider 선택

- `brev search gpu`(CLI)는 가격·GPU·vCPU를 텍스트로 뽑기 좋지만 **리전 정보가 없다**. 리전은 웹 UI의 지역 필터에서만 보인다.
- 아시아(한국·일본) 필터를 걸면 shadeform 계열 저가 L40S($1.06)는 사라지고 **AWS·GCP만 남는다**. L40S는 AWS $2.23/hr부터.
- **GCP는 제외**: 런처 제작자의 측정에 따르면 Brev의 GCP 인스턴스는 compute 전용 드라이버라 그래픽 라이브러리가 없어서 Isaac Sim이 CPU 렌더링(llvmpipe)으로 돈다.
- Isaac Sim은 RT 코어가 필요하다. A100/H100/H200/V100은 GUI 렌더링에 부적합.
- 가용성은 날마다 달라진다(어제 있던 옵션이 오늘 없을 수 있음).
- 런처의 compute를 바꾸면 "제작자 구성과 다름" 경고가 뜬다. 제작자가 검증한 `g6.xlarge`로 맞추면 무시해도 된다.

## 4. 시간과 비용의 함정

| 단계 | 소요 |
|---|---|
| VM 빌드 → 스크립트 시작 | 약 4분 |
| Docker 이미지 pull (약 34GB) | **약 28분** (서울에서 Docker Hub로) |
| 첫 Isaac Sim 기동 (셰이더 컴파일, 4 vCPU 전부 사용) | 약 10분 (604초) |

- 첫 접속까지 **약 45분** 걸렸고 그동안에도 과금된다. 런처 문서의 "약 7분"은 다른 버전(5.1.0) 기준이다.
- 인스턴스를 지우면 pull과 셰이더 캐시가 모두 사라진다. 다음엔 시간 여유가 있을 때 시작하거나, Stop/Start로 이어 쓰는 방법을 확인할 것 (Stop 중에도 디스크 요금은 나간다).
- 2.3.2(Sim 5.1.0) 런처는 드라이버를 580으로 내리고 재부팅한다. 6.0.1 런처는 595를 그대로 쓴다.

## 5. 기동 후 확인한 로그

- 무시해도 되는 것: `isaacsim.robot_motion.pink` 확장 로드 실패(pink 라이브러리 버전 불일치, Pink IK만 꺼짐), audio device 경고, `fabric` 버전 경고, `mdl_list_cache` 경고
- 정상 로드: `isaacsim.ros2.core`, `rclpy loaded`, `isaacsim.ros2.bridge`
- 주의할 것: 화면 우측 상단 `Process Memory`가 빨간색(약 11.5GiB 사용, 여유 약 1.2GiB)

## 6. ROS 2 연동 확인 절차

1. noVNC 터미널에서 `/root/isaacsim/isaac-sim.sh` 실행
2. Isaac Sim의 Window > Script Editor에서 [scripts/ros_clock_test.py](../scripts/ros_clock_test.py) 열기 → Run
3. 도구바 ▶ Play (재생 중에만 발행)
4. 다른 터미널에서 확인
   ```bash
   source /opt/ros/jazzy/setup.bash
   ros2 topic list
   ros2 topic echo /clock --once
   ```

noVNC에서는 클립보드가 막혀 있어 붙여넣기가 안 됐다. 스크립트는 `brev copy`와 `docker cp`로 컨테이너에 넣었다.

```bash
brev copy ros_clock_test.py <인스턴스명>:/tmp/
brev exec <인스턴스명> 'sudo docker cp /tmp/ros_clock_test.py $(sudo docker ps -q | head -1):/root/'
```

## 7. 다음에 할 것

1. `g6.2xlarge`(8 vCPU, 32GiB)로 재배포하고 로봇·센서·Nav2 실습 ([03 첫 실습](03-first-lab.md))
2. Stop/Start로 pull과 셰이더 캐시를 보존하는 운영 방식 확인
3. 직접 만든 이미지(이 리포 Dockerfile)를 Brev VM에서 쓸지 결정 (런처는 Jupyter·VS Code 등이 포함돼 무겁고 베타 버전)
4. 화면 방식(noVNC 유지 vs WebRTC)은 로봇 장면에서 체감해 본 뒤 결정
