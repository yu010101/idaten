import {
  DEFAULTS, pickTabsToDiscard, pickTabsForMemoryBudget, summarizeMemory, countTabs, badgeText, statusLine,
  pageProbe, probeBusy, debuggerTabIds, memoryState, stateLine, STATE_COLORS, measuredSavings, addSavings, savingsLine,
  frozenBusy, applyFrozenMessage, classifyDiscardError,
} from './policy.js';

// 0.3.0 で足した権限(manifest.json は JSON でコメントを書けないのでここに書く):
//  - "debugger": chrome.debugger.getTargets() で「何かが接続中(attached:true)のタブ」を知るためだけに使う。attach はしない。
//    Claude in Chrome などの AI エージェント拡張は chrome.debugger でタブに接続して操作するので、そのタブを眠らせると操作が切れる。
//    それを「使用中」とみなして除外する。(インストール時に「ページのデバッガ バックエンドへのアクセス」の警告が出る)
//  - "system.memory": メモリ予算が未設定のとき、状態(緑/黄/赤)を機械全体の空き(availableCapacity / capacity)で出すため
//  - content_scripts(main-world.js, MAIN world): カメラ・マイク・画面共有・WebRTC・入力途中のフォームを記録する。権限の追加は無い
//  - content_scripts(bridge.js, 隔離ワールド): 凍結直前の判定を background へ転送する。権限の追加は無い

// 凍結中のタブの判定(凍結の直前に main-world.js が記録したもの)。SW が止まっても消えないよう storage.session に置く。
// 書き込みは 1 本の鎖で順に行う(同時に来た知らせで上書きし合わない)
let frozenChain = Promise.resolve();
function updateFrozen(fn) {
  frozenChain = frozenChain.then(async () => {
    const { frozenFrames } = await chrome.storage.session.get('frozenFrames');
    await chrome.storage.session.set({ frozenFrames: fn(frozenFrames || {}) });
  }).catch(() => {});
  return frozenChain;
}
async function readFrozen() {
  await frozenChain;
  return (await chrome.storage.session.get('frozenFrames')).frozenFrames || {};
}

async function settings() {
  return { ...DEFAULTS, ...(await chrome.storage.sync.get(DEFAULTS)) };
}

// ページの中で「再生中・入力途中・カメラ/マイク/画面共有・WebRTC 通話・機器接続」を調べる(判定の式は policy.js の pageProbe)。
// MAIN world で全フレームを見る(main-world.js の記録は MAIN world にしか無い。通話は iframe の中のことも多い)。
// 返事が来ない(読み込み中など)タブは busy 扱いにして今回は眠らせない — 次の巡回で再挑戦(Swift 版の 3 秒打ち切りと同じ考え)
async function busyTabs(tabs) {
  const busy = new Set();
  const reasons = {};
  const add = r => { for (const k of r) reasons[k] = (reasons[k] || 0) + 1; };
  const frozen = await readFrozen();
  await Promise.all(tabs.map(async t => {
    const id = t.id;
    // 凍結中のタブには executeScript が返事をしない(実機 m4: 5 秒待っても返らない)。凍結直前の記録で決める
    if (t.frozen === true) {
      const r = frozenBusy(frozen[String(id)]);
      if (r.busy) busy.add(id);
      add(r.reasons.map(k => 'frozen:' + k));
      reasons.frozen = (reasons.frozen || 0) + 1;
      return;
    }
    try {
      const results = await Promise.race([
        chrome.scripting.executeScript({ target: { tabId: id, allFrames: true }, world: 'MAIN', func: pageProbe }),
        new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), 3000)),
      ]);
      const r = probeBusy(results);
      if (r.busy) busy.add(id);
      add(r.reasons);
    } catch { busy.add(id); add(['noReply']); }
  }));
  return { busy, reasons };
}

// chrome.* の callback 版を Promise にする。失敗は null(数字や状態を作らない)
function viaCallback(fn) {
  return new Promise(resolve => {
    try { fn(v => resolve(chrome.runtime.lastError ? null : v)); } catch { resolve(null); }
  });
}

// ブラウザ全体のメモリ(実測)。chrome.processes が無い・失敗したときは null。
// processes.getProcessInfo は MV3 でも Promise を返さない(IDL に supportsPromises が無い)ので callback で包む
async function measureMemory() {
  if (!chrome.processes?.getProcessInfo) return null;
  const procs = await viaCallback(cb => chrome.processes.getProcessInfo([], true, cb));
  return procs ? summarizeMemory(procs) : null;
}
const systemMemory = () => chrome.system?.memory?.getInfo ? viaCallback(cb => chrome.system.memory.getInfo(cb)) : Promise.resolve(null);
const debuggerTargets = () => chrome.debugger?.getTargets ? viaCallback(cb => chrome.debugger.getTargets(cb)) : Promise.resolve(null);

// 節約量: 累計は storage.local、今回起動からの分は storage.session(ブラウザを終了すると消える)
async function readSavings() {
  const [{ savingsTotal }, { savingsSession }] = await Promise.all([
    chrome.storage.local.get('savingsTotal'), chrome.storage.session.get('savingsSession'),
  ]);
  return { total: addSavings(savingsTotal, null), session: addSavings(savingsSession, null) };
}
async function recordSavings(delta) {
  if (!delta.tabs) return;
  const { total, session } = await readSavings();
  await Promise.all([
    chrome.storage.local.set({ savingsTotal: addSavings(total, delta) }),
    chrome.storage.session.set({ savingsSession: addSavings(session, delta) }),
  ]);
}

// バッジの文字は今まで通り(メモリ量)。色は状態(緑/黄/赤、測れなければ灰)
async function showBadge(tabs, s, mem, sys) {
  const counts = countTabs(tabs);
  const state = memoryState(s, mem, sys ?? await systemMemory());
  const sav = await readSavings();
  const line = statusLine(counts, mem), sline = stateLine(state), vline = savingsLine(sav.session, sav.total);
  await chrome.action.setBadgeText({ text: badgeText(counts, mem) });
  await chrome.action.setBadgeBackgroundColor({ color: STATE_COLORS[state.level] });
  if (chrome.action.setBadgeTextColor) await chrome.action.setBadgeTextColor({ color: state.level === 'yellow' ? '#000' : '#fff' });
  await chrome.action.setTitle({ title: `Idaten: ${line}\n${sline}\n${vline}` });
  return { counts, state, line, sline, vline };
}

// ポップアップが開いたときの表示用。休眠はしない
async function stats() {
  const s = await settings();
  const [tabs, mem] = await Promise.all([chrome.tabs.query({}), measureMemory()]);
  const r = await showBadge(tabs, s, mem);
  return { counts: r.counts, mem: mem && { ...mem, tabBytes: undefined }, line: r.line, state: r.state, stateLine: r.sline, savingsLine: r.vline, memoryAvailable: !!chrome.processes };
}

let running = false, again = null;
async function enforce(reason) {
  // 同時に何本も走らせない(Swift 版で判定要求が積み上がって本体が膨張した事故の再発防止)。
  // 走行中に来た要求は捨てずに 1 回だけ後で走らせる(タブを続けて開いたとき、最後の 1 枚を見落とさない)
  if (running) { again = reason; return; }
  running = true;
  try { await enforceOnce(reason); }
  finally {
    running = false;
    if (again) { const r = again; again = null; enforce(r + '(後追い)'); }
  }
}
async function enforceOnce(reason) {
  const s = await settings();
  const tabs = await chrome.tabs.query({});
  // AI エージェント(debugger 接続)が操作中のタブ。取れなければ空(= 従来どおり)
  const attached = debuggerTabIds(await debuggerTargets());
  const bg = tabs.filter(t => !t.active && !t.discarded && !t.pinned && !t.audible && t.autoDiscardable !== false
    && !attached.has(t.id) && /^https?:/.test(t.url || ''));
  const probe = await busyTabs(bg);
  const busy = new Set([...probe.busy, ...attached]);
  const countIds = pickTabsToDiscard(tabs, s, busy, Date.now());
  // メモリ予算が有効なら選ぶために測る。無効でも、眠らせるタブがあれば節約量のために眠らせる直前に 1 回測る
  let mem = s.memoryBudgetMB > 0 ? await measureMemory() : null;
  const memIds = pickTabsForMemoryBudget(tabs, s, busy, mem, new Set(countIds));
  const ids = [...countIds, ...memIds];
  if (ids.length && !mem) mem = await measureMemory();
  // 断られた理由は握り潰さない。「選んだのに眠らなかった」を後から追えるようにする
  // 選んでから眠らせるまでに数秒かかる(判定の待ち)。その間に閉じられた・他に眠らされた・選択されたタブは眠らせない
  const failed = [], ok = [], gone = [], idChanged = [];
  for (const id of ids) {
    let cur = null;
    try { cur = await chrome.tabs.get(id); } catch { gone.push(id); continue; }
    if (cur.discarded || cur.active) { gone.push(id); continue; }
    try {
      const t = await chrome.tabs.discard(id);
      if (!t) { failed.push(`tab ${id}: discard returned nothing`); continue; }
      ok.push(id);
      if (t.id !== id) idChanged.push([id, t.id]);   // 眠らせると ID が変わる版がある。記録だけ残す
    } catch (e) {
      if (classifyDiscardError(e) === 'gone') gone.push(id); else failed.push(String(e).slice(0, 120));
    }
  }
  const saved = measuredSavings(ok, mem);
  await recordSavings(saved);
  const lastRun = {
    at: Date.now(), reason, tabs: tabs.length, background: bg.length, busy: busy.size, busyReasons: probe.reasons,
    debuggerAttached: attached.size, notAutoDiscardable: tabs.filter(t => t.autoDiscardable === false).length,
    picked: ids.length, pickedByMemory: memIds.length, discarded: ok.length, gone: gone.length, idChanged, failed, settings: s,
    memoryBytes: mem?.complete ? mem.bytes : null, savedBytes: saved.bytes, savedMeasured: saved.measured,
    pickedTitles: ids.map(id => (tabs.find(t => t.id === id)?.title || '').slice(0, 30)),
  };
  // 直近 10 回を残す(「何回走って、どれを選んだか」を後から追えるように)
  const { runLog } = await chrome.storage.local.get('runLog');
  const entry = { at: lastRun.at, reason, picked: lastRun.pickedTitles, discarded: ok.length, gone: gone.length, busyReasons: probe.reasons };
  await chrome.storage.local.set({ lastRun, runLog: [...(runLog || []), entry].slice(-10) });
  // バッジは眠らせた後の状態で出す。眠らせたなら測り直す(前の値は古い)。何もしなかったなら今測った値を使い回す
  const after = await chrome.tabs.query({});
  await showBadge(after, s, ids.length || !mem ? await measureMemory() : mem);
}

// 表示の更新: 自分が眠らせたときだけでなく、他(組み込み版・Chromium 本体・利用者の操作)が眠らせた/起こしたときにも
// バッジとツールチップを直す。続けて起きるので 500ms まとめてから 1 回
let badgeTimer = null;
function refreshBadgeSoon() {
  clearTimeout(badgeTimer);
  badgeTimer = setTimeout(() => { if (!running) stats().catch(() => {}); }, 500);
}
chrome.tabs.onUpdated.addListener((_id, info) => { if ('discarded' in info) refreshBadgeSoon(); });
chrome.tabs.onReplaced.addListener((added, removed) => {
  updateFrozen(st => { const n = { ...st }; delete n[String(removed)]; return n; });
  refreshBadgeSoon();
});

// Swift 版と同じく、タブを切り替えた/増やした瞬間に予算を適用する(定期巡回を待たない)
chrome.tabs.onActivated.addListener(() => enforce('activated'));
chrome.tabs.onCreated.addListener(() => enforce('created'));
chrome.tabs.onRemoved.addListener(id => {   // 閉じた分をバッジにすぐ反映(休眠はしない)
  updateFrozen(st => { const n = { ...st }; delete n[String(id)]; return n; });
  stats();
});
chrome.alarms.create('idaten-sweep', { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(a => { if (a.name === 'idaten-sweep') enforce('sweep'); });
// 導入・更新の前から開いていたタブには content_scripts が入らない。入れておく(凍結中のタブは解凍まで待たされるので待たない)
async function injectExisting() {
  const tabs = await chrome.tabs.query({ discarded: false });
  for (const t of tabs) {
    if (!/^https?:/.test(t.url || '')) continue;
    chrome.scripting.executeScript({ target: { tabId: t.id, allFrames: true }, world: 'MAIN', injectImmediately: true, files: ['main-world.js'] }).catch(() => {});
    chrome.scripting.executeScript({ target: { tabId: t.id, allFrames: true }, injectImmediately: true, files: ['bridge.js'] }).catch(() => {});
  }
}
chrome.runtime.onInstalled.addListener(() => { injectExisting().catch(() => {}); enforce('installed'); });
chrome.runtime.onMessage.addListener((m, sender, reply) => {
  if (m && (m.idaten === 'frozen' || m.idaten === 'resumed')) {
    if (sender.tab && typeof sender.tab.id === 'number') updateFrozen(st => applyFrozenMessage(st, sender.tab.id, sender.frameId, m));
    return false;
  }
  if (m === 'enforce') enforce('manual').then(() => reply(true));
  else if (m === 'stats') stats().then(reply);
  else return false;
  return true;
});
