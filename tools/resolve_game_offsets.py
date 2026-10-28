"""從 game.exe + Game.pdb 解析遊戲資料位置，寫入 HIHIYONG_GameOffsets.ini。

只讀取檔案（PE header、機器碼、PDB 符號），不碰執行中的遊戲。
每次維修更新後由管理器自動呼叫；也可手動執行：

    py -3 resolve_game_offsets.py --exe F:\\HiHiYong2.0\\game.exe --out ..\\HIHIYONG_GameOffsets.ini

只使用 Python 標準函式庫與 Windows 內建的 dbghelp.dll。
"""

from __future__ import annotations

import argparse
import ctypes
import struct
import sys
from ctypes import wintypes
from datetime import datetime
from pathlib import Path

LOAD_BASE = 0x400000  # 離線載入用的假基底位址，所有結果都換算成 RVA
TAG_FUNCTION, TAG_DATA, TAG_BASECLASS = 5, 7, 18
TI_GET_SYMTAG, TI_GET_SYMNAME, TI_GET_LENGTH, TI_GET_TYPE, TI_GET_OFFSET = 0, 1, 2, 4, 10
TI_GET_CHILDRENCOUNT, TI_FINDCHILDREN = 13, 7
LEA_RAX_RIP = bytes([0x48, 0x8D, 0x05])
SYMBOL_INFOW_BASE_SIZE = 88  # sizeof(SYMBOL_INFOW) 不含名稱緩衝區（x64）
# 輸出欄位有增加時遞增；管理器發現 INI 的版本較舊會自動重新解析。
TOOL_VERSION = 20
MAP_LIST_PAIR = "std::pair<unsigned long const ,SMAPNODE>"
MAP_LIST_NODE = "std::_List_node<std::pair<unsigned long const ,SMAPNODE>,void *>"
CROW_LIST = "CGLLIST<GLCrowClient *>"
CROW_NODE = "SGLNODE<GLCrowClient *>"


class SYMBOL_INFOW(ctypes.Structure):
    _fields_ = [
        ("SizeOfStruct", wintypes.ULONG), ("TypeIndex", wintypes.ULONG), ("Reserved", ctypes.c_uint64 * 2),
        ("Index", wintypes.ULONG), ("Size", wintypes.ULONG), ("ModBase", ctypes.c_uint64),
        ("Flags", wintypes.ULONG), ("Value", ctypes.c_uint64), ("Address", ctypes.c_uint64),
        ("Register", wintypes.ULONG), ("Scope", wintypes.ULONG), ("Tag", wintypes.ULONG),
        ("NameLen", wintypes.ULONG), ("MaxNameLen", wintypes.ULONG), ("Name", wintypes.WCHAR * 1024),
    ]


class PeImage:
    def __init__(self, path: Path) -> None:
        self.data = path.read_bytes()
        pe = struct.unpack_from("<I", self.data, 0x3C)[0]
        self.timestamp = struct.unpack_from("<I", self.data, pe + 8)[0]
        count = struct.unpack_from("<H", self.data, pe + 6)[0]
        opt = pe + 24
        self.size_of_image = struct.unpack_from("<I", self.data, opt + 56)[0]
        first = opt + struct.unpack_from("<H", self.data, pe + 20)[0]
        self.sections = []
        for i in range(count):
            o = first + i * 40
            name = self.data[o:o + 8].rstrip(b"\0").decode(errors="replace")
            vsize, vaddr, rsize, raddr = struct.unpack_from("<IIII", self.data, o + 8)
            self.sections.append((name, vaddr, vsize, raddr, rsize))

    @property
    def build(self) -> str:
        # 與管理器 GetGameBuildStamp() 相同格式：TimeDateStamp-SizeOfImage
        return f"{self.timestamp:08X}-{self.size_of_image:X}"

    def read(self, rva: int, size: int) -> bytes:
        for _name, vaddr, vsize, raddr, rsize in self.sections:
            if vaddr <= rva < vaddr + max(vsize, rsize):
                start = raddr + (rva - vaddr)
                return self.data[start:start + size]
        raise ValueError(f"RVA 0x{rva:X} 不在任何區段內")

    def section_of(self, rva: int) -> str:
        for name, vaddr, vsize, _raddr, _rsize in self.sections:
            if vaddr <= rva < vaddr + vsize:
                return name
        return "?"


class Pdb:
    def __init__(self, exe: Path) -> None:
        self.dbg = ctypes.WinDLL("dbghelp", use_last_error=True)
        self.proc = ctypes.c_void_p(0x6A6B)  # 離線解析用的任意 handle
        self.dbg.SymSetOptions(0x2)  # SYMOPT_UNDNAME
        if not self.dbg.SymInitializeW(self.proc, str(exe.parent), False):
            raise ctypes.WinError(ctypes.get_last_error())
        self.dbg.SymLoadModuleExW.restype = ctypes.c_uint64
        self.dbg.SymLoadModuleExW.argtypes = [ctypes.c_void_p, ctypes.c_void_p, wintypes.LPCWSTR, wintypes.LPCWSTR,
                                              ctypes.c_uint64, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD]
        self.dbg.SymGetTypeInfo.argtypes = [ctypes.c_void_p, ctypes.c_uint64, wintypes.ULONG, ctypes.c_int, ctypes.c_void_p]
        self.base = self.dbg.SymLoadModuleExW(self.proc, None, str(exe), None, LOAD_BASE, 0, None, 0)
        if not self.base:
            raise ctypes.WinError(ctypes.get_last_error())

    def close(self) -> None:
        self.dbg.SymCleanup(self.proc)

    def _symbol(self, name: str, by_type: bool = False) -> SYMBOL_INFOW:
        info = SYMBOL_INFOW()
        info.SizeOfStruct = SYMBOL_INFOW_BASE_SIZE
        info.MaxNameLen = 1024
        fn = self.dbg.SymGetTypeFromNameW if by_type else self.dbg.SymFromNameW
        ok = fn(self.proc, ctypes.c_uint64(self.base), name, ctypes.byref(info)) if by_type \
            else fn(self.proc, name, ctypes.byref(info))
        if not ok:
            raise LookupError(f"PDB 找不到 {'型別' if by_type else '符號'}：{name}")
        return info

    def function(self, name: str) -> tuple[int, int]:
        info = self._symbol(name)
        return info.Address - self.base, info.Size

    def _enum(self, mask: str, tag: int) -> list[tuple[int, int]]:
        found: list[tuple[int, int]] = []
        cb_type = ctypes.WINFUNCTYPE(wintypes.BOOL, ctypes.POINTER(SYMBOL_INFOW), wintypes.ULONG, ctypes.c_void_p)

        def callback(p, _size, _ctx):
            if p.contents.Tag == tag and p.contents.Address:
                found.append((p.contents.Address - self.base, p.contents.Size))
            return True

        self.dbg.SymEnumSymbolsW(self.proc, ctypes.c_uint64(self.base), mask, cb_type(callback), None)
        return found

    def data_symbols(self, mask: str) -> list[int]:
        return [rva for rva, _size in self._enum(mask, TAG_DATA)]

    def overloads(self, name: str) -> list[tuple[int, int]]:
        """同名函式的所有多載：[(rva, size)]。"""
        return self._enum(name, TAG_FUNCTION)

    def _ti(self, type_id: int, what: int) -> int | None:
        out = wintypes.DWORD()
        if not self.dbg.SymGetTypeInfo(self.proc, ctypes.c_uint64(self.base), type_id, what, ctypes.byref(out)):
            return None
        return out.value

    def _name(self, type_id: int) -> str | None:
        p = ctypes.c_wchar_p()
        if not self.dbg.SymGetTypeInfo(self.proc, ctypes.c_uint64(self.base), type_id, TI_GET_SYMNAME, ctypes.byref(p)):
            return None
        return p.value

    def _children(self, type_id: int) -> list[int]:
        count = self._ti(type_id, TI_GET_CHILDRENCOUNT) or 0
        if not count:
            return []

        class FindChildren(ctypes.Structure):
            _fields_ = [("Count", wintypes.ULONG), ("Start", wintypes.ULONG), ("ChildId", wintypes.ULONG * count)]

        fc = FindChildren(count, 0)
        self.dbg.SymGetTypeInfo(self.proc, ctypes.c_uint64(self.base), type_id, TI_FINDCHILDREN, ctypes.byref(fc))
        return list(fc.ChildId)

    def _find_member(self, type_id: int, member: str) -> tuple[int, int] | None:
        """回傳 (offset, 成員型別 id)；會一併搜尋基底類別。"""
        for child in self._children(type_id):
            tag = self._ti(child, TI_GET_SYMTAG)
            if tag == TAG_DATA and self._name(child) == member:
                offset = self._ti(child, TI_GET_OFFSET)
                if offset is not None:
                    return offset, self._ti(child, TI_GET_TYPE)
            elif tag == TAG_BASECLASS:
                found = self._find_member(self._ti(child, TI_GET_TYPE), member)
                if found:
                    return (self._ti(child, TI_GET_OFFSET) or 0) + found[0], found[1]
        return None

    def member_size(self, udt: str, member: str) -> int:
        """成員本身的大小（陣列成員 = 總位元組數）。"""
        type_id = self._symbol(udt, by_type=True).TypeIndex
        found = self._find_member(type_id, member)
        if not found:
            raise LookupError(f"PDB 找不到成員：{udt}.{member}")
        out = ctypes.c_uint64()
        self.dbg.SymGetTypeInfo(self.proc, ctypes.c_uint64(self.base), found[1], TI_GET_LENGTH, ctypes.byref(out))
        return out.value

    def size(self, udt: str) -> int:
        out = ctypes.c_uint64()
        type_id = self._symbol(udt, by_type=True).TypeIndex
        self.dbg.SymGetTypeInfo(self.proc, ctypes.c_uint64(self.base), type_id, TI_GET_LENGTH, ctypes.byref(out))
        return out.value

    def offset(self, udt: str, path: str) -> int:
        """例如 offset("GLCharacter", "m_sHP.dwNow")。"""
        type_id = self._symbol(udt, by_type=True).TypeIndex
        total = 0
        for member in path.split("."):
            found = self._find_member(type_id, member)
            if not found:
                raise LookupError(f"PDB 找不到成員：{udt}.{path}（卡在 {member}）")
            total += found[0]
            type_id = found[1]
        return total


def static_instance_rva(image: PeImage, func_rva: int, func_size: int) -> int:
    """GetInstance() 以 `lea rax,[rip+disp]` 回傳靜態物件位址；取第一個落在 .data 的目標。"""
    code = image.read(func_rva, func_size)
    start = 0
    while (i := code.find(LEA_RAX_RIP, start)) >= 0:
        target = func_rva + i + 7 + struct.unpack_from("<i", code, i + 3)[0]
        if image.section_of(target) == ".data":
            return target
        start = i + 1
    raise LookupError(f"GetInstance(0x{func_rva:X}) 內找不到 lea rax 靜態物件")


def item_id_limit(image: PeImage, func_rva: int, func_size: int) -> int:
    """GLItemMan::GetItem 以 `mov eax, imm32` 載入 ID 上限（目前為 0x400）。"""
    code = image.read(func_rva, func_size)
    for i in range(len(code) - 5):
        if code[i] == 0xB8:
            value = struct.unpack_from("<I", code, i + 1)[0]
            if 0x40 <= value <= 0x10000 and value != 0xFFFF:
                return value
    return 0x400


def buff_fields(pdb: Pdb) -> dict[str, object]:
    """v15：角色身上的效果清單（右下角狀態圖示的資料來源）。M 箱用它確認「效果有沒有在作用」。
    選用：解析失敗只是沒有這組欄位，M 箱退回只看箱子數量。"""
    count = pdb.member_size("GLCHARLOGIC", "m_sSKILLFACT") // pdb.size("SSKILLFACT")
    return {
        "SkillFactOffset": pdb.offset("GLCharacter", "m_sSKILLFACT"),
        "SkillFactCount": count,
        "SkillFactSize": pdb.size("SSKILLFACT"),
        "SkillFactIdOffset": pdb.offset("SSKILLFACT", "sNATIVEID"),
        "SkillFactAgeOffset": pdb.offset("SSKILLFACT", "fAGE"),
        "SkillFactLevelOffset": pdb.offset("SSKILLFACT", "wLEVEL"),
        # M 箱這類「問號道具」效果不在 SKILLFACT，在 m_sQITEMFACT {emType:int, fTime:float, ...}（實測）
        "QItemFactOffset": pdb.offset("GLCharacter", "m_sQITEMFACT"),
        "QItemFactTimeOffset": pdb.offset("SQITEM_FACT", "fTime"),
    }


def invpage_fields(pdb: Pdb) -> dict[str, object]:
    """v17：背包視窗的分頁（H-024）。背包是 6 欄 × 50 列的長表格，視窗每次顯示 10 列 = 一頁，共 5 頁，
    用視窗上方的 5 個圓形頁籤切換（實機確認 2026-10-26）。m_Button[i] = 未選取的圓點、m_ButtonSet[i] = 選取中的圓點，
    「目前頁」= 哪一個 m_ButtonSet 可見。選用：解析失敗只是沒有這組欄位（每日道具退回只能操作第 1 頁）。"""
    return {
        "InnerInvWindowOffset": pdb.offset("CInnerInterface", "m_pInventoryWindow"),
        "InvWindowPageOffset": pdb.offset("CInventoryWindow", "m_pPage"),
        "InvPageButtonOffset": pdb.offset("CInventoryPage", "m_Button"),
        "InvPageButtonSetOffset": pdb.offset("CInventoryPage", "m_ButtonSet"),
        "InvPageButtonCount": pdb.member_size("CInventoryPage", "m_Button") // 8,
        # 可用的列數（實機 2026-10-26：46；最後一頁最下面 4 列是打叉的、不能放東西）
        "InvPageUsableRowsOffset": pdb.offset("CInventoryPage", "m_nONE_VIEW_SLOT"),
    }

def quick_fields(pdb: Pdb) -> dict[str, object]:
    """v18：道具快捷欄（畫面下方 6 格，鍵 Q W E …）。每格 SACTION_SLOT {wACT(2), sNID(4)}。
    每日道具用它找出「起點卡 / 前點卡」實際放在哪一格（角色放的位置不同時自動改按對的鍵）。選用。"""
    return {
        "ActionQuickOffset": pdb.offset("GLCharacter", "m_sACTIONQUICK"),
        "ActionQuickCount": pdb.member_size("GLCharacter", "m_sACTIONQUICK") // pdb.size("SACTION_SLOT"),
        "ActionQuickSize": pdb.size("SACTION_SLOT"),
        "ActionSlotActOffset": pdb.offset("SACTION_SLOT", "wACT"),
        "ActionSlotIdOffset": pdb.offset("SACTION_SLOT", "sNID"),
    }


def keypet_fields(pdb: Pdb) -> dict[str, object]:
    """v19：道具快捷欄各格目前設定的鍵（遊戲「快捷鍵設定」可改，存在 RANPARAM::QuickSlot，DirectInput 掃描碼 int[6]）
    與「寵物是否在外面」（GLGaeaClient.m_Pet.m_bValid）。登入後依快捷欄找寵物卡並只在寵物不在外面時按。選用。"""
    rva, size = pdb.function("RANPARAM::QuickSlot")
    return {
        "QuickKeysRva": rva,
        "QuickKeysCount": size // 4,
        "PetValidOffset": pdb.offset("GLGaeaClient", "m_Pet.m_bValid"),
    }


def login_fields(image: PeImage, pdb: Pdb) -> dict[str, object]:
    """v20：登入 / 選伺服器 / 選角畫面（COuterInterface）。各頁的控制項位置（rcGlobalPos）與可見狀態都在記憶體裡，
    登入流程可以直接讀按鈕位置，不用先記 8 個點。進入遊戲後這些頁面會被遊戲釋放（指標 = 0）。選用。"""
    out: dict[str, object] = {
        "OuterInstanceRva": static_instance_rva(image, *pdb.function("COuterInterface::GetInstance")),
        "OuterVftableRvas": "|".join(f"0x{v:X}" for v in pdb.data_symbols("COuterInterface::`vftable'")),
        "UiNameOffset": pdb.offset("CUIControl", "m_strControlName"),
        "UiRectOffset": pdb.offset("CUIControl", "m_rcGlobalPos"),
        "UiVisibleOffset": pdb.offset("CUIControl", "m_bVisible"),
        "UiChildListOffset": pdb.offset("CUIGroup", "m_ControlContainer") + pdb.offset("CUIControlContainer", "m_UIControlList"),
    }
    # 選角畫面的角色清單（DxGlobalStage.m_LobyStage）：數量、名稱、等級、目前選到哪一格
    out.update({
        "GlobalStageRva": static_instance_rva(image, *pdb.function("DxGlobalStage::GetInstance")),
        "GlobalStageActiveOffset": pdb.offset("DxGlobalStage", "m_pActiveStage"),
        "GlobalStageLobyOffset": pdb.offset("DxGlobalStage", "m_LobyStage"),
        "LobyCharCountOffset": pdb.offset("DxLobyStage", "m_nChaSNum"),
        "LobyCharSelectOffset": pdb.offset("DxLobyStage", "m_dwCharSelect"),
        "LobyCharInfoOffset": pdb.offset("DxLobyStage", "m_CharInfo"),
        "LobyCharInfoSize": pdb.size("SCHARINFO_LOBBY"),
        "LobyCharIdOffset": pdb.offset("SCHARINFO_LOBBY", "m_dwCharID"),
        "LobyCharNameOffset": pdb.offset("SCHARINFO_LOBBY", "m_szName"),
        "LobyCharLevelOffset": pdb.offset("SCHARINFO_LOBBY", "m_wLevel"),
    })
    for key, member in (("Server", "m_pSelectServerPage"), ("Login", "m_pLoginPage"), ("Char", "m_pSelectCharacterPage"),
                        ("CharLeft", "m_pSelectCharacterLeftPage"), ("SecPass", "m_pSecPassCheckPage"),
                        ("Message", "m_pMessageWindow"), ("Modal", "m_pModalWindow"), ("Wait", "m_pWaitDisplay")):
        out[f"Outer{key}PageOffset"] = pdb.offset("COuterInterface", member)
    return out


def party_fields(image: PeImage, pdb: Pdb) -> dict[str, object]:
    """v14：自動組隊用（隊伍成員、好友名單、好友視窗 / 組隊確認視窗的位置）。
    這些欄位是選用的：任何一個解析失敗就整組不輸出（只留 PartyError），不影響其他功能。"""
    parts_text = "CBasicTextBox::STEXTPART"
    line_text = "CBasicTextBox::STEXTLINE"
    word_text = "CBasicTextBox::STEXTWORD"
    entry = "std::pair<unsigned long,GLPARTY_CLIENT>"
    return {
        "PartyInstanceRva": static_instance_rva(image, *pdb.function("GLPartyClient::GetInstance")),
        "PartyIdOffset": pdb.offset("GLPartyClient", "m_dwPartyID"),
        "PartyMasterOffset": pdb.offset("GLPartyClient", "m_sMaster"),
        "PartyMapOffset": pdb.offset("GLPartyClient", "m_mapParty"),
        "PartyEntrySize": pdb.size(entry),
        "PartyEntryDataOffset": pdb.offset(entry, "second"),
        "PartyMemberGaeaOffset": pdb.offset("GLPARTY_CLIENT", "m_dwGaeaID"),
        "PartyMemberNameOffset": pdb.offset("GLPARTY_CLIENT", "m_szName"),
        "FriendInstanceRva": static_instance_rva(image, *pdb.function("GLFriendClient::GetInstance")),
        "FriendMapOffset": pdb.offset("GLFriendClient", "m_mapFriend"),
        "FriendCharIdOffset": pdb.offset("SFRIEND", "nCharID"),
        "FriendNameOffset": pdb.offset("SFRIEND", "szCharName"),
        "FriendOnlineOffset": pdb.offset("SFRIEND", "bONLINE"),
        "InnerInterfaceRva": static_instance_rva(image, *pdb.function("CInnerInterface::GetInstance")),
        "InnerInterfaceVftableRvas": "|".join(f"0x{v:X}" for v in pdb.data_symbols("CInnerInterface::`vftable'")),
        "InnerFriendWindowOffset": pdb.offset("CInnerInterface", "m_pFriendWindow"),
        "InnerPartyModalOffset": pdb.offset("CInnerInterface", "m_pPartyModalWindow"),
        "FriendWindowPageOffset": pdb.offset("CFriendWindow", "m_pNormalPage"),
        "FriendPageSelectOffset": pdb.offset("CFriendWindowNormalPage", "m_nSelectIndex"),
        "FriendPageListOffset": pdb.offset("CFriendWindowNormalPage", "m_pListText"),
        "FriendPagePartyBtnOffset": pdb.offset("CFriendWindowNormalPage", "m_pPARTY"),
        "FriendPageCharIdOffset": pdb.offset("CFriendWindowNormalPage", "m_nCharID"),
        "PartyModalTextOffset": pdb.offset("CPartyModalWindow", "m_pTextBox"),
        "PartyModalOkOffset": pdb.offset("CPartyModalWindow", "m_pOK"),
        "PartyModalCancelOffset": pdb.offset("CPartyModalWindow", "m_pCANCEL"),
        "PartyModalYesOffset": pdb.offset("CPartyModalWindow", "m_pYES"),
        "PartyModalNoOffset": pdb.offset("CPartyModalWindow", "m_pNO"),
        "UiRectOffset": pdb.offset("CUIControl", "m_rcGlobalPos"),
        "UiVisibleOffset": pdb.offset("CUIControl", "m_bVisible"),
        "TextBoxPartsOffset": pdb.offset("CBasicTextBox", "m_TextBox"),
        "TextBoxVisibleLineOffset": pdb.offset("CBasicTextBox", "m_nVisibleLine"),
        "TextBoxCurLineOffset": pdb.offset("CBasicTextBox", "m_nCurLine"),
        "TextPartLinesOffset": pdb.offset(parts_text, "dequeLine"),
        "TextPartDataOffset": pdb.offset(parts_text, "m_dwData"),
        "TextPartRectOffset": pdb.offset(parts_text, "m_rcPart"),
        "TextLineWordsOffset": pdb.offset(line_text, "vectorWord"),
        "TextWordStrOffset": pdb.offset(word_text, "strWord"),
        "TextWordSize": pdb.size(word_text),
    }


def resolve(exe: Path) -> dict[str, str]:
    image = PeImage(exe)
    pdb = Pdb(exe)
    try:
        gaea_rva = static_instance_rva(image, *pdb.function("GLGaeaClient::GetInstance"))
        itemman_rva = static_instance_rva(image, *pdb.function("GLItemMan::GetInstance"))
        # SITEM::GetName() 以 GLStringTable 把 strName（例如 IN_001_254）換成顯示名稱。
        strtable_rva = static_instance_rva(image, *pdb.function("GLStringTable::GetInstance"))
        # GetItem 有 (DWORD) 與 (WORD,WORD) 兩個多載；有邊界檢查的是較長的那個。
        get_item = max(pdb.overloads("GLItemMan::GetItem"), key=lambda f: f[1])
        vftables = pdb.data_symbols("GLGaeaClient::`vftable'")
        if not vftables:
            raise LookupError("PDB 找不到 GLGaeaClient vftable")
        values = {
            "Build": image.build,
            "GaeaInstanceRva": gaea_rva,
            "GaeaVftableRvas": "|".join(f"0x{v:X}" for v in vftables),
            "CharOffset": pdb.offset("GLGaeaClient", "m_Character"),
            # 伺服器推送的時間（假在線時伺服器不再送資料，預期會停止更新）
            "ServerTimeOffset": pdb.offset("GLGaeaClient", "m_cServerTime.m_time"),
            "HpNowOffset": pdb.offset("GLCharacter", "m_sHP.dwNow"),
            "HpMaxOffset": pdb.offset("GLCharacter", "m_sHP.dwMax"),
            "ExpNowOffset": pdb.offset("GLCharacter", "m_sExperience.lnNow"),
            "MoneyOffset": pdb.offset("GLCharacter", "m_lnMoney"),
            "InvenOffset": pdb.offset("GLCharacter", "m_cInventory"),
            "ItemMapOffset": pdb.offset("GLInventory", "m_ItemMap"),
            "InvenItemCustomOffset": pdb.offset("SINVENITEM", "sItemCustom"),
            "NativeIdOffset": pdb.offset("SITEMCUSTOM", "sNativeID"),
            "TurnNumOffset": pdb.offset("SITEMCUSTOM", "wTurnNum"),
            "ItemManInstanceRva": itemman_rva,
            "ItemManPpItemOffset": pdb.offset("GLItemMan", "m_ppItem"),
            "ItemNodeItemOffset": pdb.offset("CItemNode", "m_sItem"),
            "ItemNameOffset": pdb.offset("SITEM", "sBasicOp.strName"),
            "ItemIdLimit": item_id_limit(image, *get_item),
            # v4：每日道具（裝備欄、銀行、到期時間、職業）
            "CharClassOffset": pdb.offset("GLCharacter", "m_emClass"),
            # v10：自動攻擊（F6 → GLCharacter::ReqAutoSystem(0) 切換 sAutoSkill.bActive）
            "AutoSkillActiveOffset": pdb.offset("GLCharacter", "m_sAutoSystem.sAutoSkill.bActive"),
            "CharNameOffset": pdb.offset("GLCharacter", "m_szName"),
            "PutOnItemsOffset": pdb.offset("GLCharacter", "m_PutOnItems"),
            "ItemCustomSize": pdb.size("SITEMCUSTOM"),
            "BankOffset": pdb.offset("GLCharacter", "m_cInvenCharged"),
            "InvenItemPosOffset": pdb.offset("SINVENITEM", "wPosX"),
            "DisguiseIdOffset": pdb.offset("SITEMCUSTOM", "nidDISGUISE"),
            "DisguiseTimeOffset": pdb.offset("SITEMCUSTOM", "tDISGUISE"),
            "BornTimeOffset": pdb.offset("SITEMCUSTOM", "tBORNTIME"),
            "ItemTimeLimitOffset": pdb.offset("SITEM", "sDrugOp.tTIME_LMT"),
            # v5：每日道具自動更換（目前地圖、選擇盒內容）
            "LandPtrOffset": pdb.offset("GLGaeaClient", "m_pLandMClient"),
            "LandMapIdOffset": pdb.offset("GLLandManClient", "m_sMapID"),
            # v9：地圖清單（GLMapList.m_MapList：stdext::hash_map<DWORD, SMAPNODE>，走訪其中的 std::list）
            "MapListOffset": pdb.offset("GLGaeaClient", "m_MapList._List"),
            "MapNodeValueOffset": pdb.offset(MAP_LIST_NODE, "_Myval"),
            "MapPairNodeOffset": pdb.offset(MAP_LIST_PAIR, "second"),
            "MapNameOffset": pdb.offset("SMAPNODE", "strMapName"),
            "MapIdInNodeOffset": pdb.offset("SMAPNODE", "sNativeID"),
            "MapPeaceZoneOffset": pdb.offset("SMAPNODE", "bPeaceZone"),
            "BoxItemsOffset": pdb.offset("SITEM", "sBox.sITEMS"),
            "BoxItemSize": pdb.size("ITEM::SBOX_ITEM"),
            "BoxItemCount": pdb.size("ITEM::SBOX") // pdb.size("ITEM::SBOX_ITEM"),
            # v6：選擇盒的清單可能放在 sRandomBox.vecBOX（std::vector<SRANDOMITEM>）
            "RandomBoxVecOffset": pdb.offset("SITEM", "sRandomBox.vecBOX"),
            "RandomItemSize": pdb.size("ITEM::SRANDOMITEM"),
            "RandomItemIdOffset": pdb.offset("ITEM::SRANDOMITEM", "nidITEM"),
            # v7：裝備部位（EMSUIT：0 頭、1 上衣、2 褲子、3 手套、4 鞋子、5 手持武器）
            "SuitOffset": pdb.offset("SITEM", "sSuitOp.emSuit"),
            # v8：道具類型（EMITEM_TYPE：ITEM_BOX=12、ITEM_REWARD_BOX=60、ITEM_GACHA_BOX=79）— 背包統計排除開箱所得
            "ItemTypeOffset": pdb.offset("SITEM", "sBasicOp.emItemType"),
            "StringTableInstanceRva": strtable_rva,
            "ItemStringMapOffset": pdb.offset("GLStringTable", "m_mapItemStringTable"),
            # v11：擊殺統計（GLLandManClient.m_GlobCROWList：周圍怪物；死亡 = m_Action 為 GLAT_FALLING / GLAT_DIE）
            "LandCrowListOffset": pdb.offset("GLLandManClient", "m_GlobCROWList"),
            "CrowListHeadOffset": pdb.offset(CROW_LIST, "m_pHead"),
            "CrowNodeDataOffset": pdb.offset(CROW_NODE, "Data"),
            "CrowNodeNextOffset": pdb.offset(CROW_NODE, "pNext"),
            "CrowVftableRvas": "|".join(f"0x{v:X}" for v in pdb.data_symbols("GLCrowClient::`vftable'")),
            "CrowDataPtrOffset": pdb.offset("GLCrowClient", "m_pCrowData"),
            "CrowNativeIdOffset": pdb.offset("GLCrowClient", "m_sNativeID"),
            "CrowGlobIdOffset": pdb.offset("GLCrowClient", "m_dwGlobID"),
            "CrowHpNowOffset": pdb.offset("GLCrowClient", "m_dwNowHP"),
            "CrowActionOffset": pdb.offset("GLCrowClient", "m_Action"),
            "CrowPosOffset": pdb.offset("GLCrowClient", "m_vPos"),
            "CharPosOffset": pdb.offset("GLCharacter", "m_vPos"),
            # v12：角色正在打的怪（單一目標 / 技能命中清單 STARID[24] / 自動狩獵目標），用來判斷擊殺是誰的
            "CharTargetOffset": pdb.offset("GLCharacter", "m_sTargetID"),
            "CharTarNumOffset": pdb.offset("GLCharacter", "m_wTARNUM"),
            "CharTarIdsOffset": pdb.offset("GLCharacter", "m_sTARIDS"),
            "CharMyTargetOffset": pdb.offset("GLCharacter", "m_sMyTargetID"),
            # v13：自動採礦（角色動作 / 坐騎 / 技能快捷欄、附近的採集物、鏡頭矩陣）
            "CharActionOffset": pdb.offset("GLCharacter", "m_Action"),
            "CharActStateOffset": pdb.offset("GLCharacter", "m_dwActState"),
            "VehicleOnOffset": pdb.offset("GLCharacter", "m_bVehicle"),
            "VehicleReqOffset": pdb.offset("GLCharacter", "m_bReqVehicle"),
            "VehicleActiveOffset": pdb.offset("GLCharacter", "m_bIsVehicleActive"),
            "SkillQuickActOffset": pdb.offset("GLCharacter", "m_wSKILLQUICK_ACT"),
            "SkillQuickOffset": pdb.offset("GLCharacter", "m_sSKILLQUICK"),
            "RunSkillOffset": pdb.offset("GLCharacter", "m_sRunSkill"),
            "ActiveSkillOffset": pdb.offset("GLCharacter", "m_sActiveSkill"),
            "SkillStringMapOffset": pdb.offset("GLStringTable", "m_mapSkillStringTable"),
            "LandMaterialListOffset": pdb.offset("GLLandManClient", "m_GlobMaterialList"),
            "MaterialVftableRvas": "|".join(f"0x{v:X}" for v in pdb.data_symbols("GLMaterialClient::`vftable'")),
            "MaterialDataPtrOffset": pdb.offset("GLMaterialClient", "m_pCrowData"),
            "MaterialNativeIdOffset": pdb.offset("GLMaterialClient", "m_sNativeID"),
            "MaterialPosOffset": pdb.offset("GLMaterialClient", "m_vPos"),
            "MaterialGlobIdOffset": pdb.offset("GLMaterialClient", "m_dwGlobID"),
            "MaterialActionOffset": pdb.offset("GLMaterialClient", "m_Action"),
            "ViewPortInstanceRva": static_instance_rva(image, *pdb.function("DxViewPort::GetInstance")),
            "ViewPortVftableRvas": "|".join(f"0x{v:X}" for v in pdb.data_symbols("DxViewPort::`vftable'")),
            "ViewMatrixOffset": pdb.offset("DxViewPort", "m_matView"),
            "ProjMatrixOffset": pdb.offset("DxViewPort", "m_matProj"),
            "ViewPortRectOffset": pdb.offset("DxViewPort", "m_ViewPort"),
            "CrowDataNameOffset": pdb.offset("SCROWDATA", "m_sBasic.m_szName"),
            "CrowStringMapOffset": pdb.offset("GLStringTable", "m_mapCrowStringTable"),
        }
        try:
            values.update(buff_fields(pdb))
        except Exception as e:   # 效果清單的欄位找不到：只有 M 箱的輔助判斷停用
            values["BuffError"] = str(e).replace("\r", " ").replace("\n", " ")[:200]
        try:
            values.update(quick_fields(pdb))
        except Exception as e:   # 道具快捷欄欄位找不到：每日道具退回固定按 Q / W
            values["QuickError"] = str(e).replace("\r", " ").replace("\n", " ")[:200]
        try:
            values.update(keypet_fields(pdb))
        except Exception as e:   # 快捷鍵 / 寵物欄位找不到：登入後的寵物與傳送卡改按設定檔的鍵
            values["KeyPetError"] = str(e).replace("\r", " ").replace("\n", " ")[:200]
        try:
            values.update(login_fields(image, pdb))
        except Exception as e:   # 登入畫面欄位找不到：登入照舊用 8 個預設點
            values["LoginUiError"] = str(e).replace("\r", " ").replace("\n", " ")[:200]
        try:
            values.update(invpage_fields(pdb))
        except Exception as e:   # 背包分頁欄位找不到：只有「分頁背包」功能停用
            values["InvPageError"] = str(e).replace("\r", " ").replace("\n", " ")[:200]
        try:
            values.update(party_fields(image, pdb))
        except Exception as e:   # 任何例外（含 struct.error）都只停用組隊，不能讓整個解析失敗
            # 自動組隊的欄位找不到（例如遊戲改版改了類別）：其他功能照常，只有組隊功能停用
            values["PartyError"] = str(e).replace("\r", " ").replace("\n", " ")[:200]
    finally:
        pdb.close()
    return {k: (f"0x{v:X}" if isinstance(v, int) else v) for k, v in values.items()}


def write_ini(path: Path, values: dict[str, str], status: str, error: str = "") -> None:
    lines = ["[GameOffsets]", f"Status={status}", f"ToolVersion={TOOL_VERSION}",
             f"ResolvedAt={datetime.now():%Y-%m-%d %H:%M:%S}"]
    if error:
        lines.append(f"Error={error}")
    lines += [f"{k}={v}" for k, v in values.items()]
    path.write_text("\r\n".join(lines) + "\r\n", encoding="utf-16", newline="")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--exe", type=Path, required=True, help="game.exe 路徑（同資料夾需有 Game.pdb）")
    parser.add_argument("--out", type=Path, required=True, help="輸出的 INI 路徑")
    args = parser.parse_args()
    try:
        values = resolve(args.exe)
    except Exception as exc:  # 失敗也寫出 INI，讓管理器知道原因
        build = ""
        try:
            build = PeImage(args.exe).build
        except Exception:
            pass
        write_ini(args.out, {"Build": build}, "FAIL", f"{type(exc).__name__}: {exc}".replace("\n", " "))
        print(f"FAIL {exc}", file=sys.stderr)
        return 1
    write_ini(args.out, values, "OK")
    for k, v in values.items():
        print(f"{k}={v}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
