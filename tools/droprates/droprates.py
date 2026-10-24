"""HiHiYong2.0 怪物掉落率：從遊戲資料夾（唯讀）計算每張地圖每隻怪的掉落機率，輸出成管理程式讀的 JSON。

用法：
  python droprates.py --game F:\\HiHiYong2.0 --out <Stats\\DropRates>      # 有改版才重算（比對指紋）
  python droprates.py ... --force                                          # 強制重算
結束碼：0 = 已是最新或重算完成；1 = 失敗（訊息寫在 <out>\\last_error.txt）。

資料流程（2026-10 解析結果，見 HIHIYONG 記憶筆記）：
- data\\*.rcc 是 zip；每個項目 "BR9RCC01"|len|nonce|tag|密文，AES-256-GCM（AAD = 前 12 bytes），
  金鑰 = game.exe 資源 RT_RCDATA #50000。內層：u32 版本 + AES-ECB（CRijndael 版本金鑰），去掉結尾 0。
- crow.mnsf / item.isf / MapsList.mst / *.Lev 的內容再經過一張 256 bytes 的替換表；表在 game.exe 裡，
  位置會隨改版移動（10/24 從 RVA 0xA6AC60 搬到檔案位移 0xE25830），所以每次都重新搜尋並驗證。
- 掉落：GENRATE × fITEM_DROP_SCALE % 決定會不會掉；GENNUM 決定掉幾個；ITEMSPEC 權重 < 2 時 × fITEM_DROP_LOWER_SCALE，
  累加在 [0,100) 上（超出 100 的部分抽不到）；同一 spec 內的道具平均分配。只列材料與消耗品（裝備不計）。
"""
import argparse
import collections
import ctypes
import datetime
import hashlib
import json
import os
import re
import struct
import sys
import time
import traceback
import zipfile
from ctypes import wintypes

TOOL_VERSION = 1
SOURCES = ["game.exe", r"data\glogic\glogic.rcc", r"data\glogicserver\glogicserver.rcc", r"data\glogic\level.rcc"]
# 使用者常去的地圖（介面預設顯示這些；其餘在「全部地圖」）
FAVORITES = ["CDM 電算室2", "黑暗後裔集結區", "死神修煉場", "童話世界", "機械區", "魔術區", "裂變時空", "波斯宮",
             "異形空降區", "末日禁地島", "重力迴廊", "零號禁區", "冥神禁域"]
RIJ_KEYS = [b'fjiw239rnisf9342', b'0in123joydn11ps9', b'skrkrhtlvdj!@#wpfrmfjgrpgo!@#$qk',
            b'als!zjabsl@zpdltus#chlrkd^vmfaj*', b'ikrkrcnnsdi#!@dodutrmthriu$#@!gr', b'ukruu9nnsdi#^@wowut5kmhriu$6@!er']


# ---------------------------------------------------------------- 解密
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.LoadLibraryExW.restype = ctypes.c_void_p
k32.LoadLibraryExW.argtypes = [wintypes.LPCWSTR, ctypes.c_void_p, wintypes.DWORD]
k32.FindResourceW.restype = ctypes.c_void_p
k32.FindResourceW.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
k32.SizeofResource.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
k32.LoadResource.restype = ctypes.c_void_p
k32.LoadResource.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
k32.LockResource.restype = ctypes.c_void_p
k32.LockResource.argtypes = [ctypes.c_void_p]
k32.FreeLibrary.argtypes = [ctypes.c_void_p]
bc = ctypes.WinDLL("bcrypt")


class AUTH(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.ULONG), ("dwInfoVersion", wintypes.ULONG),
                ("pbNonce", ctypes.c_void_p), ("cbNonce", wintypes.ULONG),
                ("pbAuthData", ctypes.c_void_p), ("cbAuthData", wintypes.ULONG),
                ("pbTag", ctypes.c_void_p), ("cbTag", wintypes.ULONG),
                ("pbMacContext", ctypes.c_void_p), ("cbMacContext", wintypes.ULONG),
                ("cbAAD", wintypes.ULONG), ("cbData", ctypes.c_ulonglong), ("dwFlags", wintypes.ULONG)]


def asset_key(exe):
    h = k32.LoadLibraryExW(exe, None, 0x2 | 0x20)  # AS_DATAFILE | AS_IMAGE_RESOURCE
    if not h:
        raise RuntimeError("無法開啟 game.exe 讀取資源")
    try:
        r = k32.FindResourceW(h, ctypes.c_void_p(50000), ctypes.c_void_p(10))
        n = k32.SizeofResource(h, r) if r else 0
        if n != 32:
            raise RuntimeError("game.exe 找不到解密金鑰資源（改版可能換了加密方式）")
        return ctypes.string_at(k32.LockResource(k32.LoadResource(h, r)), n)
    finally:
        k32.FreeLibrary(h)


def _bcrypt(mode, key, data, auth=None):
    alg = ctypes.c_void_p()
    bc.BCryptOpenAlgorithmProvider(ctypes.byref(alg), "AES", None, 0)
    bc.BCryptSetProperty(alg, "ChainingMode", ctypes.create_unicode_buffer(mode), (len(mode) + 1) * 2, 0)
    k = ctypes.c_void_p()
    bc.BCryptGenerateSymmetricKey(alg, ctypes.byref(k), None, 0, key, len(key), 0)
    out = ctypes.create_string_buffer(max(1, len(data)))
    got = wintypes.ULONG()
    st = bc.BCryptDecrypt(k, ctypes.create_string_buffer(data, len(data)), len(data), auth, None, 0, out, len(data),
                          ctypes.byref(got), 0)
    bc.BCryptDestroyKey(k)
    bc.BCryptCloseAlgorithmProvider(alg, 0)
    if st:
        raise ValueError("BCryptDecrypt 0x%08X" % (st & 0xFFFFFFFF))
    return out.raw[:got.value]


def decrypt_entry(key, d):
    if d.startswith(b"BR9RCC01"):
        nb, tb, ab = [ctypes.create_string_buffer(x, len(x)) for x in (d[0xC:0x18], d[0x18:0x28], d[:12])]
        a = AUTH(ctypes.sizeof(AUTH), 1, ctypes.cast(nb, ctypes.c_void_p), 12, ctypes.cast(ab, ctypes.c_void_p), 12,
                 ctypes.cast(tb, ctypes.c_void_p), 16, None, 0, 0, 0, 0)
        d = _bcrypt("ChainingModeGCM", key, d[0x28:], auth=ctypes.byref(a))
    v = struct.unpack_from("<i", d, 0)[0] if len(d) >= 4 else 0
    if 1 <= v <= 6 and (len(d) - 4) % 16 == 0:
        d = _bcrypt("ChainingModeECB", RIJ_KEYS[v - 1], d[4:]).rstrip(b"\0")
    return d


class Archive:
    def __init__(self, path, key):
        self.z, self.key = zipfile.ZipFile(path), key
        self.names = {n.lower(): n for n in self.z.namelist()}

    def has(self, name):
        return name.lower() in self.names

    def read(self, name):
        return decrypt_entry(self.key, self.z.read(self.names[name.lower()]))


def find_table(exe_bytes, sample):
    """在 game.exe 裡找 256 bytes 的排列表，用 crow.mnsf 能不能解出怪物代碼來驗證。回傳反查表。"""
    cnt, dup, best = [0] * 256, 0, (0, None)
    body = sample[0x100:0x100 + 400000]
    for i, b in enumerate(exe_bytes):
        if cnt[b] == 1:
            dup += 1
        cnt[b] += 1
        if i >= 256:
            o = exe_bytes[i - 256]
            cnt[o] -= 1
            if cnt[o] == 1:
                dup -= 1
        if i >= 255 and dup == 0:
            t = exe_bytes[i - 255:i + 1]
            inv = bytearray(256)
            for k, x in enumerate(t):
                inv[x] = k
            hits = body.translate(bytes(inv)).count(b"CN_")
            if hits > best[0]:
                best = (hits, bytes(inv))
    if best[0] < 50:
        raise RuntimeError("game.exe 裡找不到資料替換表（改版可能換了編碼方式）")
    return best[1]


# ---------------------------------------------------------------- 解析
def parse_names(txt):
    out = {}
    for line in txt.decode("cp950", "replace").splitlines():
        p = line.split("\t")
        if len(p) >= 2 and p[0][:3] in ("IN_", "CN_"):
            out[p[0]] = p[1].strip()
    return out


def parse_crows(dec):
    crows, gen = {}, {}
    for rec in dec.split(b"\xed\xed\xed\xed"):
        m = re.search(rb"(..)(..)CN_(\d{3})_(\d{3})\x00", rec, re.S)
        if not m:
            continue
        key = struct.unpack("<HH", m.group(1) + m.group(2))
        crows[key] = "CN_%s_%s" % (m.group(3).decode(), m.group(4).decode())
        g = re.search(rb"\x03\x00\x00\x00.\x01\x00\x00[P<]\x00\x00\x00", rec, re.S)
        if not g:
            continue
        p = g.end() + 12
        n = struct.unpack_from("<I", rec, p)[0]
        gen[key] = rec[p + 4:p + 4 + n].rstrip(b"\0").decode("cp950", "replace")
    return crows, gen


def parse_items(dec):
    items = {}
    for rec in dec.split(b"\xed\xed\xed\xed"):
        m = re.search(rb"IN_(\d{3})_(\d{3})\x00", rec)
        if not m:
            continue
        g = re.search(rb"\x06\x00\x00\x00.\x01\x00\x00\x0c\x00\x00\x00(.{4})", rec, re.S)
        items["IN_%s_%s" % (m.group(1).decode(), m.group(2).decode())] = dict(
            spec=struct.unpack("<I", g.group(1))[0] if g else None,
            type=struct.unpack_from("<I", rec, m.end() + 34)[0] if m.end() + 38 <= len(rec) else -1)
    return items


def parse_maps(dec):
    maps = collections.OrderedDict()
    for m in re.finditer(rb"\x09\x01\x00\x00\x01(.)\x00\x00\x00([^\x00]+\.lev)\x00", dec, re.I | re.S):
        p = m.end()
        n = re.search(rb"(.)\x00\x00\x00([^\x00]{2,40})\x00(.)\x00\x00\x00[^\x00]*\.ogg", dec[p:p + 120], re.S | re.I)
        if n:
            maps.setdefault(n.group(2).decode("cp950", "replace"), m.group(2).decode())
    return maps


def parse_charclass(txt):
    s = txt.decode("cp949", "replace")
    def val(name, default):
        m = re.search(name + r"\s+([0-9.]+)", s)
        return float(m.group(1)) if m else default
    return val("fITEM_DROP_SCALE", 8.0), val("fITEM_DROP_LOWER_SCALE", 5.0)


def parse_gen(txt):
    g = dict(rate=0.0, nums=[], specs=[])
    for line in txt.decode("cp949", "replace").splitlines():
        w = line.split("//")[0].split()
        if not w:
            continue
        try:
            if w[0] == "GENRATE":
                g["rate"] = float(w[1])
            elif w[0] == "GENNUM":
                g["nums"].append((int(w[1]), float(w[2])))
            elif w[0] == "ITEMSPEC":
                g["specs"].append((int(w[1]), float(w[2])))
        except (IndexError, ValueError):
            pass
    return g


def gen_probs(g, scale, lower, lower_th=2.0):
    p_gen = min(1.0, g["rate"] * scale / 100)
    tot = sum(r for _, r in g["nums"]) or 100
    e_num = sum(n * r for n, r in g["nums"]) / tot if g["nums"] else 1
    acc, out = 0.0, {}
    for spec, w in g["specs"]:
        if w < lower_th:
            w *= lower
        lo, hi = acc, min(acc + w, 100.0)
        acc += w
        if hi > lo:
            out[spec] = out.get(spec, 0) + (hi - lo) / 100
    return p_gen, e_num, out


def level_mobs(raw, inv, crows, gen):
    x = raw[:0x84] + raw[0x84:].translate(inv)
    c = collections.Counter()
    for m in re.finditer(rb"\x01\x00\x00\x00(.)\x01\x00\x00(..)\x00\x00(?=[^\x00]{1,64}\x00)", x, re.S):
        if m.end() + 70 <= len(x):
            k = struct.unpack_from("<HH", x, m.end() + 65)
            if k in crows and gen.get(k):
                c[k] += 1
    return c


def compute(game):
    exe_path = os.path.join(game, "game.exe")
    key = asset_key(exe_path)
    glogic = Archive(os.path.join(game, SOURCES[1]), key)
    server = Archive(os.path.join(game, SOURCES[2]), key)
    level = Archive(os.path.join(game, SOURCES[3]), key)
    crow_raw = glogic.read("crow.mnsf")
    inv = find_table(open(exe_path, "rb").read(), crow_raw)
    crows, gen = parse_crows(crow_raw[:0x100] + crow_raw[0x100:].translate(inv))
    item_raw = glogic.read("item.isf")
    items = parse_items(item_raw[:0x100] + item_raw[0x100:].translate(inv))
    ml = glogic.read("MapsList.mst")
    maps = parse_maps(ml[:0x84] + ml[0x84:].translate(inv))
    crow_names = parse_names(glogic.read("CrowStrTable.txt"))
    item_names = parse_names(glogic.read("ItemStrTable.txt"))
    scale, lower = parse_charclass(server.read("default.charclass")) if server.has("default.charclass") else (8.0, 5.0)
    if len(crows) < 100 or len(items) < 100 or len(maps) < 20:
        raise RuntimeError("解析結果太少（怪物 %d、道具 %d、地圖 %d），改版可能換了資料格式" % (len(crows), len(items), len(maps)))

    spec_items = collections.defaultdict(list)
    for k, v in items.items():
        if v["spec"]:
            spec_items[v["spec"]].append(k)
    gen_cache = {}

    def gen_of(fn):
        if fn.lower() not in gen_cache:
            gen_cache[fn.lower()] = gen_probs(parse_gen(server.read(fn)), scale, lower) if server.has(fn) else None
        return gen_cache[fn.lower()]

    out, missing = collections.OrderedDict(), collections.Counter()
    for name, lev in maps.items():
        arc = level if level.has(lev) else glogic if glogic.has(lev) else None
        if not arc:
            continue
        c = level_mobs(arc.read(lev), inv, crows, gen)
        bygen = collections.OrderedDict()
        for k, n in c.most_common():
            bygen.setdefault(gen[k], []).append([crow_names.get(crows[k], crows[k]), n])
        groups = []
        for gens, mobs in bygen.items():
            per_item, tables = collections.Counter(), []
            for fn in gens.split(";"):
                fn = fn.strip()
                if not fn:
                    continue
                gp = gen_of(fn)
                if gp is None:
                    missing[fn] += 1
                    continue
                p_gen, e_num, sp = gp
                tables.append(dict(file=fn, chance=round(p_gen, 6), avg=round(e_num, 4)))
                for spec, ps in sp.items():
                    its = spec_items.get(spec, [])
                    for it in its:
                        if items[it]["type"] == 0:   # 裝備不計
                            continue
                        per_item[item_names.get(it, it)] += p_gen * e_num * ps / len(its)
            its = [[a, round(b, 8)] for a, b in per_item.most_common() if b > 0]
            if its:
                groups.append(dict(mobs=mobs, tables=tables, items=its))
        if groups:
            out[name] = dict(lev=lev, groups=groups)
    return out, dict(scale=scale, lower=lower, missing=dict(missing))


# ---------------------------------------------------------------- 版本與差異
def fingerprint(game):
    h = hashlib.sha1()
    for s in SOURCES:
        st = os.stat(os.path.join(game, s))
        h.update(("%s|%d|%d;" % (s, st.st_size, int(st.st_mtime))).encode())
    return h.hexdigest()[:16]


def flat(maps):
    """地圖 → 怪 → 道具 → 機率；用來比較兩個版本。"""
    d = {}
    for m, v in maps.items():
        for g in v["groups"]:
            for mob, _ in g["mobs"]:
                # 同一張地圖有同名的不同怪（例如兩種「綠能原石」）：依出現順序編號分開比，不會互相蓋掉。
                # （不用掉落表檔名當鍵：改版常常替怪加一張新表，用檔名就對不上了）
                mm = d.setdefault(m, {})
                k = 1
                while "%s|%d" % (mob, k) in mm:
                    k += 1
                mm["%s|%d" % (mob, k)] = {a: b for a, b in g["items"]}
    return d


def diff(old, new):
    """依「地圖＋道具」彙整差異（同一張地圖多隻怪同樣的變化只列一次，附怪物名稱）。"""
    a, b = flat(old), flat(new)
    rows = collections.OrderedDict()
    for m in b:
        if m not in a:
            rows[(m, "", "")] = dict(map=m, item="", old=None, new=None, mobs=[], kind="newmap")
            continue
        for mob, items in b[m].items():
            before = a[m].get(mob)
            if before is None:
                continue
            for it in set(items) | set(before):
                x, y = before.get(it, 0), items.get(it, 0)
                if abs(x - y) > 1e-9 and (max(x, y) == 0 or abs(x - y) / max(x, y) > 0.01):
                    r = rows.setdefault((m, it, round(x, 8), round(y, 8)),
                                        dict(map=m, item=it, old=x, new=y, mobs=[], kind="change"))
                    name = mob.split("|")[0]
                    if name not in r["mobs"]:
                        r["mobs"].append(name)
    return list(rows.values())


def load_index(out_dir):
    try:
        return json.load(open(os.path.join(out_dir, "index.json"), encoding="utf-8"))
    except (OSError, ValueError):
        return dict(versions=[])


def save_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
    for i in range(5):   # 管理程式剛好在讀檔時 Windows 會拒絕取代，稍等再試
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            if i == 4:
                raise
            time.sleep(0.2)


def add_version(out_dir, vid, label, maps, meta, source, fp=None):
    index = load_index(out_dir)
    vers = [v for v in index["versions"] if v["id"] != vid]
    prev = None
    for v in sorted(vers, key=lambda v: v["id"], reverse=True):
        if v["id"] < vid:
            try:
                prev = json.load(open(os.path.join(out_dir, v["id"] + ".json"), encoding="utf-8"))
            except (OSError, ValueError):
                continue
            break
    changes = diff(prev["maps"], maps) if prev else []
    if prev and prev.get("source") == "seed":   # 舊版只存了常用地圖：其他地圖不算「新地圖」
        changes = [c for c in changes if c["kind"] != "newmap"]
    doc = dict(id=vid, label=label, tool=TOOL_VERSION, source=source, built=datetime.datetime.now().isoformat(timespec="seconds"),
               favorites=[m for m in FAVORITES if m in maps], prev=prev["id"] if prev else "", prevLabel=prev["label"] if prev else "",
               changes=changes, meta=meta, maps=maps)
    save_json(os.path.join(out_dir, vid + ".json"), doc)
    vers.append(dict(id=vid, label=label, maps=len(maps), changes=len(changes), fp=fp))
    index["versions"] = sorted(vers, key=lambda v: v["id"], reverse=True)
    return index, doc


def import_seeds(out_dir):
    """內建的舊版本（工具做出來之前手動整理的常用地圖資料）：還沒有的才加入。"""
    seed_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "seed")
    if not os.path.isdir(seed_dir):
        return
    have = {v["id"] for v in load_index(out_dir)["versions"]}
    for fn in sorted(os.listdir(seed_dir)):
        if not fn.endswith(".json") or fn[:-5] in have:
            continue
        s = json.load(open(os.path.join(seed_dir, fn), encoding="utf-8"))
        index, _ = add_version(out_dir, s["id"], s["label"], s["maps"], {}, "seed")
        save_json(os.path.join(out_dir, "index.json"), index)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--game", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    err = os.path.join(a.out, "last_error.txt")
    try:
        import_seeds(a.out)
        fp = fingerprint(a.game)
        index = load_index(a.out)
        if not a.force and index.get("fingerprint") == fp and index.get("tool") == TOOL_VERSION:
            print("UP_TO_DATE")
            return 0
        # 版本 = 四個來源檔中最新的修改時間（維修可能只換資料檔、不換 game.exe）
        mt = datetime.datetime.fromtimestamp(max(os.stat(os.path.join(a.game, s)).st_mtime for s in SOURCES))
        vid, label = mt.strftime("%Y%m%d-%H%M"), mt.strftime("%m/%d") + " 維修版"
        same = {v["id"]: v.get("fp") for v in index["versions"]}
        n = 1
        while vid in same and same[vid] not in (None, fp):   # 同一分鐘又有一次不同的更新
            n += 1
            vid, label = mt.strftime("%Y%m%d-%H%M") + "-%d" % n, mt.strftime("%m/%d") + " 維修版（%d）" % n
        maps, meta = compute(a.game)
        index, doc = add_version(a.out, vid, label, maps, meta, "game", fp)
        index.update(fingerprint=fp, tool=TOOL_VERSION, latest=vid)
        save_json(os.path.join(a.out, "index.json"), index)
        if os.path.exists(err):
            os.remove(err)
        print("UPDATED %s %s maps=%d changes=%d" % (vid, label, len(maps), len(doc["changes"])))
        return 0
    except Exception as e:  # noqa: BLE001 — 任何失敗都寫下原因給管理程式顯示
        with open(err, "w", encoding="utf-8") as f:
            f.write("%s\n\n%s" % (e, traceback.format_exc()))
        print("FAILED %s" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
