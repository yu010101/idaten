// 休眠の判断だけを純関数にしておく(chrome.* に触れない)。node でそのまま試験できるように
// Idaten(Swift版)の enforceAwakeBudget / hibernateIdleTabs と同じ規則:
//  - 選択中・固定・休眠済み・音が出ているタブは対象外
//  - 起きている背景タブが budget を超えたら、最後に見た時刻が古い順に超過分を眠らせる
//  - idleMinutes 以上見ていない背景タブも眠らせる(0 なら無効)
//  - 再生中(ミュート再生を含む)・入力途中のタブは、予算を超えても眠らせない(Swift版の force:false と同じ)
//  - 例外ドメイン(と、そのサブドメイン)は眠らせない
//  - メモリ予算(memoryBudgetMB, 0 で無効): ブラウザ全体の実測メモリが予算の MEMORY_HIGH 倍を超えたら、
//    上と同じ候補(再生中・入力中・固定・選択中・例外ドメインを除く)から古い順に眠らせる
export const DEFAULTS = { budget: 6, idleMinutes: 10, neverDiscard: [], memoryBudgetMB: 0 };   // memoryBudgetMB 以外は Swift 版 Settings の既定と同じ
export const MEMORY_HIGH = 0.9;      // 予算の 90% を超えたら「超えそう」とみなして動く
export const MEMORY_LOW = 0.8;       // 80% まで下げる分だけ選ぶ(90% ちょうどで毎分 1 枚ずつ眠らせ続けないための幅)
export const MEMORY_MAX_PER_RUN = 3; // 1 回に眠らせる上限。解放量を当てにせず、次の巡回で測り直して続ける
const MB = 1024 * 1024;

export function hostMatches(host, list) {
  host = (host || '').toLowerCase();
  return list.some(d => { d = d.toLowerCase().trim(); return d && (host === d || host.endsWith('.' + d)); });
}

/** tabs: {id, active, pinned, discarded, audible, lastAccessed, url}[] / busy: Set<tabId>(再生中・入力中) */
/** 眠らせてよいタブか(タブ数の予算・放置・メモリ予算で共通) */
export function isCandidate(t, s, busy) {
  if (t.active || t.pinned || t.discarded || t.audible || busy.has(t.id)) return false;
  let host = '';
  try { host = new URL(t.url).host; } catch { return false; }   // chrome:// 等は眠らせない
  if (!/^https?:/.test(t.url)) return false;
  return !hostMatches(host, s.neverDiscard || []);
}

export function pickTabsToDiscard(tabs, settings, busy, now) {
  const s = { ...DEFAULTS, ...settings };
  const candidates = tabs.filter(t => isCandidate(t, s, busy));
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

/** 起きている/眠っているタブの数。起きている = 休眠していない全タブ(選択中・固定を含む) */
export function countTabs(tabs) {
  const asleep = tabs.filter(t => t.discarded).length;
  return { awake: tabs.length - asleep, asleep };
}

/**
 * chrome.processes.getProcessInfo([], true) の結果を足し合わせる。
 * privateMemory は Chromium の task manager の「メモリ フットプリント」(バイト)。取れなかったプロセスは -1 か欠落。
 * 1 つでも取れていなければ complete=false とし、合計は出さない(bytes=null)— 欠けた合計は実測値ではないので。
 * tabBytes: そのプロセスにタブが 1 枚だけ載っているとき tabId → そのプロセスのバイト数。
 *           複数タブ(や拡張)が同居するプロセスは、1 枚眠らせても何バイト減るか実測できないので載せない。
 */
export function summarizeMemory(processes) {
  const list = Object.values(processes || {});
  let bytes = 0, missing = 0;
  const tabBytes = new Map();
  for (const p of list) {
    const m = p.privateMemory;
    if (typeof m !== 'number' || !Number.isFinite(m) || m < 0) { missing++; continue; }
    bytes += m;
    const tasks = p.tasks || [];
    const tabIds = tasks.map(x => x.tabId).filter(x => typeof x === 'number');
    if (tabIds.length === 1 && tasks.length === 1) tabBytes.set(tabIds[0], m);
  }
  const complete = list.length > 0 && missing === 0;
  return { complete, bytes: complete ? bytes : null, processes: list.length, missing, tabBytes };
}

/**
 * メモリ予算で眠らせるタブを選ぶ。mem は summarizeMemory の戻り値。
 * already: タブ数の予算・放置ですでに選ばれた id(同じタブを二重に数えない。解放量が実測できるものは差し引く)。
 * 解放量が実測できない(同居プロセスの)タブは 0 バイトとして数え、1 回あたり MEMORY_MAX_PER_RUN 枚で止める。
 * 足りなければ次の巡回で測り直して続ける(推定で一気に眠らせない)。
 */
export function pickTabsForMemoryBudget(tabs, settings, busy, mem, already = new Set()) {
  const s = { ...DEFAULTS, ...settings };
  const budget = (s.memoryBudgetMB || 0) * MB;
  if (!(budget > 0) || !mem || !mem.complete) return [];
  if (mem.bytes <= budget * MEMORY_HIGH) return [];
  let need = mem.bytes - budget * MEMORY_LOW;
  for (const id of already) need -= mem.tabBytes.get(id) || 0;
  const pick = [];
  const sorted = tabs.filter(t => !already.has(t.id) && isCandidate(t, s, busy))
    .sort((a, b) => (a.lastAccessed ?? 0) - (b.lastAccessed ?? 0));
  for (const t of sorted) {
    if (need <= 0 || pick.length >= MEMORY_MAX_PER_RUN) break;
    pick.push(t.id);
    need -= mem.tabBytes.get(t.id) || 0;
  }
  return pick;
}

/** ツールバーのバッジ(4 文字まで)。実測できたときだけメモリを出し、できなければ起きているタブ数 */
export function badgeText(counts, mem) {
  if (mem && mem.complete) {
    const mb = Math.round(mem.bytes / MB);
    if (mb < 1000) return `${mb}M`;
    const gb = mem.bytes / (1024 * MB);
    return gb < 9.95 ? `${gb.toFixed(1)}G` : `${Math.round(gb)}G`;
  }
  return String(counts.awake);
}

/** バッジの色を赤にするか(メモリ予算が有効で、実測値が予算を超えているとき) */
export function overBudget(settings, mem) {
  const b = ({ ...DEFAULTS, ...settings }).memoryBudgetMB || 0;
  return b > 0 && !!mem && mem.complete && mem.bytes > b * MB;
}

/** ポップアップ・ツールチップ用の 1 行。取れない値は「計測できず」と書き、数字を作らない */
export function statusLine(counts, mem) {
  const m = mem && mem.complete ? `${Math.round(mem.bytes / MB)} MB`
    : `メモリ計測できず${mem ? `(${mem.missing}/${mem.processes} プロセス欠測)` : ''}`;
  return `起きている ${counts.awake} / 眠っている ${counts.asleep} / ${m}`;
}
