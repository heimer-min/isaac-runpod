# 2. RunPod 템플릿 → pod 배포 → noVNC 접속

계정·결제·콘솔 조작은 모두 직접 진행하시면 됩니다. 아래는 무엇을 어디에 넣는지와 그 이유입니다.

## 2-1. 사전 준비 (최초 1회)

### SSH 키 만들기 (내 PC)
```bash
ssh-keygen -t ed25519 -C runpod -f ~/.ssh/runpod_ed25519
```
- `-t ed25519`: 짧고 안전한 최신 키 방식입니다.
- `-f ...`: 기존 키와 섞이지 않게 RunPod 전용 파일로 만듭니다. `~/.ssh/runpod_ed25519`(개인키)와 `.pub`(공개키) 두 파일이 생깁니다.

```bash
cat ~/.ssh/runpod_ed25519.pub
```
출력된 한 줄(공개키)을 RunPod 콘솔 **Settings → SSH Public Keys**에 붙여 넣습니다. RunPod은 이 값을 pod마다 `PUBLIC_KEY` 환경변수로 넣어 주고, `start.sh`가 이를 `authorized_keys`에 씁니다.

### 레지스트리 인증 등록
**Settings → Container Registry Auth → Add**: 이름 `dockerhub`, 사용자명, 비밀번호 칸에는 Docker Hub Access Token(Read 권한이면 충분)을 넣습니다.

### (선택) VNC 비밀번호를 Secret으로
**Secrets → Create Secret**: 이름 `vnc_password`, 값은 영문·숫자 **정확히 8자**로 합니다. VNC 프로토콜이 앞 8자만 쓰기 때문입니다.
따로 만들지 않으면 `start.sh`가 pod마다 무작위 8자를 생성해 로그에 출력합니다. **저는 이 기본값을 권장합니다.** pod마다 비밀번호가 바뀌니 유출돼도 피해가 그 pod에서 끝납니다.

## 2-2. 템플릿 만들기

**My Templates → New Template**

| 필드 | 값 | 이유 |
|---|---|---|
| Template Name | `isaac-sim-6.1-novnc` | |
| Template Type | Pod | |
| Compute | Nvidia GPU | |
| Container Image | `<dockerhub-id>/isaac-sim-novnc:6.1.0-v1` | 01에서 push한 태그 |
| Container Registry Credentials | `dockerhub` | private 이미지 pull용 |
| Container Start Command | **비워 둠** | Dockerfile의 ENTRYPOINT(`start.sh`)를 그대로 사용 |
| Container Disk | **60 GB** | 이미지 압축 해제분과 셰이더·에셋 캐시. 실행 중에만 과금($0.10/GB/월 → 55시간이면 약 $0.45) |
| Volume Disk | **0 GB** | 매번 terminate하는 운영이므로 둘 필요가 없습니다(04 문서) |
| Volume Mount Path | `/workspace` (기본값 유지) | 볼륨을 쓸 때만 의미가 있습니다 |
| Expose HTTP Ports | `6080` | noVNC. RunPod 프록시가 `https://<pod-id>-6080.proxy.runpod.net`으로 연결 |
| Expose TCP Ports | `22` | SSH. 공인 IP가 있는 호스트에서만 직접 접속 가능 |

**Environment Variables**

| Key | Value | 설명 |
|---|---|---|
| `ACCEPT_EULA` | `Y` | **NVIDIA Isaac Sim 라이선스 동의.** 값을 넣기 전에 NGC 카탈로그의 Isaac Sim 페이지에서 라이선스를 직접 읽어 보세요. 이 값이 없으면 Isaac은 자동 실행되지 않습니다 |
| `PRIVACY_CONSENT` | `N` (또는 비움) | 사용 데이터 수집 동의 여부(opt-in). 동의하려면 `Y` |
| `AUTOSTART_ISAAC` | `1` | 부팅이 끝나면 Isaac GUI를 자동 실행 |
| `MAX_SESSION_HOURS` | `3` | 3시간이 지나면 pod가 스스로 terminate합니다. **깜빡 잊고 켜 둔 pod가 밤새 과금되는 사고를 막는 안전장치입니다.** 10분 전에 화면에 경고가 뜹니다 |
| `RESOLUTION` | `1920x1080` | 브라우저 창이 작으면 `1600x900` |
| `VNC_PASSWORD` | `{{ RUNPOD_SECRET_vnc_password }}` | Secret을 만든 경우에만. 아니면 이 행을 빼세요 |

> `MAX_SESSION_HOURS`는 RunPod이 pod마다 넣어 주는 `RUNPOD_API_KEY`(해당 pod 전용 권한)로 REST API `DELETE /v1/pods/{id}`를 호출합니다.
> 이 pod 전용 키에 자기 삭제 권한이 실제로 있는지는 공식 문서만으로 확인하지 못했습니다. **첫 세션에서 `MAX_SESSION_HOURS=1`로 한 번 시험해** 정말 꺼지는지 확인하세요.

## 2-3. pod 배포

1. **Pods → Deploy**
2. **Community Cloud** 선택 → GPU **RTX 4090**
3. 필터(Additional filters)의 **CUDA Versions**에서 **13.2 이상만** 체크합니다. 드라이버 R595 이상 호스트만 남기는 필터입니다.
   - 13.2 이상 4090이 하나도 없으면 그날은 조건이 안 되는 겁니다. 시간을 바꿔 다시 보거나, 05 문서의 대안(5.1 이미지)을 참고하세요.
4. 템플릿 `isaac-sim-6.1-novnc` 선택
5. 카드에 표시된 **RAM이 32GB 이상**인지 확인합니다(Isaac 6.x 최소 요구 RAM).
6. 요금 방식은 **On-Demand**로 시작하세요. Spot(Interruptible)이 더 싸지만 실습 도중 회수될 수 있어, 환경이 안정된 뒤에 시험하는 게 낫습니다.
7. **Deploy**

## 2-4. 부팅 확인 (콘솔의 Logs 탭)

이미지 pull(첫 배포 시 수 분)이 끝나면 `start.sh` 로그가 이어서 나옵니다. 정상이면 대략 이런 순서입니다.

```
[start ..] 영속 볼륨 없음 — ...
[start ..] sshd 시작 (키 인증만)
[start ..] Xvfb :1 1920x1080 시작
[start ..] VNC_PASSWORD 미설정 → 이번 pod용 무작위 비밀번호 생성: Ab3dEf9g
[start ..] x11vnc :5901 (localhost 전용)
[start ..] noVNC 준비: https://abc123xyz-6080.proxy.runpod.net/
== Isaac Sim 호스트 진단 ==
  [OK]   드라이버 595.xx ≥ 595.58.03
  [OK]   libGLX_nvidia 존재 ...
  [OK]   Vulkan → :1 출력 가능 ...
== 결과: 통과 ==
[isaac-gui ..] Isaac Sim 시작 → ...
[isaac-gui ..] Isaac Sim 창 표시됨 (window ..., 95s)
[start ..] 부팅 완료.
```

**진단 결과가 `치명적 문제`면 바로 terminate하고 다른 호스트로 재배포하세요.** 그 호스트에서 고치려고 시간을 쓰면 그만큼 과금됩니다.

## 2-5. noVNC 접속

1. pod 카드의 **Connect → HTTP Service [Port 6080]**을 누르거나, 로그에 찍힌 URL을 엽니다.
2. noVNC 화면에서 비밀번호(로그에 찍힌 8자 또는 Secret 값)를 입력합니다.
3. Isaac Sim 창이 보이면 성공입니다. 첫 실행은 셰이더 컴파일 때문에 창이 뜬 뒤에도 1~3분쯤 버벅일 수 있습니다.

조작 팁:
- 바탕화면을 **우클릭**하면 fluxbox 메뉴가 열리고, 거기서 xterm(터미널)을 열 수 있습니다.
- noVNC 왼쪽 사이드바의 **Clipboard**로 PC와 텍스트를 주고받습니다. 브라우저 Ctrl+V는 원격으로 바로 전달되지 않습니다.
- 화면이 깨지거나 느리면 사이드바 Settings에서 Quality를 낮추세요.

## 2-6. SSH 접속 (권장: 긴 작업은 웹 터미널 말고 SSH)

Connect 메뉴의 **SSH over exposed TCP** 항목에 나온 IP와 포트를 사용합니다.
```bash
ssh root@<IP> -p <PORT> -i ~/.ssh/runpod_ed25519
```
- `-p`: RunPod이 22번을 외부 포트(예: 40123)로 매핑하므로 그 포트를 지정합니다.
- `-i`: 앞에서 만든 RunPod 전용 개인키를 사용합니다.

접속 후 쓸 수 있는 명령:
```bash
isaac-diag
```
호스트 적합성을 다시 점검합니다.
```bash
isaac-gui status
```
Isaac 실행 여부와 GPU 메모리 사용량을 봅니다. `isaac-gui log`는 Isaac 로그 끝 80줄, `isaac-gui restart`는 재시작입니다.

> RunPod 웹 터미널은 연결이 끊기면 그 안에서 띄운 프로세스를 함께 죽입니다. 그래서 스크립트는 모두 `setsid`로 분리해 띄우고, 긴 작업은 SSH나 noVNC 안의 xterm, 또는 `tmux`에서 하세요.

## 2-7. 보안 정리

**구조상 지켜지는 것**
- 외부에 열린 웹 포트는 **6080 하나**입니다. VNC(5901)는 `-localhost`로 컨테이너 내부에서만 접근됩니다. 템플릿에 5901을 노출하지 마세요.
- 브라우저와 RunPod 프록시 사이는 HTTPS입니다(RunPod 프록시가 자동으로 TLS 적용).
- SSH는 키 인증만 허용하고 비밀번호 로그인은 막혀 있습니다.

**한계와 주의점**
- 프록시 URL은 pod ID만 알면 누구나 열 수 있습니다. 비밀번호가 유일한 문입니다. 이 VNC 비밀번호는 **8자 제한에 무차별 대입 방어도 약한 구식 방식**이라, 장기간 켜 두는 서비스용으로는 부족합니다. 이 구성은 몇 시간 쓰고 terminate하는 운영을 전제로 버팁니다.
- 비밀번호를 템플릿 환경변수에 평문으로 쓰지 말고, 비워 두거나(pod별 무작위) Secret을 쓰세요.
- 화면 공유나 스크린샷에 프록시 URL과 비밀번호가 같이 찍히지 않게 하세요.
- 이미지에는 비밀값을 넣지 않습니다. private 저장소라도 마찬가지입니다.

**더 안전한 대안: SSH 터널 (공인 IP 호스트일 때)**
템플릿에서 HTTP 포트 6080을 빼고 환경변수 `NOVNC_BIND=127.0.0.1`을 넣으면 noVNC가 외부에 아예 노출되지 않습니다. 접속은 내 PC에서 터널을 열어서 합니다.
```bash
ssh -N -L 6080:localhost:6080 root@<IP> -p <PORT> -i ~/.ssh/runpod_ed25519
```
- `-L 6080:localhost:6080`: 내 PC의 6080을 pod 안의 localhost:6080으로 연결합니다.
- `-N`: 원격 명령 없이 터널만 유지합니다.

그다음 브라우저에서 `http://localhost:6080`을 엽니다. 공인 IP가 없는 호스트(SSH 항목이 프록시 방식만 보이는 경우)에서는 이 방법이 안 될 수 있습니다.
