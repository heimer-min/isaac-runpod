# 1. 이미지 빌드 & push (내 PC에서, 최초 1회)

RunPod은 pod 안에서 `docker build`/`docker run`을 할 수 없습니다(pod 자체가 컨테이너이기 때문).
그래서 **내 PC에서 이미지를 만들어 레지스트리에 올리고**, RunPod이 그 이미지를 받아 pod를 띄우게 합니다.

## 준비물

- Docker Desktop (디스크 여유 **40GB 이상** — 베이스 이미지만 압축 해제 시 20GB대)
- Docker Hub 계정 (무료 플랜은 private 저장소 1개 제공)

### 왜 private 저장소인가

이 이미지에는 NVIDIA Isaac Sim 바이너리가 통째로 들어 있습니다. 이를 공개 저장소로 재배포해도 되는지는
NVIDIA 라이선스 조항에 달려 있고, 저는 그 허용 여부를 확인하지 못했습니다. **확실하지 않으니 private으로 두는 게 안전합니다.**
RunPod에는 레지스트리 인증 정보를 등록해 pull 하게 합니다(02 문서).

## 단계

### 1) Docker Hub에 private 저장소 만들기
웹에서 Repositories → Create → 이름 `isaac-sim-novnc`, Visibility **Private**.

### 2) 로그인
```bash
docker login
```
Docker Hub 계정으로 로컬 Docker를 인증합니다. 비밀번호 대신 Docker Hub의 **Personal Access Token**(Account settings → Personal access tokens, 권한 Read & Write)을 쓰는 걸 권장합니다.

### 3) 빌드 + push
프로젝트 폴더(`isaac-runpod`)에서:
```bash
docker buildx build --platform linux/amd64 -t <dockerhub-id>/isaac-sim-novnc:6.1.0-v1 --push .
```
- `buildx build`: 멀티 플랫폼 빌더입니다.
- `--platform linux/amd64`: RunPod GPU 서버는 x86_64입니다. **Apple Silicon Mac이면 이 옵션이 필수**이며, `RUN` 단계(apt 설치)가 QEMU 에뮬레이션으로 돌아 10~30분 걸릴 수 있습니다. Intel Mac/리눅스면 네이티브라 빠릅니다.
- `-t ...:6.1.0-v1`: 태그에 Isaac 버전과 내 이미지 리비전을 함께 넣습니다. 스크립트를 고치면 `v2`, `v3`로 올리세요. `latest`를 쓰면 RunPod 호스트 캐시 때문에 옛 이미지가 뜨는 혼란이 생깁니다.
- `--push`: 빌드가 끝나면 바로 레지스트리에 올립니다.

> **첫 push는 오래 걸립니다.** nvcr.io의 베이스 레이어(약 10GB)도 Docker Hub로 다시 올라가야 하기 때문입니다.
> 업로드 속도가 100Mbps면 15분 남짓, 더 느리면 1시간 이상 걸립니다. 이후 스크립트만 고쳐서 다시 push하면
> 바뀐 위쪽 레이어만 올라가므로 금방 끝납니다.

### 4) ROS 2 없이 가볍게 빌드하고 싶다면
```bash
docker buildx build --platform linux/amd64 --build-arg INSTALL_ROS=0 -t <dockerhub-id>/isaac-sim-novnc:6.1.0-noros --push .
```
`--build-arg`로 Dockerfile의 `ARG INSTALL_ROS` 값을 바꿉니다. 1~2GB가 줄지만 03 실습의 rviz2 확인 단계는 못 합니다.

### 5) 다른 Isaac 버전으로 빌드
```bash
docker buildx build --platform linux/amd64 --build-arg ISAAC_SIM_VERSION=6.0.1 -t <dockerhub-id>/isaac-sim-novnc:6.0.1-v1 --push .
```
6.x 계열은 모두 드라이버 595 이상이 필요합니다. 5.x로 내리면 `MIN_DRIVER` 환경변수(diag.sh)도 그 버전 요구사항에 맞게 바꿔야 합니다.

## 빌드 중 막히면

| 증상 | 원인·대처 |
|---|---|
| `no space left on device` | Docker Desktop → Settings → Resources → Disk usage limit 상향, `docker system prune` |
| ROS 단계에서 `api.github.com` 오류 | GitHub API 호출 제한(시간당 60회)에 걸렸을 수 있습니다. 잠시 뒤 재시도 |
| `지원하지 않는 Ubuntu` 출력 | 베이스 이미지가 22.04/24.04가 아님 → ROS 설치만 건너뛰고 빌드는 계속됨 |
| push 중 끊김 | 같은 명령을 다시 실행하면 이미 올라간 레이어는 건너뜁니다 |

빌드 로그에서 ROS 단계가 무엇을 골랐는지 확인하려면 pod에서 `cat /etc/ros_distro`를 실행하세요(24.04면 `jazzy`).
