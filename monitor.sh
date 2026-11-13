#!/usr/bin/env bash

# 관제할 프로세스 PID를 인자로 받습니다.
if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+$ ]]; then
    echo "사용법: ./monitor.sh <PID>"
    exit 1
fi

PID="$1"
LOG_FILE="$HOME/agent-app-leak/logs/monitor.log"

# 관제 대상 프로세스의 존재 여부를 확인합니다.
if ! ps -p "$PID" -o pid= >/dev/null 2>&1; then
    echo "오류: PID $PID 프로세스가 존재하지 않습니다."
    exit 1
fi

# 로그 파일에 CSV 헤더를 작성합니다.
echo "timestamp,pid,cpu_percent,rss_kb,state" > "$LOG_FILE"

echo "모니터링 시작: PID=$PID"
echo "로그 파일: $LOG_FILE"

# 프로세스가 종료될 때까지 1초 간격으로 관제합니다.
while true; do
    SAMPLE=$(ps -p "$PID" -o pcpu= -o rss= -o stat= 2>/dev/null) || break

    read -r CPU RSS STATE <<< "$SAMPLE"

    # 종료된 프로세스 또는 좀비 프로세스라면 관제를 중단합니다.
    if [[ -z "$STATE" || "$STATE" == Z* ]]; then
        break
    fi

    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    echo "$TIMESTAMP,$PID,$CPU,$RSS,$STATE" | tee -a "$LOG_FILE"

    sleep 1
done

echo "모니터링 종료: PID=$PID"
