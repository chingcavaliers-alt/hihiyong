// HIHIYONG 介面程式（原本在 index.html 的 <script>；和 AHK 用 hihiyong:// 網址與 PostWebMessage 溝通）
// v1.3.18.7 統一彩色 emoji 圖示（Windows 10 內建的 Segoe UI Emoji 都有）
const ICONS={
 home:'🏠',guide:'📖',hpmonitor:'❤️',invstats:'📦',daily:'🎁',switcher:'🔄',inventory:'🧹',layout:'🗂️',
 accounts:'🔑',monitor:'🚨',settings:'⚙️',logs:'🧰',people:'👥',window:'🎮',alert:'⚠️',wifi:'🌐',
 coin:'💰',trend:'📈',shield:'🛡️',skull:'💀'
};
function icon(name){return `<span class="emo" aria-hidden="true">${ICONS[name]||''}</span>`;}
function applyIcons(root=document){root.querySelectorAll('[data-icon]').forEach(e=>{if(!e.dataset.iconDone){e.innerHTML=icon(e.dataset.icon);e.dataset.iconDone='1';}});}
applyIcons();

const titles={home:'首頁',roles:'角色',invstats:'收益統計',tools:'功能',guide:'操作教學',setup:'設定'};


function normalizePrimaryMonitorControls(){
 document.querySelectorAll('button').forEach(b=>{
   if(b.id==='mainStartBtn'||b.id==='mainStopBtn'||b.id==='mainLaunchBtn')return;
   const t=(b.textContent||'').trim();
   if((t.includes('開始監控')||t.includes('停止監控')) && b.closest('.card')?.querySelector('.section-title')?.textContent==='快速操作') b.style.display='none';
 });
}
normalizePrimaryMonitorControls();

function moveCardByHeading(heading,targetId){
  const target=document.getElementById(targetId); if(!target)return;
  const cards=[...document.querySelectorAll('#home .card')];
  const card=cards.find(c=>{
    const t=(c.querySelector('.section-title')?.textContent||c.querySelector('div')?.textContent||'').trim();
    return t.includes(heading);
  });
  if(card) target.appendChild(card);
}
function organizePages(){
  // Move the actual v0.9.7 tested cards. No duplicate controls / IDs.
  moveCardByHeading('帳號管理','accounts');
  moveCardByHeading('Discord 通報','notify');
  moveCardByHeading('遊戲程式啟動','launcher');
  moveCardByHeading('8 點登入座標','coords');
  moveCardByHeading('地圖 / 位置判定','map');
  moveCardByHeading('監控 / 假在線','monitor');
  moveCardByHeading('Log / 工具','logs');

  // Remove old Preview placeholder cards once the real tested card exists on a page.
  const cleanup=['accounts','notify','launcher','coords','map','monitor','logs'];
  cleanup.forEach(id=>{
    const page=document.getElementById(id); if(!page)return;
    [...page.children].forEach(el=>{
      if(el.classList?.contains('card') && !el.querySelector('input,select') &&
         !el.querySelector('#profileSelect,#gameSelect') &&
         (el.textContent.includes('下一階段')||el.textContent.includes('此 Preview')||
          el.textContent.includes('沿用 v0.7.5.9')||el.textContent.includes('保留 8 點')||
          el.textContent.includes('手動測試會先')||el.textContent.includes('HP 背景監控不搶前景')))
        el.remove();
    });
  });
}
organizePages();


const pageDescriptions={
 home:'日常操作與帳號總覽',
 hpmonitor:'每個角色的血量與假在線狀態',
 accounts:'帳號密碼與遊戲視窗配對',
 notify:'自動恢復 / 死亡事件 Discord 通知',
 launcher:'Launcher 與登入後按鍵',
 coords:'8 點登入座標校正',
 map:'怪物區 / 復活點安全判定',
 monitor:'多帳號即時狀態、HP 變化、假在線偵測與 自動恢復',settings:'遊戲啟動程式、自動登入位置與 Discord 通知',switcher:'輪流顯示各角色的遊戲視窗',inventory:'依序清理多個角色的背包',layout:'記錄與還原每個遊戲視窗的位置',
 monitor:'假在線判定與網路狀態監看',
 invstats:'每日打怪拾取與金幣變化',
 daily:'一日道具到期提醒、自動更換與示範錄製',
 logs:'執行紀錄與診斷工具',
 roles:'每個角色的血量、地圖、死亡、擊殺、每日道具與重新登入',
 tools:'命運箱子、自動組隊、技能組合、視窗位置，以及開發中的功能',
 setup:'帳號、監控、自動登入與通知（設定好之後很少需要再動）'
};
pageDescriptions.home='角色狀態總覽';
pageDescriptions.invstats='每日金幣、打怪拾取與擊殺';
function ensurePageKickers(){
 Object.entries(pageDescriptions).forEach(([id,txt])=>{
   const p=document.getElementById(id); if(!p||p.querySelector('.page-kicker'))return;
   const d=document.createElement('div'); d.className='page-kicker'; d.textContent=txt; p.prepend(d);
 });
}
function showToast(msg){
 const t=document.getElementById('toast'); if(!t)return;
 t.textContent=msg; t.classList.add('show'); clearTimeout(window.toastTimer);
 window.toastTimer=setTimeout(()=>t.classList.remove('show'),2200);
}
function ensureScanFeedback(){
 document.querySelectorAll('button').forEach(b=>{
   if((b.textContent||'').includes('掃描 game.exe') && !b.dataset.scanWrapped){
     b.dataset.scanWrapped='1';
     const span=document.createElement('span'); span.className='scan-feedback'; span.dataset.scanFeedback='1';
     span.textContent='尚未掃描'; b.insertAdjacentElement('afterend',span);
     b.addEventListener('click',()=>showToast('正在掃描 game.exe…'));
   }
 });
}
ensurePageKickers(); ensureScanFeedback();


function cleanupLegacyWebUI(){
 document.querySelectorAll('.card').forEach(c=>{
   const t=(c.textContent||'');
   if(t.includes('Web 設定中心 · Phase 1')) c.remove();
 });
 document.querySelectorAll('button').forEach(b=>{
   if((b.textContent||'').trim()==='完整設定') b.style.display='none';
 });
}
cleanupLegacyWebUI();

// v1.3.9.6: consolidate configuration pages while keeping monitoring independent.
(function consolidateSettings(){
  const targets={launcher:'settingsLauncher',coords:'settingsCoords',map:'settingsMap',notify:'settingsNotify'};
  Object.entries(targets).forEach(([src,dst])=>{
    const source=document.getElementById(src), target=document.getElementById(dst);
    if(!source||!target)return;
    [...source.children].forEach(el=>target.appendChild(el));
    source.remove();
  });
  const mon=document.getElementById('monitor');
  if(mon){
    // v1.3.18.5：不再改寫監控頁標題（原本的空白標題卡已移除）
  }
})();
document.querySelectorAll('#nav button,#navBottom button').forEach(b=>b.onclick=()=>{document.querySelectorAll('#nav button,#navBottom button').forEach(x=>x.classList.remove('active'));b.classList.add('active');document.querySelectorAll('.page').forEach(x=>x.classList.remove('active'));document.getElementById(b.dataset.page).classList.add('active');document.getElementById('pageTitle').textContent=titles[b.dataset.page];const ps=document.getElementById('pageSub');if(ps)ps.textContent=pageDescriptions[b.dataset.page]||'';document.querySelector('.main').scrollTop=0;const st=document.querySelector(`#${b.dataset.page} .subtabs button.active`);if(st)onSubShown(st.dataset.sub)});
// v1.3.22.0 介面風格：存在主程式設定檔；本機也記一份，開啟時先套用避免閃一下預設色
const THEMES=[
 ['','石墨（預設）','簡潔專業的淺色',['#121419','#f4f5f7','#3b5bdb','#ffffff']],
 ['esports','暗夜電競','深色、青色霓虹',['#07090d','#0b0e14','#22d3ee','#141923']],
 ['gold','黑金尊爵','深色、金色、襯線標題',['#090807','#0f0e0c','#d4af37','#181613']],
 ['morning','清新晨光','暖白、珊瑚色、圓角',['#fffdfa','#f7f4ef','#e07a5f','#fffdfa']],
 ['fluent','Windows 11','霧面玻璃、藍色',['#e9eef8','#eef2f9','#0067c0','#ffffff']],
 ['rpg','冒險羊皮紙','羊皮紙、木頭、楷書',['#2a1d14','#e8dcc2','#8b1e1e','#f8efdc']],
];
function applyTheme(t){t=t||'';if(t)document.documentElement.dataset.theme=t;else delete document.documentElement.dataset.theme;try{localStorage.setItem('hhTheme',t);}catch(e){}renderThemeList();}
function renderThemeList(){const el=document.getElementById('themeList');if(!el)return;const cur=document.documentElement.dataset.theme||'';
 el.innerHTML=THEMES.map(([id,name,desc,c])=>`<button type="button" class="theme-opt${id===cur?' on':''}" onclick="applyTheme('${id}');send('uitheme',{value:'${id}'})"><span class="theme-sw">${c.map(x=>`<i style="background:${x}"></i>`).join('')}</span><b>${name}</b><small>${desc}</small></button>`).join('');}
try{const t=localStorage.getItem('hhTheme');if(t)document.documentElement.dataset.theme=t;}catch(e){}
renderThemeList();
// v1.3.22.0 側邊欄只剩圖示時，滑鼠移上去顯示名稱
document.querySelectorAll('#nav button,#navBottom button').forEach(b=>{b.title=(b.textContent||'').trim();});
// 換了桌面圖示後由主程式呼叫：左上角圖示跟著換
function refreshLogo(){const l=document.getElementById('appLogo');if(!l)return;l.dataset.fb='';l.src='../HiHiyong.ico?t='+Date.now();}
// v1.3.22.0 頁內分頁
function showSub(page,sub){
 document.querySelectorAll(`#${page} .subtabs button`).forEach(x=>x.classList.toggle('active',x.dataset.sub===sub));
 document.querySelectorAll(`#${page} > .subpage`).forEach(x=>x.classList.toggle('active',x.id===sub));
 document.querySelector('.main').scrollTop=0;
 onSubShown(sub);
}
function onSubShown(sub){
 if(sub==='daily'||sub==='roleCards')send('dailystate');
 if(sub==='recovery')send('recstats');
 if(sub==='dropRates')send('dropindex');
 if(sub==='mbox')send('mboxstate');
 if(sub==='lagtab')send('lagstate');
 if(sub==='party')send('partystate');
 if(sub==='companion')send('companionstate');
 if(sub==='dailyhunt')send('dailyhuntstate');
 if(sub==='automining')send('autominingstate');
 if(sub==='priority')send('prioritystate');
 if(sub==='buffcast')send('buffcaststate');
 if(sub==='settings')send('loginchars');
 if(sub==='invMain')requestInvStats();
 if(sub==='roleCards'&&(!invStatsSelected||invStatsSelected===invStatsToday))requestInvStats('',true);
}
document.querySelectorAll('.subtabs').forEach(t=>{
 const page=t.closest('.page').id;
 t.querySelectorAll('button').forEach(b=>b.onclick=()=>showSub(page,b.dataset.sub));
 const first=t.querySelector('button.active'); if(first)document.getElementById(first.dataset.sub)?.classList.add('active');
});
// 看得到才算（分頁在沒顯示的頁面裡也會帶 active）
function isShown(id){const e=document.getElementById(id);return !!e&&e.offsetParent!==null;}
// 區塊標題下第一段說明收進 ⓘ：第一次使用時點開看，平常不佔畫面
document.querySelectorAll('.section-title').forEach(t=>{
 const h=t.nextElementSibling;
 if(!h||!h.classList.contains('hint')||h.id)return;
 h.classList.add('intro');
 const b=document.createElement('button');b.className='info-btn';b.type='button';b.textContent='i';b.title='說明';
 b.onclick=e=>{e.preventDefault();e.stopPropagation();b.classList.toggle('on',h.classList.toggle('show'));};
 const pill=t.querySelector('.pill'); pill?t.insertBefore(b,pill):t.appendChild(b);
});
function send(action,payload={}){
const map={startMonitoring:'start',emergencyStop:'emergencystop',monitorcheck:'monitorcheck',batchStart:'batchstart',oneClick:'oneclick',switchNext:'switchnext',switchAutoStart:'switchautostart',switchAutoStop:'switchautostop',switchSave:'switchsave',inventoryStart:'inventorystart',inventoryStop:'inventorystop',layoutSave:'layoutsave',layoutRestore:'layoutrestore',invBindScan:'invbindscan',invPause:'invpause',resetAllStats:'resetallstats',restartChecked:'restartchecked',autoBind:'autobind',stopMonitoring:'stop',refreshGames:'refresh',checkHP:'checkhp',calibrateHP:'calibratehp',
profileSelect:'profile',gameSelect:'game',bindSelected:'bind',unbindSelected:'unbind',
showWindow:'show',recordPosition:'position',manualRecover:'recover',resetStats:'resetstats',
evidenceTest:'evidence',openLog:'log',openSettings:'settings',launcherPage:'launcherpage',coordPage:'coordpage',mapPage:'mappage',monitorPage:'monitorpage',notifyPage:'notifypage',toolsPage:'toolspage',launcherBrowse:'launcherbrowse',postKeys:'postkeys',coordStart:'coordstart',coordRecord:'coordrecord',coordClear:'coordclear',mapProfile:'mapprofile',mapTest:'maptest',mapConf:'mapconf',mapZoom:'mapzoom',mapReturn:'mapreturn',accountAdd:'accountadd',accountSave:'accountsave',accountDelete:'accountdelete',accountToggle:'accounttoggle',notifySave:'notifysave',recoveryTest:'recoverytest',deathTest:'deathtest',monitorSave:'monitorsave',evidenceTest2:'evidencetest',showLog2:'showlog',saveAll2:'saveall',selfCheck:'selfcheck'};
const cmd=map[action]||action; const hasValue=Object.prototype.hasOwnProperty.call(payload,'value');
const v=hasValue?payload.value:'';
location.href='hihiyong://'+cmd+(hasValue?'/'+encodeURIComponent(String(v)):'');
}

const dirtyFields=new Set();
function markFieldDirty(id){dirtyFields.add(id);setDirty(true);}
function clearFieldDirty(id){dirtyFields.delete(id);}
function isEditing(id){const e=document.getElementById(id);return !!e&&(document.activeElement===e||dirtyFields.has(id));}
function bindStableInputs(){
 ['discordPc','recWebhook','deathWebhook','softIdle','softConfirm','softVotes','softMultiAssist','webPostKeys','webMapConf','webMapZoom','webMapReturn','acctName','acctLogin','acctPassword','repTime','repShot','repErr'].forEach(id=>{
  const e=document.getElementById(id);if(e){e.addEventListener('input',()=>markFieldDirty(id));e.addEventListener('change',()=>markFieldDirty(id));}
 });
}
bindStableInputs();

let latestState=null;


function setLayoutAuto(on){
 location.href='hihiyong://layoutauto/'+(on?1:0);
 showToast(on?'✓ 已開啟監控啟動自動還原':'已關閉監控啟動自動還原');
}

function sendAlarmGlobal(){ const on=document.getElementById('alarmOn')?.checked?1:0; const sec=Math.max(5,Math.min(300,Number(document.getElementById('alarmSec')?.value||30))); location.href='hihiyong://alarmglobal/'+on+'~'+sec; }
function toggleAcctPassword(){
 const e=document.getElementById('acctPassword'); if(!e)return;
 e.type=e.type==='password'?'text':'password';
 event.currentTarget.textContent=e.type==='password'?'顯示':'隱藏';
}

function showInventoryRawWindow(){
 const hwnd=Number(document.getElementById('invWindowSelect')?.value||0); if(!hwnd){showToast('請先選擇遊戲視窗');return;} location.href='hihiyong://invshowwindow/'+hwnd;
}
function showInventoryProfileWindow(){
 const o=document.getElementById('invProfileSelect')?.selectedOptions?.[0]; const hwnd=Number(o?.dataset?.hwnd||0); if(!hwnd){showToast('請先選擇已綁定帳號');return;} location.href='hihiyong://invshowwindow/'+hwnd;
}
function addInventoryProfile(){
 const idx=Number(document.getElementById('invProfileSelect')?.value||0); if(!idx){showToast('請先選擇已綁定帳號');return;} location.href='hihiyong://invbindaddprofile/'+idx;
}
function addInventoryBinding(){
 const sel=document.getElementById('invWindowSelect');
 const hwnd=Number(sel?.value||0);
 if(!hwnd){showToast('請先選擇遊戲視窗');return;}
 const name=encodeURIComponent((document.getElementById('invBindName')?.value||'').trim());
 location.href='hihiyong://invbindadd/'+hwnd+'~'+name;
}
function removeInventoryBinding(idx){
 if(!confirm('確定把這個角色從清理清單移除？不影響帳號本身。'))return;
 location.href='hihiyong://invbindremove/'+idx;
}
function setInventoryBindingCheck(idx,on){
 location.href='hihiyong://invbindcheck/'+idx+'~'+(on?1:0);
}

function saveInvStartHotkey(){
 const v=(document.getElementById('invStartHotkey')?.value||'').trim();
 if(!v){showToast('請輸入啟動快捷鍵');return;}
 location.href='hihiyong://invstarthotkey/'+encodeURIComponent(v);
}
function saveInvPauseHotkey(){
 const v=(document.getElementById('invPauseHotkey')?.value||'').trim();
 if(!v){showToast('請輸入暫停快捷鍵');return;}
 location.href='hihiyong://invpausehotkey/'+encodeURIComponent(v);
}
function saveInvStopHotkey(){
 const v=(document.getElementById('invStopHotkey')?.value||'').trim();
 if(!v){showToast('請輸入終止快捷鍵');return;}
 location.href='hihiyong://invstophotkey/'+encodeURIComponent(v);
}
function saveInventorySettings(){
 const vals=[
  Math.max(1,Math.min(5,Number(document.getElementById('invStartPage')?.value||1))),
  Math.max(1,Math.min(10,Number(document.getElementById('invStartRow')?.value||1))),
  Math.max(1,Math.min(5,Number(document.getElementById('invEndPage')?.value||5))),
  Math.max(1,Math.min(10,Number(document.getElementById('invEndRow')?.value||6))),
  document.getElementById('invSpeed')?.value||'STABLE'
 ];
 location.href='hihiyong://inventorysave/'+vals.join('~');
 showToast('✓ 已儲存背包清理範圍');
}
function startInventorySetup(){
 const idx=Number(document.getElementById('invSetupProfile')?.value||0);
 if(!idx){showToast('請先選擇已綁定角色');return;}
 location.href='hihiyong://inventorysetup/'+idx;
 showToast('請回到遊戲視窗，依提示按 F6 記錄 9 個點');
}
function setInventoryCheck(idx,on){
 location.href='hihiyong://inventorycheck/'+idx+'~'+(on?1:0);
}

function loadSwitchProfile(){
 const sel=document.getElementById('switchProfile'); if(!sel||!latestState)return;
 const p=(latestState.accounts||[]).find(x=>x.index===Number(sel.value)); if(!p)return;
 document.getElementById('switchEnabled').value=p.switchEnabled?'1':'0';
 document.getElementById('switchSeconds').value=p.switchSeconds||10;
 document.getElementById('switchKeys').value=p.switchKeys||'';
}
function saveSwitchSetting(){
 const idx=Number(document.getElementById('switchProfile')?.value||0); if(!idx){showToast('請先選擇帳號');return;}
 const en=document.getElementById('switchEnabled').value;
 const sec=Math.max(1,Number(document.getElementById('switchSeconds').value||10));
 const keys=(document.getElementById('switchKeys').value||'').replace(/~/g,'');
 send('switchSave',{value:`${idx}~${en}~${sec}~${keys}`}); showToast('✓ 已儲存此視窗切換設定');
}

function quickSwitchToggle(idx,on){
 const p=(latestState?.accounts||[]).find(x=>x.index===idx); if(!p)return;
 const sec=p.switchSeconds||10, keys=(p.switchKeys||'').replace(/~/g,'');
 send('switchSave',{value:`${idx}~${on?1:0}~${sec}~${keys}`});
 showToast(`${p.name}：${on?'已加入':'已排除'}視窗切換`);
}
function saveSwitchStopHotkey(){
 const v=(document.getElementById('switchStopHotkey')?.value||'').trim();
 send('switchStopHotkey',{value:v}); showToast(v?`✓ 停止快捷鍵已設定：${v}`:'✓ 已停用停止快捷鍵');
}
function renderSwitchPage(s){
 latestState=s;
 const sel=document.getElementById('switchProfile');
 if(sel){const old=Number(sel.value||0);sel.innerHTML='<option value="0">請選擇帳號</option>'+(s.accounts||[]).map(x=>`<option value="${x.index}">${esc(x.name)}${x.hwnd?'':'（未連接）'}</option>`).join('');if(old)sel.value=String(old);if(!Number(sel.value)&&s.accounts?.length)sel.value=String(s.accounts[0].index);if(document.activeElement!==document.getElementById('switchEnabled')&&document.activeElement!==document.getElementById('switchSeconds')&&document.activeElement!==document.getElementById('switchKeys'))loadSwitchProfile();}
 const rows=document.getElementById('switchRows');if(rows)rows.innerHTML=(s.accounts||[]).map(x=>`<tr><td>${esc(x.name)}</td><td>${x.hwnd?'✓ 已連接':'未連接'}</td><td><label class="monitor-switch"><input type="checkbox" ${x.switchEnabled?'checked':''} onchange="quickSwitchToggle(${x.index},this.checked)"> ${x.switchEnabled?'加入':'不加入'}</label></td><td>${x.switchSeconds||10}s</td><td>${esc(x.switchKeys||'—')}</td></tr>`).join('');
 const hn=document.getElementById('homeSwitchNext');if(hn)hn.textContent=s.autoSwitchNextName||'—';
 const hc=document.getElementById('homeSwitchCountdown');if(hc)hc.textContent=s.autoSwitchRunning?`目前：${s.autoSwitchCurrentName||'—'}｜剩餘 ${s.autoSwitchRemain||0} 秒`:'目前：已停止';
 const st=document.getElementById('switchStatus');if(st){st.textContent=s.autoSwitchRunning?(s.autoSwitchRecoveryPaused?'⏸ 重新登入中，暫停切換':'● 運行中'):'● 停止';st.className='status-pill '+(s.autoSwitchRunning?'good':'');}
 const cur=document.getElementById('switchCurrent');if(cur)cur.textContent=s.autoSwitchRunning?`${s.autoSwitchCurrentName||'—'}`:'—';
 const cd=document.getElementById('switchCountdown');if(cd)cd.textContent=`${s.autoSwitchRemain||0} 秒`;
 const nx=document.getElementById('switchNextInfo');if(nx)nx.textContent=`${s.autoSwitchNextName||'—'}`;
 const tt=document.getElementById('switchTotal');if(tt){const sec=Number(s.autoSwitchTotalSeconds||0),m=Math.floor(sec/60),r=sec%60;tt.textContent=`一個循環總設定時間：${sec} 秒${m?`（${m} 分 ${r} 秒）`:''}`;}
 const hk=document.getElementById('switchStopHotkey');if(hk&&document.activeElement!==hk)hk.value=s.switchStopHotkey||'';


const la=document.getElementById('layoutAuto');if(la)la.checked=!!s.layoutAutoRestore;
const mw=document.getElementById('miniWin');if(mw&&document.activeElement!==mw)mw.checked=!!s.miniWindow;
const lst=document.getElementById('layoutStatus');if(lst)lst.textContent=s.layoutStatus||'待命';
const lr=document.getElementById('layoutRows');if(lr)lr.innerHTML=(s.accounts||[]).map(x=>`<tr><td>${esc(x.name)}</td><td>${x.hwnd?'✓ 已連接':'未連接'}</td><td>${x.hasPos?`X ${x.winX} / Y ${x.winY}`:'未記錄'}</td><td>${x.hasPos?`${x.winW} × ${x.winH}`:'-'}</td><td>${esc(x.state||'')}</td></tr>`).join('');

const iprof=document.getElementById('invProfileSelect');
if(iprof){const old=Number(iprof.value||0);iprof.innerHTML='<option value="0">請選擇帳號</option>'+(s.inventoryProfileCandidates||[]).map(x=>`<option value="${x.index}" data-hwnd="${x.hwnd}">${esc(x.name)}</option>`).join('');if(old)iprof.value=String(old);}
const iws=document.getElementById('invWindowSelect');
if(iws){const old=Number(iws.value||0);iws.innerHTML='<option value="0">請選擇遊戲視窗</option>'+(s.inventoryWindows||[]).map((x,i)=>`<option value="${x.hwnd}">遊戲視窗 ${i+1}｜${x.charName?'角色 '+esc(x.charName):'尚未進入遊戲'}</option>`).join('');if(old)iws.value=String(old);}
const ibr=document.getElementById('invBindRows');
if(ibr)ibr.innerHTML=(s.inventoryBindings||[]).map(x=>`<tr><td><input type="checkbox" ${x.enabled?'checked':''} onchange="setInventoryBindingCheck(${x.index},this.checked)"></td><td>${esc(x.name)}</td><td>${x.alive?'🟢 在線':'⚪ 視窗已關閉'}</td><td><button class="btn soft" style="padding:5px 8px;margin-right:5px" onclick="location.href='hihiyong://invshowwindow/'+${x.hwnd}">顯示</button><button class="btn danger" style="padding:5px 8px" onclick="removeInventoryBinding(${x.index})">移除</button></td></tr>`).join('');
const ips=document.getElementById('invSetupProfile');
if(ips){const old=Number(ips.value||0);ips.innerHTML='<option value="0">請選擇角色</option>'+(s.inventoryBindings||[]).filter(x=>x.alive).map(x=>`<option value="${x.index}">${esc(x.name)}</option>`).join('');if(old)ips.value=String(old);}
[['invStartPage',s.inventoryStartPage],['invStartRow',s.inventoryStartRow],['invEndPage',s.inventoryEndPage],['invEndRow',s.inventoryEndRow]].forEach(([id,v])=>{const e=document.getElementById(id);if(e&&document.activeElement!==e)e.value=v||1;});
const isp=document.getElementById('invSpeed');if(isp&&document.activeElement!==isp)isp.value=s.inventorySpeed||'STABLE';
const ih=document.getElementById('invSetupHint');if(ih)ih.textContent=s.inventorySetupMode?`記錄中：第 ${s.inventorySetupStep}/9 個位置｜回到遊戲按 ${s.inventorySetupHotkey||'F6'} 記錄滑鼠所在位置`:(s.inventoryConfigured?'✓ 位置已設定':'尚未記錄位置');
const isth=document.getElementById('invStartHotkey');if(isth&&document.activeElement!==isth)isth.value=s.inventoryStartHotkey||'F3';
const iph=document.getElementById('invPauseHotkey');if(iph&&document.activeElement!==iph)iph.value=s.inventoryPauseHotkey||'F8';
const ish=document.getElementById('invStopHotkey');if(ish&&document.activeElement!==ish)ish.value=s.inventoryStopHotkey||'F9';
const ist=document.getElementById('invStatus');if(ist)ist.textContent=`${s.inventoryStatus||'待命'}${s.inventoryTotal?`｜進度 ${s.inventoryProcessed||0} / ${s.inventoryTotal}`:''}`;

}
function setState(s){
renderSwitchPage(s);
[['monitored',(s.monitoring||0)+' / '+(s.total||0)],['abnormal',s.abnormal||0],['queue',s.queue||0]].forEach(([id,v])=>{const e=document.getElementById(id);if(e)e.textContent=v;});
const gch=document.getElementById('gameCountHome');if(gch)gch.textContent=s.gameCount||0;
document.getElementById('runBadge').textContent=s.running?'● 系統運行中':'● 系統待命';
const up=document.getElementById('uptime'); if(up){const sec=Number(s.uptimeSec||0),hh=String(Math.floor(sec/3600)).padStart(2,'0'),mm=String(Math.floor(sec%3600/60)).padStart(2,'0'),ss=String(sec%60).padStart(2,'0');up.textContent=`${hh}:${mm}:${ss}`;}
updateHealth(s); renderFeatures(s); renderMatrix();
if(s.uiTheme!==undefined&&(document.documentElement.dataset.theme||'')!==s.uiTheme)applyTheme(s.uiTheme);
renderAccounts(s.accounts||[]); renderHpMonitor(s.accounts||[]); const ii=document.getElementById('iniInfo'); if(ii)ii.textContent='INI：'+(s.iniInfo||'未回報');
const ps=document.getElementById('profileSelect'); if(ps){ps.innerHTML='<option value="0">請選擇帳號</option>'+(s.accounts||[]).map(x=>`<option value="${x.index}">${esc(x.name)} / ${esc(x.account)}${acctMissing(x).length?' ⚠ 未填'+acctMissing(x).join('、'):''}</option>`).join(''); ps.value=String(s.selectedProfile||0);}
renderAcctWarn(s.accounts||[],(s.accounts||[]).find(x=>x.index==s.selectedProfile));
const psm=document.getElementById('profileSelectMirror'); if(psm){const sp=(s.accounts||[]).find(x=>x.index==s.selectedProfile);psm.innerHTML=`<option>${sp?esc(sp.name)+' / '+esc(sp.account):'請先選擇上方遊戲帳號'}</option>`;}
const gs=document.getElementById('gameSelect'); if(gs){gs.innerHTML='<option value="0">請選擇遊戲視窗</option>'+(s.games||[]).map(x=>`<option value="${x.index}">${esc(x.label)}</option>`).join(''); gs.value=String(s.selectedGame||0);}
document.querySelectorAll('[data-scan-feedback]').forEach(el=>el.textContent=`找到 ${s.gameCount??(s.games||[]).length} 個遊戲視窗`);
const gc=Number(s.gameCount??(s.games||[]).length);
if(window.lastGameCount!==undefined && gc!==window.lastGameCount) showToast(`遊戲視窗：${gc} 個`);
window.lastGameCount=gc;
const selected=(s.accounts||[]).find(x=>x.index==s.selectedProfile);
const an=document.getElementById('acctName'), al=document.getElementById('acctLogin'), ap=document.getElementById('acctPassword');
if(selected){
 const profileChanged=(window.accountFormProfile!==Number(s.selectedProfile||0));
 if(profileChanged){
   window.accountFormProfile=Number(s.selectedProfile||0);
   window.accountFormDirty=false;
   if(an)an.value=selected.name||'';
   if(al)al.value=selected.account||'';
   if(ap){ap.value=selected.password||'';ap.type='password';}
 }
 if(ap)ap.placeholder=selected.hasPassword?'已載入已儲存密碼':'請輸入密碼';
 if(!window.accountFormDirty){
   ['Enabled','Launch','Death','Notify','Soft'].forEach(k=>{const e=document.getElementById('acct'+k);if(e)e.checked=({Enabled:selected.enabled,Launch:selected.launch,Death:selected.deathDetect,Notify:selected.deathNotify,Soft:selected.soft})[k]||false;}); const as=document.getElementById('acctSoftAuto');if(as)as.checked=!!selected.softAutoRecover; const af=document.getElementById('acctFirst');if(af)af.checked=!!selected.recoveryFirst; const aal=document.getElementById('acctAlarm');if(aal)aal.checked=selected.deathAlarm!==false; const arm=document.getElementById('acctReviveMode');if(arm&&document.activeElement!==arm)arm.value=selected.reviveMode||'auto'; const arr=document.getElementById('acctReviveReturn');if(arr){arr.checked=selected.reviveReturn!==false;arr.disabled=(selected.reviveMode||'auto')!=='auto';} const arf=document.getElementById('acctReviveF6');if(arf){arf.checked=selected.reviveF6!==false;arf.disabled=(selected.reviveMode||'auto')!=='auto'||selected.reviveReturn===false;} const ala=document.getElementById('acctLoginAct');if(ala&&document.activeElement!==ala)ala.value=selected.loginReturn===false?'stay':(selected.loginF6===false?'back':'back_f6'); const arh=document.getElementById('acctReviveHint');if(arh)arh.textContent=selected.reviveHint?('目前抓到：'+selected.reviveHint+'（回城復活後會按這個鍵用前點卡）'):'';
 }
} else {
 window.accountFormProfile=0;
}
const rdo=document.getElementById('recDiscordOn'); if(rdo && !isEditing('recDiscordOn'))rdo.checked=!!s.discordEnabled;
const dpc=document.getElementById('discordPc'); if(dpc && !isEditing('discordPc'))dpc.value=s.discordPc||'';
const rw=document.getElementById('recWebhook'); if(rw)rw.placeholder=s.discordHasWebhook?'已儲存（留空沿用）':'貼上 Discord Webhook 網址';
const ddo=document.getElementById('deathDiscordOn'); if(ddo && !isEditing('deathDiscordOn'))ddo.checked=!!s.deathDiscordEnabled;
const alo=document.getElementById('alarmOn'); if(alo && !isEditing('alarmOn'))alo.checked=!!s.alarmEnabled; const als=document.getElementById('alarmSec'); if(als && !isEditing('alarmSec'))als.value=s.alarmSeconds||30;
const dw=document.getElementById('deathWebhook'); if(dw)dw.placeholder=s.deathDiscordHasWebhook?'已儲存（留空沿用）':'貼上 Discord Webhook 網址';
const so=document.getElementById('softOn'); if(so && !isEditing('softOn'))so.checked=!!s.softEnabled;
const si=document.getElementById('softIdle'); if(si && !isEditing('softIdle'))si.value=s.softIdle??90;
const sc=document.getElementById('softConfirm'); if(sc && !isEditing('softConfirm'))sc.value=s.softConfirm??30;
const sv=document.getElementById('softVotes'); if(sv && !isEditing('softVotes'))sv.value=s.softMinVotes??2;
const sm=document.getElementById('softMultiAssist'); if(sm && !isEditing('softMultiAssist'))sm.checked=!!s.softMultiAssist;
const sa=document.getElementById('softAuto'); if(sa && !isEditing('softAuto'))sa.checked=!!s.softAutoRecover;
const es=document.getElementById('evidenceState'); if(es)es.textContent=s.evidenceBusy?'測試進行中…':'待命';
const wl=document.getElementById('webLauncher'); if(wl)wl.textContent=s.launcher||'尚未設定';
updateSetupWizard(s);
const pk=document.getElementById('webPostKeys'); if(pk && !isEditing('webPostKeys'))pk.value=s.postKeys||'';
const rt=document.getElementById('repTime'); if(rt && !isEditing('repTime'))rt.value=s.reportDailyTime??'08:00';
const rs=document.getElementById('repShot'); if(rs && !isEditing('repShot'))rs.value=String(s.reportSnapshotMin??60);
const re=document.getElementById('repErr'); if(re && !isEditing('repErr'))re.checked=s.reportErrorShots!==false;
window.__loginMemory=!!s.loginMemory;
const cs=document.getElementById('coordSummary'); if(cs)cs.textContent=s.coordSetup?`設定中：第 ${s.coordIndex||1}/8 個位置${s.coordTargetValid?'':'｜⚠ 原本的遊戲視窗已關閉'}｜設定沒做完時自動組隊等功能會暫停；不需要的話請按「取消設定」`:(s.loginMemory?'✓ 這台直接讀遊戲畫面登入，不需要設 8 點（請不要按「重新設定」）':s.coordConfigured?'✓ 8 個位置都已設定，自動登入可以使用':'⚠ 還沒設定完成，這台讀不到遊戲的登入畫面位置，自動登入無法使用');
const cd=document.getElementById('coordDetails'); if(cd){const need=(s.coordSetup||(!s.loginMemory&&!s.coordConfigured))?'1':'0'; if(cd.dataset.need!==need){cd.dataset.need=need;cd.open=need==='1';}}
const ccb=document.getElementById('coordCancelBtn'); if(ccb)ccb.style.display=s.coordSetup?'':'none';


const sd=document.getElementById('serverDisconnectState'); if(sd)sd.textContent=`伺服器斷線偵測：開啟｜最近一次：${s.serverDisconnectLast||'沒有發生過'}`;
const cp=document.getElementById('coordPoints'); if(cp)cp.innerHTML=(s.points||[]).map(x=>`${x.configured?'✓':'○'} ${esc(x.name)}`).join('<br>');
const mp=document.getElementById('webMapProfile'); if(mp){mp.innerHTML='<option value="0">選擇測試帳號</option>'+(s.mapProfiles||[]).map(x=>`<option value="${x.index}">${esc(x.name)}</option>`).join(''); mp.value=String(s.mapSelected||0);}
const mc=document.getElementById('webMapConf'); if(mc && !isEditing('webMapConf'))mc.value=s.mapConfidence??70;
const mz=document.getElementById('webMapZoom'); if(mz && !isEditing('webMapZoom'))mz.value=s.mapZoom??8;
const mr=document.getElementById('webMapReturn'); if(mr && !isEditing('webMapReturn'))mr.value=s.mapReturn||'W';
const mres=document.getElementById('webMapResult'); if(mres)mres.textContent='辨識結果：'+(s.mapResult||'尚未測試');
}
function updateSetupWizard(s){
 const launcherOk=!!(s.launcher&&String(s.launcher).trim());
 const coordOk=!!s.coordConfigured;
 const accounts=s.accounts||[], accountOk=accounts.length>0&&accounts.every(x=>String(x.account||'').trim()&&x.hasPassword);
 const bound=accounts.filter(x=>Number(x.hwnd||0)>0), boundOk=accounts.length>0&&bound.length===accounts.length;
 const enabled=accounts.filter(x=>x.enabled), memOk=enabled.length>0&&enabled.every(x=>x.memHpReadOk);
 const mapOk=accounts.length>0&&accounts.some(x=>x.location&&x.location!=='不確定'&&!String(x.location).includes('無法確認'));
 const set=(id,txt,ok)=>{const e=document.getElementById(id);if(!e)return;e.textContent=(ok?'✓ ':'⚠ ')+txt;e.className='status-pill '+(ok?'good':'warn');};
 set('wizLauncher',launcherOk?'已設定':'尚未設定',launcherOk); set('wizCoords',coordOk?'已設定':'尚未設定',coordOk);
 const hp=document.getElementById('wizHp');if(hp){if(!enabled.length){hp.textContent='○ 尚無啟用監控帳號';hp.className='status-pill';}else set('wizHp',memOk?`角色血量正常 ${enabled.length}/${enabled.length}`:`部分角色血量尚未讀取`,memOk);}
 
 const steps=[accountOk,boundOk,coordOk,memOk,mapOk,accountOk&&boundOk&&coordOk&&memOk]; steps.forEach((ok,i)=>{const e=document.getElementById('wstep'+(i+1));if(e)e.className='wizard-step '+(ok?'ok':'warn');});
 const a=document.getElementById('wizAdvice');if(a){
  if(!accountOk)a.textContent='下一步：先到「設定 → 帳號」完成帳號 / 密碼。';
  else if(!boundOk)a.textContent='下一步：到「設定 → 帳號」按「自動連接遊戲視窗」。';
  else if(!coordOk)a.textContent='下一步：設定自動登入要點的 8 個位置。';
  else if(!memOk)a.textContent='下一步：開始監控後，到「角色」頁確認每個角色都讀得到血量。';
  else if(!mapOk)a.textContent='角色進入遊戲後就會顯示所在地圖，不需要另外設定。';
  else a.textContent='✓ 設定都完成了，可以回首頁開始監控。';
 }
}

function friendlyState(x){
 const st=x.state||'-';
 if(st==='監控中')return ['🟢','正常','ok'];
 if(st==='排隊中'||st==='恢復中')return ['🔵',st==='排隊中'?'等待重新登入':'重新登入中','recovery'];
 if(st==='載入中')return ['🔵','遊戲載入中','recovery'];
 if(st==='需要人工確認')return ['🟡','需要人工確認','warn'];
 if(st==='恢復失敗')return ['🟡','等待重試','warn'];
 if(st==='需要人工處理')return ['🔴','需要人工處理','bad'];
 if(st==='人工操作')return ['🟡','人工操作','warn'];
 if(!x.enabled)return ['⚪','停用','muted'];
 return ['⚪',st,'warn'];
}
const hpHistory={};
// v1.3.22.0 角色卡：血量、地圖、自動攻擊、今日死亡 / 擊殺、每日道具放在同一張；診斷數字收進「詳細」
let dailyCache=null;
const roleDetailOpen=new Set();
function roleKills(name){
 const d=invStatsData; if(!d||d.day!==d.today)return null;
 const r=(d.roles||[]).find(x=>x.name===name); if(!r)return null;
 return (r.kills||[]).reduce((s,m)=>s+Number(m.total||0),0);
}
function renderHpMonitor(a,push=true){
 const el=document.getElementById('hpCards'); if(!el)return;
 if(push)a.forEach(x=>{const k=String(x.index); if(!hpHistory[k])hpHistory[k]=[]; if(x.memHpReadOk&&Number(x.memHp)>=0){hpHistory[k].push(Number(x.memHp));if(hpHistory[k].length>30)hpHistory[k].shift();}});
 if(!a.length){el.innerHTML='<div class="hint">尚未建立帳號。</div>';return;}
 const ord=[...a.filter(x=>x.enabled),...a.filter(x=>!x.enabled)];   // 監控中的角色排前面，沒監控的排最後、縮成一小張
 el.innerHTML=ord.map((x,oi)=>{
   const offHead=(!x.enabled&&(oi===0||ord[oi-1].enabled))?`<div class="hint" style="grid-column:1/-1;margin-top:4px">未監控的角色（${ord.length-oi}）</div>`:'';
   if(!x.enabled)return offHead+`<div class="role-card rc-off" style="opacity:.65"><div class="hp-head"><div class="hp-name">${esc(x.name)}</div><span class="hp-status off">未監控</span></div></div>`;
   const f=friendlyState(x); let label=f[1], cls=f[2];
   const soft=x.memSoftState||'';
   if(x.enabled&&cls==='ok'){
     if(!x.memHpReadOk){label='血量讀不到';cls='bad';}
     else if(soft==='疑似假在線'){label=soft;cls='warn';}
     else if(soft==='已確認假在線'){label=soft;cls='bad';}
     else if(x.autoAttack===0){label='沒在打怪';cls='warn';}
   }
   if(x.activityLv==='bad')cls='bad';   // 離線 / 禮盒用完：整張卡標紅
   if(cls==='muted')cls='off';
   const pill={ok:'good',warn:'warn',bad:'bad',recovery:'',off:'off'}[cls]??'';
   const hist=hpHistory[String(x.index)]||[], vals=hist.length?hist:[0], lo=Math.min(...vals), hi=Math.max(...vals), span=Math.max(1,hi-lo);
   const bars=vals.map(v=>`<i style="height:${Math.max(4,Math.round(4+(v-lo)/span*22))}px"></i>`).join('');
   const cur=x.memHpReadOk&&Number(x.memHp)>=0?Number(x.memHp):-1, max=Number(x.memHpLearnedMax)||0;
   const pct=cur>=0&&max>0?Math.max(0,Math.min(100,Math.round(cur/max*100))):0;
   const dr=(dailyCache?.roles||[]).find(r=>r.name===x.name);
   const dailyTxt=dr?(dr.expiry||dr.status||'—'):'—', dailyWarn=dr&&!String(dr.status||'').startsWith('有效')&&dr.status!=='讀取中';
   const kills=roleKills(x.name), deaths=Number(x.deathToday||0);
   const chips=[`<span class="chip">🗺️ ${esc(x.location||'未知地圖')}</span>`];
   if(x.autoAttack===1)chips.push('<span class="chip">⚔️ 自動攻擊中</span>'); else if(x.autoAttack===0)chips.push('<span class="chip warn">💤 自動攻擊關閉</span>');
   if(x.enabled&&!x.hwnd)chips.push('<span class="chip warn">⚠ 沒有連接遊戲視窗</span>');
   return `<div class="role-card rc-${cls}"><div class="hp-head"><div class="hp-name">${esc(x.name)}${x.recoveryFirst?' <span class="chip" title="重新登入時優先">👑 隊長</span>':''}</div><span class="hp-status ${pill}">${esc(label)}</span></div>`
    +(x.activity?`<div class="role-act ${esc(x.activityLv||'')}" title="現在在做什麼"><span>${esc(x.activity)}</span>${/重新登入」/.test(x.activity)?`<button class="btn" onclick="send('recoverone',{value:${x.index}});showToast('${esc(x.name)} 開始重新登入')">🔄 重新登入</button>`:''}</div>`:'')
    +`<div class="role-chips">${chips.join('')}</div>`
    +`<div class="role-hp"><span>❤️ 血量</span><span><b>${cur>=0?cur.toLocaleString():'—'}</b> / ${max>0?max.toLocaleString():'—'}</span></div><div class="hp-bar${pct&&pct<30?' low':''}"><i style="width:${pct}%"></i></div>`
    +`<div class="role-stats"><div><small>💀 今日死亡</small><b class="${deaths>0?'bad':''}">${deaths} 次</b></div><div><small>⚔️ 今日擊殺</small><b>${kills===null?'—':kills.toLocaleString()+' 隻'}</b></div><div title="${esc(dr?.status||'')}"><small>🎁 道具到期</small><b class="${dailyWarn?'warn':''}">${esc(dailyTxt)}</b></div></div>`
    +`<details ${roleDetailOpen.has(x.index)?'open':''} ontoggle="this.open?roleDetailOpen.add(${x.index}):roleDetailOpen.delete(${x.index})"><summary>詳細與開關</summary>`
    +`<div class="hp-spark" style="height:34px" title="最近約 30 秒角色血量變化">${bars||'<i style="height:4px"></i>'}</div>`
    +`<div class="hp-meta"><span>昨日死亡：${Number(x.deathYesterday||0)} 次</span><span>最後死亡：${esc(x.deathLast||'—')}</span><span>距上次血量變動：${x.memHpStaticSec??0} 秒</span><span>最長未變動：${x.memHpMaxStaticSec??0} 秒</span><span>重連保護：${x.memHpGraceSec>0?'剩餘 '+x.memHpGraceSec+' 秒':'未啟用'}</span><span title="伺服器時間停止更新可能代表假在線（目前只記錄）">伺服器時間：${Number(x.srvStaticSec)>=0?Number(x.srvStaticSec)+' 秒前更新':'—'}</span></div>`
    +`<div class="actions" style="margin-top:10px"><label class="monitor-switch"><input type="checkbox" ${x.soft?'checked':''} onchange="location.href='hihiyong://softdetect/${x.index}~'+(this.checked?1:0)"> 假在線偵測</label><label class="monitor-switch"><input type="checkbox" ${x.softAutoRecover?'checked':''} onchange="location.href='hihiyong://softautorecover/${x.index}~'+(this.checked?1:0)"> 自動恢復</label><label class="monitor-switch" title="一起重新登入時排在最前面"><input type="checkbox" ${x.recoveryFirst?'checked':''} onchange="location.href='hihiyong://recoveryfirst/${x.index}~'+(this.checked?1:0)"> 優先重新登入（隊長）</label></div></details></div>`;
 }).join('');
}
let lastAccountStructureSig='';
// 首頁血量欄：「目前 / 最大」；讀不到目前血量時只顯示最大值。
function homeHpText(x){const mx=Number(x.memHpLearnedMax||0),max=mx>0?mx.toLocaleString():'—';return x.memHpReadOk&&Number(x.memHp)>=0?`${Number(x.memHp).toLocaleString()} / ${max}`:(mx>0?`— / ${max}`:'—');}
// 沒填遊戲帳號 / 密碼的帳號：自動登入、重新登入都會失敗，到處標出來
function acctMissing(x){const m=[];if(!String(x.account||'').trim())m.push('遊戲帳號');if(!x.hasPassword)m.push('遊戲密碼');return m;}
function acctWarnLine(x){const m=acctMissing(x);return m.length?`<div class="account-sub warn" title="到「設定 → 帳號」補上並按「儲存帳號」">⚠ 還沒填${m.join('、')}（自動登入會失敗）</div>`:'';}
function renderAcctWarn(accounts,selected){
 const box=document.getElementById('acctWarn');
 if(box){const bad=accounts.filter(x=>acctMissing(x).length);
  box.style.display=bad.length?'':'none';
  box.innerHTML=bad.length?'<b>⚠ 這些帳號還沒填完整，自動登入 / 斷線重新登入會失敗：</b><br>'+bad.map(x=>`${esc(x.name)}：沒有填${acctMissing(x).join('、')}`).join('<br>')+'<br>補上後按「儲存帳號」。若只是不想自動登入，把「批次啟動時開啟」取消勾選即可。':'';}
 const ln=document.getElementById('acctLoginNote'), pn=document.getElementById('acctPassNote'), nn=document.getElementById('acctFailNote');
 const miss=selected?acctMissing(selected):[];
 if(ln)ln.textContent=selected&&miss.includes('遊戲帳號')?'⚠ 還沒填遊戲帳號':'';
 if(pn)pn.textContent=selected&&miss.includes('遊戲密碼')?'⚠ 還沒填遊戲密碼':'';
 if(nn){nn.style.display=selected&&selected.loginNote?'':'none';nn.textContent=selected&&selected.loginNote?selected.loginNote:'';}
}
function renderAccounts(a){
 const el=document.getElementById('accountRows');if(!el||dragSortBusy)return;
 a=a.slice().sort((p,q)=>(p.startPos||p.index)-(q.startPos||q.index));   // 照啟動順序排（首頁 ▲▼）
 const sig=JSON.stringify(a.map(x=>[x.startPos,x.index,x.name,x.state,x.recoveryStage,x.location,x.enabled,x.launch,x.pid,x.hwnd,x.autoAttack,x.account?1:0,x.hasPassword?1:0,x.loginNote||'']));
 if(sig===lastAccountStructureSig){
   a.forEach(x=>{const c=el.querySelector(`[data-hp-index="${x.index}"]`);if(c){const v=homeHpText(x);if(c.textContent!==v)c.textContent=v;c.className=x.memHpReadOk?'ok':'muted';}});
   return;
 }
 lastAccountStructureSig=sig;
 el.innerHTML=a.map((x,i)=>{const f=friendlyState(x);return `<tr class="drag-row" data-key="${x.index}"><td style="white-space:nowrap" title="按住拖拉調整啟動順序（越上面越先登入）"><span class="fp-grip">⠿</span><span class="dh-no">${i+1}</span></td><td><input type="checkbox" ${x.launch?'checked':''} onchange="send('launchcheck',{value:'${x.index}~'+(this.checked?1:0)})" title="套用於批次啟動帳號"></td><td><div class="account-name">${f[0]} ${esc(x.name)}</div>${acctWarnLine(x)}${x.loginNote?`<div class="account-sub warn">${esc(x.loginNote)}</div>`:''}</td><td class="${f[2]}">${esc(f[1])}${x.autoAttack===0?'<div class="account-sub warn">💤 自動攻擊關閉</div>':''}${!x.hwnd&&x.enabled?'<div class="account-sub warn" title="到「設定 → 帳號」按「自動連接遊戲視窗」">⚠ 沒有連接遊戲視窗</div>':''}</td><td data-hp-index="${x.index}" class="${x.memHpReadOk?'ok':'muted'}">${homeHpText(x)}</td><td>${esc(x.location||'-')}</td><td><label class="monitor-switch"><input type="checkbox" ${x.enabled?'checked':''} onchange="send('monitorcheck',{value:'${x.index}~'+(this.checked?1:0)});showToast('${esc(x.name)} 監控 '+(this.checked?'ON':'OFF'))">${x.enabled?'ON':'OFF'}</label></td></tr>`}).join('');
 dragSortable(el,'tr.drag-row',(f,t,after)=>{lastAccountStructureSig='';if(f===null)return;const r=dragReorder(a.map(x=>String(x.index)),f,t,after);if(r)send('startorderset',{value:r.join(',')});});
}
// v1.3.22.0 首頁「目前啟動的功能」：每個功能一個標籤，點了跳到設定
function devShow(id){document.querySelectorAll('#devzone .dev-part').forEach(x=>x.classList.toggle('active',x.id===id));document.querySelectorAll('#devzone .dev-tabs .chip').forEach(x=>x.classList.toggle('active',x.dataset.dev===id));}
function goTo(page,sub){document.querySelector(`.side [data-page="${page}"]`)?.click();if(page==='tools'&&sub==='inventory'){showSub('tools','devzone');devShow(sub);return;}if(sub)showSub(page,sub);}
function renderFeatures(s){
 const el=document.getElementById('featList'); if(!el)return;
 const a=s.accounts||[], en=a.filter(x=>x.enabled), auto=en.filter(x=>x.softAutoRecover).length;
 const inv=String(s.inventoryStatus||'待命'), invBusy=!/待命|完成|終止|停止/.test(inv);
 const shot=Number(s.reportSnapshotMin||0), rep=String(s.reportDailyTime||'').trim();
 const daily=dailyCache?((dailyCache.autorun||dailyCache.popupTimeout>0)?'on':'off'):'unk';
 const items=[
  ['🛡️','自動重新登入',s.running?'on':'off',s.running?`${en.length} 個角色`:'已停止','home'],
  ['👻','假在線偵測（總開關）',s.softEnabled?'on':'off',s.softEnabled?`自動恢復 ${auto}/${en.length}`:'','setup','monitor'],
  ['🗂️','監控時還原視窗位置',s.layoutAutoRestore?'on':'off','','tools','layout'],
  ['🎁','每日道具無人自動更換',daily==='unk'?'off':daily,daily==='unk'?'讀取中':'','roles','daily'],
  ['💬','斷線通知',s.discordEnabled?'on':'off','','setup','notifyTab'],
  ['💀','死亡通知',s.deathDiscordEnabled?'on':'off','','setup','notifyTab'],
  ['📊','每日報表',rep?'on':'off',rep?`每天 ${rep}`:'','setup','notifyTab'],
  ['📸','定時截圖',shot>0?'on':'off',shot>0?(shot>=60?`每 ${shot/60} 小時`:`每 ${shot} 分`):'','setup','notifyTab'],
 ];
 // 開著的排前面；同一組內保持原本順序（sort 是穩定排序）
 const html=items.sort((x,y)=>(x[2]==='off')-(y[2]==='off')).map(([ic,name,st,det,pg,sb])=>`<button class="feat ${st==='off'?'':st}" onclick="goTo('${pg}'${sb?`,'${sb}'`:''})" title="${st==='off'?'目前關閉':'目前開著'}｜點一下前往設定"><span class="emo">${ic}</span>${st==='off'?'○':'●'} ${esc(name)}${det?` <small>${esc(det)}</small>`:''}</button>`).join('');
 if(el.innerHTML!==html)el.innerHTML=html;
}
// 首頁「角色」：每個角色一行（類型＋會怎麼動的摘要＋跟類型不一樣的「已自訂」），點「展開設定」才出現這個角色全部的設定。
// v1.3.90.69 角色類型範本：選一種就把死亡後 / 登入後 / 自動功能套成那一組；之後手動改的項目標「已自訂」。
const ROLE_TYPES={
 hunt:{name:'打怪掛網',desc:'死亡沒珠回城→前點卡回怪區＋F6；重新登入回怪區＋F6',tpl:{reviveMode:'auto',back:'back_f6',login:'back_f6'}},
 mine:{name:'採礦',desc:'死亡回城後留在城裡；重新登入留在城裡、不開 F6',tpl:{reviveMode:'auto',back:'stay',login:'stay'}},
 member:{name:'組隊隊員',desc:'同打怪（接受隊長邀請在組隊頁設定）',tpl:{reviveMode:'auto',back:'back_f6',login:'back_f6'}},
 idle:{name:'只上線不動',desc:'死亡只通知；重新登入留在城裡',tpl:{reviveMode:'off',login:'stay'}}
};
// v1.3.90.72：類型只管「死亡後」和「登入後」；自動採礦 / 每日討伐 / 命運箱子不會因為換類型被勾掉或勾上（11/23 15:59 欸等切到組隊隊員又切回來，每日討伐被取消）
const ROLE_BACK={back_f6:'前點卡回怪區＋開 F6',back:'前點卡回怪區（不開 F6）',stay:'留在城裡'};
const ROLE_ITEMS=[
 {g:'死亡',k:'reviveMode',label:'死亡後自動復活',tip:'死亡超過 30 秒還沒復活時。每日討伐途中死亡會馬上處理。',opts:[['auto','有歸魂珠用歸魂珠，沒有就復活回城'],['bead','只用歸魂珠（沒有就通知）'],['off','不自動復活，只通知']]},
 {g:'死亡',k:'back',label:'回城後',tip:'沒有歸魂珠回城復活之後。每日道具到期時改由每日道具更換送回去；30 分鐘內第 3 次回城就不送。',opts:Object.entries(ROLE_BACK),dis:c=>c.reviveMode!=='auto'},
 {g:'重新登入',k:'login',label:'登入後',tip:'斷線 / 遊戲關閉後自動重新登入進遊戲之後。登入後按鍵裡的其他鍵（例如 A）照常送出。',opts:[['back_f6','在城裡就用前點卡回怪區＋開 F6'],['back','在城裡就用前點卡回怪區（不開 F6）'],['stay','留在城裡（不按前點卡、不開 F6）']]},
 {g:'重新登入',k:'first',label:'優先重新登入（隊長）',tip:'一起重新登入時排在最前面。隊長勾這個，隊員回來時隊長已經在怪區。',bool:true},
 {g:'自動功能',k:'mn',label:'自動採礦',tip:'水晶礦場。顏色順序、打王技能、趟數在「工具 → 自動採礦」設定。',bool:true},
 {g:'自動功能',k:'dh',label:'每日討伐',tip:'每日討伐任務。定時啟動與項目在「工具 → 每日討伐」設定。',bool:true},
 {g:'自動功能',k:'mb',label:'命運箱子',tip:'自動開命運箱子。總開關與按鍵在「工具 → 命運箱子」設定。',bool:true},
 {g:'監控與偵測',k:'mon',label:'納入監控',tip:'關掉就不偵測死亡、不自動重新登入。',bool:true},
 {g:'監控與偵測',k:'soft',label:'假在線偵測',tip:'血量長時間沒變化時判定假在線。總開關在「設定 → 監控」。',bool:true},
 {g:'監控與偵測',k:'auto',label:'假在線自動恢復',tip:'建議只對長時間掛機打怪的角色開啟。一般斷線不受這個開關影響。',bool:true}
];
// 目前的值；採礦 / 每日討伐 / 命運箱子清單還沒讀到時是 undefined（不判斷是否自訂）
function roleCur(x){
 const F=homeFeat,on=(l,f)=>l?l.some(f):undefined;
 return {reviveMode:x.reviveMode||'auto',back:x.reviveReturn===false?'stay':(x.reviveF6===false?'back':'back_f6'),
  login:x.loginReturn===false?'stay':(x.loginF6===false?'back':'back_f6'),first:!!x.recoveryFirst,
  mn:on(F.mn&&F.mn.chars,c=>c.name===x.name&&c.on),dh:on(F.dh&&F.dh.chars,c=>c.name===x.name&&c.on),
  mb:on(F.mbox&&F.mbox.roles,r=>r.name===x.name&&r.on),mon:!!x.enabled,soft:!!x.soft,auto:!!x.softAutoRecover};
}
function roleDiff(x){
 const t=ROLE_TYPES[x.roleType];if(!t)return [];
 const c=roleCur(x);
 return ROLE_ITEMS.filter(it=>(it.k in t.tpl)&&c[it.k]!==undefined&&!(it.dis&&it.dis(c))&&c[it.k]!==t.tpl[it.k]);
}
function roleSummary(x){
 const c=roleCur(x),F=homeFeat,out=[];
 out.push('死亡：'+(c.reviveMode==='auto'?'沒珠回城→'+ROLE_BACK[c.back].replace('（不開 F6）',''):c.reviveMode==='bead'?'只用歸魂珠':'只通知'));
 out.push('登入：'+ROLE_BACK[c.login].replace('（不開 F6）','').replace('開 F6','F6'));
 // 組隊：自己是隊長、自己勾了接受邀請、或被某隻隊長列在隊員名單裡（11/23 小柯基、椰奶在欸等的隊員名單，首頁卻沒標）
 const roles=(F.party&&F.party.roles)||[],me=roles.find(r=>r.name===x.name);
 const lead=roles.find(r=>r.leader&&r.name!==x.name&&(r.members||[]).includes(x.name));
 const pt=me&&me.leader?'組隊（隊長）':lead?`組隊（隊員，隊長 ${lead.name}）`:me&&me.accept?`組隊（接受${me.acceptFrom?' '+me.acceptFrom+' ':''}邀請）`:'';
 const fs=[c.mn&&('自動採礦'+(F.mn&&F.mn.running?'（執行中）':'')),c.dh&&('每日討伐'+(F.dh&&F.dh.running?'（執行中）':'')),c.mb&&'命運箱子',pt].filter(Boolean);
 if(fs.length)out.push(fs.join('、'));
 if(!c.mon)out.push('沒有納入監控');
 return out;
}
let mxOpen=0;
function mxOpenToggle(idx){mxOpen=mxOpen===idx?0:idx;renderMatrix();}
function rolePanel(x){
 const t=ROLE_TYPES[x.roleType],c=roleCur(x),diffK=new Set(roleDiff(x).map(it=>it.k));
 const types=Object.entries(ROLE_TYPES).map(([k,v])=>`<label class="rp-type ${x.roleType===k?'on':''}"><span><input type="radio" name="rt${x.index}" ${x.roleType===k?'checked':''} onchange="roleApply(${x.index},'${k}')"> ${v.name}</span><small>${esc(v.desc)}</small></label>`).join('');
 let g='',body='';
 ROLE_ITEMS.forEach(it=>{
  if(it.g!==g){body+=(g?'</div>':'')+`<div class="rp-group"><h4>${it.g}</h4>`;g=it.g;}
  const v=c[it.k],dis=it.dis&&it.dis(c);
  const ctl=it.bool?`<label class="toggle"><input type="checkbox" ${v?'checked':''} ${v===undefined?'disabled':''} onchange="roleItem(${x.index},'${it.k}',this.checked)"> ${v===undefined?'讀取中…':v?'開':'關'}</label>`
   :`<select ${dis?'disabled':''} onchange="roleItem(${x.index},'${it.k}',this.value)">${it.opts.map(([o,l])=>`<option value="${o}" ${o===v?'selected':''}>${l}</option>`).join('')}</select>`;
  const st=!t||!(it.k in t.tpl)||dis?'':diffK.has(it.k)?`<span class="mx-custom">已自訂</span><button class="rp-reset" onclick="roleReset(${x.index},'${it.k}')">改回預設</button>`:'<span class="muted">跟著類型</span>';
  body+=`<div class="rp-item"><span class="rp-label">${it.label}<span class="rp-tip" tabindex="0" title="${esc(it.tip)}" aria-label="說明：${esc(it.tip)}">ⓘ</span></span><span class="rp-ctl">${ctl}</span><span class="rp-st">${st}</span></div>`;
 });
 body+='</div>';
 const hint=(x.reviveHint||'').split('｜')[0];
 return `<div class="rp"><div class="rp-head"><b>角色類型</b><span class="muted">類型只套用「死亡後」和「登入後」；自動採礦、每日討伐、命運箱子不會因為換類型改到。手動改過的標「已自訂」。</span>${t&&diffK.size?`<button class="btn" onclick="roleResetAll(${x.index})">全部改回類型預設</button>`:''}</div>`
  +`<div class="rp-types">${types}</div>${body}<div class="hint">每日道具、組隊、採礦顏色等細項仍在各自的頁面設定。${hint?'｜'+esc(hint):''}</div></div>`;
}
// 指令一個一個送（間隔 1.5 秒）：程式存檔約 2 秒，期間連續改 location.href，後面的會蓋掉前面的（11/23 12:06 登入後沒存到）
let roleQ=[],roleQT=0;
function roleQueue(fn){roleQ.push(fn);if(!roleQT)roleQT=setInterval(()=>{const f=roleQ.shift();if(f){try{f();}catch(e){}}if(!roleQ.length){clearInterval(roleQT);roleQT=0;}},1500);}
const roleAcc=idx=>(latestState.accounts||[]).find(a=>a.index==idx);
function roleSet(idx,k,v){
 const x=roleAcc(idx);if(!x)return;
 if(k==='reviveMode')mxRevive(idx,'mode',v);
 else if(k==='back')mxRevive(idx,'back',v);
 else if(k==='login')mxLogin(idx,v);
 else if(k==='first'){x.recoveryFirst=v?1:0;location.href='hihiyong://recoveryfirst/'+idx+'~'+(v?1:0);renderMatrix();}
 else if(roleCur(x)[k]!==undefined&&roleCur(x)[k]!==v)mxToggle(k,idx,x.name);
}
function roleItem(idx,k,v){roleQueue(()=>roleSet(idx,k,v));}
// 類型＋死亡後＋登入後由程式一次改好（roleapply）；自動採礦 / 每日討伐 / 命運箱子再一項一項送
function roleApply(idx,type){
 const x=roleAcc(idx),t=ROLE_TYPES[type];if(!x||!t)return;
 const p=t.tpl;
 x.roleType=type;x.reviveMode=p.reviveMode;
 if(p.back){x.reviveReturn=p.back!=='stay';if(p.back!=='stay')x.reviveF6=p.back==='back_f6';}
 x.loginReturn=p.login!=='stay';x.loginF6=p.login==='back_f6';
 roleQueue(()=>{location.href='hihiyong://roleapply/'+idx+'~'+type;});
 ['mn','dh','mb'].filter(k=>k in p).forEach(k=>roleQueue(()=>{const y=roleAcc(idx);if(y&&roleCur(y)[k]!==undefined&&roleCur(y)[k]!==p[k])mxToggle(k,idx,y.name);}));
 renderMatrix();
}
function roleReset(idx,k){const x=roleAcc(idx),t=x&&ROLE_TYPES[x.roleType];if(t&&k in t.tpl)roleItem(idx,k,t.tpl[k]);}
function roleResetAll(idx){const x=roleAcc(idx);if(x&&ROLE_TYPES[x.roleType])roleApply(idx,x.roleType);}
const homeFeat={mn:null,dh:null,mbox:null,party:null};
function wrapHomeFeed(fn,key){const orig=window[fn];if(typeof orig!=='function')return;window[fn]=function(d){orig.apply(this,arguments);homeFeat[key]=d;renderMatrix();};}
function requestHomeFeat(){['autominingstate','dailyhuntstate','mboxstate','partystate'].forEach(a=>send(a));}
function renderMatrix(){
 const el=document.getElementById('matrixList');if(!el||!latestState)return;
 if(el.contains(document.activeElement)&&document.activeElement.tagName==='SELECT')return;   // 正在選下拉選單：先不重畫
 const acc=(latestState.accounts||[]).filter(x=>x.enabled||x.launch);
 if(!acc.length){el.innerHTML='<span class="muted">目前沒有勾選的角色</span>';return;}
 const html=acc.map(x=>{const f=friendlyState(x);const t=ROLE_TYPES[x.roleType];const diff=roleDiff(x);
  return `<div class="mx-row"><div class="mx-name">${esc(x.name)}<small class="${f[2]}">${esc(f[1])}</small></div>`
   +`<span class="mx-type ${t?'on':''}">${t?t.name:'未選類型'}</span>`
   +`<div class="mx-sum">${roleSummary(x).map(v=>`<span>${esc(v)}</span>`).join('')}${diff.length?`<span class="mx-custom">已自訂：${esc(diff.map(it=>it.label).join('、'))}</span>`:''}</div>`
   +`<button class="btn mx-open" onclick="mxOpenToggle(${x.index})">${mxOpen===x.index?'收起設定':'展開設定'}</button>`
   +(mxOpen===x.index?rolePanel(x):'')+`</div>`;}).join('');
 if(el.innerHTML!==html)el.innerHTML=html;
}
function mxRevive(idx,field,v){
 const x=(latestState.accounts||[]).find(a=>a.index==idx);if(!x)return;
 if(field==='mode')x.reviveMode=v;else{x.reviveReturn=v!=='stay';x.reviveF6=v==='back_f6';}
 const mode=x.reviveMode||'auto',r=x.reviveReturn===false?0:1,f=x.reviveF6===false?0:1;
 location.href='hihiyong://revivecfg/'+idx+'~'+mode+'~'+r+'~'+f;
 document.activeElement&&document.activeElement.blur&&document.activeElement.blur();
 renderMatrix();
}
// 直接在首頁開關：沿用各功能頁原本的儲存函式 / 指令，先樂觀更新畫面，AHK 回報後會再校正
function mxToggle(k,idx,name){
 const x=(latestState.accounts||[]).find(a=>a.index==idx);if(!x)return;
 if(k==='mon'){const v=!x.enabled;x.enabled=v?1:0;send('monitorcheck',{value:idx+'~'+(v?1:0)});}
 else if(k==='soft'){if(!latestState.softEnabled){showToast('「假在線偵測」總開關關閉中，請到 設定 → 監控 開啟');return;}const v=!x.soft;x.soft=v?1:0;location.href='hihiyong://softdetect/'+idx+'~'+(v?1:0);}
 else if(k==='auto'){const v=!x.softAutoRecover;x.softAutoRecover=v?1:0;location.href='hihiyong://softautorecover/'+idx+'~'+(v?1:0);}
 else if(k==='mn'){const i=mnChars.findIndex(c=>c.name===name);if(i<0){showToast('採礦清單裡找不到這個角色');return;}mnCharToggle(i,!mnChars[i].on);}
 else if(k==='dh'){const i=dhChars.findIndex(c=>c.name===name);if(i<0){showToast('每日討伐清單裡找不到這個角色');return;}dhCharToggle(i,!dhChars[i].on);}
 else if(k==='mb'){const r=((homeFeat.mbox&&homeFeat.mbox.roles)||[]).find(r=>r.name===name);if(!r){showToast('命運箱子清單裡找不到這個角色');return;}r.on=!r.on;send('mboxrole',{value:`${r.index}~${r.on?1:0}~${(r.key||'e').trim()}~${name}`});}
 renderMatrix();
 setTimeout(requestHomeFeat,800);
}
['renderAutoMining:mn','renderDailyHunt:dh','renderMBox:mbox','renderParty:party'].forEach(x=>{const [f,k]=x.split(':');wrapHomeFeed(f,k);});
setTimeout(requestHomeFeat,1800);setInterval(()=>{if(document.getElementById('home')?.classList.contains('active'))requestHomeFeat();},30000);
// v1.3.22.0 首頁一句話總結：幾個正常、幾個重新登入中、哪些需要注意
function updateHealth(s){
 const a=s.accounts||[], en=a.filter(x=>x.enabled);
 const cls=x=>friendlyState(x)[2];
 const ok=en.filter(x=>cls(x)==='ok'&&x.hwnd&&x.autoAttack!==0), rec=en.filter(x=>cls(x)==='recovery');
 const att=en.filter(x=>!ok.includes(x)&&!rec.includes(x));
 const badge=document.getElementById('healthBadge'),sum=document.getElementById('homeSummary'),note=document.getElementById('homeAttention');
 let bc='status-pill good',bt='● 一切正常';
 if(!s.running){bc='status-pill';bt='● 待命';}
 if(att.some(x=>cls(x)==='bad'||x.state==='需要人工確認')){bc='status-pill bad';bt='● 需要處理';}
 else if(att.length||!s.coordConfigured){bc='status-pill warn';bt='● 有注意事項';}
 else if(rec.length){bc='status-pill';bt='● 重新登入中';}
 if(badge){badge.className=bc;badge.textContent=bt;}
 if(sum)sum.textContent=en.length?`${en.length} 個角色監控中：${ok.length} 個正常`+(rec.length?`、${rec.length} 個重新登入中`:'')+(att.length?`、${att.length} 個需要注意`:''):'目前沒有角色在監控';
 if(note){
  const why=x=>!x.hwnd?'沒有連接遊戲視窗':(cls(x)==='ok'&&x.autoAttack===0?'自動攻擊關閉':friendlyState(x)[1]);
  const parts=att.map(x=>`${x.name}（${why(x)}）`);
  if(!s.coordConfigured)parts.push('自動登入位置還沒設定');
  note.textContent=parts.length?'⚠ '+parts.join('、'):'';
 }
}
function addEvent(e){let d=document.getElementById('events'),c=document.createElement('div');c.className='event';c.innerHTML=`<span>${esc(e.time||'')}</span><i class="dot ${e.level==='error'?'err':e.level==='warn'?'warn':''}"></i><span>${esc(e.text||'')}</span>`;d.prepend(c);while(d.children.length>30)d.lastChild.remove();}
function esc(s){return String(s??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));}

['acctName','acctLogin','acctPassword'].forEach(id=>{
 const el=document.getElementById(id);
 if(el)el.addEventListener('input',()=>{window.accountFormDirty=true;});
});


let settingsDirty=false;
function setDirty(v=true){
 settingsDirty=v;
 const b=document.getElementById('dirtyBadge'); if(b)b.style.display=v?'inline-flex':'none';
}
function bindDirtySettings(){
 ['discordPc','recWebhook','deathWebhook','softIdle','softConfirm','softVotes','softMultiAssist','webPostKeys','webMapConf','webMapZoom','webMapReturn'].forEach(id=>{
  const e=document.getElementById(id); if(e)e.addEventListener('input',()=>setDirty(true));
 });
 ['recDiscordOn','deathDiscordOn','softOn','softAuto','softMultiAssist'].forEach(id=>{
  const e=document.getElementById(id); if(e)e.addEventListener('change',()=>{dirtyFields.add(id);setDirty(true);});
 });
 ['acctName','acctLogin','acctPassword'].forEach(id=>{const e=document.getElementById(id);if(e)e.addEventListener('input',()=>setDirty(true));});
}
bindDirtySettings();

function packVals(vals){return vals.map(v=>encodeURIComponent(String(v))).join('~');}
function saveNotify(){
 ['recDiscordOn','recWebhook','discordPc','deathDiscordOn','deathWebhook'].forEach(clearFieldDirty); setDirty(false); showToast('✓ Discord 設定已儲存');
 const vals=[
   document.getElementById('recDiscordOn')?.checked?1:0,
   document.getElementById('recWebhook')?.value||'',
   document.getElementById('discordPc')?.value||'',
   document.getElementById('deathDiscordOn')?.checked?1:0,
   document.getElementById('deathWebhook')?.value||''
 ];
 location.href='hihiyong://notifysave/'+packVals(vals);
 if(document.getElementById('recWebhook'))document.getElementById('recWebhook').value='';
 if(document.getElementById('deathWebhook'))document.getElementById('deathWebhook').value='';
}
function saveReports(){
 ['repTime','repShot','repErr'].forEach(clearFieldDirty); setDirty(false);
 const t=(document.getElementById('repTime')?.value||'').trim(), m=document.getElementById('repShot')?.value||'0', e=document.getElementById('repErr')?.checked?1:0;
 if(t&&!/^([01]?\d|2[0-3]):[0-5]\d$/.test(t)){showToast('時間格式請輸入例如 08:00');return;}
 send('reportsave',{value:`${t}~${m}~${e}`}); showToast('✓ 報表 / 截圖設定已儲存');
}
function saveMonitor(){
 ['softOn','softIdle','softConfirm','softVotes','softAuto','softMultiAssist'].forEach(clearFieldDirty); setDirty(false); showToast('✓ 監控設定已儲存');
 const vals=[
   document.getElementById('softOn')?.checked?1:0,
   document.getElementById('softIdle')?.value||90,
   document.getElementById('softConfirm')?.value||30,
   document.getElementById('softVotes')?.value||3,
   document.getElementById('softAuto')?.checked?1:0,
   document.getElementById('softMultiAssist')?.checked?1:0
 ];
 location.href='hihiyong://monitorsave/'+packVals(vals);
}
function saveAcct(){
 ['acctName','acctLogin','acctPassword'].forEach(clearFieldDirty); setDirty(false); showToast('✓ 帳號設定已儲存');
 const n=document.getElementById('acctName')?.value||'', a=document.getElementById('acctLogin')?.value||'', p=document.getElementById('acctPassword')?.value||'';
 const packed=[n,a,p].map(x=>encodeURIComponent(x)).join('~');
 location.href='hihiyong://accountsave/'+packed;
 if(document.getElementById('acctPassword'))document.getElementById('acctPassword').value='';
 setTimeout(()=>{window.accountFormDirty=false;},1200);
}
['Enabled','Launch','Death','Notify','Soft'].forEach(k=>{
 const el=document.getElementById('acct'+k);
 if(el)el.addEventListener('change',()=>location.href='hihiyong://accounttoggle/'+k.toLowerCase()+'~'+(el.checked?1:0));
});

const acctAlarm=document.getElementById('acctAlarm'); if(acctAlarm)acctAlarm.addEventListener('change',()=>{const idx=Number(document.getElementById('profileSelect')?.value||0);if(idx)location.href='hihiyong://deathalarm/'+idx+'~'+(acctAlarm.checked?1:0);});
const reviveCfgSend=()=>{const idx=Number(document.getElementById('profileSelect')?.value||0),m=document.getElementById('acctReviveMode'),r=document.getElementById('acctReviveReturn'),f=document.getElementById('acctReviveF6');if(idx&&m&&r&&f)location.href='hihiyong://revivecfg/'+idx+'~'+m.value+'~'+(r.checked?1:0)+'~'+(f.checked?1:0);};
['acctReviveMode','acctReviveReturn','acctReviveF6'].forEach(id=>{const e=document.getElementById(id);if(e)e.addEventListener('change',reviveCfgSend);});
{const e=document.getElementById('acctLoginAct');if(e)e.addEventListener('change',()=>{const idx=Number(document.getElementById('profileSelect')?.value||0);if(idx)location.href='hihiyong://logincfg/'+idx+'~'+(e.value!=='stay'?1:0)+'~'+(e.value==='back_f6'?1:0);});}
const acctFirst=document.getElementById('acctFirst'); if(acctFirst)acctFirst.addEventListener('change',()=>{const idx=Number(document.getElementById('profileSelect')?.value||0);if(idx)location.href='hihiyong://recoveryfirst/'+idx+'~'+(acctFirst.checked?1:0);});
const acctSoftAuto=document.getElementById('acctSoftAuto'); if(acctSoftAuto)acctSoftAuto.addEventListener('change',()=>{const idx=Number(document.getElementById('profileSelect')?.value||0);if(idx)location.href='hihiyong://softautorecover/'+idx+'~'+(acctSoftAuto.checked?1:0);});

function showSelfCheck(d){
 const box=document.getElementById('selfCheckResult'); if(!box)return;
 box.style.display='block';
 box.innerHTML=`<b>系統檢查：${d.ok}/${d.total} 正常</b><br>`+(d.items||[]).map(x=>`${x.ok?'✓':'⚠'} ${esc(x.name)}　${esc(x.detail)}`).join('<br>');
 showToast(`系統檢查完成：${d.ok}/${d.total} 項正常`);
}
// v1.3.18.8 每小時收益曲線
let invStatsData=null;
function renderHourly(){
 const d=invStatsData; if(!d)return;
 const sel=document.getElementById('hourRole'), roles=d.roles||[];
 if(sel){const keep=sel.value;const opts='<option value="">全部角色</option>'+roles.map(r=>`<option value="${esc(r.name)}">${esc(r.name)}</option>`).join('');if(sel.dataset.opts!==opts){sel.innerHTML=opts;sel.dataset.opts=opts;sel.value=roles.some(r=>r.name===keep)?keep:'';}}
 const pick=sel?sel.value:'', chosen=roles.filter(r=>!pick||r.name===pick);
 const sum=k=>Array.from({length:24},(_,h)=>chosen.reduce((s,r)=>s+Number((r[k]||[])[h]||0),0));
 const money=sum('hourMoney'), items=sum('hourItems');
 const nowH=d.day===d.today?new Date().getHours():-1;
 // H-026：選了統計時段，圖上時段外的柱子變淡、時段內有底色，合計也只算時段內
 const rg=d.range&&d.range.partial?d.range:null, inR=(v,h)=>(!rg||(h>=rg.from&&h<rg.to))?Number(v):0;
 drawHourChart('hourMoneyChart',money,v=>fmtMoney(v),nowH,rg);
 drawHourChart('hourItemsChart',items,v=>Number(v).toLocaleString()+' 個',nowH,rg);
 const hh3=n=>String(n).padStart(2,'0')+':00', lab=rg?'（'+hh3(rg.from)+'～'+hh3(rg.to)+'）':'';
 const ms=document.getElementById('hourMoneySum');if(ms)ms.textContent='合計'+lab+' '+fmtMoney(money.reduce((a,b,h)=>a+inR(b,h),0));
 const is=document.getElementById('hourItemsSum');if(is)is.textContent='合計'+lab+' '+items.reduce((a,b,h)=>a+inR(b,h),0).toLocaleString()+' 個';
 askHourSum(d.day); renderHourSum();
}
// 每小時摘要：死亡、採礦效率（中位數）、循環太慢的次數、異常事件。AHK 讀當天日誌算（HourlySummary.ahk），同一天一分鐘最多要一次
let hourSumData=null, hourSumAsk={day:'',at:0};
const HS_ISSUE_NAME={MN_ERROR:'採礦錯誤',MN_HANG:'採礦卡住',KICKED:'被踢',RECOVERY_FAIL:'重新登入失敗',MANUAL_REQUIRED:'需要人工處理',QUICKKEYS:'快捷欄讀取',CW_FAIL:'召喚失敗',DH_ERROR:'討伐錯誤',DH_STOP_STUCK:'討伐卡住',DH_CROWDED:'討伐太擠',DAILY_FAIL:'換道具失敗',REVIVE_CLICK_FAIL:'復活點擊失敗',MBOX_STUCK:'開箱卡住'};
function askHourSum(day){const now=Date.now();if(!day||(hourSumAsk.day===day&&now-hourSumAsk.at<60000))return;hourSumAsk={day,at:now};send('hoursummary',{value:day});}
function renderHourSum(d){
 if(d)hourSumData=d; d=hourSumData; const el=document.getElementById('hourSumRows'); if(!el||!d)return;
 const inv=invStatsData, pick=document.getElementById('hourRole')?.value||'', base=d.base||{};
 const sl=document.getElementById('hourSumSlow'); if(sl)sl.textContent=base.slow||110;
 const note=document.getElementById('hourSumNote'); if(note)note.textContent=`維修前基準：採集 ${base.gather} 秒、走路 ${base.walk} 秒、循環中位 ${base.cycle} 秒`;
 const roles=((d.sum||{}).roles||[]).filter(r=>!pick||r.name===pick);
 const invRoles=(inv&&inv.day===d.day?(inv.roles||[]):[]).filter(r=>!pick||r.name===pick);
 const rows=[];
 for(let h=23;h>=0;h--){
   const hs=roles.map(r=>({name:r.name,b:(r.hours||[]).find(x=>x.h===h)})).filter(x=>x.b);
   const money=invRoles.reduce((s,r)=>s+Number((r.hourMoney||[])[h]||0),0);
   if(!hs.length&&!money)continue;
   const deaths=hs.reduce((s,x)=>s+x.b.deaths,0), gathers=hs.reduce((s,x)=>s+x.b.gathers,0), slow=hs.reduce((s,x)=>s+x.b.slow,0);
   const mine=hs.filter(x=>x.b.gathers>0).sort((a,b)=>b.b.gathers-a.b.gathers)[0];   // 全部角色時：秒數看這小時採最多的那隻
   const sec=(v,ref)=>v<0||v===undefined?'—':`<span class="${ref&&v>ref*1.2?'hs-warn':''}">${v}</span>`;
   const iss={}; hs.forEach(x=>Object.entries(x.b.issues||{}).forEach(([k,n])=>iss[k]=(iss[k]||0)+n));
   const issTxt=Object.keys(iss).map(k=>`${esc(HS_ISSUE_NAME[k]||k)}×${iss[k]}`).join('、');
   rows.push(`<tr><td>${String(h).padStart(2,'0')}:00</td><td>${money?fmtMoney(money):'—'}</td><td class="${deaths>=3?'hs-bad':deaths?'hs-warn':''}">${deaths||'—'}</td><td>${gathers?gathers+' 顆':'—'}</td>`
    +`<td>${mine?sec(mine.b.gatherMed,base.gather):'—'}</td><td>${mine?sec(mine.b.walkMed,15):'—'}</td><td>${mine?sec(mine.b.cycleMed,base.cycle)+(!pick&&roles.length>1?` <span class="muted">（${esc(mine.name)}）</span>`:''):'—'}</td>`
    +`<td class="${slow?'hs-warn':''}">${gathers?slow:'—'}</td><td class="${issTxt?'hs-bad':''}">${issTxt||'—'}</td></tr>`);
 }
 el.innerHTML=rows.length?rows.join(''):'<tr><td colspan="9" class="hint">這一天還沒有資料</td></tr>';
}
// 單一數列長條圖：24 小時，柱頂 4px 圓角、柱間 2px 間隔，滑鼠移上顯示數值（不畫每根柱子的數字）
function drawHourChart(id,vals,fmt,nowH,rg){
 const el=document.getElementById(id); if(!el)return;
 const W=600,H=170,L=34,R=4,T=10,B=20,cw=(W-L-R)/24,max=Math.max(...vals,0);
 const top=max>0?niceMax(max):1, y=v=>T+(H-T-B)*(1-v/top);
 let g='';
 if(rg)g+=`<rect class="band" x="${L+cw*rg.from}" y="${T}" width="${cw*(rg.to-rg.from)}" height="${H-T-B}"/>`;
 [0,.5,1].forEach(f=>{const v=top*f,yy=y(v);g+=`<line class="grid" x1="${L}" x2="${W-R}" y1="${yy}" y2="${yy}"/><text class="axis" x="${L-4}" y="${yy+3}" text-anchor="end">${f?esc(fmt(v).replace(' 個','')):'0'}</text>`;});
 for(let h=0;h<24;h+=3)g+=`<text class="axis" x="${L+cw*h+cw/2}" y="${H-5}" text-anchor="middle">${h}</text>`;
 vals.forEach((v,h)=>{
  const x=L+cw*h+1,w=cw-2,yy=y(v),hh=H-B-yy,r=Math.min(4,w/2,hh);
  if(v>0)g+=hh>r?`<path class="bar${h===nowH?' now':''}${rg&&(h<rg.from||h>=rg.to)?' out':''}" d="M${x},${H-B} V${yy+r} Q${x},${yy} ${x+r},${yy} H${x+w-r} Q${x+w},${yy} ${x+w},${yy+r} V${H-B} Z"/>`:`<rect class="bar" x="${x}" y="${yy}" width="${w}" height="${Math.max(hh,1)}"/>`;
  g+=`<rect class="hit" x="${L+cw*h}" y="${T}" width="${cw}" height="${H-T-B}" data-h="${h}" data-v="${esc(fmt(v))}"/>`;
 });
 el.innerHTML=`<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="每小時數值">${g}</svg><div class="hour-tip"></div>`;
 const tip=el.querySelector('.hour-tip');
 el.querySelectorAll('.hit').forEach(r=>{
  r.addEventListener('mouseenter',()=>{const b=r.getBoundingClientRect(),c=el.getBoundingClientRect(),h=Number(r.dataset.h);tip.textContent=`${String(h).padStart(2,'0')}:00–${String(h+1).padStart(2,'0')}:00｜${r.dataset.v}`;tip.style.left=(b.left-c.left+b.width/2)+'px';tip.style.top=(Number(r.getAttribute('y'))/H*c.height+8)+'px';tip.classList.add('show');});
  r.addEventListener('mouseleave',()=>tip.classList.remove('show'));
 });
}
function niceMax(v){const p=Math.pow(10,Math.floor(Math.log10(v))),n=v/p;return (n<=1?1:n<=2?2:n<=5?5:10)*p;}
// v1.3.13.0 每日背包統計
let invStatsSelected='',invStatsToday='';
// H-023 自訂統計時段（整點，起含迄不含；整天 = 0～24）。時段只套用在「收益統計」頁；其他頁面要資料時一律要整天。
let invFrom=0,invTo=24;
try{const r=JSON.parse(localStorage.getItem('hhInvRange')||'null');if(r&&Number.isInteger(r.f)&&Number.isInteger(r.t)&&r.f>=0&&r.t<=24&&r.t>r.f){invFrom=r.f;invTo=r.t;}}catch(e){}
function invRangePartial(){return invFrom>0||invTo<24;}
function invSaveRange(){try{localStorage.setItem('hhInvRange',JSON.stringify({f:invFrom,t:invTo}));}catch(e){}}
function invFillRange(){
 const a=document.getElementById('invFrom'),b=document.getElementById('invTo');if(!a||!b)return;
 const hh=n=>String(n).padStart(2,'0')+':00';
 a.innerHTML=Array.from({length:24},(_,i)=>`<option value="${i}"${i===invFrom?' selected':''}>${hh(i)}</option>`).join('');
 b.innerHTML=Array.from({length:24},(_,i)=>i+1).map(i=>`<option value="${i}"${i===invTo?' selected':''}>${hh(i)}</option>`).join('');
}
function invRangeChanged(){
 invFrom=Number(document.getElementById('invFrom').value);invTo=Number(document.getElementById('invTo').value);
 if(invTo<=invFrom)invTo=Math.min(24,invFrom+1);
 invSaveRange();invFillRange();requestInvStats();
}
function invRangeAll(){invFrom=0;invTo=24;invSaveRange();invFillRange();requestInvStats();}
function invExport(mode){send('invstatsexport',{value:(invStatsSelected||'')+'|'+invFrom+'|'+invTo+'|'+mode});}
function requestInvStats(day,full){
 if(day!==undefined)invStatsSelected=day;
 send('invstats',{value:(invStatsSelected||'')+(!full&&invRangePartial()?'|'+invFrom+'|'+invTo:'')});
}
function fmtNum(n){return n===null||n===undefined?'—':Number(n).toLocaleString();}
function fmtSigned(n){n=Number(n||0);return `<span class="${n>0?'money-pos':n<0?'money-neg':''}" title="${n.toLocaleString()}">${n>0?'+':''}${fmtMoney(n)}</span>`;}
// 金幣簡寫：1 億以上顯示「x.xx 億」、1 萬以上顯示「x.x 萬」；完整數字放在滑鼠提示
function fmtMoney(n){if(n===null||n===undefined||n==='')return '—';n=Number(n);const a=Math.abs(n);if(a>=1e8)return (n/1e8).toFixed(2)+' 億';if(a>=1e4)return (n/1e4).toFixed(a>=1e6?0:1)+' 萬';return n.toLocaleString();}
function invItemTable(list,limit,cols){
 if(!list||!list.length)return '<div class="item-empty">沒有紀錄</div>';
 const shown=limit?list.slice(0,limit):list;
 return `<ul class="item-list${cols?' cols':''}">`+shown.map(x=>{const n=x.name||'（未知道具）';return `<li title="${esc(n)}｜ID ${esc(x.key)}"><span class="item-name">${esc(n)}</span><span class="item-count">×${Number(x.count).toLocaleString()}</span></li>`}).join('')+'</ul>'+(limit&&list.length>limit?`<div class="item-more">…另有 ${list.length-limit} 種</div>`:'');
}
// v1.3.18.9 每日擊殺：依地圖分組，列出各怪物隻數
// 卡片收合（每小時收益、全部角色合計）：狀態記在瀏覽器
let cardCollapsed={};
try{cardCollapsed=JSON.parse(localStorage.getItem('hhCardCollapsed')||'{}')||{};}catch(e){cardCollapsed={};}
function applyCardState(){Object.keys(cardCollapsed).forEach(id=>{const c=document.getElementById(id);if(c)c.classList.toggle('collapsed',!!cardCollapsed[id]);});}
function toggleCard(id){const c=document.getElementById(id);if(!c)return;const on=!c.classList.contains('collapsed');c.classList.toggle('collapsed',on);cardCollapsed[id]=on?1:0;try{localStorage.setItem('hhCardCollapsed',JSON.stringify(cardCollapsed));}catch(e){}}
// 每一區都能收合：有標題（.section-title）但還沒有收合鈕的卡片自動加上。沒有 id 的用「所在頁面 + 標題文字」當 id，
// 收合狀態和原本的收合鈕一樣記在這台電腦（hhCardCollapsed）。標題被重畫掉按鈕時，每 3 秒補回來。
function addCardToggles(){const used=new Set();document.querySelectorAll('.card').forEach(c=>{const t=[...c.children].find(x=>x.classList&&x.classList.contains('section-title'));if(!t)return;
 if(!c.id){const pg=c.closest('.subpage,.page,.dev-part');let id='cc_'+(pg&&pg.id?pg.id+'_':'')+(t.textContent||'').replace(/\s+/g,'').replace(/[^\w一-鿿]/g,'').slice(0,24);let n=id,k=2;while(used.has(n)||document.getElementById(n))n=id+'_'+(k++);c.id=n;}
 used.add(c.id);if(t.querySelector('.card-toggle'))return;
 const b=document.createElement('button');b.type='button';b.className='card-toggle';b.title='收合 / 展開這一區';b.addEventListener('click',e=>{e.stopPropagation();toggleCard(c.id);});t.appendChild(b);
 if(cardCollapsed[c.id])c.classList.add('collapsed');});}
addCardToggles();setInterval(addCardToggles,3000);
applyCardState();// H-021 擊殺列表可展開 / 收合：每個角色一個總標題、每張地圖一列（點開才看怪物明細）。
// 展開狀態記在瀏覽器（每 10 秒重畫也不會被收回去）。預設：總標題展開、地圖收合。
let killState={};
try{killState=JSON.parse(localStorage.getItem('hhKillState')||'{}')||{};}catch(e){killState={};}
function killIsOpen(k,def){return Object.prototype.hasOwnProperty.call(killState,k)?!!killState[k]:def;}
function killToggle(el){killState[el.dataset.k]=el.open?1:0;try{localStorage.setItem('hhKillState',JSON.stringify(killState));}catch(e){}}
function killAll(open){document.querySelectorAll('#invStatsRoles details.kill-map-d').forEach(el=>{el.open=open;killState[el.dataset.k]=open?1:0;});
 try{localStorage.setItem('hhKillState',JSON.stringify(killState));}catch(e){}}
function killBlock(maps,role){
 if(!maps||!maps.length)return '';
 const total=maps.reduce((s,m)=>s+Number(m.total),0), kinds=maps.reduce((s,m)=>s+(m.mobs||[]).length,0);
 const sk='S|'+(role||'');
 return `<details class="kill-sec" data-k="${esc(sk)}" ${killIsOpen(sk,true)?'open':''} ontoggle="killToggle(this)"><summary class="inv-sub">⚔️ 擊殺 <span class="count" title="${kinds} 種怪">${total.toLocaleString()} 隻｜${maps.length} 張圖</span></summary>`
  +maps.map(m=>{const mk='M|'+(role||'')+'|'+m.map;
   return `<details class="kill-map-d" data-k="${esc(mk)}" ${killIsOpen(mk,false)?'open':''} ontoggle="killToggle(this)"><summary class="kill-map">🗺️ ${esc(m.map)}<span>${(m.mobs||[]).length} 種｜${Number(m.total).toLocaleString()} 隻</span></summary>`
   +`<ul class="item-list">`+(m.mobs||[]).map(x=>`<li><span class="item-name">👾 ${esc(x.name)}</span><span class="item-count">×${Number(x.count).toLocaleString()}</span></li>`).join('')+'</ul></details>';}).join('')
  +'</details>';
}
function renderInvStats(d){
 invStatsData=d;renderHourly(); if(latestState)renderHpMonitor(latestState.accounts||[],false);
 invStatsSelected=d.day;invStatsToday=d.today;
 const sel=document.getElementById('invStatsDay');
 if(sel){const opts=(d.days||[]).map(x=>`<option value="${x}"${x===d.day?' selected':''}>${x}${x===d.today?'（今天）':''}</option>`).join('');if(sel.innerHTML!==opts)sel.innerHTML=opts;}
 const hint=document.getElementById('invStatsHint');
 const part=!!(d.range&&d.range.partial);
 const hh2=n=>String(n).padStart(2,'0')+':00';
 if(hint)hint.textContent=!d.pdbReady?'遊戲資料讀取尚未就緒，暫時無法統計（遊戲更新後第一次啟動需要幾十秒）':(part?`只統計 ${hh2(d.range.from)}～${hh2(d.range.to)}｜`:'')+(d.day===d.today?'自動更新中':'歷史紀錄');
 const t=d.totals||{},gained=t.gained||[],totalCount=gained.reduce((s,x)=>s+Number(x.count),0);
 const tot=document.getElementById('invStatsTotals');
 if(tot)tot.innerHTML=`<div class="card stat"><div class="ico g">${icon('coin')}</div><div><div class="label">${part?'該時段金幣淨變化':'金幣淨變化'}</div><div class="num">${fmtSigned(t.moneyNet)}</div></div></div>`
  +`<div class="card stat"><div class="ico b">${icon('trend')}</div><div><div class="label">金幣增加 / 減少</div><div class="num" style="font-size:20px"><span title="${fmtNum(t.moneyGain)}">${fmtMoney(t.moneyGain)}</span> / <span title="${fmtNum(t.moneySpend)}">${fmtMoney(t.moneySpend)}</span></div></div></div>`
  +`<div class="card stat"><div class="ico a">${icon('invstats')}</div><div><div class="label">打怪拾取</div><div class="num" style="font-size:18px">${gained.length} 種 / ${totalCount.toLocaleString()} 個</div></div></div>`
  +`<div class="card stat"><div class="ico b">${icon('people')}</div><div><div class="label">統計角色</div><div class="num">${(d.roles||[]).length}</div></div></div>`;
 const ti=document.getElementById('invStatsTotalItems');if(ti)ti.innerHTML=invItemTable(gained,40,true);
 const tp=document.getElementById('invStatsTotalPill');if(tp)tp.textContent=`${gained.length} 種｜${totalCount.toLocaleString()} 個`;
 const rl=document.getElementById('invStatsRoles');
 if(rl)rl.innerHTML=(d.roles||[]).length?orderedRoles(d.roles).map(r=>{const gn=(r.gained||[]).reduce((s,x)=>s+Number(x.count),0);return `<div class="hp-card inv-card" data-role="${esc(r.name)}"><div class="hp-head"><span class="drag-h" draggable="true" title="按住這裡拖拉，可以換這個角色的順序">⠿</span><div class="hp-name">${esc(r.name)}</div><span class="hp-status ${r.live?'good':'off'}">${r.live?'統計中':'未連線'}</span></div>`
  +(part?`<div class="inv-money"><div><small>該時段增加</small><b class="money-pos" title="${fmtNum(r.moneyGain)}">+${fmtMoney(r.moneyGain)}</b></div><div><small>該時段減少</small><b title="${fmtNum(r.moneySpend)}">−${fmtMoney(r.moneySpend)}</b></div><div><small>淨變化</small><b title="${fmtNum(r.moneyNet)}">${fmtSigned(r.moneyNet)}</b></div></div>`+(r.hasHourly===false?`<div class="hint" style="margin:6px 0">⚠ 這天是舊版留下的紀錄，沒有逐小時的道具資料：只算得出金幣增加，道具與金幣減少無法分時段（整天的數字請把時段改成「整天」）。</div>`:''):`<div class="inv-money"><div><small>開始金幣</small><b title="${fmtNum(r.moneyStart)}">${fmtMoney(r.moneyStart)}</b></div><div><small>目前金幣</small><b title="${fmtNum(r.moneyNow)}">${fmtMoney(r.moneyNow)}</b></div><div><small>今日增加</small><b class="money-pos" title="增加 ${fmtNum(r.moneyGain)}｜減少 ${fmtNum(r.moneySpend)}">+${fmtMoney(r.moneyGain)}</b></div></div>`)
  +killBlock(r.kills,r.name)
  +`<div class="inv-sub">打怪拾取 <span class="count">${(r.gained||[]).length} 種｜${gn.toLocaleString()} 個</span></div>${invItemTable(r.gained,15)}`
  +((r.removed||[]).length?`<details><summary>減少道具（${r.removed.length} 種）</summary>${invItemTable(r.removed)}</details>`:'')
  +(((r.xferIn||[]).length||(r.xferOut||[]).length||r.moneyXferIn||r.moneyXferOut)?`<details><summary>🔁 角色間轉移（不算拾取）</summary>${r.moneyXferIn||r.moneyXferOut?`<div class="account-sub">💰 轉入 ${fmtMoney(r.moneyXferIn||0)}｜轉出 ${fmtMoney(r.moneyXferOut||0)}</div>`:''}${(r.xferIn||[]).length?`<div class="inv-sub">⬅️ 從其他角色收到</div>${invItemTable(r.xferIn)}`:''}${(r.xferOut||[]).length?`<div class="inv-sub">➡️ 給了其他角色</div>${invItemTable(r.xferOut)}`:''}</details>`:'')+`</div>`}).join('')
  :'<div class="hint">這一天還沒有統計資料。角色登入遊戲後會自動開始統計。</div>';
}
// H-022 各角色統計卡可以拖拉排順序（記在瀏覽器；新出現的角色排在最後）
let roleOrder=[];
try{roleOrder=JSON.parse(localStorage.getItem('hhRoleOrder')||'[]')||[];}catch(e){roleOrder=[];}
function orderedRoles(roles){
 const pos=new Map(roleOrder.map((n,i)=>[n,i]));
 return roles.map((r,i)=>[r,i]).sort((a,b)=>{const pa=pos.has(a[0].name)?pos.get(a[0].name):1e6+a[1],pb=pos.has(b[0].name)?pos.get(b[0].name):1e6+b[1];return pa-pb;}).map(x=>x[0]);
}
function saveRoleOrder(){try{localStorage.setItem('hhRoleOrder',JSON.stringify(roleOrder));}catch(e){}}
function resetRoleOrder(){roleOrder=[];saveRoleOrder();if(invStatsData)renderInvStats(invStatsData);}
(function(){
 let dragging=null;
 const box=()=>document.getElementById('invStatsRoles');
 document.addEventListener('dragstart',e=>{const h=e.target.closest&&e.target.closest('.drag-h');if(!h)return;dragging=h.closest('.inv-card');if(!dragging)return;
  dragging.classList.add('dragging');try{e.dataTransfer.effectAllowed='move';e.dataTransfer.setData('text/plain',dragging.dataset.role||'');}catch(x){}});
 document.addEventListener('dragend',()=>{if(dragging)dragging.classList.remove('dragging');document.querySelectorAll('.inv-card.drop-target').forEach(c=>c.classList.remove('drop-target'));dragging=null;});
 document.addEventListener('dragover',e=>{if(!dragging)return;const c=e.target.closest&&e.target.closest('.inv-card');if(!c||!box()||!box().contains(c))return;e.preventDefault();
  document.querySelectorAll('.inv-card.drop-target').forEach(x=>x.classList.remove('drop-target'));if(c!==dragging)c.classList.add('drop-target');});
 document.addEventListener('drop',e=>{if(!dragging)return;const c=e.target.closest&&e.target.closest('.inv-card');if(!c||!box()||!box().contains(c)||c===dragging)return;e.preventDefault();
  const cards=[...box().querySelectorAll('.inv-card')];const from=cards.indexOf(dragging),to=cards.indexOf(c);
  if(from<to)c.after(dragging);else c.before(dragging);
  roleOrder=[...box().querySelectorAll('.inv-card')].map(x=>x.dataset.role);saveRoleOrder();});
})();invFillRange();
// H-017 命運箱子自動開啟
let mboxSig='';
function renderMBox(d){
 const en=document.getElementById('mboxEnabled'),iv=document.getElementById('mboxInterval'),bl=document.getElementById('mboxBlocker'),pill=document.getElementById('mboxPill');
 if(en&&document.activeElement!==en)en.checked=!!d.enabled;
 if(iv&&document.activeElement!==iv)iv.value=d.interval;
 const on=(d.roles||[]).filter(r=>r.on).length;
 if(pill)pill.textContent=d.enabled?`啟用中｜${on} 個角色`:'未啟用';
 if(bl)bl.textContent=d.enabled&&d.blocker?'⏸ 暫停中：'+d.blocker:'';
 const box=document.getElementById('mboxRows');if(!box)return;
 const ae=document.activeElement;if(box.contains(ae)&&ae.tagName==='INPUT'&&ae.type==='text')return;   // 正在輸入按鍵時不重畫
 box.innerHTML=(d.roles||[]).length?d.roles.map(r=>`<tr data-idx="${r.index}" data-name="${esc(r.name)}"><td><input type="checkbox" ${r.on?'checked':''} onchange="saveMBoxRole(this)"></td>`
  +`<td class="account-name">${esc(r.name)}${r.alive?'':' <span class="account-sub">（未連線）</span>'}</td>`
  +`<td><input type="text" value="${esc(r.key)}" maxlength="3" style="width:60px" onchange="saveMBoxRole(this)"></td>`
  +`<td>${r.on?(r.nextIn>0?r.nextIn+' 秒後':(d.enabled?'馬上':'—')):'—'}</td><td>${r.count>=0?r.count+' 個':'—'}</td><td class="account-sub">${esc(r.status||'')}${r.buff?'<br><span title="遊戲角色身上的效果清單（右下角狀態圖示的資料）">'+esc(r.buff)+'</span>':''}</td></tr>`).join('')
  :'<tr><td colspan="6" class="hint">沒有開啟監控的角色</td></tr>';
}
function saveMBoxCfg(){send('mboxcfg',{value:`${document.getElementById('mboxEnabled').checked?1:0}~${Math.max(30,Number(document.getElementById('mboxInterval').value)||180)}`});}
function saveMBoxRole(el){const tr=el.closest('tr');const key=(tr.querySelector('input[type=text]').value||'e').trim();
 send('mboxrole',{value:`${tr.dataset.idx}~${tr.querySelector('input[type=checkbox]').checked?1:0}~${key}~${tr.dataset.name}`});}
// H-027 技能組合
let partySig='';
function renderParty(d){
 const en=document.getElementById('partyEnabled'),st=document.getElementById('partySettle'),bl=document.getElementById('partyBlocker'),pill=document.getElementById('partyPill');
 if(en&&document.activeElement!==en)en.checked=!!d.enabled;
 if(st&&document.activeElement!==st)st.value=d.settle;
 const rj=document.getElementById('partyRejoin');if(rj&&document.activeElement!==rj)rj.checked=!!d.rejoin;
 const hb=document.getElementById('partyHandback');if(hb&&document.activeElement!==hb)hb.checked=!!d.handback;
 const leaders=(d.roles||[]).filter(r=>r.leader).length;
 if(pill)pill.textContent=d.enabled?`啟用中｜${leaders} 位隊長`:'未啟用';
 if(bl)bl.textContent=d.enabled&&d.blocker?'⏸ 暫停中：'+d.blocker:'';
 const box=document.getElementById('partyRows');if(!box)return;
 const names=d.names||[];
 const sig=JSON.stringify([names,(d.roles||[]).map(r=>[r.index,r.name,r.alive,r.leader,r.members,r.remote])]);
 if(sig!==partySig){   // 名單或設定變了才重畫（不然你正在點的勾選框會被洗掉）
  partySig=sig;
  box.innerHTML=(d.roles||[]).length?d.roles.map(r=>{
   const others=names.filter(n=>n!==r.name);
   const remoteBox=`<div style="margin-top:6px"><span class="account-sub">另一台電腦的角色（遊戲內名稱，用半形逗號 , 分隔）：</span><input class="party-remote" style="width:100%;max-width:340px" value="${esc(r.remote||'')}" placeholder="例如 角色甲,角色乙" onchange="savePartyRemote(this)"></div>`;
   const mem=r.leader?(others.length?others.map(n=>`<label style="display:inline-block;margin:2px 10px 2px 0"><input type="checkbox" class="party-mem" value="${esc(n)}" ${(r.members||[]).includes(n)?'checked':''} onchange="savePartyRole(this)"> ${esc(n)}</label>`).join(''):'<span class="account-sub">沒有其他角色</span>')+remoteBox:'<span class="account-sub">勾選「隊長」後才能選隊員</span>';
   const hidden=(r.members||[]).filter(n=>!names.includes(n));   // 沒開啟監控所以沒列出來的既有隊員：存檔時要保留
   return `<tr data-idx="${r.index}" data-name="${esc(r.name)}" data-hidden="${esc(hidden.join('|'))}"><td><input type="checkbox" class="party-leader" ${r.leader?'checked':''} onchange="savePartyRole(this)"></td>`
    +`<td class="account-name">${esc(r.name)}${r.alive?'':' <span class="account-sub">（未連線）</span>'}</td><td>${mem}</td>`
    +`<td class="account-sub party-status"></td><td>${r.leader&&((r.members||[]).length||r.remote)?`<button class="btn soft" onclick="send('partynow',{value:'${r.index}'})">立即組隊</button>`:''}</td></tr>`;}).join('')
   :'<tr><td colspan="5" class="hint">沒有開啟監控的角色</td></tr>';
 }
 (d.roles||[]).forEach(r=>{const tr=box.querySelector(`tr[data-idx="${r.index}"]`);const c=tr&&tr.querySelector('.party-status');if(c)c.textContent=r.leader?(r.status||''):'';});
 const mbox=document.getElementById('partyMemRows');
 if(mbox){   // 沒有輸入框，每次直接重畫
  const chip={ok:['在隊中','ok'],wait:['進行中','info'],warn:['要注意','warn'],bad:['失敗 / 設定有問題','bad'],mute:['暫時不用管',''],pending:['待邀請','info'],none:['還沒檢查','']};
  const rows=[];
  (d.roles||[]).filter(r=>r.leader).forEach(r=>(r.memberStat||[]).forEach(m=>{
   const c=chip[m.st]||chip.none;
   rows.push(`<tr><td class="account-name">${esc(r.name)}</td><td>${esc(m.name)}${m.remote?' <span class="account-sub">（另一台電腦）</span>':''}</td><td><span class="mchip ${c[1]}">${c[0]}</span></td><td class="account-sub">${esc(m.text||'')}</td><td class="account-sub">${m.next>0?(m.next>=90?Math.ceil(m.next/60)+' 分鐘後':m.next+' 秒後'):'—'}</td></tr>`);}));
  mbox.innerHTML=rows.length?rows.join(''):'<tr><td colspan="5" class="hint">沒有設定隊員</td></tr>';
 }
 const abox=document.getElementById('partyAcceptRows');if(!abox)return;
 const asig=JSON.stringify((d.roles||[]).map(r=>[r.index,r.name,r.accept,r.acceptFrom]));
 if(asig!==partyAcceptSig){
  partyAcceptSig=asig;
  abox.innerHTML=(d.roles||[]).length?d.roles.map(r=>`<tr data-idx="${r.index}" data-name="${esc(r.name)}"><td><input type="checkbox" class="party-accept" ${r.accept?'checked':''} onchange="savePartyAccept(this)"></td><td class="account-name">${esc(r.name)}</td><td><input class="party-from" style="width:100%;max-width:300px" value="${esc(r.acceptFrom||'')}" placeholder="必填：隊長的遊戲內名稱" onchange="savePartyAccept(this)"></td><td class="account-sub party-accept-status"></td></tr>`).join(''):'<tr><td colspan="4" class="hint">沒有開啟監控的角色</td></tr>';
 }
 (d.roles||[]).forEach(r=>{const tr=abox.querySelector(`tr[data-idx="${r.index}"]`);const c=tr&&tr.querySelector('.party-accept-status');if(c)c.textContent=r.accept?(r.acceptStatus||''):'';});
}
function renderCompanion(d){
 const en=document.getElementById('cwEnabled'),pe=document.getElementById('cwPet'),me=document.getElementById('cwMerc'),dl=document.getElementById('cwDoll'),pill=document.getElementById('cwPill'),bl=document.getElementById('cwBlocker'),box=document.getElementById('cwRows');
 if(en&&document.activeElement!==en)en.checked=!!d.enabled;
 if(pe&&document.activeElement!==pe)pe.checked=!!d.pet;
 if(me&&document.activeElement!==me)me.checked=!!d.merc;
 if(dl&&document.activeElement!==dl)dl.checked=!!d.doll;
 if(pill)pill.textContent=d.enabled?'監測中':'未啟用';
 renderCwQuick(d.roles);
 if(bl)bl.textContent=d.enabled&&d.blocker?'⏸ 暫停中：'+d.blocker:'';
 if(box)box.innerHTML=(d.roles||[]).length?d.roles.map(r=>`<tr><td class="account-name">${esc(r.name)}</td><td class="account-sub">${d.pet?esc(r.pet||'—'):'不監測'}</td><td class="account-sub">${d.merc?esc(r.merc||'—'):'不監測'}</td><td class="account-sub">${d.doll?esc(r.doll||'—'):'不監測'}</td></tr>`).join(''):'<tr><td colspan="4" class="hint">沒有開啟監控的角色</td></tr>';
}
function cwQuickSave(i,name,clear){const el=document.getElementById('cwQk'+i);const v=clear?'':(el?el.value:'');send('quickkeyset',{value:`${i}~${v}~${name}`});}
function renderCwQuick(roles){
 const act=document.activeElement;if(act&&act.id&&act.id.startsWith('cwQk'))return;   // 正在輸入時不重畫
 const box=document.getElementById('cwQuickRows'),warn=document.getElementById('cwQuickWarn');if(!box)return;
 let bad=[];
 box.innerHTML=(roles||[]).length?roles.map(r=>{const q=r.quick;if(!q)return `<tr><td class="account-name">${esc(r.name)}</td><td colspan="7" class="account-sub">讀不到（沒有連線 / 這個遊戲版本沒有資料）</td></tr>`;
  if(!q.ok)bad.push(r.name+'（'+q.keys+'）');
  return `<tr><td class="account-name">${esc(r.name)}</td>`+q.slots.map(s=>`<td class="account-sub" style="${s.t==='命運箱子'?'color:#c0392b;font-weight:600':''}"><b>${esc((s.k||'?').toUpperCase())}</b> ${esc(s.n)}${s.t?` <span class="pill">${esc(s.t)}</span>`:''}</td>`).join('')+`<td class="account-sub">${q.manual?'<span class="pill">手動</span> ':''}<input type="text" id="cwQk${r.index}" value="${esc(q.set||q.auto||q.keys)}" placeholder="q,w,e,a,s,d" style="width:130px" title="6 格的鍵，用逗號分開；留白按「自動」= 改回程式自己讀"> <button class="btn soft" onclick="cwQuickSave(${r.index},'${esc(r.name).replace(/'/g,"")}',false)">儲存</button> <button class="btn soft" onclick="cwQuickSave(${r.index},'${esc(r.name).replace(/'/g,"")}',true)" title="改回自動讀取">自動</button>${q.manual&&q.auto?`<div class="hint">自動讀到：${esc(q.auto)}</div>`:''}</td></tr>`;}).join(''):'<tr><td colspan="8" class="hint">沒有角色</td></tr>';
 if(warn)warn.textContent=bad.length?'⚠ 鍵位和預設的 Q W E A S D 不同：'+bad.join('、')+'。如果不是你自己改過按鍵，可能是位置資料讀錯了，請先關掉寵物 / 雇傭兵 / 魔法娃娃監測，並把診斷包給作者。':'';
}
function saveCompanion(){const v=id=>document.getElementById(id).checked?1:0;send('companionset',{value:`${v('cwEnabled')}~${v('cwPet')}~${v('cwMerc')}~${v('cwDoll')}`});}
let dhOn=new Set(),dhTasks=[],dhChars=[],dhRunning=false,dhTest=false;
function dhEditing(){return false;}
let dhLast=null;
function renderDailyHunt(d){
 dhLast=d;if(dragSortBusy)return;
 dhTasks=d.tasks||[];{const on=dhTasks.map((t,i)=>({t,i})).filter(x=>x.t.on).sort((a,b)=>a.t.rank-b.t.rank||a.i-b.i).map(x=>x.t.map);const rest=(d.selected||[]).filter(id=>!on.includes(id));dhOn=new Set([...on,...rest]);}dhChars=d.chars||[];dhRunning=!!d.running;dhTest=!!d.test;{const rs=document.getElementById('dhResume');if(rs&&document.activeElement!==rs&&d.resume!==undefined)rs.checked=!!d.resume;}{const tc=document.getElementById('dhTest');if(tc)tc.checked=dhTest;}
 const btn=document.getElementById('dhRun'),box0=document.getElementById('dhChars'),pill=document.getElementById('dhPill'),st=document.getElementById('dhStatus'),box=document.getElementById('dhRows');
 if(btn){btn.textContent=dhRunning?'■ 停止':'▶ 啟動';}
 if(d.after){const a=d.after,cb=document.getElementById('dhAfterOn'),w=document.getElementById('dhAfterWhere'),m=document.getElementById('dhAfterMsg'),c=document.getElementById('dhAfterClear');if(cb&&document.activeElement!==cb)cb.checked=!!a.on;if(w)w.textContent=a.map?`${a.name} ${a.spot}`:'（還沒記錄掛機位置）';if(m)m.textContent=a.msg||'';if(c)c.style.visibility=a.map?'':'hidden';}
 [['dhNpc',d.npc],['dhCard',d.card],['dhRow',d.row]].forEach(([id,v])=>{const e=document.getElementById(id);if(e&&document.activeElement!==e&&v!==undefined)e.value=v;});
 {const sel=document.getElementById('dhNpcSel'),inp=document.getElementById('dhNpc');if(sel&&inp&&d.npc!==undefined&&document.activeElement!==sel&&document.activeElement!==inp){const known=[...sel.options].some(o=>o.value===d.npc&&o.value!=='__other');sel.value=known?d.npc:'__other';inp.style.display=known?'none':'';}}
 {const editing=document.activeElement&&document.activeElement.id&&document.activeElement.id.startsWith('dhSchedIn');
 if(box0&&!editing){const sc=d.sched||[];dhSchedNames=dhChars.map(c=>c.name);box0.innerHTML=dhChars.map((c,i)=>{const s=(d.states||[]).find(x=>x.name===c.name)||{};const sd=sc.find(x=>x.name===c.name)||{};const bad=/⚠|卡住|失敗|沒有可跑/.test(s.text||'');return `<div class="char-card ${c.on?(bad?'warn':'on'):''}"><div class="cc-head"><label class="toggle" style="margin:0"><input type="checkbox" ${c.on?'checked':''} onchange="dhCharToggle(${i},this.checked)"> ${esc(c.name)}</label></div>${dhRunning&&c.on?`<div class="cc-state">${esc(s.text||'等待中')}</div>`:`<div class="cc-meta">${c.on?'已勾選':'未勾選'}</div>`}<div class="cc-row"><span class="cc-meta">⏰ 每天</span><input type="text" id="dhSchedIn${i}" value="${esc(sd.times||'')}" placeholder="05:10, 13:00" onkeydown="if(event.key==='Enter')dhSchedSave(${i})"><button class="btn" onclick="dhSchedSave(${i})">儲存</button></div>${sd.status?`<div class="cc-meta">${esc(sd.status)}</div>`:''}</div>`;}).join('')||'<span class="hint">沒有角色</span>';}}
 {const bar=document.getElementById('dhOpBar'),sum=document.getElementById('dhSum'),sub=document.getElementById('dhSumSub');if(bar&&sum&&sub){const on=dhChars.filter(c=>c.on),sts=(d.states||[]).filter(x=>on.some(c=>c.name===x.name));const bad=sts.find(x=>/⚠|卡住|失敗/.test(x.text||''));const warn=(d.alerts||[]).length>0||!!bad;
  bar.className='op-bar'+(warn?' warn':(dhRunning?' on':''));
  if((d.alerts||[]).length){sum.textContent='⚠ 有定時啟動沒有成功';sub.textContent='詳細原因在下方紅色提醒';}
  else if(!dhRunning){sum.textContent='已停止';sub.textContent=on.length?`已勾選 ${on.length} 個角色　｜　勾選且未完成 ${d.pending||0} 張圖`:'請先在下方勾選要跑的角色';}
  else{const first=sts[0];sum.textContent=bad?`⚠ ${bad.name}：${bad.text}`:(dhTest?'測試流程中（只走路、不打怪）':'自動跑圖中');sub.textContent=(first&&!bad&&first.text?`${first.name}：${first.text}　｜　`:'')+`勾選且未完成 ${d.pending||0} 張圖`;}}}
 renderDhSched(d);
 if(pill)pill.textContent=dhRunning?(dhTest?'測試流程中（不打怪）':'自動跑圖中'):'已停止';
 const sm=document.getElementById('dhSpotMsg');if(sm)sm.textContent=d.spotMsg||'';
 const bd=document.getElementById('dhBuild');if(bd){bd.textContent=d.build||'';bd.style.color=(d.build||'').includes('⚠')?'#c0392b':'';}
 if(st)st.textContent=d.status||(d.using?`顯示角色：${d.using}｜勾選且未完成：${d.pending} 張圖`:'');
 const dhNo=dhOrderMap();if(box)box.innerHTML=dhTasks.length?dhTasks.map(t=>{const full=t.done>=t.target;const note=!t.runnable?'尚未支援（只能自己打）':(t.claimed?'已領獎':(full?'已打滿':''));return `<tr${dhNo.has(t.map)?` class="drag-row" data-key="${t.map}"`:''}><td style="white-space:nowrap"><input type="checkbox" ${dhOn.has(t.map)?'checked':''} ${t.runnable?'':'disabled'} onchange="dhToggle(${t.map},this.checked)">${dhNo.has(t.map)?`<span class="fp-grip" title="按住拖拉調整執行順序（沒打滿的先跑，再跑已打滿的）">⠿</span><span class="dh-no" title="執行順序（沒打滿的先跑，再跑已打滿的）">${dhNo.get(t.map)}</span>`:''}</td><td class="account-name">${esc(t.name.split(' / ')[0])}</td><td class="account-sub">${esc(t.name.split(' / ')[1]||'')}</td><td class="account-sub">${t.done} / ${t.target}${full?' ✓':''}</td><td class="account-sub">${esc(t.group)}</td><td class="account-sub">${note}</td><td class="account-sub dh-spot">${t.runnable?`<span class="dh-xy">${t.spot?`<b>${esc(t.spot)}</b>`:'自動找怪'}</span><button class="btn" onclick="dhSpot(${t.map},'teach')">記錄</button><button class="btn" style="${t.spot?'':'visibility:hidden'}" ${t.spot?'':'tabindex="-1" disabled'} onclick="dhSpot(${t.map},'clear')">清除</button>`:''}</td></tr>`;}).join(''):'<tr><td colspan="7" class="hint">還沒有任務資料：勾選角色並按「▶ 啟動」後程式會自己按 T 讀取，或在遊戲裡按 T 打開一次。</td></tr>';
 if(box)dragSortable(box,'tr.drag-row',(f,t,after)=>{if(f===null){if(dhLast)renderDailyHunt(dhLast);return;}dhDrop(Number(f),Number(t),after);});
}
let fpOrder=[];
// 拖拉排列（功能優先順序 / 首頁啟動順序 / 每日討伐順序共用）：按住一列拖到另一列放開。
// 拖拉中 dragSortBusy=true：程式送來的畫面更新先不重畫，免得拖到一半被換掉。drop(null) = 拖拉取消。
let dragSortBusy=false;
function dragSortable(el,sel,drop){let from=null;const rows=[...el.querySelectorAll(sel)];const clr=()=>rows.forEach(x=>x.classList.remove('fp-over-top','fp-over-bottom','fp-dragging'));
 rows.forEach(r=>{r.setAttribute('draggable','true');
  r.addEventListener('dragstart',e=>{from=r.dataset.key;dragSortBusy=true;r.classList.add('fp-dragging');e.dataTransfer.effectAllowed='move';try{e.dataTransfer.setData('text/plain',from);}catch{}});
  r.addEventListener('dragover',e=>{if(from===null)return;e.preventDefault();e.dataTransfer.dropEffect='move';const b=r.getBoundingClientRect(),after=e.clientY>b.top+b.height/2;rows.forEach(x=>x.classList.remove('fp-over-top','fp-over-bottom'));if(r.dataset.key!==from)r.classList.add(after?'fp-over-bottom':'fp-over-top');});
  r.addEventListener('drop',e=>{e.preventDefault();if(from===null)return;const b=r.getBoundingClientRect(),after=e.clientY>b.top+b.height/2,f=from;from=null;dragSortBusy=false;clr();drop(r.dataset.key!==f?f:null,r.dataset.key,after);});
  r.addEventListener('dragend',()=>{if(from!==null){from=null;dragSortBusy=false;clr();drop(null);}});
 });}
// 把 from 移到 to 的上面（after=false）或下面（after=true）；回傳新的清單
function dragReorder(list,from,to,after){const i=list.indexOf(from);let j=list.indexOf(to);if(i<0||j<0)return null;j+=after?1:0;if(j>i)j-=1;const r=list.slice();r.splice(i,1);r.splice(j,0,from);return r;}
function renderPriority(d){if(dragSortBusy)return;fpOrder=(d.order||[]);const el=document.getElementById('fpList');if(!el)return;el.innerHTML=fpOrder.map((o,i)=>`<div class="fp-row" data-key="${esc(o.key)}" title="按住拖拉調整順序"><span class="fp-grip">⠿</span><span class="dh-no">${i+1}</span><span style="min-width:200px">${esc(o.name)}</span></div>`).join('');
 dragSortable(el,'.fp-row',(f,t,after)=>{if(f!==null){const r=dragReorder(fpOrder.map(o=>o.key),f,t,after);if(r){fpOrder=r.map(k=>fpOrder.find(o=>o.key===k));send('priorityset',{value:r.join(',')});}}renderPriority({order:fpOrder});});}
function fpMove(i,dir){const j=i+dir;if(j<0||j>=fpOrder.length)return;[fpOrder[i],fpOrder[j]]=[fpOrder[j],fpOrder[i]];renderPriority({order:fpOrder});send('priorityset',{value:fpOrder.map(o=>o.key).join(',')});}
function fpReset(){send('priorityset',{value:'daily,switcher,mining,boss,dailyhunt,party,companion,mbox,lagfix'});}
let mnCur=null,mnChars=[],mnRunning=false,mnColorList=['綠','紫','紅','黃','藍'],mnColorOn=new Set(mnColorList);const mnColorCss={'綠':'#27ae60','紫':'#8e44ad','紅':'#e74c3c','黃':'#f1c40f','藍':'#2980b9'};
function renderMnColors(){const el=document.getElementById('mnColors');if(!el||dragSortBusy)return;el.innerHTML=mnColorList.map((c,i)=>{const on=mnColorOn.has(c);const no=on?mnColorList.slice(0,i+1).filter(x=>mnColorOn.has(x)).length:'';return `<div class="fp-row" data-key="${c}" title="按住拖拉調整優先順序"><span class="fp-grip">⠿</span><label class="toggle"><input type="checkbox" ${on?'checked':''} onchange="mnColorToggle('${c}',this.checked)"> <span style="display:inline-block;width:12px;height:12px;border-radius:50%;background:${mnColorCss[c]}"></span> ${c}能原石</label>${on?`<span class="dh-no">${no}</span>`:''}</div>`;}).join('');
 dragSortable(el,'.fp-row',(f,t,after)=>{if(f!==null){const r=dragReorder(mnColorList,f,t,after);if(r){mnColorList=r;saveAutoMining();}}renderMnColors();});}
function mnColorToggle(c,on){if(on)mnColorOn.add(c);else mnColorOn.delete(c);renderMnColors();saveAutoMining();}
function mnColorMove(i,dir){const j=i+dir;if(j<0||j>=mnColorList.length)return;[mnColorList[i],mnColorList[j]]=[mnColorList[j],mnColorList[i]];renderMnColors();saveAutoMining();}
function renderAutoMining(d){mnLast=d;renderMnStats(d.stats);if(Array.isArray(d.colors)){mnColorOn=new Set(d.colors);mnColorList=[...d.colors,...mnColorList.filter(c=>!d.colors.includes(c))];renderMnColors();}mnChars=d.chars||[];mnRunning=!!d.running;const btn=document.getElementById('mnRun'),box=document.getElementById('mnChars'),pill=document.getElementById('mnPill'),en=document.getElementById('mnEnter'),kp=document.getElementById('mnKeep'),bs=document.getElementById('mnBoss'),br=document.getElementById('mnBar'),sk=document.getElementById('mnSkill'),cs=document.getElementById('mnCurSkill'),sh=document.getElementById('mnSkipHard'),hc=document.getElementById('mnHardCount'),lp=document.getElementById('mnLoops'),stc=document.getElementById('mnStrict'),rs=document.getElementById('mnResume');if(rs&&document.activeElement!==rs&&d.resume!==undefined)rs.checked=!!d.resume;if(lp&&document.activeElement!==lp&&d.loops!==undefined)lp.value=String(d.loops);if(stc&&document.activeElement!==stc&&d.strictColor!==undefined)stc.checked=!!d.strictColor;mnCur=d.curSkill||null;if(sh&&document.activeElement!==sh&&d.skipHard!==undefined)sh.checked=!!d.skipHard;if(hc)hc.textContent=(d.hardCount||d.blockCount)?`（已記下 ${d.hardCount||0} 個不好走、${d.blockCount||0} 個不去採的位置）`:'';if(btn)btn.textContent=mnRunning?'■ 停止':'▶ 啟動';if(pill)pill.textContent=mnRunning?'採礦中':'已停止';if(btn)btn.disabled=d.licensed===false;if(d.licensed===false&&pill)pill.textContent='🔒 這台電腦沒有有效的使用授權';if(en&&document.activeElement!==en)en.checked=!!d.autoEnter;if(kp&&document.activeElement!==kp)kp.checked=!!d.keepInv;if(bs&&document.activeElement!==bs)bs.checked=!!d.boss;if(br&&document.activeElement!==br&&d.bossBar!==undefined)br.value=String(d.bossBar);if(sk&&document.activeElement!==sk&&d.bossSkill!==undefined)sk.value=d.bossSkill;if(cs)cs.textContent=mnCur?`目前：${mnCur.name||'（未知技能）'}（${mnCur.id||'—'}）｜技能欄 F${mnCur.bar}`:'';renderMnRelay(d);if(box&&!(box.contains(document.activeElement)&&['INPUT','SELECT'].includes(document.activeElement.tagName)))box.innerHTML=mnChars.length?mnChars.map((c,i)=>{const s=(d.states||[]).find(x=>x.name===c.name)||{};const sr=(d.stats||[]).find(x=>x.name===c.name);const bad=/⚠|卡住|失敗|不足|沒有入場|斷線/.test(s.text||'');return `<div class="char-card ${c.on?(bad?'warn':'on'):''}"><div class="cc-head"><label class="toggle" style="margin:0"><input type="checkbox" ${c.on?'checked':''} onchange="mnCharToggle(${i},this.checked)"> ${esc(c.name)}</label>${sr?`<span class="cc-meta" style="margin-left:auto">今天 ${sr.dayGathers} 顆</span>`:''}</div>${mnRunning&&c.on?`<div class="cc-state">${esc(s.text||'等待中')}</div>${s.visit?`<div class="cc-meta">${esc(s.visit)}</div>`:''}${s.eta?`<div class="cc-meta">⏱ ${esc(s.eta)}</div>`:''}`:`<div class="cc-meta">${c.on?'已勾選，按啟動開始':'未勾選'}</div>`}${c.sched?`<div class="cc-meta">⏰ 排班 ${esc(c.sched)}｜${esc(c.schedStatus||'')}</div>`:''}${mnCharCfgHtml(c,i)}</div>`;}).join(''):'<span class="hint">沒有可用的角色</span>';
 {const bar=document.getElementById('mnOpBar'),sum=document.getElementById('mnSum'),sub=document.getElementById('mnSumSub');if(bar&&sum&&sub){const on=mnChars.filter(c=>c.on),sts=(d.states||[]).filter(x=>on.some(c=>c.name===x.name));const bad=sts.find(x=>/⚠|卡住|失敗|不足|沒有入場|斷線/.test(x.text||''));const today=(d.stats||[]).filter(x=>on.some(c=>c.name===x.name)).reduce((a,x)=>a+(x.dayGathers||0),0);
  bar.className='op-bar'+(d.licensed===false?' warn':(bad?' warn':(mnRunning?' on':'')));
  if(d.licensed===false){sum.textContent='🔒 這台電腦沒有有效的使用授權';sub.textContent='請到「設定 → 其他 → 使用授權」確認';}
  else if(!mnRunning){sum.textContent='已停止';sub.textContent=on.length?`已勾選 ${on.length} 個角色　｜　今天共採集 ${today} 顆`:'請先在下方勾選要採礦的角色';}
  else{const first=sts[0];sum.textContent=bad?`⚠ ${bad.name}：${bad.text}`:`採礦中 · ${on.map(c=>c.name).join('、')}`;sub.textContent=(first&&!bad&&first.text?`${first.name}：${first.text}　｜　`:'')+`今天共採集 ${today} 顆`+(first&&first.visit?`　｜　${first.visit}`:'');}}}}
function renderMnStats(rows){const el=document.getElementById('mnStats');if(!el)return;rows=rows||[];if(!rows.length){el.textContent='還沒有紀錄';return;}const tot={},day={};let g=0,dg=0;rows.forEach(r=>{g+=r.gathers;dg+=r.dayGathers;(r.items||[]).forEach(i=>{tot[i.n]=(tot[i.n]||0)+i.t;day[i.n]=(day[i.n]||0)+i.d;});});const fmt=o=>Object.keys(o).filter(k=>o[k]>0).sort((a,b)=>o[b]-o[a]).map(k=>`${esc(k)} ×${o[k]}`).join('、')||'（沒有）';let h=`<div>累積採集 <b>${g}</b> 顆｜今天 <b>${dg}</b> 顆</div><div style="margin-top:4px">累積取得：${fmt(tot)}</div><div style="margin-top:2px">今天取得：${fmt(day)}</div>`;if(rows.length>1){h+='<div style="margin-top:8px"><table><thead><tr><th>角色</th><th>累積顆數</th><th>今天顆數</th><th>累積取得</th></tr></thead><tbody>'+rows.map(r=>{const o={};(r.items||[]).forEach(i=>o[i.n]=i.t);return `<tr><td>${esc(r.name)}</td><td>${r.gathers}</td><td>${r.dayGathers}</td><td>${fmt(o)}</td></tr>`;}).join('')+'</tbody></table></div>';}const runs=[];rows.forEach(r=>(r.runs||[]).forEach(x=>runs.push({name:r.name,...x})));runs.sort((a,b)=>b.start<a.start?-1:(b.start>a.start?1:0));const multi=rows.length>1;if(runs.length){const itx=x=>x.items.length?x.items.slice().sort((a,b)=>b.c-a.c).map(i=>`${esc(i.n)} ×${i.c}`).join('、'):'（沒有）';h+=`<div style="margin-top:12px"><b>每輪統計</b> <span class="account-sub">（每次進礦場算一輪，最近 10 輪；王的掉落也算在那一輪）</span><table style="margin-top:6px"><thead><tr>${multi?'<th>角色</th>':''}<th>輪</th><th>開始</th><th>待了</th><th>採集</th><th>王</th><th>取得</th></tr></thead><tbody>`+runs.slice(0,10).map(x=>`<tr>${multi?`<td>${esc(x.name)}</td>`:''}<td>第 ${x.n} 輪${x.open?' <span class="pill" style="margin-left:4px">進行中</span>':''}</td><td>${esc(x.start)}</td><td>${x.mins} 分</td><td>${x.gathers} 顆</td><td>${x.boss?x.boss+' 隻':'—'}</td><td>${itx(x)}</td></tr>`).join('')+'</tbody></table></div>';}el.innerHTML=h;}
function mnResetHard(){send('autominingresethard',{value:''});}
function mnResetStats(){if(confirm('確定要清除所有挖礦統計嗎？（累積數字會歸零）'))send('autominingreset',{value:''});}
function mnUseCurSkill(){if(mnCur&&mnCur.id){const sk=document.getElementById('mnSkill');if(sk)sk.value=mnCur.id;saveAutoMining();}}
function mnSlot(i,v){if(mnChars[i])mnChars[i].slot=parseInt(v)||0;saveAutoMining();}
function mnCharToggle(i,on){if(mnChars[i])mnChars[i].on=on;saveAutoMining();}
function mnToggleRun(){mnRunning=!mnRunning;saveAutoMining();}
// v1.3.90.72：顏色、打王、打王技能欄 / 右鍵技能、趟數改成只在每個角色的「設定」裡改；共用值保留在設定檔當作新角色的預設，這裡照最後讀到的送回去
let mnLast={};
function saveAutoMining(){const en=document.getElementById('mnEnter'),kp=document.getElementById('mnKeep'),sh=document.getElementById('mnSkipHard'),stc=document.getElementById('mnStrict'),rs=document.getElementById('mnResume'),L=mnLast;send('autominingset',{value:`${mnRunning?1:0}~${mnChars.filter(c=>c.on).map(c=>c.name).join('|')}~${en&&en.checked?1:0}~${kp&&kp.checked?1:0}~${(L.colors||[]).join(',')}~${L.boss?1:0}~${L.bossBar??8}~${L.bossSkill||''}~${sh&&sh.checked?1:0}~${Math.max(0,Math.min(99,parseInt(L.loops)||0))}~${stc&&stc.checked?1:0}~${mnChars.filter(c=>c.slot>0).map(c=>c.name+':'+c.slot).join('|')}~${rs&&rs.checked?1:0}`});}
function dhNpcPick(){const sel=document.getElementById('dhNpcSel'),inp=document.getElementById('dhNpc');if(sel.value==='__other'){inp.style.display='';inp.focus();return;}inp.style.display='none';inp.value=sel.value;saveDailyHunt();}
function dhSpot(map,what){send('dailyhuntspot',{value:`${map}~${what}`});}
function dhAfter(v){send('dailyhuntafter',{value:v});}
let dhSchedNames=[];
function dhFmt(sec){sec=Math.round(sec);const h=Math.floor(sec/3600),m=Math.floor(sec%3600/60),x=sec%60;return h?`${h} 小時 ${m} 分 ${x} 秒`:(m?`${m} 分 ${x} 秒`:`${x} 秒`);}
function renderDhSched(d){
 const al=document.getElementById('dhAlerts');
 if(al)al.innerHTML=(d.alerts||[]).map(a=>`<div class="dh-alert"><div style="flex:1">⚠️ <b>${esc(a.at)}</b>　${esc(a.text)}</div><button class="btn" onclick="send('dhschedack',{value:'${a.id}'})">知道了</button></div>`).join('');
 const stb=document.getElementById('dhStats');
 if(stb)stb.innerHTML=(d.stats||[]).length?`<table><thead><tr><th>角色</th><th>開始</th><th>觸發</th><th>各地圖花的時間</th><th>總時長</th><th>實際作業</th></tr></thead><tbody>`+(d.stats||[]).map(r=>`<tr><td>${esc(r.char)}</td><td>${esc(r.date)}</td><td>${esc(r.trigger)}</td><td>${r.maps.map(m=>esc(m.n)+' '+dhFmt(m.s)).join('<br>')}</td><td>${dhFmt(r.wall)}</td><td>${dhFmt(r.active)}</td></tr>`).join('')+'</tbody></table>':'還沒有跑完的紀錄';
}
// v1.3.90.71 每個角色自己的採礦設定（空白 = 用上面的共用設定）＋排班進場時間；「存」一次送出
const mnOpen=new Set();
const MN_ALL_COLORS=['綠','紫','紅','黃','藍'];
// 顏色文字用的色（比圓點的色深一點，白底看得清楚；黃色特別加深）
const MN_COLOR_TEXT={'綠':'#1e8449','紫':'#7d3c98','紅':'#c0392b','黃':'#9a7d0a','藍':'#1f618d'};
const mnColorWord=x=>`<b style="color:${MN_COLOR_TEXT[x]||'inherit'}">${esc(x)}</b>`;
function mnCharCfgHtml(c,i){
 const L=mnLast,opt=(val,t,cur)=>`<option value="${val}" ${String(cur)===String(val)?'selected':''}>${t}</option>`;
 const colors=c.cColors==='-'?'':(c.cColors||(L.colors||[]).join(',')),boss=c.cBoss!==''&&c.cBoss!==undefined?c.cBoss:(L.boss?'1':'0'),loops=c.cLoops!==''&&c.cLoops!==undefined?c.cLoops:String(L.loops??0);
 const cl=colors?colors.split(','):[];
 // 顏色順序：第 1～5 順位各一個下拉，選「—」= 不挖；同一個顏色選兩次只算前面那個
 const colorSel=[0,1,2,3,4].map(k=>`<label class="cc-meta" style="display:inline-flex;align-items:center;gap:3px">${k+1}<select id="mnCo${i}_${k}" aria-label="第 ${k+1} 順位" onchange="mnColorDedupe(${i})" style="color:${MN_COLOR_TEXT[cl[k]]||'inherit'};font-weight:${cl[k]?'700':'400'}">${opt('','—',cl[k]||'').replace('<option','<option style="color:var(--text);font-weight:400"')}${MN_ALL_COLORS.map(x=>opt(x,'● '+x,cl[k]||'').replace('<option',(cl.includes(x)&&cl[k]!==x?'<option disabled':'<option')+` style="color:${MN_COLOR_TEXT[x]};font-weight:700"`)).join('')}</select></label>`).join('');
 const sl=c.slots||null,slot=c.slot>=1&&c.slot<=10?c.slot:1;
 return `<details class="cc-more" ${mnOpen.has(c.name)?'open':''} ontoggle="mnOpenToggle(${i},this.open)"><summary><span class="cc-more-btn">⚙ 採礦設定<small>排班・顏色・打王・趟數</small></span><span class="cc-more-sum">${colors?cl.map(mnColorWord).join(' &gt; '):'沒有選顏色'}｜${boss==='1'?'打王':'不打王'}｜${loops==='0'?'一直循環':loops+' 趟'}${c.sched?'｜排班 '+esc(c.sched):''}</span></summary>`
  +`<div class="cc-row"><span class="cc-meta">排班進場時間</span><input id="mnSc${i}" value="${esc(c.sched||'')}" placeholder="例如 06:00（空白＝不排班）" style="width:150px" title="照時間排順序，一次只有一隻在礦場；上一隻結束（跑滿趟數或入場卷用完）就換下一隻，實際以結束時間為準"></div>`
  +`<div class="cc-row"><span class="cc-meta">顏色順序</span><span style="display:inline-flex;flex-wrap:wrap;gap:6px">${colorSel}</span></div>`
  +`<div class="cc-row"><span class="cc-meta">打王</span><select id="mnBo${i}">${opt('1','打',boss)}${opt('0','不打',boss)}</select></div>`
  +`<div class="cc-row"><span class="cc-meta">打王技能（F1 技能欄）</span><select id="mnSl${i}" onchange="mnSlot(${i},this.value)" title="打王前按 F1 切到第一排技能欄，再按這一格的數字鍵選成右鍵技能">${[1,2,3,4,5,6,7,8,9,10].map(n=>opt(String(n),`${n===10?0:n}${sl&&sl[n-1]?'：'+esc(sl[n-1]):(sl?'（空）':'')}`,String(slot))).join('')}</select></div>`
  +`<div class="cc-meta">${sl?(sl[slot-1]?`會用：F1 第 ${slot===10?0:slot} 格＝<b>${esc(sl[slot-1])}</b>`:'<span style="color:var(--amber)">這一格是空的，請選有技能的格子</span>'):'技能名稱要角色在遊戲裡才讀得到'}</div>`
  +`<div class="cc-row"><span class="cc-meta">進礦場趟數</span><input id="mnLp${i}" value="${esc(loops)}" placeholder="0＝一直循環" style="width:80px" inputmode="numeric"></div>`
  +`<div class="cc-row">${c.boxes>=0?`<span class="cc-meta">入場卷禮盒剩 ${c.boxes} 個</span>`:'<span class="cc-meta">入場卷：進過礦場後才讀得到</span>'}<button class="btn primary" style="margin-left:auto" onclick="mnCharSave(${i})">存</button></div></details>`;
}
// 顏色順序防呆：其他順位已經選的顏色變灰、不能再選
function mnColorDedupe(i){
 const sels=[0,1,2,3,4].map(k=>document.getElementById('mnCo'+i+'_'+k)).filter(Boolean);
 const used=sels.map(e=>e.value);
 sels.forEach((e,k)=>{[...e.options].forEach(o=>{o.disabled=!!o.value&&used.some((u,j)=>j!==k&&u===o.value);});if(e.style){e.style.color=MN_COLOR_TEXT[e.value]||'inherit';e.style.fontWeight=e.value?'700':'400';}});
}
function mnOpenToggle(i,open){const c=mnChars[i];if(!c)return;open?mnOpen.add(c.name):mnOpen.delete(c.name);}
function mnCharSave(i){
 const c=mnChars[i];if(!c)return;const g=id=>(document.getElementById(id+i)?.value||'').trim().replace(/~/g,'');
 const cols=[];for(let k=0;k<5;k++){const v=(document.getElementById('mnCo'+i+'_'+k)?.value||'');if(v&&!cols.includes(v))cols.push(v);}
 send('mncharcfg',{value:[c.name,cols.join(','),g('mnBo'),'','',g('mnLp'),g('mnSc')].join('~')});   // 打王技能固定 F1：不再送右鍵技能 / 技能欄
 document.activeElement&&document.activeElement.blur&&document.activeElement.blur();
}
// 排班表：順序、設定時間、趟數、預估開始（上一隻開始＋趟數 × 一趟分鐘）、今天狀態、警語
function renderMnRelay(d){
 const el=document.getElementById('mnRelay');if(!el)return;
 const r=d.relay||[];
 if(!r.length){el.innerHTML='<span class="hint">還沒有排班。在下面角色卡的「個別設定」填「排班進場時間」，就會照時間排成順序，一次一隻輪流進礦場。</span>';return;}
 el.innerHTML=`<div class="hint" style="margin-bottom:6px">一次只有一隻在礦場；上一隻跑滿趟數或入場卷用完就換下一隻（以實際結束時間為準）。預估一趟 ${d.tripMin||150} 分鐘。王打到一半被踢出，下一隻進場接著打。</div>`
  +`<div style="overflow-x:auto"><table><thead><tr><th>順序</th><th>角色</th><th>設定</th><th>趟數</th><th>預估開始</th><th>今天</th></tr></thead><tbody>`
  +r.map((w,k)=>`<tr><td>${k+1}</td><td>${esc(w.name)}</td><td>${esc(w.time)}</td><td>${w.loops?w.loops:'0（一直循環）'}${w.tickets>=0?`<br><small class="muted">禮盒 ${w.tickets}</small>`:''}</td><td>${esc(w.est)}</td><td>${esc(w.status)}</td></tr>${w.warn?`<tr><td></td><td colspan="5"><span class="mx-custom">⚠ ${esc(w.warn)}</span></td></tr>`:''}`).join('')
  +'</tbody></table></div>';
}
// v1.3.90.88 一鍵施法：每個角色一張卡、6 組，每組自己選觸發鍵（滑鼠側鍵 / Ctrl＋左鍵 / 鍵盤鍵），各自設技能欄、施放順序、等施法、切回
let bcData=null;
const BC_KEYS=[['XButton1','滑鼠：後退鍵'],['XButton2','滑鼠：前進鍵'],['^LButton','滑鼠：Ctrl＋左鍵'],...'abcdefghijklmnopqrstuvwxyz'.split('').map(k=>[k,'鍵盤：'+k.toUpperCase()]),...['`','-','=','[',']',',','.','/',"'",'\\'].map(k=>[k,'鍵盤：'+k]),...[0,1,2,3,4,5,6,7,8,9].map(n=>['Numpad'+n,'數字鍵盤 '+n])];
function renderBuffCast(d){
 bcData=d;const oa=document.getElementById('bcOnAll');if(oa&&document.activeElement!==oa)oa.checked=d.on!==false;
 const el=document.getElementById('bcChars');if(!el)return;
 if(el.contains(document.activeElement)&&['INPUT','SELECT'].includes(document.activeElement.tagName))return;
 el.innerHTML=(d.chars||[]).length?d.chars.map((x,i)=>bcCardHtml(x,i)).join(''):'<span class="hint">沒有啟用的角色</span>';
}
// 只顯示有設定的組（至少一組）；「＋ 新增一組」再多出一組，最多 6 組；「刪除」把那組移到最後清空（按「存」才生效）
const bcShow={};   // 角色名 → 多顯示幾個空白組
const BC_BLANK=()=>({key:'',on:true,bar:2,order:[1,2,3,4,5,6,7,8],delay:150,waitCast:true,retBar:0,retSlot:1,clicks:1});
function bcVisible(x){const g=x.groups||[];let n=0;g.forEach((v,j)=>{if(v.key||v.on)n=j+1;});return Math.min(g.length,Math.max(1,n)+(bcShow[x.name]||0));}
function bcCardHtml(x,i){
 const nm=(b,k)=>x.names&&x.names[b-1]?x.names[b-1][k-1]:'';
 const kk=k=>k===10?0:k;
 const opt=(v,t,cur)=>`<option value="${esc(v)}" ${String(v)===String(cur)?'selected':''}>${esc(t)}</option>`;
 const groups=x.groups||[],vis=bcVisible(x);
 const keysUsed=groups.slice(0,vis).filter(g=>g.on).map(g=>g.key);
 const gHtml=(g,j)=>{
  // 這一排 1～0 每一格：點一下加入施放順序（標出第幾個放），再點一下拿掉；空格（讀得到技能時）不能點
  const slotBtns=[1,2,3,4,5,6,7,8,9,10].map(k=>{const pos=(g.order||[]).indexOf(k)+1,n=nm(g.bar,k),empty=x.alive&&!n;
   return `<button class="bc-slot ${pos?'on':''}" ${empty&&!pos?'disabled':''} onclick="bcToggleSlot(${i},${j},${k})" title="${pos?'第 '+pos+' 個放，點一下拿掉':'點一下加入施放順序'}"><span class="bc-no">${pos||''}</span><span class="bc-k">${kk(k)}</span>${n?esc(n):(x.alive?'（空）':'')}</button>`;}).join('');
  const dup=g.on&&g.key&&keysUsed.filter(k=>k===g.key).length>1;
  const adv=`${(g.clicks||1)>1?'右鍵 '+g.clicks+' 下｜':''}${g.waitCast!==false?'等施法結束':'固定間隔'}${g.delay?'＋'+g.delay+'ms':''}｜${g.retBar?'切回 F'+g.retBar+'-'+kk(g.retSlot):'不切回'}`;
  return `<div class="bc-group ${g.on?'on':''}"><div class="cc-row">`
   +`<label class="toggle" title="取消勾選＝先不用這組"><input type="checkbox" id="bcOn${i}_${j}" ${g.on||!g.key?'checked':''}> <b>${j+1}</b></label>`
   +`<select id="bcK${i}_${j}" onchange="bcRerender(${i})" aria-label="觸發鍵">${opt('','觸發鍵…',g.key)}${BC_KEYS.map(([v,t])=>opt(v,t,g.key)).join('')}</select>`
   +`<select id="bcB${i}_${j}" onchange="bcBarSwitch(${i},${j})" aria-label="技能欄">${[1,2,3,4,5,6,7,8,9,10].map(b=>opt(b,'F'+b,g.bar)).join('')}</select>`
   +`<span class="cc-meta">${(g.order||[]).length?'放 '+g.order.length+' 個':'點下面的格子加入'}</span>`
   +`<button class="rp-reset" onclick="bcClearOrder(${i},${j})">清除</button>`
   +`<button class="rp-reset" style="margin-left:auto" onclick="bcDel(${i},${j})">刪除</button></div>`
   +(dup?'<div class="cc-meta"><span class="mx-custom">這個鍵別組也用了</span></div>':'')
   +`<div class="bc-slots">${slotBtns}</div>`
   +(x.alive?'':'<div class="cc-meta">技能名稱要角色在遊戲裡才讀得到（沒讀到也可以先選格子）</div>')
   +`<details class="bc-adv"><summary>進階（${esc(adv)}）</summary><div class="cc-row" style="flex-wrap:wrap">`
   +`<span class="cc-meta">每格右鍵連按</span><select id="bcC${i}_${j}" title="照手動的習慣連按右鍵，前一招動作還沒結束時比較接得上">${[1,2,3,4,5,6].map(n=>opt(n,n+' 下',g.clicks||1)).join('')}</select>`
   +`<label class="toggle"><input type="checkbox" id="bcW${i}_${j}" ${g.waitCast!==false?'checked':''}> 等施法動作結束才放下一格</label><span class="cc-meta">再多等</span><input id="bcD${i}_${j}" value="${g.delay}" style="width:60px" inputmode="numeric"><span class="cc-meta">毫秒</span>`
   +`<span class="cc-meta">放完切回</span><select id="bcRB${i}_${j}" onchange="bcRerender(${i})">${opt(0,'不切回',g.retBar)}${[1,2,3,4,5,6,7,8,9,10].map(b=>opt(b,'F'+b,g.retBar)).join('')}</select>${g.retBar?`<select id="bcRS${i}_${j}">${[1,2,3,4,5,6,7,8,9,10].map(k=>opt(k,kk(k)+(nm(g.retBar,k)?'：'+nm(g.retBar,k):(x.alive?'（空）':'')),g.retSlot)).join('')}</select>`:''}</div></details></div>`;
 };
 return `<div class="char-card ${x.enabled!==false&&groups.some(g=>g.on&&g.key)?'on':''}"><div class="cc-head"><b>${esc(x.name)}</b><label class="toggle" style="margin-left:auto" title="關掉＝這隻角色的觸發鍵都不攔（打字照常）"><input type="checkbox" ${x.enabled!==false?'checked':''} onchange="send('buffcastcharon',{value:'${esc(x.name).replace(/'/g,"\\'")}~'+(this.checked?1:0)})"> ${x.enabled!==false?'一鍵施法：開':'一鍵施法：關'}</label>${x.alive?'':'<span class="cc-meta">沒有連接遊戲視窗</span>'}</div>`
  +(x.enabled===false?'<div class="cc-meta" style="margin:4px 0"><span class="mx-custom">總開關關著：下面的觸發鍵都不會動作</span></div>':'')
  +groups.slice(0,vis).map(gHtml).join('')
  +`<div class="cc-row">${vis<groups.length?`<button class="btn" onclick="bcAdd(${i})">＋ 新增一組</button>`:'<span class="cc-meta">最多 6 組</span>'}<button class="btn primary" style="margin-left:auto" onclick="bcSaveChar(${i})">存</button></div></div>`;
}
function bcCollect(i){const x=bcData.chars[i],vis=bcVisible(x);
 (x.groups||[]).forEach((g,j)=>{if(j>=vis)return;const v=id=>document.getElementById(id+i+'_'+j);
  g.on=!!v('bcOn')?.checked;g.key=v('bcK')?.value||'';g.bar=+(v('bcB')?.value)||2;
  if(v('bcW')){g.clicks=+(v('bcC')?.value)||1;g.waitCast=!!v('bcW').checked;g.delay=Math.max(0,parseInt(v('bcD')?.value)||0);g.retBar=+(v('bcRB')?.value)||0;g.retSlot=+(v('bcRS')?.value||g.retSlot||1);}});
 return x;}
function bcBarSwitch(i,j){if(!bcData)return;const x=bcData.chars[i],old=x.groups[j].bar;bcCollect(i);if(x.groups[j].bar!==old)x.groups[j].order=[];bcRedraw();}
function bcToggleSlot(i,j,k){if(!bcData)return;const x=bcCollect(i),g=x.groups[j];const p=g.order.indexOf(k);if(p>=0)g.order.splice(p,1);else g.order.push(k);bcRedraw();}
function bcClearOrder(i,j){if(!bcData)return;const x=bcCollect(i);x.groups[j].order=[];bcRedraw();}
function bcRedraw(){const el=document.getElementById('bcChars');document.activeElement&&document.activeElement.blur&&document.activeElement.blur();el.innerHTML=bcData.chars.map((x,k)=>bcCardHtml(x,k)).join('');}
function bcRerender(i){if(!bcData)return;bcCollect(i);bcRedraw();}
function bcAdd(i){if(!bcData)return;const x=bcCollect(i);const vis=bcVisible(x);if(vis>=x.groups.length)return;x.groups[vis]=BC_BLANK();bcShow[x.name]=0;bcRedraw();}
function bcDel(i,j){if(!bcData)return;const x=bcCollect(i);x.groups.splice(j,1);x.groups.push({...BC_BLANK(),on:false});bcShow[x.name]=0;bcRedraw();showToast&&showToast('按「存」才會真的刪掉這一組');}
function bcSaveChar(i){if(!bcData)return;const x=bcCollect(i),vis=bcVisible(x);
 send('buffcastchar',{value:x.name+'~'+(x.groups||[]).map((g,j)=>j<vis?[g.key,g.on?1:0,g.bar,g.order.join(','),g.delay,g.waitCast?1:0,g.retBar,g.retSlot,g.clicks||1].join(';'):';0;2;;150;1;0;1;1').join('|')});
 bcShow[x.name]=0;document.activeElement&&document.activeElement.blur&&document.activeElement.blur();}
function dhSchedSave(i){const e=document.getElementById('dhSchedIn'+i);if(!e||!dhSchedNames[i])return;send('dhschedset',{value:dhSchedNames[i]+'~'+e.value});e.blur();}
function dhCharToggle(i,on){if(dhChars[i])dhChars[i].on=on;saveDailyHunt();}
function dhToggleRun(){dhRunning=!dhRunning;saveDailyHunt();}function dhToggle(id,on){if(on)dhOn.add(id);else dhOn.delete(id);saveDailyHunt();}
function dhPick(mode){dhOn=new Set(dhTasks.filter(t=>t.runnable&&(mode==='all'||(mode==='todo'&&t.done<t.target))).map(t=>t.map));saveDailyHunt();}
function dhExecList(){const a=[...dhOn],on=dhTasks.filter(t=>t.runnable&&dhOn.has(t.map)).sort((x,y)=>a.indexOf(x.map)-a.indexOf(y.map));return [...on.filter(t=>t.done<t.target),...on.filter(t=>t.done>=t.target)];}
function dhOrderMap(){const m=new Map();dhExecList().forEach((t,i)=>m.set(t.map,i+1));return m;}
function dhMove(map,dir){const l=dhExecList(),i=l.findIndex(t=>t.map===map),j=i+dir;if(i<0||j<0||j>=l.length)return;if((l[i].done>=l[i].target)!==(l[j].done>=l[j].target))return;const a=[...dhOn],x=a.indexOf(l[i].map),y=a.indexOf(l[j].map);[a[x],a[y]]=[a[y],a[x]];dhOn=new Set(a);saveDailyHunt();}
function dhDrop(from,to,after){const l=dhExecList(),a=l.find(t=>t.map===from),b=l.find(t=>t.map===to);if(!a||!b)return;
 if((a.done>=a.target)!==(b.done>=b.target)){if(dhLast)renderDailyHunt(dhLast);return;}   // 已打滿的固定排在沒打滿的後面
 const r=dragReorder(l.map(t=>t.map),from,to,after);if(!r)return;dhOn=new Set([...r,...[...dhOn].filter(m=>!r.includes(m))]);saveDailyHunt();}
function saveDailyHunt(){const g=id=>{const e=document.getElementById(id);return e?e.value:''};send('dailyhuntset',{value:`${dhRunning?1:0}~${dhChars.filter(c=>c.on).map(c=>c.name).join('|')}~${[...dhOn].join(',')}~${g('dhNpc')}~${g('dhCard')}~${g('dhRow')}~${(document.getElementById('dhTest')||{}).checked?1:0}~${(document.getElementById('dhResume')||{}).checked?1:0}`});}
let partyAcceptSig='';
function savePartyRemote(el){const tr=el.closest('tr');el.value=el.value.replace(/~/g,'');send('partyremote',{value:`${tr.dataset.idx}~${el.value.trim()}~${tr.dataset.name}`});}
function savePartyAccept(el){const tr=el.closest('tr');const f=tr.querySelector('.party-from');f.value=f.value.replace(/~/g,'');send('partyaccept',{value:`${tr.dataset.idx}~${tr.querySelector('.party-accept').checked?1:0}~${tr.querySelector('.party-from').value.trim()}~${tr.dataset.name}`});}
function savePartyCfg(){send('partycfg',{value:`${document.getElementById('partyEnabled').checked?1:0}~${Math.max(0,Math.min(600,Number(document.getElementById('partySettle').value)||0))}~${document.getElementById('partyRejoin').checked?1:0}~${document.getElementById('partyHandback').checked?1:0}`});}
function savePartyRole(el){const tr=el.closest('tr');const lead=tr.querySelector('.party-leader').checked?1:0;
 const mem=[...[...tr.querySelectorAll('.party-mem:checked')].map(x=>x.value),...(tr.dataset.hidden?tr.dataset.hidden.split('|'):[])].join('|');
 send('partyrole',{value:`${tr.dataset.idx}~${lead}~${mem}~${tr.dataset.name}`});}
// H-016 GitHub 更新：有新版時頂端出現「🆕 有新版」，按了確認才更新
let updateState=null,updateLastStatus='';
function renderUpdate(d){
 updateState=d;const b=document.getElementById('updateBadge'),l=document.getElementById('updateLink');
 if(b){b.style.display=d.available?'':'none';if(d.available)b.textContent='🆕 有新版 '+d.available.version;}
 if(l)l.textContent=d.checking?'檢查中…':'檢查更新';
 if(d.status&&d.status!==updateLastStatus)showToast(d.status);updateLastStatus=d.status||'';
}
// H-042 使用授權：設定→其他的卡片；剩 7 天內頂端出現提醒
let licWarnShown='';
function renderLicense(d){
 const $=id=>document.getElementById(id);if(!$('licenseCard'))return;
 const ok=d.state==='ok',left=d.daysLeft;
 $('licensePill').textContent=ok?(d.warn?'⚠️ 即將到期':'✅ 已授權'):'⛔ 無法使用';
 $('licenseHint').textContent=ok?(d.warn||'這台電腦已取得使用許可。'):(d.reason||'這份程式需要作者授權才能使用。');
 $('licUser').textContent=d.user||'—';
 $('licExpire').textContent=d.expires?(d.expires+(ok&&left>=0?`（剩 ${left} 天）`:'')):'—';
 $('licMode').textContent=!d.mode?'—':d.mode==='any'?'不限帳號':d.mode==='count'?`最多 ${d.count} 個帳號`:'只限指定帳號';
 $('licMachine').textContent=d.machine||'—';
 const b=$('licBlocked');
 if(d.blocked&&d.blocked.length){b.style.display='';b.textContent='🚫 這些帳號沒有授權，不會被監控或啟動：'+d.blocked.join('、')+'（請向作者申請，設定不會遺失）';}else b.style.display='none';
 const badge=$('licenseBadge');
 if(badge){badge.style.display=d.warn?'':'none';if(d.warn){badge.textContent='⚠️ 授權剩 '+left+' 天';badge.title=d.warn;}}
 if(d.warn&&d.warn!==licWarnShown){licWarnShown=d.warn;showToast(d.warn);}
}
function askUpdate(){
 const a=updateState&&updateState.available;if(!a)return;
 const notes=(a.notes||[]).map(n=>'・'+n).join('\n');
 if(updateState.busy){alert(`目前${updateState.busy}，請稍後再更新。`);return;}
 if(confirm(`更新到 ${a.version}${a.date?'（'+a.date+'）':''}？\n\n${notes||'（沒有更新說明）'}\n\n只會換程式檔：帳號密碼、Discord、統計、日誌、遊戲偏移設定都不會動；舊版會先備份到 app\\backup。\n更新完管理程式會自動重新啟動。`))send('updateapply');
}
// H-015 怪物掉落率
let dropIndex=null,dropDoc=null,dropWant='';
const dropPct=p=>p>=0.01?(p*100).toFixed(2)+'%':p>=0.0001?(p*100).toFixed(3)+'%':(p*100).toFixed(4)+'%';
const dropEvery=p=>p>0?'約 '+Math.round(1/p).toLocaleString()+' 隻 1 個':'—';
// 同名的不同怪物（例如兩種「綠能原石」）只列一次
const dropMobNames=mobs=>[...new Set(mobs.map(x=>x[0]))].join('、');
function renderDropIndex(d){
 dropIndex=d.index;const st=document.getElementById('dropStatus');
 if(st)st.textContent=(d.running?'🔄 正在檢查遊戲改版… ':'')+(d.status||'');
 const sel=document.getElementById('dropVer');if(!sel)return;
 const vers=(dropIndex&&dropIndex.versions)||[];
 if(!vers.length){document.getElementById('dropGroups').innerHTML='<div class="hint">還沒有掉落率資料。程式啟動 1 分鐘後會自動計算，或按「立即檢查改版」。</div>';sel.innerHTML='';return;}
 const latest=dropIndex.latest||vers[0].id;
 const opts=vers.map(v=>`<option value="${esc(v.id)}">${esc(v.label)}${v.id===latest?'（最新）':''}</option>`).join('');
 if(sel.innerHTML!==opts)sel.innerHTML=opts;
 // 預設看最新版；有新版出現時自動切過去
 if(!dropWant||!vers.some(v=>v.id===dropWant)||(sel.dataset.latest&&sel.dataset.latest!==latest))dropWant=latest;
 sel.dataset.latest=latest;sel.value=dropWant;
 if(!dropDoc||dropDoc.id!==dropWant)send('dropver',{value:dropWant});
}
function loadDropVer(id){dropWant=id;send('dropver',{value:id});}
function renderDropVer(doc){if(!doc||doc.id!==dropWant)return;dropDoc=doc;renderDropMaps();renderDropChanges();}
function renderDropMaps(){
 if(!dropDoc)return;const sel=document.getElementById('dropMap'),all=document.getElementById('dropAll').checked;
 const names=Object.keys(dropDoc.maps||{}),fav=(dropDoc.favorites||[]).filter(n=>names.includes(n));
 const list=all||!fav.length?names:fav,keep=sel.value;
 sel.innerHTML=list.map(n=>`<option value="${esc(n)}">${esc(n)}</option>`).join('');
 if(list.includes(keep))sel.value=keep;
 const pill=document.getElementById('dropVerPill');if(pill)pill.textContent=`${dropDoc.label}｜${names.length} 張地圖`;
 renderDrop();
}
function renderDropChanges(){
 const box=document.getElementById('dropChanges'),pill=document.getElementById('dropChangesPill');if(!box)return;
 const ch=(dropDoc.changes||[]).filter(c=>c.kind==='change');
 if(pill)pill.textContent=dropDoc.prev?`和 ${dropDoc.prevLabel} 比｜${ch.length} 項`:'第一個版本';
 box.innerHTML=!dropDoc.prev?'<div class="hint">這是最早的版本，沒有可以比較的。</div>':!ch.length?'<div class="hint">🎉 這一版掉落率沒有變動。</div>'
  :'<div class="table-wrap"><table><thead><tr><th>地圖</th><th>道具</th><th>變動（每隻）</th><th>怪物</th></tr></thead><tbody>'+ch.map(c=>{
   const tag=!c.old?'<span class="ok">🆕 新增</span>':!c.new?'<span class="warn">移除</span>':(c.new>c.old?'<span class="ok">⬆ 提高</span>':'<span class="warn">⬇ 降低</span>');
   return `<tr><td class="account-name">${esc(c.map)}</td><td>${esc(c.item)}</td><td>${tag} ${c.old?dropPct(c.old):'—'} → ${c.new?dropPct(c.new):'—'}</td><td class="account-sub">${c.mobs.map(esc).join('、')}</td></tr>`}).join('')+'</tbody></table></div>';
}
function dropTable(rows,withMap){
 if(!rows.length)return '<div class="hint">沒有符合的道具</div>';
 const max=rows[0].p;
 return '<div class="table-wrap"><table><thead><tr>'+(withMap?'<th>地圖</th><th>怪物</th>':'')+'<th>道具</th><th>每隻機率</th><th>大約</th><th style="width:30%"></th></tr></thead><tbody>'
  +rows.map(r=>`<tr>${withMap?`<td class="account-name">${esc(r.map)}</td><td class="account-sub">${esc(r.mobs)}</td>`:''}<td>${esc(r.item)}</td><td><b>${dropPct(r.p)}</b></td><td class="account-sub">${dropEvery(r.p)}</td><td><div class="drop-barbox"><div class="drop-bar" style="width:${Math.max(2,Math.round(100*Math.sqrt(r.p/max)))}%"></div></div></td></tr>`).join('')+'</tbody></table></div>';
}
function renderDrop(){
 const box=document.getElementById('dropGroups');if(!box||!dropDoc)return;
 const q=document.getElementById('dropQ').value.trim();
 if(q){ // 搜尋道具：列出所有地圖（勾「全部地圖」時）或常用地圖中掉這個道具的怪
  const all=document.getElementById('dropAll').checked,fav=dropDoc.favorites||[],rows=[];
  for(const [m,v] of Object.entries(dropDoc.maps))if(all||!fav.length||fav.includes(m))for(const g of v.groups)for(const [it,p] of g.items)if(it.includes(q))rows.push({map:m,mobs:dropMobNames(g.mobs),item:it,p});
  rows.sort((a,b)=>b.p-a.p);
  box.innerHTML=`<div class="card"><div class="section-title"><span class="ni"><span class="emo">🔍</span></span>「${esc(q)}」<span class="pill">${rows.length} 筆</span></div>${dropTable(rows,true)}</div>`;return;
 }
 const m=dropDoc.maps[document.getElementById('dropMap').value];
 if(!m){box.innerHTML='<div class="hint">請選擇地圖</div>';return;}
 box.innerHTML=m.groups.map(g=>`<div class="card" style="margin-bottom:14px"><div class="section-title"><span class="ni"><span class="emo">👾</span></span>${esc(dropMobNames(g.mobs))}<span class="pill">${g.items.length} 種</span></div>`
  +dropTable(g.items.map(([it,p])=>({item:it,p})),false)+'</div>').join('');
}
// H-003 重新登入成功率卡片（H-012 起放在「角色 → 🔁 重新登入」分頁）（rate=-1 → 「—」且無長條）
function fmtSec(n){n=Math.round(Number(n)||0);if(n<=0)return '—';return n>=60?Math.floor(n/60)+' 分 '+(n%60)+' 秒':n+' 秒';}
function recPct(r){return r<0?'—':Math.round(r*100)+'%';}
function renderRecStats(d){
 const bars=document.getElementById('recStatsBars'),roles=document.getElementById('recStatsRoles'),pill=document.getElementById('recStatsPill'),top=document.getElementById('recStatsTop');
 if(!bars||!d)return;
 const t=d.total||{};
 if(pill)pill.textContent=!d.files?'沒有日誌':(t.total?`共 ${t.total} 次｜成功率 ${recPct(t.rate)}`:'沒有紀錄');
 bars.innerHTML=(d.byDay||[]).length?'<div class="rec-bars">'+d.byDay.map(x=>{const r=Number(x.rate),h=r<0?0:Math.max(3,Math.round(r*80)),c=r>=0.8?'':(r>=0.5?' mid':' low');
  return `<div class="rec-col" title="${esc(x.day)}｜${x.total} 次｜成功 ${x.ok}｜失敗 ${x.fail}"><div class="rec-barbox">${r<0?'':`<div class="rec-bar${c}" style="height:${h}px"></div>`}</div><b>${recPct(r)}</b><small>${esc(String(x.day).slice(5))}</small></div>`}).join('')+'</div>'
  :'<div class="hint">還沒有資料。</div>';
 if(roles)roles.innerHTML=(d.roles||[]).length?'<table><thead><tr><th>角色</th><th>次數</th><th>成功率</th><th>平均耗時</th><th>最長耗時</th><th>最常卡住</th></tr></thead><tbody>'+d.roles.map(r=>{const s=(r.topSteps||[])[0];return `<tr><td class="account-name">${esc(r.name)}</td><td>${r.total}</td><td>${recPct(Number(r.rate))}</td><td>${fmtSec(r.avgSec)}</td><td>${fmtSec(r.maxSec)}</td><td>${s?esc(s.label)+' ×'+s.count:'🎉 沒有'}</td></tr>`}).join('')+'</tbody></table>':'';
 const ts=t.topSteps||[];
 if(top)top.textContent=ts.length?'🚧 整體最常卡住：'+ts.map(x=>`${x.label} ×${x.count}`).join('、'):'';
}
document.querySelector('.side [data-page="invstats"]')?.addEventListener('click',()=>requestInvStats(''));
// v1.3.16.0 每日道具 / 示範錄製
// v1.3.24.0 每日道具角色設定：勾選項目、回城 / 原地換、武器造型種類
let dailyCfgSig='';
function renderDailyCfg(d){
 const box=document.getElementById('dailyCfgRows');if(!box)return;
 const ae=document.activeElement;if(box.contains(ae)&&(ae.type==='text'||ae.tagName==='SELECT'))return;   // 正在輸入 / 選擇時不重畫
 if(box.querySelector('.dd-list:not([hidden])'))return;   // 下拉清單開著時不重畫
 const ck=d.cardKeys||{};for(const [id,v] of [['dcStart',ck.start],['dcPrev',ck.prev],['dcQuick',ck.quick]]){const e=document.getElementById(id);if(e&&document.activeElement!==e)e.value=(v||'').toUpperCase();}
 const roles=d.roles||[],opts=d.options||[];
 const sig=JSON.stringify([opts,d.weaponDefault,d.weaponChoices,roles.map(r=>[r.index,r.name,r.items,r.mode,r.weapon])]);
 if(sig===dailyCfgSig)return;dailyCfgSig=sig;
 if(!roles.length){box.innerHTML='<div class="hint">沒有開啟監控的角色</div>';return;}
 box.innerHTML=roles.map(r=>{const has=new Set(String(r.items||'').split(',').filter(Boolean));
  return `<div class="daily-cfg-row${has.size?'':' daily-cfg-off'}" data-idx="${r.index}" data-name="${esc(r.name)}"><div class="account-name">${esc(r.name)}${has.size?'':'<div class="account-sub">不自動更換</div>'}</div>`
      +`<div class="daily-cfg-opts"><div class="dd" data-items="${esc([...has].join(','))}"><button type="button" class="dd-btn" onclick="ddToggle(this)" title="按一下選要自動更換的道具"><span class="dd-sum">${ddSummary(opts,has)}</span><span class="dd-caret">▾</span></button>`
   +`<div class="dd-list" hidden>${opts.map(o=>`<div class="dd-item${has.has(o[0])?' on':''}" data-opt="${o[0]}" onclick="ddPick(this)"><span class="dd-check">${has.has(o[0])?'✓':''}</span><span>${esc(o[1])}</span></div>`).join('')}`
   +`<div class="dd-foot"><a href="#" onclick="ddAll(this,true);return false">全選</a> · <a href="#" onclick="ddAll(this,false);return false">全不選</a></div></div></div></div>`
   +`<div class="daily-cfg-side"><select onchange="saveDailyCfg(this)" title="在哪裡換"><option value="town"${r.mode==='here'||r.mode==='auto'?'':' selected'}>🏙️ 回城換</option><option value="here"${r.mode==='here'?' selected':''}>📍 原地換</option><option value="auto"${r.mode==='auto'?' selected':''}>🧭 自動（看快捷欄）</option></select>`
   +weaponCtl(r,d)+`</div></div>`}).join('');
}
// H-033 登入後選擇角色：每個帳號一個下拉選單（選項來自遊戲的選角清單）
let lcSig='';
function renderLoginChars(d){
 const box=document.getElementById('lcRows');if(!box)return;
 if(box.contains(document.activeElement)&&document.activeElement.tagName==='SELECT')return;
 const roles=d.roles||[];
 const sig=JSON.stringify(roles);if(sig===lcSig)return;lcSig=sig;
 const pill=document.getElementById('lcPill');if(pill)pill.textContent=roles.filter(r=>r.selected).length+' 個帳號指定了角色';
 if(!roles.length){box.innerHTML='<div class="hint">還沒有帳號</div>';return;}
 box.innerHTML=roles.map(r=>{
  const names=r.chars.slice();if(r.selected&&!/^#/.test(r.selected)&&!names.includes(r.selected))names.push(r.selected);
  const multi=names.length>1;
  return `<div class="lc-row" data-idx="${r.index}" data-name="${esc(r.name)}"><div class="account-name">${esc(r.name)}</div>`
   +`<select onchange="saveLoginChar(this)" title="重新登入後要進哪一隻角色"><option value="">預設（照原本位置 / 第 1 隻）</option><optgroup label="依順序（選角畫面由左到右）">${[1,2,3,4].map(i=>`<option value="#${i}"${r.selected==='#'+i?' selected':''}>第 ${i} 隻${names[i-1]?'：'+esc(names[i-1]):''}</option>`).join('')}</optgroup><optgroup label="依角色名稱（換順序也不會錯）">${names.map(n=>`<option value="${esc(n)}"${n===r.selected?' selected':''}>${esc(n)}</option>`).join('')}</optgroup></select>`
   +`<div class="hint" style="margin:0">${names.length?(multi?`選角清單有 ${names.length} 隻角色`:'這個帳號只有 1 隻角色'):'還沒讀過選角清單（先讓這個帳號的遊戲開著）'}</div></div>`}).join('');
}
function saveLoginChar(el){const row=el.closest('.lc-row');if(!row)return;lcSig='';send('logincharsave',{value:`${row.dataset.idx}~${el.value.replace(/[~|\r\n]/g,'')}~${row.dataset.name}`});}
// 武器造型選擇盒要選哪一個：選項直接來自遊戲裡盒子的內容（讀過一次後記住）；還讀不到時才讓你自己打字
function weaponCtl(r,d){
 const ch=d.weaponChoices||[];
 if(!ch.length)return `<input type="text" class="wpn" value="${esc(r.weapon||'')}" placeholder="武器：${esc(d.weaponDefault||'')}（共用）" title="武器造型選擇盒要選的武器（例如 雙槍、弓、劍）；空白用共用設定。選項還沒讀到（需要有人的背包裡出現過選擇盒）" onchange="saveDailyCfg(this)">`;
 const cur=r.weapon||'',known=ch.some(c=>c.name===cur);
 return `<select class="wpn" onchange="saveDailyCfg(this)" title="打開紀念造型服飾禮包後，武器造型貼選擇盒要選哪一個"><option value="">武器：共用設定（${esc(d.weaponDefault||'')}）</option>`
  +ch.map(c=>`<option value="${esc(c.name)}"${c.name===cur?' selected':''}${c.ok?'':' disabled'}>第 ${c.index} 個：${esc(c.name)}${c.ok?'':'（要捲動，暫不支援）'}</option>`).join('')
  +(cur&&!known?`<option value="${esc(cur)}" selected>${esc(cur)}（自訂）</option>`:'')+`</select>`;
}
function saveDailyCardKeys(){const g=id=>document.getElementById(id).value.replace(/[~|\r\n\s]/g,'');send('dailycardkeys',{value:g('dcStart')+'~'+g('dcPrev')+'~'+g('dcQuick')});}
// H-025 每日道具「要換哪些」改成下拉清單：點開後每個項目旁邊打勾，可多選（和旁邊「回城換 / 原地換」的下拉一致）
function ddSummary(opts,has){
 const names=opts.filter(o=>has.has(o[0])).map(o=>o[1]);
 if(!names.length)return '不自動更換';
 if(names.length===opts.length)return `全部（${names.length} 項）`;
 return names.length<=2?names.join('、'):`${names.slice(0,2).join('、')} 等 ${names.length} 項`;
}
function ddClose(){document.querySelectorAll('.dd-list:not([hidden])').forEach(l=>l.hidden=true);}
function ddToggle(btn){const l=btn.parentElement.querySelector('.dd-list');const open=l.hidden;ddClose();l.hidden=!open;}
function ddRefresh(dd){
 const items=[...dd.querySelectorAll('.dd-item')];
 items.forEach(i=>{i.querySelector('.dd-check').textContent=i.classList.contains('on')?'✓':'';});
 const on=items.filter(i=>i.classList.contains('on'));
 dd.querySelector('.dd-sum').textContent=!on.length?'不自動更換':(on.length===items.length?`全部（${on.length} 項）`:(on.length<=2?on.map(i=>i.textContent.replace('✓','').trim()).join('、'):`${on.slice(0,2).map(i=>i.textContent.replace('✓','').trim()).join('、')} 等 ${on.length} 項`));
}
function ddPick(item){item.classList.toggle('on');const dd=item.closest('.dd');ddRefresh(dd);saveDailyCfg(dd);}
function ddAll(a,on){const dd=a.closest('.dd');dd.querySelectorAll('.dd-item').forEach(i=>i.classList.toggle('on',on));ddRefresh(dd);saveDailyCfg(dd);}
document.addEventListener('click',e=>{if(!e.target.closest('.dd'))ddClose();});
function saveDailyCfg(el){
 const row=el.closest('.daily-cfg-row');if(!row)return;
 const items=[...row.querySelectorAll('.dd-item.on')].map(x=>x.dataset.opt).join(',');
 const mode=row.querySelector('select').value,weapon=row.querySelector('.wpn').value.replace(/[~|\r\n]/g,'').trim();
 row.classList.toggle('daily-cfg-off',!items);dailyCfgSig='';
 send('dailycfg',{value:`${row.dataset.idx}~${items}~${mode}~${weapon}~${row.dataset.name}`});
}
function renderDiag(d){
 const b=document.getElementById('diagBtn'),o=document.getElementById('diagOpenBtn'),r=document.getElementById('diagResult');
 if(b){b.disabled=!!d.busy;b.textContent=d.busy?'匯出中…':'匯出診斷包';}
 if(o)o.style.display=d.path?'':'none';
 if(r)r.textContent=d.err?('⚠ 匯出失敗：'+d.err):(d.path?`✓ 已匯出（${d.at}，${(d.size/1048576).toFixed(1)} MB）：${d.path}`:'');
}
function renderLag(d){
 const on=document.getElementById('lagOn');if(on&&document.activeElement!==on)on.checked=!!d.enabled;
 const mi=document.getElementById('lagMarkInfo');if(mi)mi.textContent=d.marks?`　已標記 ${d.marks} 筆（最後一次 ${d.markAt}）`:'';
 const rows=document.getElementById('lagRows');if(!rows)return;
 const fmtUp=m=>m>=120?(m/60).toFixed(1)+' 小時':Math.round(m)+' 分';
 rows.innerHTML=(d.rows||[]).length?d.rows.map(r=>{
  if(r.t===undefined)return `<tr><td class="account-name">${esc(r.name)}</td><td colspan="6" class="hint">等待第一次量測…</td><td></td></tr>`;
  const slow=r.ping!==null&&r.ping>=100;
  return `<tr><td class="account-name">${esc(r.name)}</td><td>${fmtUp(r.up)}</td><td>${Math.round(r.priv)} MB</td><td>${r.cpu===null?'—':r.cpu+'%'}</td><td class="${slow?'warn':''}">${r.min?'（最小化）':(r.ping===null?'—':r.ping+' ms（最大 '+r.pingMax+'）')}</td><td>${r.fg?'是':'否'}</td><td>${esc(r.t)}</td><td><button class="btn soft" onclick="send('lagmark',{value:${r.index}});showToast('已標記 ${esc(r.name)}')">標記這個</button></td></tr>`}).join(''):'<tr><td colspan="8" class="hint">沒有已連接的遊戲視窗</td></tr>';
}
function saveLagFix(){const on=document.getElementById('lfOn').checked?1:0;const ms=Math.max(30,Math.min(2000,parseInt(document.getElementById('lfMs').value,10)||100));send('lfset',{value:`${on}~${ms}`});}
function renderLagFix(d){
 const on=document.getElementById('lfOn');if(on&&document.activeElement!==on)on.checked=!!d.enabled;
 const ms=document.getElementById('lfMs');if(ms&&document.activeElement!==ms)ms.value=d.pingMs;
 const rows=document.getElementById('lfRows');if(!rows)return;
 rows.innerHTML=(d.rows||[]).length?d.rows.map(r=>`<tr><td class="account-name">${esc(r.name)}</td><td>${r.med===null?'—':r.med+' ms'}</td><td>${r.runs}</td><td>${esc(r.text||'')}</td><td><button class="btn soft" onclick="if(confirm('現在對這個視窗做一次過圖（起點卡→前點卡）？等鍵盤滑鼠閒置後才會執行。'))send('lfnow',{value:${r.index}})">現在過圖</button></td></tr>`).join(''):'<tr><td colspan="5" class="hint">沒有已連接的遊戲視窗</td></tr>';
}
setInterval(()=>{const t=document.getElementById('lagRows');if(t&&t.offsetParent)send('lagstate');},3000);
// 每日道具要遊戲畫面剛好 1024x768：每個監控中的視窗先顯示符不符合，不用等到要更換時才失敗
function dailyCond(r){
 if(!r.alive)return '<span class="account-sub">— 未連線</span>';
 if(r.cmin)return '<span class="warn">⚠ 視窗縮到最小，請還原</span>';
 if(!r.cok)return `<span class="warn">⚠ ${r.cw}×${r.ch}</span><div class="account-sub">要 1024×768，請把遊戲視窗調成這個大小（Windows 縮放建議 100%，目前 ${r.dpi}%）</div>`;
 const dpi=r.dpi!==100?`<div class="account-sub">Windows 縮放 ${r.dpi}%（建議 100%）</div>`:'';
 if(r.block)return `<span class="ok">✓ ${r.cw}×${r.ch}</span><div class="account-sub">但現在不能自動更換：${esc(r.block)}</div>${dpi}`;
 return `<span class="ok">✓ ${r.cw}×${r.ch} 符合</span>${dpi}`;
}
function renderDaily(d){
 dailyCache=d; if(latestState)renderFeatures(latestState); if(latestState)renderHpMonitor(latestState.accounts||[],false);
 const delay=document.getElementById('dailyDelay');if(delay)delay.textContent=`到期 ${d.delay} 分鐘後提醒`;
 const rows=document.getElementById('dailyRows');
 if(rows)rows.innerHTML=(d.roles||[]).length?d.roles.map(r=>{const cls=r.status.startsWith('有效')?'ok':(r.status==='讀取中'?'muted':'warn');const busy=d.running===r.name;return `<tr><td class="account-name">${esc(r.name)}${r.alive?'':' <span class="account-sub">（未連線）</span>'}</td><td>${esc(r.expiry||'—')}</td><td>${esc(r.due||'—')}</td><td class="${cls}">${busy?'🔄 自動更換中…':esc(r.status)}${(!busy&&r.fail)?`<div class="account-sub" style="margin-top:4px;color:var(--red)">上次自動更換沒完成：${esc(r.fail)}</div>`:''}</td><td>${r.packsStale?(r.packs>=0?r.packs+' 個（上次讀到，':'—（')+'打開一次銀行分頁後更新）':(r.packs>=0?r.packs+' 個':'—')}</td><td><button class="btn soft" ${(!r.alive||d.running)?'disabled':''} onclick="if(confirm('立即自動更換「${esc(r.name)}」的每日道具？\\n執行期間請勿操作鍵盤滑鼠，F10 可中止。'))send('dailyrun',{value:${r.index}})">立即更換</button></td><td>${dailyCond(r)}</td></tr>`}).join(''):'<tr><td colspan="7" class="hint">沒有開啟監控的角色</td></tr>';
 renderDailyCfg(d);
 const info=document.getElementById('dailyRunInfo');
 if(info)info.textContent=(d.running?`🔄 正在自動更換：${d.running}　`:'')+(d.queue?`等待中：${d.queue}　`:'')+(d.popupTimeout>0?`到期後跳出提醒；${d.popupTimeout} 秒內沒有人點選提醒視窗就自動更換。`:d.autorun?`到期後跳出提醒；${d.idle} 秒內沒有鍵鼠操作就自動更換。`:'到期後跳出提醒（目前未開啟無人自動執行，可在提醒視窗按「立即更換」）。');
 const sel=document.getElementById('recRole');
 if(sel&&document.activeElement!==sel){const keep=sel.value;const opts=(d.roles||[]).filter(r=>r.alive).map(r=>`<option value="${r.index}">${esc(r.name)}｜${esc(r.status)}</option>`).join('');if(sel.innerHTML!==opts){sel.innerHTML=opts;if(keep)sel.value=keep;}}
 const rec=d.recorder||{},badge=document.getElementById('recBadge'),st=document.getElementById('recStatus');
 if(badge){badge.textContent=rec.active?'● 錄製中':'未錄製';badge.style.color=rec.active?'var(--red)':'';}
 if(st)st.textContent=rec.active?`${rec.name}｜已記錄 ${rec.count} 次滑鼠操作｜${rec.seconds} 秒`:'';
 const sb=document.getElementById('recStartBtn'),eb=document.getElementById('recStopBtn');
 if(sb)sb.disabled=!!rec.active; if(eb)eb.disabled=!rec.active;
}
setInterval(()=>{if(isShown('daily'))send('dailystate');},5000);
setInterval(()=>{if(isShown('recovery'))send('recstats');},60000);
setInterval(()=>{if(isShown('dropRates'))send('dropindex');},30000);
setInterval(()=>{if(isShown('mbox'))send('mboxstate');},2000);
setInterval(()=>{if(isShown('party'))send('partystate');},2000);
setInterval(()=>{if(isShown('companion'))send('companionstate');},2000);
setInterval(()=>{if(isShown('dailyhunt')&&!dhEditing())send('dailyhuntstate');},3000);
setInterval(()=>{if(isShown('automining'))send('autominingstate');},3000);
setInterval(()=>{if(isShown('home')||!dailyCache)send('dailystate');},60000);
setTimeout(()=>send('dailystate'),1500);
setTimeout(()=>send('updatestate'),2500);
setTimeout(()=>send('licensestate'),2000);setInterval(()=>send('licensestate'),600000);
setInterval(()=>{if(isShown('roleCards')){send('dailystate');if(!invStatsSelected||invStatsSelected===invStatsToday)requestInvStats('');}},30000);
setInterval(()=>{if(isShown('invMain')&&(!invStatsSelected||invStatsSelected===invStatsToday))requestInvStats();},10000);
if(window.chrome?.webview){window.chrome.webview.addEventListener('message',e=>{let m=e.data;if(typeof m==='string'){try{m=JSON.parse(m)}catch{}}if(m?.type==='state')setState(m.data);if(m?.type==='event')addEvent(m.data);if(m?.type==='selfcheck')showSelfCheck(m.data);if(m?.type==='invstats')renderInvStats(m.data);if(m?.type==='recstats')renderRecStats(m.data);if(m?.type==='hoursum')renderHourSum(m.data);if(m?.type==='dropindex')renderDropIndex(m.data);if(m?.type==='update')renderUpdate(m.data);if(m?.type==='license')renderLicense(m.data);if(m?.type==='mbox')renderMBox(m.data);if(m?.type==='party')renderParty(m.data);if(m?.type==='companion')renderCompanion(m.data);if(m?.type==='dailyhunt')renderDailyHunt(m.data);if(m?.type==='automining')renderAutoMining(m.data);if(m?.type==='priority')renderPriority(m.data);if(m?.type==='buffcast')renderBuffCast(m.data);if(m?.type==='dropver')renderDropVer(m.data);if(m?.type==='daily')renderDaily(m.data);if(m?.type==='diag')renderDiag(m.data);if(m?.type==='lag')renderLag(m.data);if(m?.type==='lagfix')renderLagFix(m.data);if(m?.type==='loginchars')renderLoginChars(m.data);});}
// 11/22：滑鼠停在數字框上滾輪會改到數字（挖礦「進礦場趟數」被改成 1，傳送卡到期後就不進圖）→ 數字框有焦點時滾輪先讓它失去焦點，不改值
document.addEventListener('wheel',e=>{const t=e.target;if(t&&t.tagName==='INPUT'&&t.type==='number'&&document.activeElement===t)t.blur();},{passive:true});
