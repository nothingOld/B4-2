# B4-2 | 컴퓨터가 갑자기 느려지거나 멈췄을 때 원인 찾아 고치기

Linux 환경에서 제공된 `agent-leak-app-x86`의 리소스 장애를 재현하고, CPU·메모리·프로세스 상태를 관측하여 원인을 분석한 실습 프로젝트입니다. **OOM, CPU 과점유, Deadlock** 세 시나리오를 각각 Before/After로 비교하고, 실행 로그·시스템 관측 자료·스크린샷을 제출 증거로 정리했습니다.

## 1. 수행 환경과 범위

| 항목 | 내용 |
|---|---|
| 실행 환경 | Ubuntu 22.04.5 LTS, Linux x86_64 (OrbStack 가상머신) |
| 실행 계정 | 일반 사용자(`root`가 아닌 서비스 사용자) |
| 대상 프로그램 | 과제에서 제공한 `agent-leak-app-x86` |
| 서비스 포트 | TCP `15034` |
| 모니터링 | Bash `monitor.sh`, `ps`, `top` |
| 종료 신호 분석 | `strace` |
| 분석 시나리오 | OOM / CPU 과점유 / Deadlock |

과제에서 제공한 **실행 바이너리 `agent-leak-app-x86`는 이 저장소의 ZIP에 포함되어 있지 않습니다.** 직접 재현할 경우 과제 배포 파일을 별도로 준비해야 합니다. 또한 `api_keys/secret.key`는 실행에 필요한 테스트용 파일이며 제출 자료에 포함하지 않았습니다.

## 2. 프로젝트 구성

```text
B4-2/
├── README.md
├── monitor.sh
├── report/
│   ├── 01-oom-incident.md
│   ├── 02-cpu-incident.md
│   └── 03-deadlock-incident.md
├── evidence/
│   ├── 01.ubuntu-env.png
│   ├── 01.ubuntu-env-chk.png
│   ├── 02.boot-sequence-success.png
│   ├── oom/
│   │   ├── before/                # 128MB 실행 로그 + monitor.log
│   │   ├── after/                 # 256MB 실행 로그 + monitor.log
│   │   ├── 03.oom-before.png
│   │   └── 03.oom-after.png
│   ├── cpu/
│   │   ├── before/                # 80% 실행·top·Watchdog·SIGTERM 로그
│   │   ├── after/                 # 40% Cooldown 실행 로그
│   │   ├── 04.cpu-before-80%.png
│   │   ├── 04.cpu-after-40%.png
│   │   ├── 04.cpu-top-spike.png
│   │   ├── 04.cpu-watchdog.png
│   │   └── 04.cpu-sigterm.png
│   └── deadlock/
│       ├── before/                # 상호 대기 로그 + 프로세스 상태
│       ├── after/                 # 정상 작업 완료 로그
│       ├── 05.deadlock-process-before.png
│       ├── 05.deadlock-before-blocked.png
│       └── 05.deadlock-after.png
└── logs/                         # 부트 점검 및 모니터링 보조 로그
```

보고서의 파일 링크와 이미지 링크는 **이 저장소의 실제 경로**를 기준으로 작성했습니다.

## 3. 실행 환경 설정

다음 명령어는 **직접 재현할 경우**의 예시입니다. `monitor.sh`는 로그 출력 경로를 `$HOME/agent-app-leak/logs/monitor.log`로 고정하므로, 프로젝트를 `~/agent-app-leak`에 배치하여 실행합니다. 현재 ZIP의 최상위 폴더명이 `B4-2`인 점에 주의해 주세요.

```bash
cd "$HOME/agent-app-leak"

export AGENT_HOME="$HOME/agent-app-leak"
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR="$AGENT_HOME/upload_files"
export AGENT_KEY_PATH="$AGENT_HOME/api_keys"
export AGENT_LOG_DIR="$AGENT_HOME/logs"

mkdir -p "$AGENT_UPLOAD_DIR" "$AGENT_KEY_PATH" "$AGENT_LOG_DIR"
chmod 700 "$AGENT_UPLOAD_DIR" "$AGENT_KEY_PATH" "$AGENT_LOG_DIR"
```

과제 배포 파일 `agent-leak-app-x86`를 프로젝트 루트에 놓고 실행 권한을 부여합니다.

```bash
chmod +x ./agent-leak-app-x86
```

### 테스트용 키 파일

이 프로그램은 부트 시퀀스에서 `$AGENT_KEY_PATH/secret.key`가 존재하는지와 **과제에서 지정한 검증용 문자열**을 확인합니다. 이 키는 외부 AI API를 호출하는 데 사용한 것이 아닙니다.

```bash
printf '%s\n' 'agent_api_key_test' > "$AGENT_KEY_PATH/secret.key"
chmod 600 "$AGENT_KEY_PATH/secret.key"
```

위 문자열은 **과제 전용 테스트 값**이며 실제 서비스 API 비밀키가 아닙니다. 실제 비밀키·토큰·개인정보가 들어 있는 파일은 공개 저장소에 업로드하지 마세요.

### 기본 부트 테스트

```bash
export MEMORY_LIMIT=256
export CPU_MAX_OCCUPY=80
export MULTI_THREAD_ENABLE=true

./agent-leak-app-x86
```

정상적으로 시작하면 여섯 가지 부트 검사가 `[OK]`로 표시되고 `All Boot Checks Passed!`, `Agent READY` 및 `Agent listening at port 15034`가 출력됩니다. **부트 성공은 이후 장애가 발생하지 않는다는 뜻이 아닙니다.** 해당 실행은 선택된 실험 시나리오에 따라 종료되거나 대기 상태로 진입할 수 있습니다.

## 4. 프로세스 모니터링

`monitor.sh`는 전달받은 **PID 하나**를 1초 간격으로 확인하여 `timestamp,pid,cpu_percent,rss_kb,state` 형식의 CSV를 `logs/monitor.log`에 기록합니다.

```bash
cd "$HOME/agent-app-leak"
chmod +x monitor.sh

# 예시: 첫 번째 터미널에서 실행
./agent-leak-app-x86 > logs/manual-app.log 2>&1 &
APP_PID=$!
sleep 3
WORKER_PID=$(pgrep -P "$APP_PID" | head -n 1)

# 자식 프로세스가 확인되었을 때만 관제
./monitor.sh "$WORKER_PID"
```

실제 관측 시 실행 파일이 부모·자식 프로세스로 구분되어 동작했으며, 장애 작업을 수행하는 **자식 프로세스의 PID**를 대상으로 측정했습니다. PID는 실행마다 달라집니다. `monitor.sh`는 새로 실행할 때 `logs/monitor.log`를 덮어쓰므로 각 실험의 제출 증거는 `evidence/` 아래에 별도로 보존했습니다.

`ps`의 `%CPU`는 누적 실행 시간을 기준으로 계산되므로 아주 짧은 부하 급상승을 놓칠 수 있습니다. CPU 실험에서는 `top`의 측정 간격을 0.1초로 줄여 별도로 관측했습니다.

## 5. 장애별 실험 조건과 검증 결과

### 5.1 OOM — MemoryGuard 자체 종료

| 항목 | Before | After |
|---|---|---|
| `MEMORY_LIMIT` | `128` | `256` |
| `CPU_MAX_OCCUPY` | `80` | `80` |
| `MULTI_THREAD_ENABLE` | `true` | `true` |
| 종료 직전 내부 Heap | 약 150MB | 약 275MB |
| 결과 | MemoryGuard 자체 종료 | 종료 시점 지연, 동일 장애 재발 |

- 원인: `MemoryWorker`의 메모리 사용량 증가가 설정 제한에 도달했습니다.
- 조치: `MEMORY_LIMIT`를 128MB에서 256MB로 상향했습니다.
- 판정: **장애 발생 시점을 늦춘 임시 조치**입니다. 커널 OOM Killer 종료라고 판단하지 않았습니다.
- 분석 보고서: [01-oom-incident.md](report/01-oom-incident.md)
- 주요 증거: [Before 로그](evidence/oom/before/app.log), [After 로그](evidence/oom/after/app.log), [Before 캡처](evidence/oom/03.oom-before.png), [After 캡처](evidence/oom/03.oom-after.png)

### 5.2 CPU — Threshold 위반과 Watchdog SIGTERM

| 항목 | Before | After |
|---|---|---|
| `MEMORY_LIMIT` | `512` | `512` |
| `CPU_MAX_OCCUPY` | `80` | `40` |
| `MULTI_THREAD_ENABLE` | `false` | `false` |
| 동작 | 내부 부하 약 50% 초과 시 Threshold 위반 | 40% 도달 시 Cooldown |
| 결과 | Watchdog 긴급 종료 기록 | Cooldown 반복 후 실행 지속 |

- `top -b -d 0.1` 측정에서 짧은 구간의 OS CPU 사용률이 **최대 50%**까지 상승했습니다. 이는 내부 `Current Load`와 다른 지표이며, 지속적인 CPU 80% 초과를 의미하지 않습니다.
- 가상 터미널 기록에는 `WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM)`이 출력되었습니다.
- 별도의 `strace` 재현에서 `kill(PID, SIGTERM)`과 SIGTERM에 의한 종료가 확인되었습니다. **Watchdog·`top`·`strace` 증거는 서로 다른 재현 실행에서 수집**했습니다.
- 분석 보고서: [02-cpu-incident.md](report/02-cpu-incident.md)
- 주요 증거: [Before 로그](evidence/cpu/before/app.log), [After 로그](evidence/cpu/after/app.log), [CPU 관측](evidence/cpu/before/top-fast.log), [Watchdog 로그](evidence/cpu/before/watchdog-terminal.log), [SIGTERM 추적](evidence/cpu/before/strace-signals.log)
- 이미지: [Before](evidence/cpu/04.cpu-before-80%25.png), [After](evidence/cpu/04.cpu-after-40%25.png), [top 급상승](evidence/cpu/04.cpu-top-spike.png), [Watchdog](evidence/cpu/04.cpu-watchdog.png), [SIGTERM](evidence/cpu/04.cpu-sigterm.png)

### 5.3 Deadlock — 스레드 간 순환 대기

| 항목 | Before | After |
|---|---|---|
| `MEMORY_LIMIT` | `512` | `512` |
| `CPU_MAX_OCCUPY` | `40` | `40` |
| `MULTI_THREAD_ENABLE` | `true` | `false` |
| 상태 | 서로의 락 대기(`WAITING/BLOCKED`) | Scheduler 전체 작업 완료 |

- 원인: Thread 1이 `Shared_Memory_A`를, Thread 2가 `Socket_Pool_B`를 보유한 채 서로 상대 자원을 기다렸습니다.
- `ps`로 확인한 PID 및 스레드 TID는 5초 후에도 유지되었고 CPU·RSS 수치가 정체되었습니다.
- 조치: `MULTI_THREAD_ENABLE=false`로 전환하여 동시 처리 모드에서 발생하는 순환 대기를 회피했습니다.
- 분석 보고서: [03-deadlock-incident.md](report/03-deadlock-incident.md)
- 주요 증거: [Before 로그](evidence/deadlock/before/app.log), [프로세스 관측](evidence/deadlock/before/process-state.log), [After 로그](evidence/deadlock/after/app.log)
- 이미지: [프로세스 상태](evidence/deadlock/05.deadlock-process-before.png), [WAITING/BLOCKED](evidence/deadlock/05.deadlock-before-blocked.png), [After](evidence/deadlock/05.deadlock-after.png)

## 6. 부트 및 운영 환경 증거

- [Ubuntu 실행 환경](evidence/01.ubuntu-env.png)
- [Ubuntu 환경 확인](evidence/01.ubuntu-env-chk.png)
- [부트 시퀀스 정상 완료](evidence/02.boot-sequence-success.png)
- 부트·관제 보조 로그는 [`logs/`](logs/) 아래에 보관했습니다.