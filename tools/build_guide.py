r"""產生「操作教學」分頁：用 Edge 無頭模式替 ui\index.html 的各個畫面截圖，抓出要標示的元件位置，
畫面上用紅框 + 編號標出重點，寫進 ui\index.html 的 <!--GUIDE-START-->…<!--GUIDE-END--> 之間。
介面改版後重新跑一次就會更新教學畫面：  py -3 -I tools\build_guide.py
截圖來源是「沒有任何帳號資料的乾淨介面」（只有示範用的假資料），不含你的帳號、密碼、通知網址。
"""
import json, re, subprocess, sys, time, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UI = ROOT / "ui"
OUT = UI / "guide"
EDGE = next((p for p in (r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
                         r"C:\Program Files\Microsoft\Edge\Application\msedge.exe") if Path(p).exists()), None)
PROFILE = ROOT / "work" / "guide_edge_profile"
W = 1360

# ----------------------------------------------------------------------------- 教學內容
# 每章：(id, 按鈕文字, [步驟])；步驟：dict(title, html, shot=dict(page, sub, h, js, boxes=[(選擇器, 說明)]))
DEMO_ROWS = ("document.getElementById('accountRows').innerHTML="
             "'<tr><td><input type=checkbox checked></td><td>範例角色 A</td><td>● 監控中</td><td>31,200 / 31,200</td><td>商洞電算室入口</td><td><input type=checkbox checked></td></tr>"
             "<tr><td><input type=checkbox checked></td><td>範例角色 B</td><td>● 監控中</td><td>28,760 / 30,000</td><td>末日禁地島</td><td><input type=checkbox checked></td></tr>"
             "<tr><td><input type=checkbox></td><td>範例角色 C</td><td>○ 未連接</td><td>—</td><td>—</td><td><input type=checkbox></td></tr>';"
             "document.getElementById('homeSummary').textContent='2 個角色監控中';")

CHAPTERS = [
 ("gd1", "① 開始前", [
  dict(title="需要準備什麼", html="""
<ul>
<li><b>遊戲</b>：已安裝好、手動登入過一次，確認可以正常進入遊戲。</li>
<li><b>遊戲畫面大小</b>：視窗模式 <b>1024×768</b>，Windows 顯示縮放建議 <b>100%</b>（不是 100% 時程式會自動換算，但請不要用其他解析度）。</li>
<li><b>遊戲帳號</b>：想掛幾隻角色就準備幾組帳號密碼（密碼存在這台電腦、用 Windows 加密，不會上傳）。</li>
<li><b>Discord</b>（想收通知才需要）：一個自己能管理的伺服器和文字頻道，下一章會教你建立 Webhook。</li>
<li><b>授權</b>：第一次使用請到「設定 → 其他 → 使用授權」輸入授權碼。</li>
</ul>
<div class="gd-tip">教學裡每張圖都是這支程式的真實畫面，<b>紅框＋編號</b>就是這一步要看 / 要按的地方；編號對應圖下方的說明。</div>"""),
  dict(title="認識主畫面", html="第一次打開會看到「首頁」。左邊是選單：首頁、角色、收益統計、功能、操作教學（就是這裡）、設定。",
       shot=dict(page="home", h=820, js=DEMO_ROWS, boxes=[
           ("#nav", "左側選單：換頁用。設定在最下面。"),
           (".hero-actions", "三個大按鈕：啟動勾選帳號、開始監控、F10 停止自動操作。"),
           (".feat-card", "「目前啟動的功能」：綠色＝開著，灰色＝關閉，點一下跳到該功能的設定。"),
           (".home-table", "角色列表：狀態、血量、所在地圖，每個角色可以分開開關「監控」。")])),
 ]),
 ("gd2", "② 第一次設定", [
  dict(title="啟動與登入設定", html="到「設定 → 🚀 啟動與登入」。最上面的「設定檢查」會自己檢查目前設定能不能用，<b>只有沒通過的項目才需要處理</b>。",
       shot=dict(page="setup", sub="settings", h=1180, boxes=[
           ("#setupWizard .formgrid", "設定檢查：遊戲程式、登入位置、角色血量，三項都亮綠燈就可以用了。"),
           ("#wizardFlow", "六個步驟：帳號 → 遊戲視窗 → 登入位置 → 角色血量 → 所在地圖 → 開始監控，照順序做。"),
           ("text:選擇啟動程式", "按這裡選擇遊戲的啟動程式（遊戲資料夾裡的 Launcher.exe）。自動登入、重新登入時會用它開遊戲。"),
           ("text:檢查既有設定", "改完設定後按這個，重新檢查一次。")])),
  dict(title="登入後選擇角色", html="如果一個遊戲帳號底下有多隻角色，在「登入後選擇角色」指定重新登入後要進哪一隻（依順序或依角色名稱）。選項要等該帳號的遊戲開著時才讀得到，讀過一次就會記住。",
       shot=dict(page="setup", sub="settings", h=1180, boxes=[
           ("#settingsCoords .card", "登入後選擇角色：每個帳號各一列。登入畫面的位置是直接讀遊戲，不需要先記點。")])),
 ]),
 ("gd3", "③ Discord 通知", [
  dict(title="Webhook 是什麼？", html="""
<p>Webhook 是 Discord 頻道給的一組<b>專屬網址</b>：程式把訊息丟到這個網址，那個頻道就會收到通知（斷線、死亡、每日報表…）。下面用 Discord 電腦版的<b>實際畫面</b>示範，約 1 分鐘就能完成。</p>
<div class="gd-tip">沒有自己的伺服器？在 Discord 左側按「＋」→「親自建立」→「僅供我和我的朋友使用」，建一個專用的伺服器和文字頻道就好。要有「管理 Webhook」權限（自己建的伺服器預設就有）。</div>"""),
  dict(title="步驟 1：打開要收通知的頻道的設定", html="進入伺服器，把滑鼠移到要收通知的<b>文字頻道</b>上，右邊會出現兩個小圖示，按<b>⚙（編輯頻道）</b>。",
       pics=[dict(file="dc_a_gear.png", w=295, h=95, boxes=[(258, 25, 32, 32, "按 ⚙「編輯頻道」。（建議另外建一個專門收通知的頻道，例如 #通知。）")])]),
  dict(title="步驟 2：選「整合」", html="頻道設定的左邊選單裡點<b>整合</b>。",
       pics=[dict(file="dc_b_menu.png", w=255, h=215, boxes=[(3, 126, 244, 38, "點「整合」。")])]),
  dict(title="步驟 3：建立 Webhook", html="在「Webhook」那一列按<b>建立 Webhook</b>（如果這個頻道已經有 Webhook，按左上角的「新 Webhook」）。",
       pics=[dict(file="dc_c_integrations.png", w=1040, h=380, boxes=[(826, 202, 118, 38, "按「建立 Webhook」。")])]),
  dict(title="步驟 4：命名、確認頻道、複製網址", html="Discord 會建立一個 Webhook（預設名字很怪，可以改）。",
       pics=[dict(file="dc_d_webhook.png", w=1040, h=560, boxes=[
           (443, 408, 242, 44, "名稱：改成你認得的，例如 HIHIYONG；通知裡會用這個名字發言。"),
           (701, 408, 242, 44, "頻道：確認是要收通知的那個頻道，可以從這裡換。"),
           (443, 497, 146, 36, "按「複製 Webhook 網址」。接著切回本程式貼上（下一步）；改了名稱要先按下方的「儲存變更」。")])],
       html2="""<div class="gd-warn"><b>Webhook 網址等於這個頻道的「發言密碼」</b>：不要貼到公開地方、不要截圖給別人（所以上面的畫面刻意沒有顯示網址）。程式儲存後會加密保存，畫面上也只顯示成圓點。想把「斷線通知」和「死亡通知」分開收，就在兩個頻道各建一個 Webhook；不分的話兩邊貼同一個網址也可以。</div>"""),  dict(title="把網址貼進程式", html="到「設定 → 💬 通知與報表」，照編號填：",
       shot=dict(page="setup", sub="notifyTab", h=820, boxes=[
           ("#recDiscordOn", "勾選「啟用」＝斷線 / 自動重新登入時發通知。"),
           ("#discordPc", "這台電腦的名稱：多台電腦各自設定時，通知裡會顯示是哪一台。"),
           ("#recWebhook", "貼上「斷線通知」用的 Webhook 網址（貼上後顯示成圓點）。"),
           ("#deathDiscordOn", "勾選＝角色死亡 / 復活時發通知。"),
           ("#deathWebhook", "貼上「死亡通知」用的 Webhook 網址。"),
           ("text:儲存 Discord 設定", "填完一定要按這個才會存。"),
           ("text:發送測試：斷線通知", "按測試，Discord 頻道收到訊息就成功了；死亡通知也有自己的測試鈕。")])),
  dict(title="每日報表與截圖（選用）", html="報表和截圖會發到<b>斷線通知</b>那個頻道：每天固定時間送出前一天的收益報表、定時把所有遊戲視窗拼成一張圖、異常時附上當下畫面。",
       shot=dict(page="setup", sub="notifyTab", h=820, boxes=[
           ("#repTime", "每日報表發送時間，例如 08:00；留空不發。"),
           ("#repShot", "定時截圖：不發送，或每 30 分鐘到 4 小時一次。"),
           ("#repErr", "異常時截圖：斷線、假在線、卡復活等狀況附上畫面。"),
           ("text:儲存報表 / 截圖設定", "設定完按這裡儲存；旁邊兩顆可以立即發一份測試。")])),
 ]),
 ("gd4", "④ 新增帳號", [
  dict(title="建立帳號並設定選項", html="到「設定 → 🔑 帳號」。新增的帳號預設<b>不</b>納入監控，填好資料、連上遊戲視窗後再開。",
       shot=dict(page="setup", sub="accounts", h=780, boxes=[
           ("text:＋ 新增帳號", "按這裡新增一個空白帳號。"),
           ("#acctName", "名稱（顯示用）：隨你取，建議和遊戲角色名一樣，自動連接視窗時會依角色名配對。"),
           ("#acctLogin", "遊戲帳號。"),
           ("#acctPassword", "遊戲密碼（加密保存；之後修改其他選項時留空就會保留原密碼）。"),
           (".formgrid:has(#acctEnabled)", "各種開關：納入監控、批次啟動、死亡偵測 / 通報 / 警報音、假在線偵測與自動恢復、優先重新登入（隊長）。"),
           ("text:儲存帳號", "全部填好按「儲存帳號」。")])),
  dict(title="這些選項怎麼選", html="""
<ul>
<li><b>納入監控</b>：開了才會被偵測死亡、斷線、假在線。</li>
<li><b>批次啟動時開啟</b>：按首頁「啟動勾選帳號」時，會一起把這個帳號的遊戲開起來並自動登入。</li>
<li><b>死亡偵測 / 死亡通報 / 死亡警報音</b>：死亡超過 30 秒沒復活才會響警報；通報會發到 Discord。</li>
<li><b>假在線偵測 / 假在線自動恢復</b>：角色看起來在線但其實沒動（血量、經驗、金幣、背包都沒變）時提醒，自動恢復會重新登入。建議只對長時間掛機打怪的角色開自動恢復。</li>
<li><b>優先重新登入（隊長）</b>：大家一起斷線時，勾了的角色最先登回來。</li>
</ul>"""),
  dict(title="連接遊戲視窗", html="帳號存好、遊戲也開著之後，在下面的「遊戲視窗綁定」把帳號和遊戲視窗配對。一般按「自動連接」就好。",
       shot=dict(page="setup", sub="accounts", h=780, boxes=[
           ("text:自動連接遊戲視窗", "依遊戲中的角色名稱自動配對。"),
           ("#gameSelect", "配錯時，手動從這裡選遊戲視窗，再按「連接選定視窗」。"),
           ("text:顯示遊戲視窗", "不確定是哪一個視窗時，按這個把它顯示出來確認。")])),
 ]),
 ("gd5", "⑤ 開始掛機", [
  dict(title="啟動、監控、緊急停止", html="""
<ol class="gd-steps">
<li>回到「首頁」。在角色列表勾選要啟動的角色（「啟動」欄）。</li>
<li>按<b>啟動勾選帳號</b>：程式會開遊戲、自動登入、連接視窗。已經開著遊戲的話可以跳過這步。</li>
<li>按<b>開始監控</b>：開始偵測死亡、斷線、假在線，並在需要時自動重新登入。</li>
<li>任何時候想停下所有自動操作，按<b>F10</b>（鍵盤）或畫面上的紅色按鈕；遊戲不會被關閉。</li>
</ol>""",
       shot=dict(page="home", h=820, js=DEMO_ROWS, boxes=[
           ("text:啟動勾選帳號", "開遊戲、自動登入。"),
           ("text:開始監控", "開始偵測與自動恢復。"),
           ("text:F10 停止自動操作", "緊急停止（也可以直接按鍵盤 F10）。"),
           ("#accountRows", "每個角色的「監控」欄可以單獨開關。")])),
  dict(title="縮小程式也能看狀態（小窗）", html="想把程式縮小又想看狀態：到「設定 → 🧰 其他」勾選「縮小程式時顯示小窗」。縮小主視窗後，螢幕右下角會出現一個永遠在最上面的小窗，<b>滑鼠滾輪或 ◀ ▶ 切頁</b>：① 概況 ② 角色清單 ③ 功能開關（忘記勾的功能可以直接在小窗開）。",
       shot=dict(page="setup", sub="logs", h=820, boxes=[
           ("#miniWin", "勾選就啟用小窗。")])),
 ]),
 ("gd6", "⑥ 角色頁", [
  dict(title="角色狀態", html="「角色」→「👥 角色狀態」：每個角色一張卡，看血量、活動圖、今日死亡次數、是否假在線。", shot=dict(page="roles", sub="roleCards", h=820, boxes=[
       ("#hpCards", "每個角色的血量卡片（連接遊戲後才有資料）。")])),
  dict(title="每日道具 / 重新登入", html="「🎁 每日道具」處理每天要領的道具；「🔁 重新登入」統計自動重新登入的成功率與最常卡住的步驟，不影響任何自動操作。",
       shot=dict(page="roles", sub="daily", h=900, boxes=[("#daily .card", "每日道具設定與狀態。")])),
  dict(title="寵物 / 雇傭兵 / 魔法娃娃監測", html="掛機中發現寵物、雇傭兵或魔法娃娃不在外面，就按快捷欄裡那張卡叫出來。<b>只在遊戲資料確認「不在外面」時才按</b>，避免「開關型」的卡被按成收起來。",
       shot=dict(page="roles", sub="companion", h=820, boxes=[
           ("#cwPet", "勾選要監測的種類：寵物、雇傭兵、魔法娃娃。"),
           ("#cwRows", "每個角色目前的狀態。")])),
  dict(title="流暢度偵測", html="「久掛延遲量測」每 30 秒記錄記憶體、CPU、視窗回應時間；看到動作變慢時按「標記 Lag」方便比對。「變慢自動過圖」偵測到變慢會自動換圖恢復。",
       shot=dict(page="roles", sub="lagtab", h=900, boxes=[
           ("#lagOn", "久掛延遲量測開關。"), ("#lfOn", "變慢自動過圖開關（預設關閉）。")])),
 ]),
 ("gd7", "⑦ 功能頁", [
  dict(title="🎁 命運箱子", html="定時自動開命運箱子：切到遊戲視窗按快捷鍵、確認背包數量減少才算成功、再切回原本視窗。每個角色可自選。你正在操作鍵盤滑鼠時不會切視窗（停手一段時間才動作）。",
       shot=dict(page="tools", sub="mbox", h=640, boxes=[("#mbox .card", "開關、間隔秒數、每個角色的按鍵。")])),
  dict(title="🤝 自動組隊", html="全部登入完成後，由隊長邀請設定好的隊員；隊員斷線重登會自動補邀。可設定兩台電腦組隊（對方要先是好友）。預設關閉。",
       shot=dict(page="tools", sub="party", h=1100, boxes=[("#party .card", "先勾隊長，再勾這位隊長要帶的隊員。")])),
  dict(title="🎯 每日討伐", html="自動完成每日討伐：搭公車到目標地圖、走到固定點、開自動打怪、看進度換圖，死亡會復活後繼續。選角色與地圖後按啟動；<b>啟動前會等你停手 2 秒</b>。",
       shot=dict(page="tools", sub="dailyhunt", h=1100, boxes=[("#dailyhunt .card", "選角色、選地圖、啟動 / 停止。")])),
  dict(title="⌨️ 視窗按鍵精靈", html="自己挑要加入的遊戲視窗，每個視窗可自由設定<b>停留秒數</b>和<b>切過去後要按的鍵</b>（多個鍵用逗號，例如 H,W,P），依清單順序輪流切換並按鍵。",
       shot=dict(page="tools", sub="switcher", h=1100, boxes=[
           ("text:▶ 啟動", "啟動 / 停止。"),
           ("#switchSeconds", "這個視窗停留幾秒。"),
           ("#switchKeys", "切過去之後按哪些鍵。"),
           ("text:儲存此視窗設定", "每個視窗設好都要儲存。")])),
  dict(title="🗂️ 視窗位置", html="記錄每個遊戲視窗的位置與大小，開始監控或重新登入後自動還原，避免視窗亂跑。",
       shot=dict(page="tools", sub="layout", h=640, boxes=[
           ("#layoutAuto", "啟動監控時自動還原。"),
           ("text:記錄目前全部位置", "排好視窗後按這個記下來。")])),
  dict(title="🚧 開發中：技能組合 / 背包清理", html="還在調整的功能，建議先在單一角色試用。<b>技能組合</b>：設定觸發鍵，一鍵連按一組技能；<b>背包清理</b>：依序清理多個角色的背包。",
       shot=dict(page="tools", sub="devzone", h=900, boxes=[("#devzone .dev-tabs", "切換：技能組合 / 背包清理。")])),
 ]),
 ("gd8", "⑧ 統計與維護", [
  dict(title="收益統計", html="「收益統計」：每 5 秒讀各角色背包 / 銀行 / 裝備，和上次比較，統計每天打怪拾取、金幣與道具變化；角色之間互相轉移的不會重複計算。可匯出 CSV；「掉落率」讀遊戲掉落表（已套用伺服器倍率）。",
       shot=dict(page="invstats", sub="invMain", h=820, boxes=[("#invMain", "每日收益。")])),
  dict(title="遊戲改版後會怎樣", html="遊戲更新後，程式會自動準備新版的資料位置：先看有沒有內建、再到 GitHub 下載、再用 Game.pdb 解析，都沒有時由已登入的遊戲自動推算。期間畫面會顯示「正在等待新版資料位置」，約每 10 分鐘重試；也可以按左下角「檢查更新」。"),
  dict(title="遇到問題怎麼辦", html="""
<ul>
<li>「設定 → 🚀 啟動與登入」→ <b>系統自檢</b>：檢查常見問題。</li>
<li>「設定 → 🧰 其他」→ <b>開啟執行紀錄</b>：看程式做了什麼；<b>匯出診斷包</b>可以打包成 zip 給協助的人（<b>不含帳號密碼、通知網址、授權檔</b>）。</li>
<li>血量一直讀不到：「啟動與登入」→ 重新校正血量讀取。</li>
<li>換電腦後自動登入點錯位置：先確認遊戲視窗大小和 Windows 顯示縮放與原本一樣。</li>
<li>任何時候覺得不對勁：按 <b>F10</b> 停止所有自動操作。</li>
</ul>"""),
 ]),
]

CSS = """
.gd-step{background:var(--surface,#fff);border:1px solid var(--line);border-radius:14px;padding:18px 20px;margin-bottom:16px}
.gd-step h3{margin:0 0 8px;font-size:16px}
.gd-step p,.gd-step li{line-height:1.75}
.gd-step ul,.gd-step ol{padding-left:22px;margin:8px 0}
.gd-shot{position:relative;margin-top:12px;border:1px solid var(--line);border-radius:10px;overflow:hidden;line-height:0}
.gd-shot img{width:100%;display:block}
.gd-box{position:absolute;border:3px solid #e11d48;border-radius:6px;box-shadow:0 0 0 2px rgba(255,255,255,.85);pointer-events:none}
.gd-box b{position:absolute;left:-3px;top:-11px;transform:translateY(-50%);background:#e11d48;color:#fff;border-radius:999px;min-width:20px;height:20px;line-height:20px;font-size:12px;text-align:center;padding:0 4px;font-weight:700}
.gd-legend{margin:12px 0 0;padding:0;list-style:none;display:grid;gap:6px}
.gd-legend li{display:flex;gap:10px;align-items:flex-start;line-height:1.6}
.gd-legend li b{flex:none;background:#e11d48;color:#fff;border-radius:999px;min-width:20px;height:20px;line-height:20px;font-size:12px;text-align:center;font-weight:700}
.gd-tip{background:var(--chip,#eef4ff);border-radius:10px;padding:10px 14px;margin-top:10px;line-height:1.7}
.gd-warn{background:#fff1f2;color:#9f1239;border:1px solid #fecdd3;border-radius:10px;padding:10px 14px;margin-top:10px;line-height:1.7}
"""


# ----------------------------------------------------------------------------- 截圖
HOOK = r"""
<script>
(function(){
 var cfg={};try{cfg=JSON.parse(decodeURIComponent(location.hash.slice(1)));}catch(e){}
 function find(sel){
  if(sel.indexOf('text:')===0){
   var t=sel.slice(5),best=null,bl=1e9;
   [].slice.call(document.querySelectorAll('button,.btn,label,.section-title,.field,.status-pill,.card,summary')).forEach(function(e){
    if(e.offsetParent===null)return;var s=(e.textContent||'').replace(/\s+/g,' ').trim();
    if(s.indexOf(t)>=0&&s.length<bl){best=e;bl=s.length;}
   });
   return best;
  }
  var els=[].slice.call(document.querySelectorAll(sel));
  return els.filter(function(e){return e.offsetParent!==null;})[0]||null;
 }
 window.addEventListener('load',function(){setTimeout(function(){
  try{window.send=function(){};window.showToast=function(){};}catch(e){}
  try{
   if(cfg.page){var b=document.querySelector('.side [data-page="'+cfg.page+'"]');if(b)b.click();if(cfg.sub)showSub(cfg.page,cfg.sub);}
   if(cfg.js)(0,eval)(cfg.js);
  }catch(e){document.title='__RERR '+e;return;}
  setTimeout(function(){
   var out=[];
   (cfg.boxes||[]).forEach(function(sel){
    var el=find(sel);
    if(!el){out.push(null);return;}
    var r=el.getBoundingClientRect();
    out.push([r.left,r.top,r.width,r.height]);
   });
   document.title='__R'+JSON.stringify({w:innerWidth,h:innerHeight,boxes:out});
  },500);
 },500);});
})();
</script>
"""


def cap_url(shot):
    cfg = {"page": shot.get("page"), "sub": shot.get("sub"), "js": shot.get("js"),
           "boxes": [b[0] for b in shot.get("boxes", [])]}
    from urllib.parse import quote
    return (UI / "_capture.html").as_uri() + "#" + quote(json.dumps(cfg, ensure_ascii=False))


def edge_args(extra):
    return [EDGE, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
            f"--user-data-dir={PROFILE}", "--hide-scrollbars", "--force-device-scale-factor=1"] + extra


def capture(shot, png, port):
    global PROFILE
    PROFILE = ROOT / "work" / f"guide_edge_{time.time_ns()}"   # 每次用新的設定資料夾，避免上一個 Edge 還沒完全結束時卡住
    h = shot.get("h", 820)
    url = cap_url(shot)
    # 1) 截圖
    for attempt in range(3):
        r = subprocess.run(edge_args([f"--window-size={W},{h}", "--virtual-time-budget=5000", f"--screenshot={png}", url]),
                           capture_output=True, timeout=90)
        if Path(png).exists():
            break
        print(f"  截圖重試 {attempt + 1}（結束碼 {r.returncode}）{r.stderr[-300:]!r}", file=sys.stderr)
        time.sleep(2)
    if not Path(png).exists():
        raise SystemExit(f"截圖失敗：{png}")
    # 2) 取元件位置（網頁把結果寫在標題）；偶爾 Edge 沒起來，換新的設定資料夾和連接埠重試
    res = None
    for attempt in range(3):
        PROFILE = ROOT / "work" / f"guide_edge_{time.time_ns()}"
        proc = subprocess.Popen(edge_args([f"--window-size={W + 24},{h + 92}", f"--remote-debugging-port={port + attempt * 50}", url]),
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(50):
                time.sleep(0.5)
                try:
                    tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port + attempt * 50}/json/list", timeout=2))
                except Exception:
                    continue
                for t in tabs:
                    if t.get("type") == "page" and t.get("title", "").startswith("__R"):
                        res = t["title"]
                        break
                if res:
                    break
        finally:
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(1)
        if res:
            break
        print(f"  量位置重試 {attempt + 1}", file=sys.stderr)
    if not res or res.startswith("__RERR"):
        raise SystemExit(f"取不到元件位置：{shot.get('page')}/{shot.get('sub')}｜{res}")
    import html
    data = json.loads(html.unescape(res[3:]))
    if (data["w"], data["h"]) != (W, h):
        raise SystemExit(f"量位置時的視窗大小 {data['w']}x{data['h']} 和截圖 {W}x{h} 不同，位置會對不上")
    return data


def render_step(step, idx, shots_dir_rel):
    parts = [f'<div class="gd-step"><h3>{step["title"]}</h3>']
    if step.get("html"):
        h = step["html"].strip()
        parts.append(h if h.startswith("<") else f"<p>{h}</p>")
    for pic in step.get("pics", []):
        mw = f' style="max-width:{int(pic["w"] * 1.6)}px"' if pic["w"] < 600 else ""   # 小張的裁切圖不要放大到整排寬
        parts.append(f'<div class="gd-shot"{mw}><img src="{shots_dir_rel}/{pic["file"]}" alt="{step["title"]}" loading="lazy">')
        legend = []
        for n, (x, y, bw, bh, label) in enumerate(pic["boxes"], 1):
            parts.append(f'<i class="gd-box" style="left:{x / pic["w"] * 100:.3f}%;top:{y / pic["h"] * 100:.3f}%;width:{bw / pic["w"] * 100:.3f}%;height:{bh / pic["h"] * 100:.3f}%"><b>{n}</b></i>')
            legend.append(f'<li><b>{n}</b><span>{label}</span></li>')
        parts.append("</div>")
        if legend:
            parts.append('<ul class="gd-legend">' + "".join(legend) + "</ul>")
    shot = step.get("shot")
    if shot:
        boxes, png = shot["_rects"], shot["_png"]
        w, h = boxes["w"], boxes["h"]
        parts.append(f'<div class="gd-shot"><img src="{shots_dir_rel}/{png}" alt="{step["title"]}" loading="lazy">')
        legend = []
        n = 0
        for (sel, label), r in zip(shot["boxes"], boxes["boxes"]):
            if r is None:
                print(f"  ! 找不到元件：{sel}", file=sys.stderr)
                continue
            n += 1
            x, y, bw, bh = r
            pad = 4
            l, t = max(0, x - pad), max(0, y - pad)
            bw2, bh2 = min(w - l, bw + 2 * pad), min(h - t, bh + 2 * pad)
            parts.append(f'<i class="gd-box" style="left:{l / w * 100:.3f}%;top:{t / h * 100:.3f}%;width:{bw2 / w * 100:.3f}%;height:{bh2 / h * 100:.3f}%"><b>{n}</b></i>')
            legend.append(f'<li><b>{n}</b><span>{label}</span></li>')
        parts.append("</div>")
        if legend:
            parts.append('<ul class="gd-legend">' + "".join(legend) + "</ul>")
    if step.get("html2"):
        parts.append(step["html2"].strip())
    parts.append("</div>")
    return "\n".join(parts)


def main():
    if not EDGE:
        raise SystemExit("找不到 Microsoft Edge")
    OUT.mkdir(exist_ok=True)
    index = UI / "index.html"
    src = index.read_text(encoding="utf-8")
    cap = UI / "_capture.html"
    cap.write_text(src.replace("</body>", HOOK + "</body>"), encoding="utf-8")
    try:
        n = 0
        port = 9411
        for cid, _, steps in CHAPTERS:
            for s in steps:
                shot = s.get("shot")
                if not shot:
                    continue
                n += 1
                png = f"{cid}_{n:02d}.png"
                print(f"[{n}] {cid} {shot.get('page')}/{shot.get('sub', '')} → {png}")
                shot["_png"] = png
                shot["_rects"] = capture(shot, OUT / png, port + n)
    finally:
        cap.unlink(missing_ok=True)
        import shutil
        for d in (ROOT / "work").glob("guide_edge_*"):
            shutil.rmtree(d, ignore_errors=True)
    nav = "".join('<button data-sub="%s"%s>%s</button>' % (cid, ' class="active"' if i == 0 else "", label) for i, (cid, label, _) in enumerate(CHAPTERS))
    body = []
    for i, (cid, _, steps) in enumerate(CHAPTERS):
        body.append(f'<div class="subpage" id="{cid}">')
        body += [render_step(s, k, "guide") for k, s in enumerate(steps)]
        body.append("</div>")
    section = ('<!--GUIDE-START-->\n<section class="page" id="guide">\n<div class="subtabs">' + nav + "</div>\n"
               + "\n".join(body) + "\n</section>\n<!--GUIDE-END-->")
    if "<!--GUIDE-START-->" in src:
        src = re.sub(r"<!--GUIDE-START-->.*?<!--GUIDE-END-->", lambda m: section, src, flags=re.S)
    else:
        src = src.replace('<section class="page" id="setup">', section + '\n<section class="page" id="setup">', 1)
    css = "/*GUIDE-CSS-START*/" + CSS + "/*GUIDE-CSS-END*/"
    if "/*GUIDE-CSS-START*/" in src:
        src = re.sub(r"/\*GUIDE-CSS-START\*/.*?/\*GUIDE-CSS-END\*/", lambda m: css, src, flags=re.S)
    else:
        src = src.replace("</style>", css + "\n</style>", 1)
    index.write_text(src, encoding="utf-8", newline="")
    print(f"完成：{n} 張截圖，教學已寫進 ui\\index.html")


if __name__ == "__main__":
    main()
