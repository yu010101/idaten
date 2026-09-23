import { DEFAULTS, pickTabsToDiscard } from './policy.js';

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

let running = false;
async function enforce(reason) {
  if (running) return;   // 同時に何本も走らせない(Swift 版で判定要求が積み上がって本体が膨張した事故の再発防止)
  running = true;
  try {
    const s = await settings();
    const tabs = await chrome.tabs.query({});
    const bg = tabs.filter(t => !t.active && !t.discarded && !t.pinned && !t.audible && /^https?:/.test(t.url || ''));
    const busy = await busyTabs(bg.map(t => t.id));
    const ids = pickTabsToDiscard(tabs, s, busy, Date.now());
    // 断られた理由は握り潰さない。「選んだのに眠らなかった」を後から追えるようにする
    const failed = [];
    let done = 0;
    for (const id of ids) {
      try { await chrome.tabs.discard(id); done++; }
      catch (e) { failed.push(String(e).slice(0, 120)); }
    }
    await chrome.storage.local.set({ lastRun: {
      at: Date.now(), reason, tabs: tabs.length, background: bg.length, busy: busy.size,
      picked: ids.length, discarded: done, failed, settings: s,
    } });
  } finally { running = false; }
}

// Swift 版と同じく、タブを切り替えた/増やした瞬間に予算を適用する(定期巡回を待たない)
chrome.tabs.onActivated.addListener(() => enforce('activated'));
chrome.tabs.onCreated.addListener(() => enforce('created'));
chrome.alarms.create('idaten-sweep', { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(a => { if (a.name === 'idaten-sweep') enforce('sweep'); });
chrome.runtime.onInstalled.addListener(() => enforce('installed'));
chrome.runtime.onMessage.addListener((m, _s, reply) => {
  if (m === 'enforce') enforce('manual').then(() => reply(true));
  return true;
});
