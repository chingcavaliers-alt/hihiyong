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
    pos:=recoveryQueue.Length+1
    if ProfileRecoveryFirst(profiles[idx]) {
        for i,q in recoveryQueue {
            if !ProfileRecoveryFirst(profiles[q]) {
                pos:=i
                break
            }
        }
    }
    queued[idx]:=true, recoveryQueue.InsertAt(pos,idx)
    if pos<=recoveryQueue.Length-1
        EventLog(profiles[idx].name,"QUEUE_PRIORITY","優先重新登入（隊長）｜排在第 " pos " 位")
    profiles[idx].state:="排隊中"
    EventLog(profiles[idx].name, "QUEUE", reason)
    RecoveryWebhook(profiles[idx],"偵測異常 / 加入重啟遊戲排程",reason)
    AddRecentEvent(profiles[idx].name " → Recovery Queue：" reason)
    Status.Text:="狀態：" profiles[idx].name " → " reason "｜已加入 Recovery Queue"
    RefreshProfileLV()
}

ProfileRecoveryFirst(p) => p.HasOwnProp("recoveryFirst") && p.recoveryFirst
