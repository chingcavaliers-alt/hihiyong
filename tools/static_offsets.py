"""離線推算遊戲位置：只比對兩個 game.exe 檔（不用開遊戲、不用登入、不用 Game.pdb）。
原理：已知版本的每個全域物件 / 虛擬函式表，在程式碼裡都有幾處「lea / mov reg,[rip+位移]」的引用。
把這些引用前後的機器碼當特徵，到新版 exe 裡找到對應處，再從那裡的位移算出新位置；同一個位置至少要有 2 處引用算出相同結果才採用。
結果只是「候選」（Method=static、Verified=0），要等遊戲登入後用 derive_game_offsets 的驗證才算數。
用法：static_offsets.py --ref-exe 舊版game.exe --ref-ini 舊版.ini --exe 新版game.exe --out 候選.ini
"""
import argparse, re, struct, sys
from datetime import datetime
from pathlib import Path

TOOL_VERSION = 31
SIZES = [(24, 10), (16, 8), (10, 5), (6, 3)]   # (位移前幾個位元組, 位移後幾個位元組)
MAX_MATCH = 4                                   # 一個特徵在新版裡找到超過這麼多處就太鬆，不用


class Static(Exception):
    pass


class Pe:
    def __init__(self, path):
        self.b = Path(path).read_bytes()
        b = self.b
        pe = struct.unpack_from("<I", b, 0x3C)[0]
        n = struct.unpack_from("<H", b, pe + 6)[0]
        osz = struct.unpack_from("<H", b, pe + 20)[0]
        stamp = struct.unpack_from("<I", b, pe + 8)[0]
        size = struct.unpack_from("<I", b, pe + 24 + 56)[0]
        self.build = f"{stamp:08X}-{size:X}"
        self.secs = []
        for i in range(n):
            nm, vs, va, rs, ro = struct.unpack_from("<8sIIII", b, pe + 24 + osz + i * 40)
            self.secs.append((nm.rstrip(b"\0").decode(errors="replace"), va, vs, ro, rs))
        code = [s for s in self.secs if s[0] == ".text" and s[4] > 0x100000]
        if not code:
            raise Static("找不到 .text 區段")
        _, self.tva, _, ro, rs = code[0]
        self.text = b[ro:ro + rs]

    def section_of(self, rva):
        for nm, va, vs, ro, rs in self.secs:
            if va <= rva < va + vs:
                return nm
        return ""

    def refs(self):
        """(位置 p, 目標 rva)：modrm 是 rip 相對（mod=00 rm=101）的位移欄位。"""
        t, va = self.text, self.tva
        out = []
        for p in range(2, len(t) - 4):
            if (t[p - 1] & 0xC7) != 0x05:
                continue
            d = struct.unpack_from("<i", t, p)[0]
            out.append((p, va + p + 4 + d))
        return out


def ctx_regex(ctx_before, ctx_after):
    """機器碼特徵；call/jmp rel32 的位移和疑似 rip 相對的位移會隨版本變，用萬用字元。"""
    def mask(bs, ahead_ok):
        out, i = [], 0
        while i < len(bs):
            c = bs[i]
            if c in (0xE8, 0xE9) and i + 5 <= len(bs):
                out.append(re.escape(bytes([c])) + b".{4}")
                i += 5
            elif (c & 0xC7) == 0x05 and i > 0 and bs[i - 1] in (0x8B, 0x8D, 0x89, 0x83, 0x39, 0x3B, 0x03, 0x2B, 0x0B, 0x33, 0x85) and i + 5 <= len(bs):
                out.append(re.escape(bytes([c])) + b".{4}")
                i += 5
            else:
                out.append(re.escape(bytes([c])))
                i += 1
        return b"".join(out)
    return re.compile(mask(ctx_before, True) + b".{4}" + mask(ctx_after, False), re.S)


def read_ini(path):
    vals = {}
    for line in Path(path).read_text(encoding="utf-16").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            vals[k.strip()] = v.strip()
    return vals


def derive(ref_exe, ref_ini, new_exe):
    old, new = Pe(ref_exe), Pe(new_exe)
    ref = read_ini(ref_ini)
    if ref.get("Build") and ref["Build"] != old.build:
        raise Static(f"參考 exe 版本 {old.build} 和參考 INI 版本 {ref['Build']} 不同")
    old_refs = old.refs()
    new_t = new.text
    # 第一輪：每個位置各自投票。strong = 特徵在新版只找到 1 處、而且特徵裡不是都是 0xCC 填充（短小的函式很容易誤中別處）
    cand = {}   # (key, item_index) -> (tgt, 相符引用數, 是否有 strong, 舊 rva)
    for key, val in ref.items():
        if not re.search(r"Rvas?$", key):
            continue
        for ii, item in enumerate(val.split("|")):
            rva = int(item, 16)
            sites = [p for p, r in old_refs if r == rva]
            if not sites:
                raise Static(f"{key} {item} 在舊版程式碼裡找不到引用，無法比對")
            votes, strong = {}, set()
            for si, p in enumerate(sites):
                for b, a in SIZES:
                    if p - b < 0:
                        continue
                    ctx = old.text[p - b:p] + old.text[p + 4:p + 4 + a]
                    rx = ctx_regex(old.text[p - b:p], old.text[p + 4:p + 4 + a])
                    hits = []
                    for m in rx.finditer(new_t):
                        hits.append(m.start() + b)
                        if len(hits) > MAX_MATCH:
                            break
                    if not hits or len(hits) > MAX_MATCH:
                        continue
                    found = False
                    for q in hits:
                        d = struct.unpack_from("<i", new_t, q)[0]
                        tgt = new.tva + q + 4 + d
                        if new.section_of(tgt) != old.section_of(rva):   # 目標要落在同一種區段（資料 / 唯讀資料）
                            continue
                        votes.setdefault(tgt, set()).add(si)
                        found = True
                        if len(hits) == 1 and sum(1 for c in ctx if c != 0xCC) >= 12:
                            strong.add((tgt, si))
                    if found:
                        break   # 這個引用已有結果，不用再放寬
            ranked = sorted(votes.items(), key=lambda kv: -len(kv[1]))
            if not ranked:
                raise Static(f"{key} {item}：{len(sites)} 處引用，在新版裡一處都對不上")
            if len(ranked) > 1 and len(ranked[1][1]) == len(ranked[0][1]):
                raise Static(f"{key} {item}：兩個候選票數相同，無法決定")
            tgt = ranked[0][0]
            cand[(key, ii)] = (tgt, len(ranked[0][1]), any(t == tgt for t, _ in strong), rva, len(sites))
    # 第二輪：票數 >= 2 的直接採用；只有 1 票（但是 strong）的，要和已採用的位置有相同的平移量才採用
    sure = {k: v for k, v in cand.items() if v[1] >= 2}
    shifts = {v[0] - v[3] for v in sure.values()}
    result, notes = {}, []
    for key, val in ref.items():
        if not re.search(r"Rvas?$", key):
            continue
        outs = []
        for ii, item in enumerate(val.split("|")):
            tgt, n, strong, rva, total = cand[(key, ii)]
            if n < 2 and not (strong and (tgt - rva) in shifts):
                raise Static(f"{key} {item}：{total} 處引用只有 {n} 處對得上，也沒有其他位置佐證，不採用")
            outs.append(tgt)
            notes.append(f"{key} {item} → 0x{tgt:X}（{n}/{total} 處引用相符，平移 {tgt - rva:+#x}）")
        result[key] = "|".join(f"0x{x:X}" for x in outs)
    return new.build, ref, result, notes


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ref-exe", type=Path, required=True)
    ap.add_argument("--ref-ini", type=Path, required=True)
    ap.add_argument("--exe", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    try:
        build, ref, result, notes = derive(args.ref_exe, args.ref_ini, args.exe)
    except Exception as exc:
        print(f"FAIL {exc}", file=sys.stderr)
        return 1
    lines = ["[GameOffsets]", "Status=OK", f"ToolVersion={TOOL_VERSION}", f"ResolvedAt={datetime.now():%Y-%m-%d %H:%M:%S}", f"Build={build}"]
    for k, v in ref.items():
        if k in ("Status", "ToolVersion", "ResolvedAt", "Build", "Error", "DerivedFrom", "Method", "Verified", "DailyError"):
            continue
        lines.append(f"{k}={result.get(k, v)}")
    lines += [f"DerivedFrom={ref['Build']}", "Method=static", "Verified=0"]
    args.out.write_text("\r\n".join(lines) + "\r\n", encoding="utf-16", newline="")
    for n in notes:
        print(n)
    print(f"OK build={build} from={ref['Build']}（候選，尚未用遊戲驗證）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
