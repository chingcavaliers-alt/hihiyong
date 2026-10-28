; ============================================================================
; RecoveryBatch：斷線重新登入「一整批」結束後，把所有遊戲視窗的畫面合成一張傳到 Discord。
; 一批 = 從第一個帳號開始重新登入，到佇列清空、沒有人在登入 / 載入、畫面穩定為止。
; 依賴主程式的全域：processingQueue, recoveryQueue, foregroundOwner
; 依賴主程式的函式：AsyncLoadingBlocksQueue, EventLog, ReportSendSnapshot
; ============================================================================

global RECOVERY_BATCH_SETTLE_MS := 15000   ; 全部閒下來之後再等這麼久（讓最後一個角色的畫面載入完）才截圖
global RECOVERY_BATCH_TICK_MS := 3000
global recoveryBatchCount := 0
global recoveryBatchStart := 0
global recoveryBatchIdleSince := 0
global recoveryBatchFailShot := false   ; 這一批已經上傳過失敗截圖了（每批最多一張）

; ProcessNextRecovery 每開始處理一個帳號就呼叫一次。
RecoveryBatchNote() {
    global recoveryBatchCount,recoveryBatchStart,recoveryBatchIdleSince,RECOVERY_BATCH_TICK_MS
    if !recoveryBatchCount
        recoveryBatchStart:=A_TickCount
    recoveryBatchCount+=1
    recoveryBatchIdleSince:=0
    SetTimer RecoveryBatchTick,RECOVERY_BATCH_TICK_MS
}

RecoveryBatchBusy() {
    global processingQueue,recoveryQueue,foregroundOwner
    return processingQueue || recoveryQueue.Length || foregroundOwner!="" || AsyncLoadingBlocksQueue()
}

RecoveryBatchTick() {
    global recoveryBatchCount,recoveryBatchStart,recoveryBatchIdleSince,recoveryBatchFailShot,RECOVERY_BATCH_SETTLE_MS
    if !recoveryBatchCount {
        SetTimer RecoveryBatchTick,0
        return
    }
    if RecoveryBatchBusy() {
        recoveryBatchIdleSince:=0
        return
    }
    if !recoveryBatchIdleSince {
        recoveryBatchIdleSince:=A_TickCount
        return
    }
    if A_TickCount-recoveryBatchIdleSince<RECOVERY_BATCH_SETTLE_MS
        return
    SetTimer RecoveryBatchTick,0
    n:=recoveryBatchCount, secs:=Round((A_TickCount-recoveryBatchStart)/1000)
    recoveryBatchCount:=0, recoveryBatchIdleSince:=0, recoveryBatchFailShot:=false
    ok:=false
    try ok:=ReportSendSnapshot("🔁 斷線重新登入流程結束｜共處理 " n " 個帳號｜歷時 " (secs//60) " 分 " Mod(secs,60) " 秒")
    EventLog("GLOBAL","RECOVERY_BATCH_DONE","重新登入流程結束｜處理 " n " 個帳號｜歷時 " secs " 秒｜" (ok ? "已上傳畫面到 Discord" : "沒有可截的畫面或上傳失敗"))
}

; 登入失敗截圖要不要上傳：每一批最多上傳一張（第一張），避免連續失敗洗版；回傳 true = 這張可以上傳。
RecoveryBatchTakeFailShot() {
    global recoveryBatchFailShot
    if recoveryBatchFailShot
        return false
    recoveryBatchFailShot:=true
    return true
}
