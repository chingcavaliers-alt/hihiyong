"""自動採礦監控摘要（讀管理程式日誌）：用法 py -3 -I tools/mining_status.py [角色名] [分鐘]"""
import sys, re, glob, os, datetime, subprocess
sys.stdout.reconfigure(encoding="utf-8")
name = sys.argv[1] if len(sys.argv) > 1 else "欸等欸"
LOGDIR = r"D:\HIHIYONG\Release\HIHIYONG\app\Logs"
files = sorted(glob.glob(os.path.join(LOGDIR, "HIHIYONG_20*.log")))[-2:]
lines = []
for f in files:
    with open(f, encoding="utf-8", errors="ignore") as fh:
        lines += fh.read().splitlines()[-40000:]
now = datetime.datetime.now()
def ts(l):
    try: return datetime.datetime.strptime(l[:19], "%Y-%m-%d %H:%M:%S")
    except Exception: return None
mine = [l for l in lines if f"| {name} |" in l]
print("現在", now.strftime("%m/%d %H:%M:%S"), "角色", name)
def last(pat):
    for l in reversed(mine):
        if re.search(pat, l): return l
def ago(l):
    t = ts(l) if l else None
    return f"{int((now - t).total_seconds())} 秒前" if t else "（沒有）"
for pat, label in [("MN_GATHER_START", "最後一次開始採集"), ("MN_GATHER_DONE", "最後一次採完"), ("MN_IN\b", "最後一次進礦場"), ("MN_KICKED", "最後一次被踢出"), ("MN_ENTERED", "最後一次進圖成功"), ("MN_STALL|MN_NOLOOT", "卡住 / 沒收穫通知"), ("MN_ERROR", "最後一次錯誤"), ("MN_BOSS_(START|DONE)", "王")]:
    l = last(pat)
    print(f"{label}: {ago(l)} | {(l or '')[20:150]}")
print("--- 最近 14 筆採礦相關 ---")
for l in [x for x in mine if re.search(r"MN_|RECOVERY|SOFT_DISCONNECT|DEATH|DAILY_(START|DONE|FAIL|WAIT)", x)][-14:]:
    print(l[:210])
rec = [l for l in lines if re.search(r"RECOVERY_(START|OK|FAIL)|SOFT_DISCONNECT_CONFIRMED|GAME_EXIT|PROCESS_GONE", l) and name in l][-4:]
if rec:
    print("--- 重新登入 / 假在線 ---")
    for l in rec: print(l[:200])
mgr = subprocess.run(["powershell", "-NoProfile", "-Command", "Get-CimInstance Win32_Process -Filter \"Name='AutoHotkey64.exe'\" | Where-Object { $_.CommandLine -match 'HIHIYONG_Multi' } | ForEach-Object { \"$($_.ProcessId) $($_.CreationDate)\" }"], capture_output=True, text=True).stdout.strip()
print("管理程式:", mgr or "（沒有在跑！）")
