// 休眠の判断だけを純関数にしておく(chrome.* に触れない)。node でそのまま試験できるように
// Idaten(Swift版)の enforceAwakeBudget / hibernateIdleTabs と同じ規則:
//  - 選択中・固定・休眠済み・音が出ているタブは対象外
//  - 起きている背景タブが budget を超えたら、最後に見た時刻が古い順に超過分を眠らせる
//  - idleMinutes 以上見ていない背景タブも眠らせる(0 なら無効)
//  - 再生中(ミュート再生を含む)・入力途中のタブは、予算を超えても眠らせない(Swift版の force:false と同じ)
//  - 例外ドメイン(と、そのサブドメイン)は眠らせない
export const DEFAULTS = { budget: 6, idleMinutes: 10, neverDiscard: [] };   // Swift 版 Settings の既定と同じ

export function hostMatches(host, list) {
  host = (host || '').toLowerCase();
  return list.some(d => { d = d.toLowerCase().trim(); return d && (host === d || host.endsWith('.' + d)); });
}

/** tabs: {id, active, pinned, discarded, audible, lastAccessed, url}[] / busy: Set<tabId>(再生中・入力中) */
export function pickTabsToDiscard(tabs, settings, busy, now) {
  const s = { ...DEFAULTS, ...settings };
  const candidates = tabs.filter(t => {
    if (t.active || t.pinned || t.discarded || t.audible || busy.has(t.id)) return false;
    let host = '';
    try { host = new URL(t.url).host; } catch { return false; }   // chrome:// 等は眠らせない
    if (!/^https?:/.test(t.url)) return false;
    return !hostMatches(host, s.neverDiscard);
  });
  // 背景で起きているタブの数。固定タブは利用者が意図して置いているので数えない(Swift 版には固定タブが無い)。
  // 再生中・入力中は数に入れる — 眠らせられない分は、眠らせられる中から古い順に補って予算を守る
  // (Swift 版は最古から超過分だけを見て、眠らせられないものは飛ばすだけだった。こちらの方が予算を守る)
  const awakeBackground = tabs.filter(t => !t.active && !t.discarded && !t.pinned);
  const pick = new Set();
  const overflow = awakeBackground.length - s.budget;
  if (overflow > 0) {
    [...candidates].sort((a, b) => (a.lastAccessed ?? 0) - (b.lastAccessed ?? 0))
      .slice(0, overflow).forEach(t => pick.add(t.id));
  }
  if (s.idleMinutes > 0) {
    for (const t of candidates) if (now - (t.lastAccessed ?? now) > s.idleMinutes * 60000) pick.add(t.id);
  }
  return [...pick];
}
