"""由「執行中的遊戲」推算新版 game.exe 的資料位置（沒有對應的 Game.pdb 時的後備做法）。

遊戲小改版時，全域物件（GLGaeaClient、背包表、好友、大地圖視窗…）和虛擬函式表的位置會整體平移，
但結構內部的欄位偏移通常不變。這支工具拿「上一個已驗證的版本」(offsets_db\\<Build>.ini) 當參考，
在執行中的遊戲記憶體裡找出每個全域物件的新位置，逐項用資料內容驗證（角色名字 / 血量、道具表、字串表、
視角矩陣、好友表、視窗名稱…），全部通過才輸出；任何一項對不上就失敗，不輸出猜的結果。

只讀遊戲記憶體（OpenProcess 0x0410），不寫入、不注入。
用法：python -I derive_game_offsets.py --exe game.exe --pid 1234 [--pid 5678] --out 輸出.ini [--db offsets_db]
"""
import argparse
import ctypes
import re
import struct
import sys
from ctypes import wintypes
from datetime import datetime
from pathlib import Path

TOOL_VERSION = 31          # 要和參考 INI / 管理器 GAME_OFFSETS_TOOL_VERSION 相同
SEARCH_GAEA = 0x300000     # 找 GLGaeaClient 時，相對參考位置最多平移多遠
SEARCH_NEAR = 0x6000       # 其他全域物件相對 Gaea 平移量的搜尋範圍
SEARCH_VFT = 0x100000      # 虛擬函式表平移量上限

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
psapi = ctypes.WinDLL("psapi")
k32.OpenProcess.restype = ctypes.c_void_p


class Derive(Exception):
    pass


# ----------------------------------------------------------------- 讀遊戲記憶體
def rd(h, addr, n):
    buf = ctypes.create_string_buffer(n)
    got = ctypes.c_size_t()
    if not k32.ReadProcessMemory(ctypes.c_void_p(h), ctypes.c_void_p(addr), buf, n, ctypes.byref(got)) or got.value != n:
        return None
    return buf.raw


def rd_chunks(h, addr, n):
    out = bytearray()
    off = 0
    while off < n:
        c = min(0x10000, n - off)
        d = rd(h, addr + off, c)
        out += d if d else b"\0" * c
        off += c
    return bytes(out)


def u64(h, a):
    d = rd(h, a, 8)
    return struct.unpack("<Q", d)[0] if d else None


def i32(h, a):
    d = rd(h, a, 4)
    return struct.unpack("<i", d)[0] if d else None


def u32(h, a):
    d = rd(h, a, 4)
    return struct.unpack("<I", d)[0] if d else None


def isptr(h, q):
    return bool(q) and 0x10000 < q < 0x7FFFFFFFFFFF and rd(h, q, 8) is not None


class Game:
    def __init__(self, pid):
        self.pid = pid
        self.h = k32.OpenProcess(0x0410, 0, pid)
        if not self.h:
            raise Derive(f"打不開遊戲行程 {pid}")
        mods = (ctypes.c_void_p * 1)()
        need = wintypes.DWORD()
        psapi.EnumProcessModules(ctypes.c_void_p(self.h), mods, 8, ctypes.byref(need))
        self.base = mods[0]
        hdr = rd(self.h, self.base, 0x1000)
        if not hdr or hdr[:2] != b"MZ":
            raise Derive("讀不到 game.exe 標頭")
        pe = struct.unpack_from("<I", hdr, 0x3C)[0]
        n = struct.unpack_from("<H", hdr, pe + 6)[0]
        opt = struct.unpack_from("<H", hdr, pe + 20)[0]
        self.build = f"{struct.unpack_from('<I', hdr, pe + 8)[0]:08X}-{struct.unpack_from('<I', hdr, pe + 0x50)[0]:X}"
        self.secs = {}
        so = pe + 24 + opt
        for i in range(n):
            nm, vs, va, rs, ro = struct.unpack_from("<8sIIII", hdr, so + i * 40)
            self.secs.setdefault(nm.rstrip(b"\0").decode(errors="replace"), []).append((va, vs))
        for need_sec in (".data", ".rdata", ".text"):
            if need_sec not in self.secs:
                raise Derive(f"game.exe 沒有 {need_sec} 區段")
        self.data_va, self.data_size = self.secs[".data"][0]
        self.rdata = self.secs[".rdata"][0]
        self.text = [(va, va + vs) for va, vs in self.secs[".text"]]
        self.data = rd_chunks(self.h, self.base + self.data_va, self.data_size)

    def in_rdata(self, rva):
        return self.rdata[0] <= rva < self.rdata[0] + self.rdata[1]

    def in_text(self, rva):
        return any(a <= rva < b for a, b in self.text)

    def vft_of(self, addr):
        """物件第一個 qword（虛擬函式表位址）轉成 RVA；不像虛擬函式表就回 None。"""
        q = u64(self.h, addr)
        if q is None:
            return None
        rva = q - self.base
        return rva if self.in_rdata(rva) else None

    def looks_like_vft(self, rva):
        """虛擬函式表：連續幾個 qword 都指向 .text。"""
        d = rd(self.h, self.base + rva, 32)
        if not d:
            return False
        return all(self.in_text(q - self.base) for q in struct.unpack("<4Q", d))


# ----------------------------------------------------------------- 參考 INI
def read_ini(path):
    vals = {}
    for line in Path(path).read_text(encoding="utf-16").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            vals[k.strip()] = v.strip()
    return vals


def pick_reference(db, build):
    """offsets_db 裡最接近目標版本、Status=OK、工具版本相同的一份。"""
    want = int(build.split("-")[0], 16)
    best = None
    for f in Path(db).glob("*.ini"):
        try:
            v = read_ini(f)
        except Exception:
            continue
        if v.get("Status") != "OK" or v.get("Build") == build or "GaeaInstanceRva" not in v:
            continue
        if not v.get("ToolVersion", "").isdigit() or int(v["ToolVersion"]) != TOOL_VERSION:
            continue
        try:
            stamp = int(v["Build"].split("-")[0], 16)
        except Exception:
            continue
        key = (stamp <= want, -abs(want - stamp))   # 優先「比目標舊、最接近」的版本
        if best is None or key > best[0]:
            best = (key, v)
    if not best:
        raise Derive("offsets_db 裡沒有可當參考的已知版本位置資料")
    return best[1]


# ----------------------------------------------------------------- 找各個全域物件
class Finder:
    def __init__(self, g, ref):
        self.g, self.ref = g, ref
        self.H = lambda key: int(ref[key].split("|")[0], 16)

    def has_off(self, *names):
        return all(n in self.ref for n in names)

    def data_u64(self, rva):
        i = rva - self.g.data_va
        if i < 0 or i + 8 > len(self.g.data):
            return None
        return struct.unpack_from("<Q", self.g.data, i)[0]

    # GLGaeaClient：角色名字、血量、地圖
    def valid_gaea(self, rva):
        g, H = self.g, self.H
        i = rva - g.data_va
        need = H("CharOffset") + max(H("HpMaxOffset"), H("CharNameOffset") + 40, 0x20)
        if i < 0 or i + need >= len(g.data) or i + H("LandPtrOffset") + 8 >= len(g.data):
            return False
        q = struct.unpack_from("<Q", g.data, i)[0]
        if not g.in_rdata(q - g.base):
            return False
        c = i + H("CharOffset")
        hp = struct.unpack_from("<i", g.data, c + H("HpNowOffset"))[0]
        mx = struct.unpack_from("<i", g.data, c + H("HpMaxOffset"))[0]
        if not (0 < hp <= mx <= 2_000_000_000):
            return False
        raw = g.data[c + H("CharNameOffset"):c + H("CharNameOffset") + 34].split(b"\0")[0]
        if not (1 <= len(raw) <= 33):
            return False
        try:
            name = raw.decode("cp950")
        except UnicodeDecodeError:
            return False
        if not name.isprintable():
            return False
        land = struct.unpack_from("<Q", g.data, i + H("LandPtrOffset"))[0]
        if not isptr(g.h, land):
            return False
        mid = i32(g.h, land + H("LandMapIdOffset"))
        return mid is not None and 0 < mid < 100000

    def find_gaea(self):
        ref = self.H("GaeaInstanceRva")
        hits = []
        for d in range(-SEARCH_GAEA, SEARCH_GAEA + 1, 8):
            if self.valid_gaea(ref + d):
                hits.append(d)
        if not hits:
            raise Derive("找不到 GLGaeaClient（角色可能還沒登入遊戲）")
        return min(hits, key=abs)

    # 其他全域物件
    def nearest(self, key, validator, around, span=SEARCH_NEAR):
        ref = self.H(key)
        hits = []
        for d in range(around - span, around + span + 1, 8):
            try:
                if validator(ref + d):
                    hits.append(d)
            except (struct.error, TypeError):
                pass
        if not hits:
            return None
        return min(hits, key=lambda d: abs(d - around))

    def v_itemman(self, rva):
        g, H = self.g, self.H
        arr = self.data_u64(rva + H("ItemManPpItemOffset"))
        if not isptr(g.h, arr):
            return False
        d = rd(g.h, arr, 0x400 * 8)
        if not d:
            return False
        ptrs = struct.unpack("<1024Q", d)
        if sum(1 for q in ptrs if isptr(g.h, q)) < 200:
            return False
        names = 0
        for q in ptrs[1:40]:
            it = u64(g.h, q) if q else None
            s = rd(g.h, it + H("ItemNameOffset"), 12) if it else None
            if s and re.match(rb"IN_\d{3}_\d{3}\x00", s):
                names += 1
        return names >= 3

    def v_strtable(self, rva):
        g, H = self.g, self.H
        head = self.data_u64(rva + H("ItemStringMapOffset"))
        size = self.data_u64(rva + H("ItemStringMapOffset") + 8)
        return isptr(g.h, head) and size is not None and 1000 < size < 5_000_000

    def v_viewport(self, rva):
        g, H = self.g, self.H
        if g.vft_of(g.base + rva) is None:
            return False
        r = rd(g.h, g.base + rva + H("ViewPortRectOffset"), 16)
        if not r:
            return False
        x, y, w, hh = struct.unpack("<4i", r)
        if not (x == 0 and y == 0 and 320 <= w <= 8000 and 240 <= hh <= 8000):
            return False
        m = rd(g.h, g.base + rva + H("ViewMatrixOffset"), 12)
        return bool(m) and all(abs(v) <= 1.001 for v in struct.unpack("<3f", m))

    def v_inner(self, rva):
        g, H = self.g, self.H
        if g.vft_of(g.base + rva) is None:
            return False
        ok = 0
        for key in ("InnerPartyWindowOffset", "InnerFriendWindowOffset", "InnerBusWindowOffset",
                    "InnerDialogueWindowOffset", "InnerInvWindowOffset", "InnerNewMapWindowOffset"):
            w = u64(g.h, g.base + rva + H(key))
            nm = rd(g.h, w + H("UiNameOffset"), 12) if isptr(g.h, w) else None
            if nm and (nm.startswith(b"BASIC_WINDOW") or nm.startswith(b"BASE_WINDOW")):
                ok += 1
        return ok >= 4

    def v_stage(self, rva):
        g, H = self.g, self.H
        if g.vft_of(g.base + rva) is None:
            return False
        return isptr(g.h, self.data_u64(rva + H("GlobalStageActiveOffset"))) and isptr(g.h, self.data_u64(rva + H("GlobalStageLobyOffset")))

    def v_friend(self, rva):
        g, H = self.g, self.H
        head = self.data_u64(rva + H("FriendMapOffset"))
        cnt = self.data_u64(rva + H("FriendMapOffset") + 8)
        if not isptr(g.h, head) or cnt is None or cnt > 600:
            return False
        flag = rd(g.h, head + 0x19, 1)
        return bool(flag) and flag[0] == 1

    def v_party(self, rva):
        g, H = self.g, self.H
        pid_ = self.data_u64(rva + H("PartyIdOffset"))
        vb = self.data_u64(rva + H("PartyMapOffset"))
        ve = self.data_u64(rva + H("PartyMapOffset") + 8)
        if pid_ is None or vb is None or ve is None:
            return False
        if (pid_ & 0xFFFFFFFF) != 0xFFFFFFFF and (pid_ & 0xFFFFFFFF) > 1_000_000:
            return False
        if vb == 0 and ve == 0:
            return (pid_ & 0xFFFFFFFF) == 0xFFFFFFFF
        sz = H("PartyEntrySize")
        return isptr(g.h, vb) and ve >= vb and (ve - vb) % sz == 0 and (ve - vb) // sz <= 16

    def v_quick(self, rva):
        n = self.H("QuickKeysCount")
        d = rd(self.g.h, self.g.base + rva, 4 * n)
        if not d:
            return False
        v = struct.unpack("<%di" % n, d)
        return all(0 < x < 256 for x in v) and len(set(v)) == len(v)


# ----------------------------------------------------------------- 虛擬函式表
def crow_vft(g, f, land, list_key="LandCrowListOffset"):
    """怪物（或採集物，list_key 換成 LandMaterialListOffset）清單裡最常見的虛擬函式表。"""
    H = f.H
    lst = land + H(list_key)
    amt = i32(g.h, lst)
    node = u64(g.h, lst + H("CrowListHeadOffset"))
    vs = {}
    for _ in range(min(amt or 0, 50)):
        if not node:
            break
        nb = rd(g.h, node, H("CrowNodeNextOffset") + 8)
        if not nb:
            break
        obj = struct.unpack_from("<Q", nb, H("CrowNodeDataOffset"))[0]
        node = struct.unpack_from("<Q", nb, H("CrowNodeNextOffset"))[0]
        r = g.vft_of(obj) if obj else None
        if r is not None:
            vs[r] = vs.get(r, 0) + 1
    return max(vs, key=vs.get) if vs else None


def window_vft(g, f, inner_rva, key):
    w = u64(g.h, g.base + inner_rva + f.H(key))
    return g.vft_of(w) if isptr(g.h, w) else None


def vft_delta(old_list, new_rva):
    d = new_rva - old_list[0]
    return d if abs(d) <= SEARCH_VFT else None


# ----------------------------------------------------------------- 推算
def derive_one(g, ref):
    f = Finder(g, ref)
    H = f.H
    deltas = {}
    log = []
    dg = f.find_gaea()
    deltas["GaeaInstanceRva"] = dg
    gaea_rva = H("GaeaInstanceRva") + dg
    for key, validator in (("ItemManInstanceRva", f.v_itemman), ("StringTableInstanceRva", f.v_strtable),
                           ("ViewPortInstanceRva", f.v_viewport), ("InnerInterfaceRva", f.v_inner),
                           ("GlobalStageRva", f.v_stage), ("FriendInstanceRva", f.v_friend)):
        d = f.nearest(key, validator, dg)
        if d is None:
            raise Derive(f"對不上 {key}")
        deltas[key] = d
    # 隊伍：和好友相鄰；沒有隊伍時資料很空，先試和好友同一個平移量
    df = deltas["FriendInstanceRva"]
    if f.v_party(H("PartyInstanceRva") + df):
        deltas["PartyInstanceRva"] = df
    else:
        d = f.nearest("PartyInstanceRva", f.v_party, df, 0x400)
        if d is None:
            raise Derive("對不上 PartyInstanceRva")
        deltas["PartyInstanceRva"] = d
    # 外介面：和內介面相鄰的固定距離
    di = deltas["InnerInterfaceRva"]
    for d in sorted(range(di - 0x200, di + 0x201, 8), key=lambda x: abs(x - di)):
        if g.vft_of(g.base + H("OuterInstanceRva") + d) is not None:
            deltas["OuterInstanceRva"] = d
            break
    else:
        raise Derive("對不上 OuterInstanceRva")
    # 快捷鍵：有固定的 6 個掃描碼
    if "QuickKeysRva" in ref:
        d = f.nearest("QuickKeysRva", f.v_quick, dg)
        if d is None:
            raise Derive("對不上 QuickKeysRva")
        deltas["QuickKeysRva"] = d
    # 每日任務狀態：打開過 T 視窗才有資料，只能靠前後已驗證的全域物件夾住（兩邊平移量相同才採用）
    if "DailyStateRva" in ref:
        old = H("DailyStateRva")
        lo = [(H(k), d) for k, d in deltas.items() if H(k) < old]
        hi = [(H(k), d) for k, d in deltas.items() if H(k) > old]
        if lo and hi:
            dlo = max(lo)[1]
            dhi = min(hi)[1]
            if dlo == dhi:
                deltas["DailyStateRva"] = dlo
    # 虛擬函式表
    vdelta = {}
    old_v = lambda key: [int(x, 16) for x in ref[key].split("|")]
    q = g.vft_of(g.base + gaea_rva)
    d = vft_delta(old_v("GaeaVftableRvas"), q) if q is not None else None
    if d is None:
        raise Derive("對不上 GaeaVftableRvas")
    vdelta["GaeaVftableRvas"] = d
    for key, inst in (("ViewPortVftableRvas", "ViewPortInstanceRva"), ("InnerInterfaceVftableRvas", "InnerInterfaceRva"),
                      ("OuterVftableRvas", "OuterInstanceRva")):
        if key in ref:
            q = g.vft_of(g.base + H(inst) + deltas[inst])
            d = vft_delta(old_v(key), q) if q is not None else None
            if d is None:
                raise Derive(f"對不上 {key}")
            vdelta[key] = d
    inner_rva = H("InnerInterfaceRva") + deltas["InnerInterfaceRva"]
    for key, off in (("PartyWindowVftableRvas", "InnerPartyWindowOffset"), ("ModalWindowVftableRvas", "InnerModalWindowOffset")):
        if key in ref:
            q = window_vft(g, f, inner_rva, off)
            d = vft_delta(old_v(key), q) if q is not None else None
            if d is None:
                raise Derive(f"對不上 {key}")
            vdelta[key] = d
    land = u64(g.h, g.base + gaea_rva + H("LandPtrOffset"))
    q = crow_vft(g, f, land) if isptr(g.h, land) else None
    if q is not None:
        d = vft_delta(old_v("CrowVftableRvas"), q)
        if d is not None:
            vdelta["CrowVftableRvas"] = d
    # 採集物：附近有採集物就直接看它的虛擬函式表（各個虛擬函式表的平移量不一定相同，這版 Material 就和別的不一樣）
    if "MaterialVftableRvas" in ref and "MaterialVftableRvas" not in vdelta and isptr(g.h, land):
        try:
            q = crow_vft(g, f, land, "LandMaterialListOffset")
        except KeyError:
            q = None
        d = vft_delta(old_v("MaterialVftableRvas"), q) if q is not None else None
        if d is not None:
            vdelta["MaterialVftableRvas"] = d
    # 沒有物件可看的（這張圖沒有怪 / 沒有採集物）：用其他已驗證的平移量當候選，只有「看起來像虛擬函式表」的候選才採用
    for key in ("CrowVftableRvas", "MaterialVftableRvas"):
        if key in vdelta or key not in ref:
            continue
        cands = sorted(set(vdelta.values()))
        ok = [c for c in cands if g.looks_like_vft(old_v(key)[0] + c)]
        if len(ok) != 1:
            if key == "MaterialVftableRvas":   # 只有採集功能用：附近沒有採集物又對不上就先留空，其他功能照常用
                continue
            raise Derive(f"無法確認 {key}（候選 {len(ok)} 個）")
        vdelta[key] = ok[0]
    return deltas, vdelta


def compose(ref, deltas, vdelta, build):
    out = {}
    unhandled = []
    for k, v in ref.items():
        if k in ("Status", "ToolVersion", "ResolvedAt", "Build", "Error"):
            continue
        if k in deltas:
            out[k] = f"0x{int(v, 16) + deltas[k]:X}"
        elif k in vdelta:
            out[k] = "|".join(f"0x{int(x, 16) + vdelta[k]:X}" for x in v.split("|"))
        elif re.search(r"Rvas?$", k):
            unhandled.append(k)
            if k == "DailyStateRva":
                continue
            if k == "MaterialVftableRvas":
                out["MaterialError"] = "新版推算時附近沒有採集物，無法確認採集物位置（採集功能暫不可用）"
                continue
            raise Derive(f"無法推算 {k}")
        else:
            out[k] = v
    if "DailyStateRva" in unhandled:
        out["DailyError"] = "新版推算時無法確認每日任務狀態位置"
    out = {"Build": build, **out}
    return out


def write_ini(path, values, status, error=""):
    lines = ["[GameOffsets]", f"Status={status}", f"ToolVersion={TOOL_VERSION}",
             f"ResolvedAt={datetime.now():%Y-%m-%d %H:%M:%S}"]
    if error:
        lines.append(f"Error={error}")
    lines += [f"{k}={v}" for k, v in values.items()]
    Path(path).write_text("\r\n".join(lines) + "\r\n", encoding="utf-16", newline="")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--exe", type=Path, required=True)
    ap.add_argument("--pid", type=int, action="append", required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--db", type=Path, required=True)
    args = ap.parse_args()
    build = ""
    try:
        errors = []
        result = None
        for pid in args.pid:
            try:
                g = Game(pid)
                build = g.build
                ref = pick_reference(args.db, build)
                deltas, vdelta = derive_one(g, ref)
                result = (compose(ref, deltas, vdelta, build), ref)
                break
            except Derive as e:
                errors.append(f"{pid}: {e}")
        if not result:
            raise Derive("；".join(errors) or "沒有可用的遊戲行程")
        values, ref = result
        values["DerivedFrom"] = ref["Build"]
    except Exception as exc:
        write_ini(args.out, {"Build": build}, "FAIL", f"推算失敗：{exc}".replace("\n", " "))
        print(f"FAIL {exc}", file=sys.stderr)
        return 1
    write_ini(args.out, values, "OK")
    if re.fullmatch(r"[0-9A-F]+-[0-9A-F]*[1-9A-F][0-9A-F]*", build):
        try:
            args.db.mkdir(parents=True, exist_ok=True)
            write_ini(args.db / f"{build}.ini", values, "OK")
        except OSError as exc:
            print(f"WARN 無法寫入已知版本資料夾：{exc}", file=sys.stderr)
    print(f"OK build={build} from={values['DerivedFrom']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
