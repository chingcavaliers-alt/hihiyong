#!/usr/bin/env bash
# 最近幾輪打王的統計：結束時間、參加角色數、打幾隻、一輪總時間、撿到幾個。用法：bash round_summary.sh [輪數=10] [管理程式資料夾]
here="$(cd "$(dirname "$0")" && pwd)"
n="${1:-10}"
app="${2:-$(powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$here/find_app.ps1")" 2>/dev/null | tr -d '\r')}"
[ -z "$app" ] && { echo "找不到管理程式資料夾"; exit 1; }
L="$(cygpath -u "$app")/Logs"
cat "$L/HIHIYONG_$(date -d yesterday +%Y-%m-%d).log" "$L/HIHIYONG_$(date +%Y-%m-%d).log" 2>/dev/null |
  grep -E "\| BR_STATS \||\| BR_LOOT \|" |
  awk -F'｜' '/BR_LOOT/ { loot=$2; next }
              /BR_STATS/ { t=substr($0,1,16); who=$3; c=gsub(/、/,"、",who)+1;
                           b="?"; if (match($0, /｜王 [0-9]+ 隻/)) { b=substr($0, RSTART, RLENGTH); gsub(/[^0-9]/,"",b) }
                           tot=$0; sub(/.*一輪總時間 /,"",tot);
                           printf "%s｜%d 隻角色｜王 %s 隻｜%s｜%s\n", t, c, b, tot, loot; loot="" }' | tail -n "$n"
