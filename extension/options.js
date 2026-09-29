import { DEFAULTS, STATE_COLORS } from './policy.js';
const $ = id => document.getElementById(id);
const s = await chrome.storage.sync.get(DEFAULTS);
$('budget').value = s.budget; $('idle').value = s.idleMinutes; $('never').value = s.neverDiscard.join('\n');
$('mem').value = s.memoryBudgetMB;
async function show() {
  // 起きている/眠っている/メモリは background で実測した値(取れないメモリは「計測できず」)
  const st = await chrome.runtime.sendMessage('stats');
  $('now-stats').textContent = st?.line ?? '計測できず';
  // 状態(緑/黄/赤)と効果(休眠で約 N MB 節約)。どちらも background で実測・集計した値だけを出す
  document.querySelector('#state .dot').style.background = STATE_COLORS[st?.state?.level] ?? STATE_COLORS.unknown;
  $('state-text').textContent = st?.stateLine ?? '状態: 不明';
  $('savings').textContent = st?.savingsLine ?? '';
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
    memoryBudgetMB: Math.max(0, Math.round(+$('mem').value || 0)),
  });
  $('status').textContent = '保存しました';
};
$('now').onclick = async () => { await chrome.runtime.sendMessage('enforce'); show(); };
show();
