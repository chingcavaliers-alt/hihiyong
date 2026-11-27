#!/usr/bin/env bash
# 看日誌直到：一輪結束（BR_STATS / BR_END）、出問題、或 45 分鐘。印出這段期間打王相關的紀錄（跨日也看得到）。
# 用法：bash watch.sh [管理程式資料夾]
here="$(cd "$(dirname "$0")" && pwd)"
app="${1:-$(powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$here/find_app.ps1")" 2>/dev/null | tr -d '\r')}"
[ -z "$app" ] && { echo "找不到管理程式資料夾"; exit 1; }
L="$(cygpath -u "$app")/Logs"
t0=$(date '+%Y-%m-%d %H:%M:%S')
pat='BR_STATS|BR_END|BR_FAIL|BR_FAKE_ONLINE|BR_INSTANCE|BR_FORCE_IDLE|暫停 30 分鐘|SOFT_DISCONNECT_CONFIRMED|RECOVERY_START'
new() { cat "$L/HIHIYONG_$(date -d yesterday +%Y-%m-%d).log" "$L/HIHIYONG_$(date +%Y-%m-%d).log" 2>/dev/null | awk -v t="$t0" 'substr($0,1,19) > t'; }
for i in $(seq 1 450); do
  if new | grep -qE "$pat"; then break; fi
  sleep 6
done
sleep 25
new | grep -E "\| (BR_(FAIL|FINISH|LOOT|LOOT_CHECK|STATS|END|LOOP|START|ENTERED|FORCE_IDLE|PAUSE|RESUME|WAIT|LEAVE|FAKE_ONLINE|INSTANCE)|BL_FAIL|RECOVERY_(START|OK|FAIL)|SOFT_DISCONNECT_CONFIRMED|PARTY_(JOIN|FAIL))" | grep -v "MBOX_RELOCK" | cut -c1-300
echo "== now $(date +%T)"
