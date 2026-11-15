# B4-2 | 컴퓨터가 갑자기 느려지거나 멈췄을 때 원인 찾아 고치기

> **미션:** Linux 프로세스의 OOM·CPU 과점유·Deadlock을 재현하고, 시스템 관측값과 애플리케이션 로그로 장애 원인 및 설정 변경 효과를 검증한다.
>
> **증거 원칙:** 이 문서는 **실제로 관측한 결과**, **그 결과를 근거로 한 해석**, **향후 개선 제안(미구현)**을 구분한다. 표의 시간은 모두 **KST(UTC+09:00)**이다.
>
> **현재 재현 상태:** 원래 사용한 OrbStack Ubuntu 머신은 현재 없으며, **이번 README 정리는 기존 `B4-2-main.zip`에 보존된 원본 로그와 스크린샷만 사용**했다. 새 실험을 수행하거나 누락된 로그를 생성했다고 주장하지 않는다.

## 0. 평가 핵심 요약 — 1분 설명

> Ubuntu/OrbStack에서 제공된 `agent-leak-app-x86`의 **OOM·CPU 과점유·Deadlock**을 각각 재현하고, 로그의 **시간·PID·측정 지표**를 근거로 설정 변경 전후를 비교했다. **OOM:** `MEMORY_LIMIT` 128→256MB로 종료 트리거까지의 관측시간이 17.321→32.585초 증가했지만 동일 종료가 재발했다. **CPU:** `CPU_MAX_OCCUPY` 80→40%로 내부 보호 임계치 약 50% 위반을 회피하고 Cooldown 14회를 확인했다. **Deadlock:** `MULTI_THREAD_ENABLE` true→false로 상호 Lock 대기 경로를 회피하고 Scheduler 작업 완료를 확인했다. **세 조치는 코드 수정이 아닌 임시 완화·회피**다.

**평가 관점별 위치:** [① 3대 장애의 전후 비교](#3-oom--memoryguard-자체-종료) · [② 진단 도구와 절차](#23-모니터링-및-기록-형식) · [③ OS 원리·원인](#33-원인-os-원리-및-조치) · ④ 운영 개선·우선순위

## 1. 수행 환경 및 제출물

| 항목 | 실제 수행 환경 |
|---|---|
| 운영체제 | Ubuntu 22.04.5 LTS, Linux x86_64 (OrbStack 환경) |
| 실행 계정 | `root`가 아닌 일반 사용자 (`sevencvter4085`; 과거 실험 로그의 계정) |
| 대상 | 미션에서 제공한 `agent-leak-app-x86` (GitHub 저장소에 미포함) |
| 서비스 | `0.0.0.0:15034` 바인딩 |
| 진단 | Bash `monitor.sh`, `ps`, `ps -L`, `top`, `strace`, `script` |
| 장애 유형 | 메모리 누적/OOM 유사 종료, CPU Threshold/Watchdog 종료, Deadlock |
| 보고서 형식 | GitHub Issue 템플릿과 동일한 4개 본문 섹션 |

**보고서 3건:** [OOM](report/01-oom-incident.md) · [CPU](report/02-cpu-incident.md) · [Deadlock](report/03-deadlock-incident.md)

**증거 구성:** `evidence/oom/{before,after}/`, `evidence/cpu/{before,after}/`, `evidence/deadlock/{before,after}/`에 실행 로그와 관측 원본을 보존했다. 스크린샷은 각 장애 유형 폴더 바로 아래에 있다. 키 파일은 제출하지 않았다.

> **재현 전제:** GitHub에 실행 바이너리와 `secret.key`가 포함되어 있지 않으므로, 재현자는 미션 제공 바이너리를 별도로 준비해야 한다. 아래 명령은 원래 실험 경로인 `~/agent-app-leak`을 기준으로 한다. 실행 파일은 실험에 따라 자체 종료되거나 멈출 수 있으므로 공유 운영 서버에서 실행하지 않는다.

## 2. 실행·재현 절차

### 2.1 부트 조건 및 기본 환경

```bash
cd "$HOME/agent-app-leak"

export AGENT_HOME="$HOME/agent-app-leak"
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR="$AGENT_HOME/upload_files"
export AGENT_KEY_PATH="$AGENT_HOME/api_keys"
export AGENT_LOG_DIR="$AGENT_HOME/logs"
mkdir -p "$AGENT_UPLOAD_DIR" "$AGENT_KEY_PATH" "$AGENT_LOG_DIR"
chmod 700 "$AGENT_UPLOAD_DIR" "$AGENT_KEY_PATH" "$AGENT_LOG_DIR"

# 과제에서 지정한 공개 테스트 문자열이며 실서비스 인증키가 아니다.
printf '%s\n' 'agent_api_key_test' > "$AGENT_KEY_PATH/secret.key"
chmod 600 "$AGENT_KEY_PATH/secret.key"
chmod +x ./agent-leak-app-x86 ./monitor.sh

# 시작 전 포트 중복 점검
ss -ltnp | grep ':15034' || echo '15034 포트 사용 프로세스 없음'
```

부트 단계에서는 사용자 계정, 환경변수, 필수 파일, 포트, 로그 권한, 미션 설정 총 **6개 항목**을 검사한다. `All Boot Checks Passed!`와 `Agent READY`는 **시작 조건 통과**이지 런타임 장애가 없다는 보장은 아니다. 키는 부트 검증에만 사용했으며 외부 API를 호출하지 않았다. [부트 성공 화면](evidence/02.boot-sequence-success.png)

### 2.2 조건별 재현 설정

세 실험 모두 동일한 바이너리를 사용했다. 각 행의 **Before/After는 설정 비교를 뜻하며 실제 실행 시각의 선후 관계를 뜻하지 않는다**.

| 실험 | 구분 | `MEMORY_LIMIT`(MB) | `CPU_MAX_OCCUPY`(%) | `MULTI_THREAD_ENABLE` | 결과 |
|---|---|---:|---:|---|---|
| OOM | Before | 128 | 80 | true | Heap 150MB, MemoryGuard 종료 |
| OOM | After | 256 | 80 | true | Heap 275MB, 종료 지연 후 재발 |
| CPU | Before | 512 | 80 | false | 내부 부하 약 50%에서 Threshold 위반 및 종료 |
| CPU | After | 512 | 40 | false | 40%에서 Cooldown, 지속 동작 |
| Deadlock | Before | 512 | 40 | true | 스레드 2개의 순환 대기 |
| Deadlock | After | 512 | 40 | false | Scheduler 작업 완료 |

실행 예시(아래 변수만 원하는 행으로 바꾸어 **한 번에 하나의 실험**을 실행):

```bash
export MEMORY_LIMIT=512
export CPU_MAX_OCCUPY=80
export MULTI_THREAD_ENABLE=false

./agent-leak-app-x86 > logs/manual-app.log 2>&1 &
APP_PID=$!
sleep 3
WORKER_PID=$(pgrep -P "$APP_PID" | head -n 1)
echo "부모=$APP_PID 자식=$WORKER_PID"
ps -p "$APP_PID","$WORKER_PID" -o pid,ppid,pcpu,rss,stat,args
```

**실험 유형별 설정 명령 — 설명용 재현 레시피(실행 기록 자체는 증거 폴더 참조):**

```bash
# [OOM Before] 아래 셋을 설정한 뒤 ./agent-leak-app-x86 실행
export MEMORY_LIMIT=128
export CPU_MAX_OCCUPY=80
export MULTI_THREAD_ENABLE=true

# [OOM After] 첫 실험 종료 및 포트 해제 확인 후 변경
export MEMORY_LIMIT=256
# 다른 두 변수는 위와 동일하게 유지

# [CPU Before] 다른 실험과 혼동되지 않도록 세 변수를 모두 지정
export MEMORY_LIMIT=512
export CPU_MAX_OCCUPY=80
export MULTI_THREAD_ENABLE=false

# [CPU After] 첫 실험 종료 및 포트 해제 확인 후 변경
export CPU_MAX_OCCUPY=40

# [Deadlock Before] 동시 처리 활성화 (MEMORY=512, CPU=40 유지)
export MULTI_THREAD_ENABLE=true

# [Deadlock After] 교착 증거를 수집·실험 종료한 뒤 변경
export MULTI_THREAD_ENABLE=false
```

위 코드는 **각 구간에서 실행 파일을 따로 실행해야 하는 설정 예시**다. 여섯 조건이 하나의 연속 실행으로 자동 수행되는 스크립트가 아니다. `export`는 실행 자식 프로세스에 환경변수를 전달하며 **MemoryGuard/Watchdog/Lock의 내부 구현을 직접 수정하지 않는다.**

- **OOM:** 128→256MB 조정 후 Heap 증가, MemoryGuard 종료, `monitor.log`의 RSS 및 관측시간 비교.
- **CPU:** 80→40% 조정 후 내부 Threshold/Watchdog 종료와 `Peak reached`·`Cooldown complete` 비교.
- **Deadlock:** true→false 변경 후 두 스레드의 `WAITING/BLOCKED`와 `All tasks completed` 비교.
- **Deadlock 실험은 프로세스가 살아 있어도 응답이 없을 수 있다.** 증거 수집 후 실험에서 확인된 PID만 `kill -TERM <PID>`로 종료하고 `ss -ltnp`로 포트 해제 확인. 다음 실험 전에 동일 포트 사용 프로세스가 없어야 한다.

### 2.3 모니터링 및 기록 형식

[`monitor.sh`](monitor.sh)는 **PID 하나**를 받아 `ps`로 약 **1초 간격**으로 CPU 사용률·RSS·상태를 읽고 `~/agent-app-leak/logs/monitor.log`에 저장한다. 파일 확장자는 `.log`지만 데이터는 **CSV 형식**이다.

```bash
# 관측할 자식 PID가 존재할 때
./monitor.sh "$WORKER_PID"
# 별도 터미널에서 종료하거나 대상 프로세스가 종료되면 수집 중단
```

**실제 CSV 발췌:** [`evidence/oom/before/monitor.log`](evidence/oom/before/monitor.log)

```csv
timestamp,pid,cpu_percent,rss_kb,state
2026-11-14 00:22:25,2243,1.6,69648,SN
2026-11-14 00:22:29,2243,1.6,120856,SN
2026-11-14 00:22:32,2243,1.6,146460,SN
```

- `timestamp`: 현지 시스템 시각; `pid`: 대상 프로세스 ID; `cpu_percent`: `ps`의 프로세스 CPU 사용률; `rss_kb`: 물리 메모리에 상주하는 크기(KB); `state`: Linux `STAT` 코드.
- `monitor.sh`는 시작할 때 `monitor.log`를 **덮어쓰므로** 실행 직후 해당 실험의 `evidence/.../monitor.log`로 별도 복사하여 보존했다.
- 이 스크립트에는 **샘플링 간격을 바꾸는 CLI 옵션이 없다.** 다른 관측 간격이 필요하면 `monitor.sh`의 `sleep 1`을 변경한 별도 사본을 사용하거나 아래처럼 `top`의 간격을 바꾼다.

```bash
# CSV에서 RSS가 120000KB를 초과한 관측 행 조회
awk -F, 'NR==1 || $4>120000' evidence/oom/before/monitor.log

# 특정 PID에 대해 0.1초 간격으로 100회 관측(약 10초)
top -b -d 0.1 -n 100 -p "$WORKER_PID" > logs/top-short.log
```

**`monitor.sh`의 실제 처리 순서:** 인자 `PID`가 정수인지 검사 → `ps`로 PID 존재 확인 → CSV 헤더 기록(기존 파일 덮어쓰기) → `ps -p "$PID" -o pcpu= -o rss= -o stat=` 결과를 파싱 → `date`로 시각 생성 → `tee -a`로 화면과 파일에 동시 출력 → `sleep 1` 후 반복 → PID가 사라지거나 `STAT`이 `Z`로 시작하면 중단. `sleep 1`은 **관측 주기 제어**이지 애플리케이션 `CpuWorker`의 Cooldown이 아니다.

**샘플링 주의:** `ps %CPU`는 누적 CPU 사용 시간을 반영하므로 짧은 스파이크를 희석할 수 있다. `top -d 0.1`은 짧은 변화를 더 잘 포착하지만 0.1초 간격의 샘플 값이므로 지속적인 CPU 포화의 증거는 아니다. `strace`는 시스템 호출·신호를 확인하지만 추적 오버헤드가 있어 성능 측정용 도구는 아니다.

### 2.4 프로세스 생존·스레드·CPU 진단 명령

```bash
# 부모 APP_PID와 자식 WORKER_PID를 확인한 뒤 상태 비교
ps -p "$APP_PID","$WORKER_PID" -o pid,ppid,stat,pcpu,rss,args

# 자식 프로세스의 스레드 식별자(TID)와 상태 확인
ps -L -p "$WORKER_PID" -o pid,tid,stat,pcpu,rss,comm

# 실제 제출된 단기 CPU 관측과 동일한 간격·샘플 수
# -b: 배치, -d 0.1: 약 0.1초 간격, -n 450: 450회, -p: 지정 PID
# 실행 당시 해당 PID가 존재할 때만 의미 있음
top -b -d 0.1 -n 450 -p "$WORKER_PID" > logs/top-fast.log
```

- **진단 판단 순서:** PID 존재 → 일정 시간의 CPU/RSS 및 작업 로그 확인 → `ps -L`로 TID 생존 확인 → `LOCK ACQUIRED` 뒤 `WAITING/BLOCKED`가 상대 방향으로 연결되는지 확인. **CPU 0%만으로 Deadlock이라고 판단하지 않는다.**
- **`top` 화면 해석:** [CPU 급상승 화면](evidence/cpu/04.cpu-top-spike.png)은 `sort -k9,9nr`로 높은 `%CPU`부터 재정렬한 결과다. 화면에서 10→50%가 시간순으로 상승한 것으로 읽어서는 안 된다. `-d 0.1`은 **측정 간격**이지 0.1초 만에 50%로 상승한 시간이 아니다.

## 3. OOM — MemoryGuard 자체 종료

**실제 증거:** [Before 애플리케이션](evidence/oom/before/app.log) · [Before 관제](evidence/oom/before/monitor.log) · [After 애플리케이션](evidence/oom/after/app.log) · [After 관제](evidence/oom/after/monitor.log) · [전후 보고서](report/01-oom-incident.md) · [Before 화면](evidence/oom/03.oom-before.png) · [After 화면](evidence/oom/03.oom-after.png)

### 3.1 종료 전 로그와 PID·시각

**Before, 128MB, 자식 PID 2243:**

```text
2026-11-14 00:22:19,705 [INFO] [MemoryWorker] Current Heap: 25MB
2026-11-14 00:22:28,868 [INFO] [MemoryWorker] Current Heap: 100MB
2026-11-14 00:22:34,977 [INFO] [MemoryWorker] Current Heap: 150MB
2026-11-14 00:22:34,977 [CRITICAL] [MemoryGuard] Memory limit exceeded (150MB >= 128MB) / (Recommend Over 256MB)
2026-11-14 00:22:34,977 [CRITICAL] [MemoryGuard] Self-terminating process 2243 to prevent system instability.
```

**After, 256MB, 자식 PID 2014:**

```text
2026-11-13 23:21:45,715 [INFO] [MemoryWorker] Current Heap: 25MB
2026-11-13 23:22:07,088 [INFO] [MemoryWorker] Current Heap: 200MB
2026-11-13 23:22:16,251 [INFO] [MemoryWorker] Current Heap: 275MB
2026-11-13 23:22:16,251 [CRITICAL] [MemoryGuard] Memory limit exceeded (275MB >= 256MB) / (Recommend Over 256MB)
2026-11-13 23:22:16,251 [CRITICAL] [MemoryGuard] Self-terminating process 2014 to prevent system instability.
```

### 3.2 생존시간·메모리 정량 비교 (#2, #8)

| 측정 항목 | Before 128MB | After 256MB |
|---|---|---|
| 최초 타임스탬프 (`SafetyGuard`) | 11/14 00:22:17.656 | 11/13 23:21:43.666 |
| MemoryGuard 종료 시각 | 11/14 00:22:34.977 | 11/13 23:22:16.251 |
| **로그 기반 실행 관측시간** | **17.321초** | **32.585초** |
| `MemoryWorker` 첫 로그 → 종료 | 15.272초 | 30.536초 |
| 종료 직전 내부 Heap | 150MB | 275MB |
| RSS 관측 예시 | 69,648 → 146,460KB | 223,160 → 274,368KB |
| 결과 | MemoryGuard 자체 종료 | 동일 장애 재발, 종료 지연 |

관측시간은 **프로그램 시작 이후 첫 번째 타임스탬프부터 종료 트리거 로그까지의 차이**로 계산했다. 엄밀한 OS 수준의 `PID elapsed`(전체 실제 수명) 측정값은 아니다. 같은 기준으로 비교하면 **15.264초(+88.1%)** 더 오래 지속되었다. `Before/After`는 설정 비교 명칭이며 원본 After 로그가 시간상 먼저 수집되었다.

### 3.3 원인, OS 원리 및 조치

- **현상:** 약 3초마다 25MB씩 **계단식·거의 일정한 간격으로 증가**한 `MemoryWorker`의 Heap과 `monitor.sh`의 RSS 증가 추세를 확인했다. 연속 시간의 완전한 직선 증가를 측정한 것은 아니다. 이 증가 양상은 메모리 누수 **의심 근거**이며, 누수의 정확한 객체·코드 위치는 확인하지 못했다.
- **보호 정책의 관측된 조건:** `MemoryGuard`가 **보고된 Heap ≥ 설정된 `MEMORY_LIMIT`**인 상태를 감지하고 `Self-terminating process <PID>`를 출력했다. Heap이 25MB 단위로 보고되어 실제 한도를 다소 넘은 150MB/275MB에서 감지되었다.
- **종료 방식의 한계:** 내부의 정확한 종료 시스템 호출이나 커널 OOM Killer 동작은 이 로그만으로 확인되지 않는다. **Linux OOM Killer로 단정하지 않는다.**
- **메모리 구조/영향:** Heap은 동적 할당 영역, Stack은 함수 호출 관련 영역이다. **가상 메모리는 프로세스에 매핑된 논리적 주소 공간**으로 RAM에 올리지 않은 부분도 포함할 수 있으며, **RSS는 그중 실제 RAM에 상주하는 부분**이다. Heap과 RSS는 같은 값이 아니다. 누적 사용이 지속되면 가용 메모리 감소, 페이지 회수·스왑 증가, 다른 프로세스 지연과 시스템 OOM 위험으로 이어질 수 있다. **이번 실험에서 시스템 전체 장애를 직접 측정한 것은 아니다.**
- **조치·판정:** 128→256MB 상향은 종료를 약 15.3초 지연시켰지만 재발을 막지 못한 **임시 완화책**이다.
- **코드 수준 개선 제안(미구현):** 메모리 할당·참조 해제 지점 점검, 누적 자료구조의 보유 상한 설정, 사용 완료 객체 참조 해제, 캐시 크기·TTL 관리, 힙 프로파일링, 장기 RSS 추적. `del` 실행만으로 RSS가 즉시 감소한다고 단정하지 않는다.

## 4. CPU — 내부 임계치 위반과 Watchdog SIGTERM

**실제 증거:** [Before 로그](evidence/cpu/before/app.log) · [After 로그](evidence/cpu/after/app.log) · [0.1초 top](evidence/cpu/before/top-fast.log) · [동일 top 실행의 앱 로그](evidence/cpu/before/app-top-fast.log) · [Watchdog 터미널](evidence/cpu/before/watchdog-terminal.log) · [strace 신호](evidence/cpu/before/strace-signals.log) · [동일 strace 실행의 앱 로그](evidence/cpu/before/app-strace.log) · [보고서](report/02-cpu-incident.md)

**스크린샷:** [80% Before](evidence/cpu/04.cpu-before-80%25.png) · [40% After](evidence/cpu/04.cpu-after-40%25.png) · [CPU 급상승](evidence/cpu/04.cpu-top-spike.png) · [Watchdog](evidence/cpu/04.cpu-watchdog.png) · [SIGTERM](evidence/cpu/04.cpu-sigterm.png)

### 4.1 CPU 80%·40% 정량 비교 (#3, #4, #13)

| 항목 | Before: CPU 80% | After: CPU 40% |
|---|---|---|
| 나머지 조건 | MEMORY=512MB, MULTI_THREAD=false | 동일 |
| 최초 타임스탬프 | 11/14 01:27:27.975 | 11/14 01:00:46.344 |
| 내부 CpuWorker 시작 | 01:27:29.989 | 01:00:49.171 |
| 마지막 관측 시각 | 01:28:13.791 (Threshold 위반) | 01:12:02.334 (정상 활동 기록) |
| **로그 기반 관측시간** | **45.816초 후 임계치 위반** | **최소 675.990초 정상 활동 관측** |
| 내부 부하 | 50.20%에서 위반 | 40.00%에서 Cooldown, 5% 부근까지 감소 |
| `Peak reached` / `Cooldown complete` | 0회 / 0회 | **14회 / 14회** |
| 프로세스 결과 | 종료 경로 진입 | 관측 구간 동안 자발 종료 기록 없음 |

**해석 범위:** After는 약 11분 16초까지 **로그가 관측된 기간**이며, 실제 최종 수명이나 처리량·응답시간 측정값이 아니다. 서로 다른 시각·개별 실행을 비교하였으므로 엄격한 동일 기간 성능 벤치마크가 아니다. 실험에서 확인한 개선은 **자동 종료 회피와 Cooldown 반복**이지 서비스 지연 시간 감소의 직접 측정은 아니다.

```text
2026-11-14 01:27:29,989 [INFO] [CpuWorker] Started. Maximum CPU Limit: 80%
2026-11-14 01:28:10,567 [INFO] [CpuWorker] Current Load: 43.89%
2026-11-14 01:28:13,689 [INFO] [CpuWorker] Current Load: 50.20%
2026-11-14 01:28:13,791 [CRITICAL] [CpuWorker] CPU Threshold Violated! (50.199999999999996%).
```

```text
2026-11-14 01:11:34,271 [INFO] [CpuWorker] Peak reached (40.00%). Starting cooldown...
2026-11-14 01:12:02,334 [INFO] [CpuWorker] Cooldown complete (5.00%). Resuming load increase...
```

**판정 기준:** 설정 80%인 실행에서도 내부 `Current Load`가 약 50%를 초과할 때 Threshold 위반이 반복 관측되고 부트 시 `WARNING: Recommend Under 50%`가 표시된다. 이는 **내부 약 50% 보호 기준이 존재한다는 관측 기반 해석**이다. 로그만으로 별도 조건의 정확한 구현식이나 **초과 지속시간 임계값**은 확인할 수 없다. 내부 부하와 OS `%CPU`는 다른 값이다.

### 4.2 Watchdog 종료 메시지와 PID 신호 추적

**Watchdog 메시지가 보인 실행 — PID는 이 로그에 명시되지 않음:**

```text
2026-11-14 02:27:07,733 [INFO] [CpuWorker] Current Load: 50.92%
2026-11-14 02:27:07,834 [CRITICAL] [CpuWorker] CPU Threshold Violated! (50.92%).
>>> [SYSTEM] WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM) <<<
Script done on 2026-11-14 02:27:07+09:00 [COMMAND_EXIT_CODE="143"]
```

**동일 종류의 장애를 `strace`로 별도 재현한 실행 — 자식 PID 3040, 부모 PID 3039:**

```text
2026-11-14 01:56:08,746 [CRITICAL] [CpuWorker] CPU Threshold Violated! (52.69%).
3040  01:56:08.746420 kill(3040, SIGTERM) = 0
3040  01:56:08.746952 --- SIGTERM {si_signo=SIGTERM, si_code=SI_USER, si_pid=3040, si_uid=1267601390} ---
3040  01:56:08.748286 +++ killed by SIGTERM +++
3039  01:56:08.752313 tgkill(3039, 3039, SIGTERM) = 0
3039  01:56:08.752495 +++ killed by SIGTERM +++
```

- 이 SIGTERM은 **프로세스의 자기 자신에 대한 신호 전송**으로 관측됐다. 독립적인 외부 Watchdog 프로세스에 의한 전송을 입증하지 않는다.
- Watchdog 출력, `strace`, `top`은 **서로 다른 실행에서 확보**했다. 위 로그를 동일 실행의 연속 출력으로 해석하지 않는다.
- 단순한 `> app.log 2>&1`에서는 종료 직전 `print` 메시지가 버퍼링으로 누락될 가능성이 있어 `script -q -f -c './agent-leak-app-x86' evidence/cpu/before/watchdog-terminal.log`로 가상 터미널을 캡처했다.
- SIGTERM은 종료 요청 신호이고 SIGKILL은 처리할 수 없는 강제 종료 신호다.

**실제 OS CPU 스파이크(확인):** `top -b -d 0.1 -n 450 -p "$WORKER_PID"`를 사용한 별도 실행에서 **자식 PID 3065의 `%CPU` 최대 50.0%**를 확인했다([top-fast.log](evidence/cpu/before/top-fast.log)). 이 값은 **운영체제에서 측정한 샘플 사용률**이며 `CpuWorker`의 `Current Load=50.20%`와 같은 측정값이 아니다. 스크린샷의 높은 순서 정렬 결과는 시간순 증가 증거도 아니다.

**1초 측정 관련 증거 한계(중요):** 기존 [CPU 보고서](report/02-cpu-incident.md)에 적혀 있던 **"1초 간격에서는 최대 5.0%"**라는 수치를 입증하는 **1초 간격 원본 `top` 로그는 이번 ZIP에 없다.** 따라서 이번 README에서는 그 값을 **확인된 실측 비교 결과로 채택하지 않는다.** 0.1초 측정 최대 50%는 확인되지만 **1초 대비 10배 차이를 이번 보존 자료로 증명했다고 주장하지 않는다.** 또한 지속적인 50% 이상 점유, CPU 80% 도달, 시스템 전체 응답 지연 개선은 직접 측정하지 않았다.

**이론적 원리와 종료 정책:** CPU 경합이 발생하면 Linux의 선점형 스케줄러가 실행 시간을 나누는 과정에서 다른 실행 가능 작업의 대기 시간이 늘어날 수 있다. **프로세스가 종료되지 않아야 다른 작업이 실행되는 것은 아니다.** CPU를 과도하게 소모하는 작업 하나를 종료하면 해당 작업의 CPU 요구가 제거되어 시스템을 보호할 수 있다. 다만 운영 환경에서는 정상 프로세스의 무조건적인 종료보다 부하 제어·작업량 제한·알림을 우선 검토한다. 이번 실험에서 다른 프로세스의 실제 응답시간을 계측한 것은 아니다.

**Cooldown의 의미:** `CPU_MAX_OCCUPY=40`에서는 내부 `Current Load`가 40%에 도달하면 `Peak reached ... Starting cooldown`, 5%까지 내려가면 `Cooldown complete ... Resuming load increase`가 반복된다. **프로세스 전체 정지나 실제 OS CPU 사용률 40→5%를 증명하는 것은 아니다.** 제공된 실행 파일의 Cooldown이 실제로 `sleep()`을 사용했는지는 확인되지 않았다. `monitor.sh`의 `sleep 1`과 혼동하지 않는다.

**코드 수준 개선 제안(미구현):** CPU 집약 작업 분할 및 협력적 양보, 부하 조절 로직과 OS 실제 `%CPU` 비교 계측, Watchdog의 임계치·초과 지속시간을 설정과 분리해 명문화, SIGTERM 직전 메시지 flush 및 PID·원인 로그 구조화.

## 5. Deadlock — 살아 있지만 멈춘 프로세스

**실제 증거:** [Before 앱 로그](evidence/deadlock/before/app.log) · [Before PID/TID/CPU/RSS](evidence/deadlock/before/process-state.log) · [After 앱 로그](evidence/deadlock/after/app.log) · [보고서](report/03-deadlock-incident.md) · [상태 화면](evidence/deadlock/05.deadlock-process-before.png) · [BLOCKED 화면](evidence/deadlock/05.deadlock-before-blocked.png) · [After 화면](evidence/deadlock/05.deadlock-after.png)

### 5.1 자원 점유·대기의 시간순 근거

```text
2026-11-14 00:49:32,060 [INFO] [AgentWorker][Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
2026-11-14 00:49:32,061 [INFO] [AgentWorker][Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
2026-11-14 00:49:34,072 [INFO] [AgentWorker][Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
2026-11-14 00:49:34,074 [INFO] [AgentWorker][Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
```

**자원 의존 관계:** Thread 1은 A 보유→B 요구, Thread 2는 B 보유→A 요구. 서로 상대방이 가진 락이 풀리기를 기다리는 **A→B→A 순환 대기**다.

| PID / TID 상태 | 2026-11-14 00:51:58 KST | 00:52:03 KST (5초 후) |
|---|---|---|
| 부모 PID 2652 | STAT=S, CPU 0.0%, RSS 920KB | 동일 |
| 자식 PID 2654 | STAT=SNl, CPU 0.0%, RSS 16,300KB | 동일 |
| 자식의 TID | 2654, 2660, 2661 | 모두 유지 |
| 작업 로그 | 마지막 `BLOCKED` 로그가 00:49:34.074 | 이후 작업 완료 로그 없음 |

마지막 `BLOCKED` 기록(00:49:34.074)부터 관측 종료(00:52:03)까지 **약 149초** 동안 프로세스가 살아 있었으며, 종료 구간에서 5초 간 CPU와 RSS가 정체되었다. 이는 **전체 멈춤의 하한 관측 근거**일 뿐, 프로세스가 그 이후에도 영원히 멈춘다고 계측한 것은 아니다. `ps -L`에서 식별된 TID를 애플리케이션 로그의 Thread 1·2 이름과 **일대일로 대응시키는 증거는 없다**.

**Deadlock 4가지 필요 조건:**

1. **상호 배제(Mutual Exclusion):** 한 번에 하나의 스레드만 락이 보호하는 자원을 점유한다.
2. **점유 대기(Hold and Wait):** 이미 획득한 락을 보유하면서 다른 락을 기다린다.
3. **비선점(No Preemption):** 락 소유자가 해제하기 전에는 다른 스레드가 임의로 회수하지 못한다(일반적인 락 가정; 내부 구현 확인은 별도).
4. **순환 대기(Circular Wait):** Thread 1과 Thread 2가 서로의 락 해제를 기다린다.

**스택 트레이스 수집 여부:** 원본 증거에는 **스레드별 호출 스택 덤프가 없다.** 대신 타임스탬프가 있는 LOCK ACQUIRED→WAITING/BLOCKED의 순서, `ps -L`의 TID 존재와 CPU·RSS 정체를 결합해 추론했다. **스택 트레이스를 수집했다고 주장하지 않는다.** 향후에는 스레드 덤프 지원 도구·런타임 진단 기능이 허용되는 환경에서 추가 수집을 검토한다.

### 5.2 회피 전후 비교 (#6)

| 항목 | Before: true | After: false |
|---|---|---|
| MEMORY_LIMIT / CPU_MAX_OCCUPY | 512MB / 40% | 동일 |
| 관측된 실험 | 교착상태 1회 재현 | 정상 완료 1회 확인 |
| 작업 상태 | 2개의 `BLOCKED` 로그 이후 완료 기록 없음 | `All tasks completed` |
| 진행 시간 | `BLOCKED` 이후 관측 종료까지 약 149초 동안 작업 정체 | Scheduler 시작 01:00:48.356 → 완료 01:00:49.132 = **0.776초** |
| 결과 | 프로세스 생존, 작업 정체 | 정상 작업 완료, 이후에도 로그 지속 |

재현·회피는 **각 조건에서 확보한 1회의 대표 실행**에 근거한다. 재현 성공률을 계산할 만큼 반복 실험한 것은 아니다. `MULTI_THREAD_ENABLE=false`는 동시 처리 경로를 우회하는 임시 해결이며, 실제 코드에서는 락 획득 순서를 통일하거나 타임아웃·실패 시 안전한 복구를 설계해야 한다.

**자주 묻는 차이:** After 로그에서 `Thread-B → Thread-C → Thread-A`가 순차 완료된 것은 **Scheduler의 실제 작업 실행 순서**다. 사용자가 B→C→A 순서를 지정한 증거도, **Lock A→B 획득 순서를 코드에서 통일한 증거도 아니다.** 왜 하필 B→C→A가 선택되었는지는 로그만으로 알 수 없다. **작업(Task)의 실행 순서**와 **동시에 실행되는 스레드의 Lock 획득 순서**는 별개의 개념이다.

## 6. 장애 탐지 기준 및 향후 관제 개선

아래 수치는 **제안하는 운영 알림 기준이며 실제로 구현하거나 검증한 수치는 아니다.** 실제 서비스에서는 평상시 부하·하드웨어·업무별 SLO에 맞춰 조정한다.

| 대상 | 경보·의심 기준(예시) | 후속 확인 |
|---|---|---|
| 메모리 증가 | RSS가 10초 동안 50MB 이상 증가하는 현상이 반복 | 누적 증가·프로세스 수명·MemoryGuard 로그 대조 |
| CPU 급상승 | 0.1초 `top`에서 40% 이상인 구간 포착 | 1초 평균·반복 횟수·워커 로그와 함께 판단 |
| 무응답 의심 | PID 존재 + 10초 이상 CPU/RSS 변화 미미 + 작업 완료/진행 로그 없음 | `ps -L`, 스레드 락 대기 로그로 교착상태인지 추가 검증 |
| Watchdog 종료 | `CPU Threshold Violated` 또는 `WATCHDOG` 발생 | 해당 PID, 발생시각, SIGTERM 추적 저장 |

**탐지 개선 제안(미구현):** (1) 이전·현재 RSS와 타임스탬프를 저장해 MB/초 단위 증가 속도를 계산한다. (2) 10초 50MB 증가 같은 **예시 기준이 N회 연속 발생**하면 경고를 생성한다(일시 급증은 오탐 방지). (3) 이메일·메신저·운영 관제에 PID/발생 시각/최근 측정치를 알리고, (4) 로그 회전·실행별 `run_id`·측정 주기 옵션·프로세스 헬스체크를 추가한다. RSS는 정상 캐시 증가로도 늘 수 있으므로 **증가 추세 자체가 메모리 누수 확정은 아니다.** CPU·RSS 정체만으로도 Deadlock을 확정하지 않는다.

**현재 `monitor.sh`에 없는 기능:** 자동 경보, RSS 증가 속도 계산, 실행별 별도 로그 경로, 스레드 덤프, 서비스 응답시간 측정. 표의 기준은 **모두 제안이며 실제 동작·검증 결과가 아니다.**

## 7. 심각도, 동시 장애 우선순위 및 예방

**판정 기준 제안 — 이번 실습에 실제로 배정했던 운영 장애 등급은 아님.**

| 등급 | 예시 영향 범위 | 우선 대응 |
|---|---|---|
| S1 (긴급) | 서비스 완전 중단, 데이터 유실·무결성 위험, 복구 불가 | 영향 격리·상태 및 로그 보존·즉시 복구 |
| S2 (높음) | 주요 기능 응답 지연, 반복적인 프로세스 재시작 | 병목 원인 진단·용량 및 설정 완화 |
| S3 (보통) | 사용자 영향 없는 경고, 선제 대응 가능한 증가 추세 | 추세 관찰·예방 작업 계획 |

**"세 장애 중 가장 치명적인 것"에 대한 평가 답변 예시:** 이번 실험에서 **OOM을 가장 큰 확산 위험으로 선정**할 수 있다. 통제되지 않은 메모리 누적은 가용 RAM을 감소시켜 다른 프로세스까지 영향을 줄 수 있기 때문이다. 이번 관측에서는 MemoryGuard가 해당 프로세스를 자체 종료했으므로 **시스템 전체 메모리 고갈을 실제 확인한 것은 아니다.** 서비스 전체가 Deadlock으로 멈춘 상황이라면 Deadlock을 더 우선할 수 있다. 따라서 "항상 OOM이 가장 치명적"이라고 단정하지 않는다. **예방:** OOM은 참조·할당 누적 제거와 캐시·자료구조 크기 제한, CPU는 불필요한 연산 최적화·부하 제어, Deadlock은 Lock 순서 통일·타임아웃 설계가 핵심이다.

**OOM과 Deadlock 동시 발생 가정 — 대응 예시:** 두 증상의 PID/시각/로그를 먼저 확보한다. **OOM으로 반복 종료·가용 메모리 급감 및 타 서비스 확산 위험이 있는 상황**이라면 메모리 압박을 먼저 완화·격리한 뒤, 살아 있지만 멈춘 작업의 A↔B Lock 대기 관계를 분석하고 동시 처리 비활성화 등으로 우회한다. 반대로 Deadlock이 결제·데이터 무결성을 위협하는 S1 장애이고 OOM이 경고 수준이라면 Deadlock을 먼저 조치한다. **실제로 동시 재현 실험을 수행한 것은 아니다.**

**여러 장애가 동시에 나타날 때의 판단 순서(제안):**

1. **서비스 영향**(중단/무응답/지연), **데이터 위험**, **확산 가능성**으로 우선순위를 정한다. 장애 이름만으로 무조건 OOM→CPU→Deadlock 순서로 고정하지 않는다.
2. 즉시 PID, 시각, `ps/top` 출력 및 원본 로그를 보존한다. 증거 보존 전에 습관적으로 전체 시스템을 재부팅하지 않는다.
3. PID 존재 여부, 진행 로그, CPU/RSS 추세, Watchdog/MemoryGuard/락 대기 로그를 대조하여 서로 다른 증상을 구분한다.
4. 해당 장애의 **최소 영향 완화책**(메모리 한도 임시 상향, CPU 임계 설정 하향, 동시 처리 비활성화)을 적용하고 같은 지표로 검증한다.
5. 반복 재현·근본 원인 분석·개선 작업을 Issue로 남기고 추후 코드 변경을 검증한다.

**예방·코드 개선 제안(미구현):** OOM은 할당 상한·캐시 TTL·참조 해제·프로파일링, CPU는 처리 단위 분할·부하 제어·Watchdog 경보, Deadlock은 락 순서 통일·임계 구역 최소화·타임아웃·예외 시 자원 해제. 제공 바이너리는 수정하지 않았으며, 해당 제안은 **패치 완료**를 의미하지 않는다. 미션 제약을 준수하여 바이너리 역공학을 제출용 절차로 사용하지 않는다.

## 8. GitHub Issue 보고서·육하원칙

세 보고서는 모두 **`[Bug] 장애 유형 - 요약`** 제목과 다음 구조를 따른다.

| 공통 섹션 | 포함 내용 | 육하원칙 연계 |
|---|---|---|
| `1. Description` | 누가·언제·어디서 무엇을 겪었는지 | 누가 / 언제 / 어디서 / 무엇을 |
| `2. Evidence & Logs` | 실제 로그, 타임스탬프·PID, 시스템 명령어와 스크린샷, 재현 조건 | 어떻게 |
| `3. Root Cause Analysis` | 기술적 원인과 OS 동작 원리, 확인 근거·한계 | 왜 |
| `4. Workaround & Verification` | 변경한 설정값, Before/After, 완화 효과·재발 여부 | 어떻게 조치/검증했는지 |

- [OOM 이슈 형식 보고서](report/01-oom-incident.md)
- [CPU 이슈 형식 보고서](report/02-cpu-incident.md)
- [Deadlock 이슈 형식 보고서](report/03-deadlock-incident.md)

위 3개는 **GitHub Issue 형식의 Markdown 보고서**다. ZIP에는 실제 GitHub Issue의 **등록 번호·URL을 확인할 수 있는 증거가 없다.** `report/*.md` 작성과 GitHub의 **실제 Issues 등록**은 별도 작업이다. 평가에서 이슈 생성 자체를 요구한다면 GitHub Issues에 동일한 내용을 등록하고 번호·URL을 추가해야 한다. 보고서 본문의 증거 링크는 **저장소 내 Markdown 파일 위치 기준**이다.

## 9. 회고와 다음 실험 자동화 계획

**실제로 수행한 개선:** OOM·CPU·Deadlock의 원본 로그 및 스크린샷을 `evidence/`에 보존했고, CPU의 1초 샘플에서 확인되지 않던 짧은 피크를 `top -d 0.1`로 추가 측정했으며, Watchdog의 터미널 출력을 `script`로 확보했다.

**다음 실험에서 바꿀 점(제안, 미구현):**

- 한 실행마다 `run_id`, 환경변수, 시작·종료 시간, 부모·자식 PID 및 종료 코드가 같은 폴더에 기록되도록 래퍼 스크립트를 만든다.
- `monitor.sh`의 고정 `monitor.log` 덮어쓰기를 피하고, 실행마다 다른 경로에 바로 저장하며 가능하면 주기를 CLI 옵션으로 지원한다.
- 재현 설정을 데이터로 관리하여 자동 실행→측정→원본 보존→정량 비교를 한 번의 워크플로로 연결한다.
- OOM의 실제 PID elapsed, CPU의 응답지연·처리량, Deadlock의 스레드 호출 스택을 지원 도구와 허용 범위 안에서 추가 수집한다.
- 한 번의 성공만으로 재현률을 단정하지 않고 각 조건을 3회 이상 반복해 분포·편차를 보고한다.