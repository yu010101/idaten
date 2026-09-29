import { DEFAULTS, pickTabsToDiscard, pickTabsForMemoryBudget, summarizeMemory, countTabs, badgeText, overBudget, statusLine } from './policy.js';

async function settings() {
  return { ...DEFAULTS, ...(await chrome.storage.sync.get(DEFAULTS)) };
}

// ページの中で「再生中か・入力途中か」を調べる。Swift 版の hibernate() の判定と同じ式。
// 返事が来ない(読み込み中など)タブは busy 扱いにして今回は眠らせない — 次の巡回で再挑戦(Swift 版の 3 秒打ち切りと同じ考え)
async function busyTabs(tabIds) {
  const busy = new Set();
  await Promise.all(tabIds.map(async id => {
    try {
      const [r] = await Promise.race([
        chrome.scripting.executeScript({
          target: { tabId: id },
          func: () => {
            const playing = [...document.querySelectorAll('video,audio')].some(m => !m.paused && !m.ended);
            const a = document.activeElement;
            const editing = !!a && (a.isContentEditable || ((a.tagName === 'TEXTAREA' || a.tagName === 'INPUT') && (a.value || '').length > 0));
            return playing || editing;
          },
        }),
        new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), 3000)),
      ]);
      if (r?.result) busy.add(id);
    } catch { busy.add(id); }
  }));
  return busy;
}

// ブラウザ全体のメモリ(実測)。chrome.processes が無い・失敗したときは null を返し、数字を作らない。
// processes.getProcessInfo は MV3 でも Promise を返さない(IDL に supportsPromises が無い)ので callback で包む
function measureMemory() {
  return new Promise(resolve => {
    if (!chrome.processes?.getProcessInfo) return resolve(null);
    try {
      chrome.processes.getProcessInfo([], true, procs => {
        if (chrome.runtime.lastError) return resolve(null);
        resolve(summarizeMemory(procs));
      });
    } catch { resolve(null); }
  });
}

async function showBadge(tabs, s, mem) {
  const counts = countTabs(tabs);
  await chrome.action.setBadgeText({ text: badgeText(counts, mem) });
  await chrome.action.setBadgeBackgroundColor({ color: overBudget(s, mem) ? '#c62828' : '#555' });
  await chrome.action.setTitle({ title: 'Idaten: ' + statusLine(counts, mem) });
  return counts;
}

// ポップアップが開いたときの表示用。休眠はしない
async function stats() {
  const s = await settings();
  const [tabs, mem] = await Promise.all([chrome.tabs.query({}), measureMemory()]);
  const counts = await showBadge(tabs, s, mem);
  return { counts, mem: mem && { ...mem, tabBytes: undefined }, line: statusLine(counts, mem), memoryAvailable: !!chrome.processes };
}

let running = false;
async function enforce(reason) {
  if (running) return;   // 同時に何本も走らせない(Swift 版で判定要求が積み上がって本体が膨張した事故の再発防止)
  running = true;
  try {
    const s = await settings();
    const tabs = await chrome.tabs.query({});
    const bg = tabs.filter(t => !t.active && !t.discarded && !t.pinned && !t.audible && /^https?:/.test(t.url || ''));
    const busy = await busyTabs(bg.map(t => t.id));
    const countIds = pickTabsToDiscard(tabs, s, busy, Date.now());
    // メモリ予算が無効(0)なら選択用には測らない(バッジ用に後で 1 回だけ測る)
    const mem = s.memoryBudgetMB > 0 ? await measureMemory() : null;
    const memIds = pickTabsForMemoryBudget(tabs, s, busy, mem, new Set(countIds));
    const ids = [...countIds, ...memIds];
    // 断られた理由は握り潰さない。「選んだのに眠らなかった」を後から追えるようにする
    const failed = [];
    let done = 0;
    for (const id of ids) {
      try { await chrome.tabs.discard(id); done++; }
      catch (e) { failed.push(String(e).slice(0, 120)); }
    }
    await chrome.storage.local.set({ lastRun: {
      at: Date.now(), reason, tabs: tabs.length, background: bg.length, busy: busy.size,
      picked: ids.length, pickedByMemory: memIds.length, discarded: done, failed, settings: s,
      memoryBytes: mem?.complete ? mem.bytes : null,
    } });
    // バッジは眠らせた後の状態で出す。眠らせたなら測り直す(前の値は古い)。何もしなかったなら今測った値を使い回す
    const after = await chrome.tabs.query({});
    await showBadge(after, s, ids.length || !mem ? await measureMemory() : mem);
  } finally { running = false; }
}

// Swift 版と同じく、タブを切り替えた/増やした瞬間に予算を適用する(定期巡回を待たない)
chrome.tabs.onActivated.addListener(() => enforce('activated'));
chrome.tabs.onCreated.addListener(() => enforce('created'));
chrome.tabs.onRemoved.addListener(() => stats());   // 閉じた分をバッジにすぐ反映(休眠はしない)
chrome.alarms.create('idaten-sweep', { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(a => { if (a.name === 'idaten-sweep') enforce('sweep'); });
chrome.runtime.onInstalled.addListener(() => enforce('installed'));
chrome.runtime.onMessage.addListener((m, _s, reply) => {
  if (m === 'enforce') enforce('manual').then(() => reply(true));
  else if (m === 'stats') stats().then(reply);
  else return false;
  return true;
});
