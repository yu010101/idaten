import { DEFAULTS } from './policy.js';
const $ = id => document.getElementById(id);
const s = await chrome.storage.sync.get(DEFAULTS);
$('budget').value = s.budget; $('idle').value = s.idleMinutes; $('never').value = s.neverDiscard.join('\n');
async function show() {
  const { lastRun } = await chrome.storage.local.get('lastRun');
  const tabs = await chrome.tabs.query({});
  const asleep = tabs.filter(t => t.discarded).length;
  $('status').textContent = `タブ ${tabs.length} 枚 / 休眠中 ${asleep} 枚` +
    (lastRun ? ` / 最終適用 ${new Date(lastRun.at).toLocaleTimeString()}(${lastRun.discarded}枚を休眠)` : '');
}
$('save').onclick = async () => {
  await chrome.storage.sync.set({
    budget: Math.max(1, +$('budget').value || DEFAULTS.budget),
    idleMinutes: Math.max(0, +$('idle').value || 0),
    neverDiscard: $('never').value.split('\n').map(x => x.trim()).filter(Boolean),
  });
  $('status').textContent = '保存しました';
};
$('now').onclick = async () => { await chrome.runtime.sendMessage('enforce'); show(); };
show();
