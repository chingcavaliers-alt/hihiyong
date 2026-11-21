; ============================================================================
; RecoveryQueue：重新登入排程（Recovery Queue）的排入邏輯。
; 從主程式搬出（H-004），行為與日誌 / 副作用順序完全不變，讓單元測試能測真正的程式。
; 排入規則：已在佇列略過、載入中略過、勾了「優先重新登入（隊長）」的排到一般角色前面。
; 依賴主程式的全域：profiles, recoveryQueue, queued, Status, asyncLoadingEntries
; 依賴主程式的函式：EventLog, RecoveryWebhook, AddRecentEvent, RefreshProfileLV
; ============================================================================

EnqueueRecovery(idx,reason) {
    global profiles,recoveryQueue,queued,Status,asyncLoadingEntries
    if queued.Has(idx)
        return
    ; v1.3.14.0: 已按下開始遊戲、正在背景等待載入的帳號不重複排入。
    if asyncLoadingEntries.Has(idx) {
        EventLog(profiles[idx].name,"QUEUE_SKIP_LOADING","遊戲載入中，略過重複排入｜" reason)
        return
    }
    ; v1.3.22.0：勾了「優先重新登入（隊長）」的角色排到一般角色前面，隊員回來時隊長已經在怪區
    ; v1.3.90.61：再依首頁排的「啟動順序」；同一個順序（都沒排過）照排入的先後
    key:=ProfileStartKey(profiles[idx])
    pos:=recoveryQueue.Length+1
    for i,q in recoveryQueue {
        if ProfileStartKey(profiles[q])>key {
            pos:=i
            break
        }
    }
    queued[idx]:=true, recoveryQueue.InsertAt(pos,idx)
    if pos<=recoveryQueue.Length-1
        EventLog(profiles[idx].name,"QUEUE_PRIORITY",(ProfileRecoveryFirst(profiles[idx]) ? "優先重新登入（隊長）" : "啟動順序第 " profiles[idx].startOrder) "｜排在第 " pos " 位")
    profiles[idx].state:="排隊中"
    EventLog(profiles[idx].name, "QUEUE", reason)
    RecoveryWebhook(profiles[idx],"偵測異常 / 加入重啟遊戲排程",reason)
    AddRecentEvent(profiles[idx].name " → Recovery Queue：" reason)
    Status.Text:="狀態：" profiles[idx].name " → " reason "｜已加入 Recovery Queue"
    RefreshProfileLV()
}

ProfileRecoveryFirst(p) => p.HasOwnProp("recoveryFirst") && p.recoveryFirst
; 首頁「啟動順序」（▲▼ 排的，1 最先）；沒排過是 0
ProfileStartOrder(p) => p.HasOwnProp("startOrder") && IsInteger(p.startOrder) && p.startOrder>0 ? p.startOrder : 0
; 排隊用的先後：隊長在前，再依啟動順序；沒排過的排在最後（彼此照排入先後）
ProfileStartKey(p) => (ProfileRecoveryFirst(p) ? 0 : 1000000000) + (ProfileStartOrder(p) ? ProfileStartOrder(p) : 999999999)

; 首頁顯示 / 移動用：所有帳號照啟動順序排好的 index 清單（沒排過的照帳號清單順序排在後面）
ProfileStartList() {
    global profiles
    list:=[]
    for i,p in profiles
        list.Push(i)
    ; 插入排序：帳號最多十幾個
    Loop list.Length - 1 {
        j:=A_Index+1, cur:=list[j]
        while j>1 && ProfileStartSortKey(list[j-1])>ProfileStartSortKey(cur) {
            list[j]:=list[j-1], j-=1
        }
        list[j]:=cur
    }
    return list
}
ProfileStartSortKey(i) {
    global profiles
    o:=ProfileStartOrder(profiles[i])
    return o ? o : 100000+i
}
; ▲▼：把第 idx 個帳號往前（dir=-1）或往後（dir=1）移一格，全部重新編號 1..N
ProfileMoveStartOrder(idx,dir) {
    global profiles
    list:=ProfileStartList()
    pos:=0
    for k,v in list
        if v=idx
            pos:=k
    to:=pos+dir
    if !pos || to<1 || to>list.Length
        return false
    t:=list[pos], list[pos]:=list[to], list[to]:=t
    for k,v in list
        profiles[v].startOrder:=k
    return true
}
