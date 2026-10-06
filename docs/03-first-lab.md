# 3. 첫 실습: 로봇 임포트 → LiDAR 부착 → ROS 2 브리지 → rviz2

목표: **Isaac Sim의 LiDAR 점군을 ROS 2 토픽(`/point_cloud`)으로 받아 rviz2에서 보는 것**까지 갑니다. 모든 작업은 noVNC 화면 안에서 진행합니다.
예상 소요는 1.5~2시간(약 $0.6)입니다. 개념 파트는 **pod를 켜기 전에** PC에서 읽어 두면 그만큼 비용이 줄어듭니다.

---

## 3-0. 개념 정리 (pod 끄고 읽기)

| 용어 | 뜻 | ROS 경험에 빗대면 |
|---|---|---|
| **Omniverse Kit** | Isaac Sim이 올라탄 앱 프레임워크. 기능은 모두 *extension* 단위로 켜고 끈다 | 패키지/플러그인 시스템 |
| **USD** (Universal Scene Description) | 씬 파일 포맷이자 데이터 모델. `.usd`/`.usda` | URDF + world 파일을 합친 것보다 훨씬 범용 |
| **Stage** | 현재 열린 USD 씬 전체 | Gazebo의 world |
| **Prim** | Stage 트리의 노드 하나(`/World/Robot/chassis`). 경로로 식별 | TF 프레임 + 링크 + 속성을 한 노드에 |
| **Reference** | 다른 USD 파일을 씬에 끼워 넣는 것. 로봇 에셋은 대부분 클라우드 USD를 reference함 | xacro include |
| **PhysX** | 물리 엔진. Play를 누르면 돈다 | Gazebo 물리 |
| **RTX 렌더러** | 레이트레이싱 렌더러. **카메라뿐 아니라 RTX LiDAR도 이 렌더러로 광선을 쏴서** 점군을 만든다 | gpu_ray 센서 |
| **Render Product** | 센서 하나가 렌더링 결과를 내보내는 출력 단위. RTX LiDAR도 카메라처럼 render product가 필요하다 | — |
| **OmniGraph / Action Graph** | 노드를 선으로 이어 만드는 비주얼 로직. ROS 2 발행·구독을 여기서 구성한다 | launch + 노드 연결 |
| **ROS 2 Bridge** | `isaacsim.ros2.bridge` extension. Isaac **내장** ROS 2 라이브러리로 DDS에 직접 발행 | ros_gz_bridge 같은 역할 |

**Isaac Sim 6.0에서 바뀐 점**(구 튜토리얼과 다른 부분):
- LiDAR는 Camera prim이 아니라 **OmniLidar prim**입니다.
- 발행 주기는 노드의 `frameSkipCount`가 아니라 **센서 prim의 `omni:sensor:tickRate` 속성**으로 정합니다.
- PointCloud2의 intensity 같은 메타데이터 필드는 opt-in입니다.

블로그나 4.x 시절 영상과 화면이 다르면 대부분 이 변경 때문입니다.
참고: https://docs.isaacsim.omniverse.nvidia.com/latest/migration_guides/isaac_sim_6_0/ros2_sensor_graph_migration.html

**이 환경에서의 구조**: Isaac Sim과 ros2 CLI/rviz2가 **같은 컨테이너** 안에 있습니다. Isaac은 내장 ROS 2(Ubuntu 24.04면 Jazzy) 라이브러리로 발행하고, 터미널의 `ros2`는 이미지에 설치한 시스템 ROS 2로 받습니다. 둘 다 Fast DDS(`rmw_fastrtps_cpp`)와 `ROS_DOMAIN_ID=0`을 씁니다.

---

## 3-1. 씬 준비

1. **File → New**로 빈 Stage를 엽니다.
2. 바닥 만들기: **Create → Physics → Ground Plane**
3. 장애물 몇 개: **Create → Shape → Cube**를 2~3개 만들고, 오른쪽 **Property** 패널의 Transform에서 위치를 로봇 주변(예: x=3, y=0, z=0.5)으로 옮깁니다. LiDAR 점군에 무언가 찍혀야 확인이 쉽습니다.

> 메뉴 이름은 6.1 기준으로 썼습니다. 다르게 보이면 상단 메뉴를 훑거나 3-5의 공식 튜토리얼 화면과 대조하세요.
> 큰 창고 환경(warehouse)은 에셋 다운로드와 VRAM 소모가 크니 첫 실습에서는 쓰지 않습니다.

## 3-2. 로봇 임포트

1. **Window → Browsers**에서 Isaac Sim 에셋 브라우저(Isaac Sim Assets)를 엽니다.
2. 검색창에 `carter`를 입력하고 **Nova Carter**를 고릅니다. LiDAR 실습의 공식 예제 로봇이자 차동구동 AMR입니다.
3. 뷰포트로 드래그하면 Stage에 reference로 들어갑니다. 첫 로드는 NVIDIA 클라우드에서 에셋을 받느라 수십 초 걸립니다.
4. 왼쪽 **Stage** 패널에서 로봇 트리를 펼쳐 링크 구조(chassis, wheel 등)를 확인합니다. URDF의 link 트리와 비교해 보면 USD 구조를 이해하는 데 도움이 됩니다.

확인: 툴바의 **▶ Play**를 눌러 로봇이 바닥에 안정적으로 서 있는지 보고, **■ Stop**으로 멈춥니다.

## 3-3. LiDAR 부착

1. Stage에서 로봇의 몸체 링크(예: `chassis_link` 또는 `base_link`)를 선택합니다.
2. **Create → Sensors → RTX Lidar → NVIDIA → Example Rotary** (3D 회전형 예제 LiDAR)
3. 새 LiDAR prim이 선택한 링크 **아래**에 생겼는지 확인합니다. 다른 곳에 생겼으면 Stage 패널에서 링크 아래로 드래그합니다. 부모 아래에 있어야 로봇과 함께 움직입니다.
4. Property 패널에서 Translate를 로봇 위쪽(예: z = 0.5)으로 올립니다. 몸체 안에 묻히면 자기 몸체만 찍힙니다.
5. 같은 패널에서 `omni:sensor:tickRate` 속성을 찾아 값(예: 10Hz)을 확인합니다.
6. 이 LiDAR prim의 **경로**를 메모합니다(예: `/World/nova_carter/chassis_link/lidar`). 다음 단계에서 씁니다.

> **캘리브레이션 공부 포인트**: Isaac에서 센서 prim의 Transform은 **정답 extrinsic**입니다. 나중에 카메라를 같은 링크에 붙이고 직접 짠 카메라-LiDAR 캘리브레이션 결과를 이 값과 비교하면, 실차에서는 할 수 없는 "정답지 있는 검증"을 할 수 있습니다.

## 3-4. ROS 2 브리지 (Action Graph)

1. **Window → Graph Editors → Action Graph** → **New Action Graph**
2. 왼쪽 노드 검색창에서 아래 노드를 찾아 드래그합니다.

| 노드 | 역할 |
|---|---|
| On Playback Tick | Play 중 매 프레임 실행 신호 |
| ROS 2 Context | ROS 2 도메인 ID 설정(기본 0) |
| Isaac Run One Simulation Frame | 시작 시 render product 파이프라인을 한 번 돌림 |
| Isaac Create Render Product | LiDAR의 렌더 출력 생성 |
| ROS 2 RTX Lidar Helper | 렌더 출력을 PointCloud2로 발행 |

3. 연결합니다.
   - `On Playback Tick.Tick` → `Isaac Run One Simulation Frame.Exec In`
   - `Isaac Run One Simulation Frame.Step` → `Isaac Create Render Product.Exec In`
   - `Isaac Create Render Product.Exec Out` → `ROS 2 RTX Lidar Helper.Exec In`
   - `Isaac Create Render Product.Render Product Path` → `ROS 2 RTX Lidar Helper.Render Product Path`
   - `ROS 2 Context.Context` → `ROS 2 RTX Lidar Helper.Context`
4. 노드 속성을 설정합니다.
   - **Isaac Create Render Product → cameraPrim**: 3-3에서 메모한 LiDAR prim
   - **ROS 2 RTX Lidar Helper**: `type` = `point_cloud`, `topicName` = `point_cloud`, `frameId` = `sim_lidar`
5. **▶ Play**

> 포트 이름은 버전마다 조금씩 다릅니다. 연결 구조는 공식 튜토리얼과 같으니 막히면 공식 화면과 대조하세요:
> https://docs.isaacsim.omniverse.nvidia.com/latest/ros2_tutorials/tutorial_series/tutorial_ros2_rtx_lidar.html

## 3-5. ROS 2에서 받기

noVNC 바탕화면을 우클릭해 **xterm을 새로 엽니다**. Isaac을 띄운 셸과 분리하는 게 핵심입니다.
```bash
ros
```
이 셸에 시스템 ROS 2를 올리는 함수입니다(`shell-env.sh`에 정의, `setup.bash` source + RMW 지정).
```bash
ros2 topic list
```
DDS로 보이는 토픽 목록입니다. `/point_cloud`가 있어야 합니다.
```bash
ros2 topic hz /point_cloud
```
초당 수신 횟수를 봅니다. tickRate(예: 10Hz) 근처면 정상입니다. Ctrl+C로 멈춥니다.
```bash
ros2 topic echo /point_cloud --once --no-arr
```
메시지 1개의 헤더·필드 구조만 출력합니다(`--no-arr`는 거대한 data 배열을 생략). `frame_id: sim_lidar`와 `fields`(x, y, z ...)를 확인하세요.
```bash
rviz2
```
rviz2가 noVNC 화면에 뜹니다. 설정 순서:
1. 왼쪽 Global Options → **Fixed Frame**에 `sim_lidar`를 직접 입력합니다. TF를 발행하지 않으므로 센서 프레임을 기준으로 봅니다.
2. **Add → By topic → /point_cloud → PointCloud2**
3. Size(m)를 0.03 정도로 키웁니다. 큐브 장애물 형태가 점으로 보이면 성공입니다.

rviz2가 GL 오류로 안 뜨면 소프트웨어 렌더링을 강제합니다:
```bash
LIBGL_ALWAYS_SOFTWARE=1 rviz2
```

**토픽은 보이는데 hz가 0이면** /dev/shm 문제일 가능성이 큽니다. 05 문서 #6을 참고하세요.

## 3-6. 같은 걸 Python으로 (Standalone 워크플로)

GUI로 만든 그래프를 코드로 재현하는 공식 예제가 이미지 안에 있습니다. 먼저 **읽고**, 그다음 실행합니다.

```bash
less /isaac-sim/standalone_examples/api/isaacsim.ros2.bridge/rtx_lidar.py
```
읽을 포인트:
- `Lidar.create(path=..., config="Example_Rotary", tick_rate=10.0, ...)`: 3-3에서 GUI로 한 일
- `sensor.attach_writer("RtxLidarROS2PublishPointCloud", topicName=..., frameId=...)`: 3-4의 Action Graph를 writer 한 줄로 대체

실행은 GPU를 비우려고 GUI Isaac을 먼저 끄고, **ROS를 source하지 않은 새 xterm**에서 합니다.
```bash
isaac-gui stop
```
```bash
/isaac-sim/python.sh /isaac-sim/standalone_examples/api/isaacsim.ros2.bridge/rtx_lidar.py
```
`python.sh`는 Isaac에 번들된 Python입니다. 시스템 `python3`으로는 Isaac 모듈을 import할 수 없습니다. 스크립트가 띄우는 창도 noVNC 화면(:1)에 나타납니다.
ROS 셸에서 `ros2 topic list`로 `/point_cloud`와 `/scan`이 보이면 성공입니다.

**수정해 보기**(학습용): 예제를 `/root/work/my_lidar.py`로 복사한 뒤 `tick_rate`, `translations`, `topicName`을 바꿔 실행하고 `ros2 topic hz`로 변화를 확인하세요. 실습이 끝나면 GUI를 되살립니다.
```bash
isaac-gui start
```

## 3-7. 작업 저장 (terminate 전 필수)

- 씬 저장: **File → Save As → `/root/work/lab01.usd`**. 로봇 에셋은 클라우드 reference라 파일이 작습니다.
- 다음은 `/root/work`를 git 저장소로 만들어 GitHub(private)에 push하는 루틴입니다. 방법은 04 문서에 있습니다.

## 다음 실습 후보 (자율주행 인지 쪽)

1. **내 1/5 스케일 플랫폼 URDF 임포트**(File → Import, URDF importer): 실제 플랫폼 형상과 센서 배치를 그대로 옮깁니다.
2. **카메라 추가**(Create → Sensors → Camera)와 ROS 2 Camera Helper로 `image_raw`/`camera_info` 발행: 카메라-LiDAR 투영 실습
3. **TF 발행**(ROS 2 Publish Transform Tree 노드)과 **Clock 발행**: rviz2를 `map`/`base_link` 기준으로 보기, `use_sim_time`
4. LiDAR 설정을 실제 센서 프로파일(Ouster/Velodyne 계열 config)로 바꿔 보며 점군 패턴 비교
