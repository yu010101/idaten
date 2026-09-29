// 休眠の判断だけを純関数にしておく(chrome.* に触れない)。node でそのまま試験できるように
// Idaten(Swift版)の enforceAwakeBudget / hibernateIdleTabs と同じ規則:
//  - 選択中・固定・休眠済み・音が出ているタブは対象外
//  - 起きている背景タブが budget を超えたら、最後に見た時刻が古い順に超過分を眠らせる
//  - idleMinutes 以上見ていない背景タブも眠らせる(0 なら無効)
//  - 再生中(ミュート再生を含む)・入力途中のタブは、予算を超えても眠らせない(Swift版の force:false と同じ)
//  - 例外ドメイン(と、そのサブドメイン)は眠らせない
//  - 0.3.0 で Chrome/Edge の休眠除外に揃えて追加: autoDiscardable:false のタブ、カメラ・マイク・画面共有・WebRTC 通話中、
//    入力途中のフォーム(input/textarea/select/contenteditable の変更)、USB/HID/シリアル/Bluetooth 接続中、
//    AI エージェント等が chrome.debugger で接続中のタブ。ページ内の判定は pageProbe、合成は probeBusy / debuggerTabIds
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
  if (t.autoDiscardable === false) return false;   // 利用者や他の拡張が「自動で破棄しない」と指定したタブ(Chrome 本体の休眠も同じく飛ばす)
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

// ---- 0.3.0: 眠らせない条件(Chrome に揃える) ----

/**
 * chrome.debugger.getTargets() の結果から、何かが接続中(attached:true)のタブ id を集める。
 * Claude in Chrome などの AI エージェント拡張は chrome.debugger でタブに接続して操作するので「使用中」とみなす。
 * DevTools を開いているタブも attached:true になる(こちらも眠らせない方が自然なので区別しない)。
 */
export function debuggerTabIds(targets) {
  const ids = new Set();
  for (const t of targets || []) if (t && t.attached === true && typeof t.tabId === 'number') ids.add(t.tabId);
  return ids;
}

/** pageProbe が返す理由のうち、1 つでも真なら眠らせない */
export const BUSY_REASONS = ['playing', 'editing', 'capturing', 'rtc', 'device'];

/**
 * chrome.scripting.executeScript({allFrames:true}) の結果(フレームごと)を 1 タブの判定にまとめる。
 * どれか 1 フレームでも理由があれば busy。reasons はそのタブで立った理由の一覧(記録用)。
 */
export function probeBusy(results) {
  const reasons = new Set();
  for (const r of results || []) {
    const v = r && r.result;
    if (v === true) reasons.add('legacy');            // 旧版の真偽値の返事にも対応
    else if (v && typeof v === 'object') for (const k of BUSY_REASONS) if (v[k] === true) reasons.add(k);
  }
  return { busy: reasons.size > 0, reasons: [...reasons] };
}

/**
 * ページの中(MAIN world)で動かす判定。chrome.scripting.executeScript の func として直列化されるので、
 * この関数の外の名前を参照してはいけない(自己完結)。同期の判定(再生・入力・カメラ・WebRTC)は main-world.js の
 * live.check() に一本化してある(凍結直前の記録と同じ式にするため)。ここは機器の確認(非同期)を足すだけ。
 * 返り値: { playing, editing, capturing, rtc, device, hooked, devices:{usb,hid,serial,bluetooth} }
 *   devices の各値: true=接続中 / false=接続なし / null=その API が無い・読めない(未対応)
 */
export async function pageProbe() {
  const live = window[Symbol.for('idaten.live')] || null;
  let base = null;
  if (live && typeof live.check === 'function') { try { base = live.check(); } catch { base = null; } }
  if (!base) {
    // main-world.js が入っていない(拡張の導入前から開いていた・注入に失敗した)ときの予備。
    // 再生中・焦点のある入力欄・<video> に映した自分の映像(カメラ)だけは、記録が無くても見える
    const media = [...document.querySelectorAll('video,audio')];
    const liveStream = s => { try { return s.getTracks().some(t => t.readyState === 'live'); } catch { return false; } };
    const a = document.activeElement;
    base = {
      playing: media.some(m => !m.paused && !m.ended),
      editing: !!a && (a.isContentEditable || ((a.tagName === 'TEXTAREA' || a.tagName === 'INPUT') && (a.value || '').length > 0)),
      capturing: media.some(m => m.srcObject && typeof m.srcObject.getTracks === 'function' && liveStream(m.srcObject)),
      rtc: false,
    };
  }
  // 機器: getDevices/getPorts は「このサイトに許可済み」のものしか返さない。サイトが開けるのも許可済みのものだけなので、
  // その中で開いている(opened / readable / gatt.connected)ものがあれば接続中とみなす。1 秒で返らなければ読めない扱い
  const timed = p => Promise.race([p, new Promise(r => setTimeout(() => r(null), 1000))]);
  const check = async (api, fn, test) => {
    try {
      if (!api || typeof api[fn] !== 'function') return null;
      const list = await timed(api[fn]());
      return Array.isArray(list) ? list.some(d => { try { return test(d); } catch { return false; } }) : null;
    } catch { return null; }
  };
  const n = navigator;
  const [usb, hid, serial, bluetooth] = await Promise.all([
    check(n.usb, 'getDevices', d => d.opened === true),
    check(n.hid, 'getDevices', d => d.opened === true),
    check(n.serial, 'getPorts', p => p.readable != null || p.writable != null),
    check(n.bluetooth, 'getDevices', d => !!(d.gatt && d.gatt.connected)),
  ]);
  const device = usb === true || hid === true || serial === true || bluetooth === true;
  return { playing: base.playing === true, editing: base.editing === true, capturing: base.capturing === true, rtc: base.rtc === true,
    device, hooked: !!live, devices: { usb, hid, serial, bluetooth } };
}

// ---- 0.3.0: メモリの「状態+効果」 ----
export const STATE_GREEN = 0.7;    // 〜70% 緑
export const STATE_YELLOW = 0.9;   // 〜90% 黄、超えたら赤
export const STATE_COLORS = { green: '#2e7d32', yellow: '#f9a825', red: '#c62828', unknown: '#555' };
const LEVEL_JA = { green: '緑', yellow: '黄', red: '赤', unknown: '不明' };

/**
 * 状態。メモリ予算が設定されていれば予算比(ブラウザの実測/予算)、未設定なら機械全体の使用率(1 - 空き/容量)。
 * sys: chrome.system.memory.getInfo() の結果 {capacity, availableCapacity}(バイト)。取れない値からは状態を作らない(unknown)
 */
export function memoryState(settings, mem, sys) {
  const b = ({ ...DEFAULTS, ...settings }).memoryBudgetMB || 0;
  let ratio = null, basis;
  if (b > 0) {
    basis = 'budget';
    if (mem && mem.complete && typeof mem.bytes === 'number') ratio = mem.bytes / (b * MB);
  } else {
    basis = 'system';
    const cap = sys && sys.capacity, av = sys && sys.availableCapacity;
    if (typeof cap === 'number' && cap > 0 && typeof av === 'number' && av >= 0 && av <= cap) ratio = 1 - av / cap;
  }
  if (ratio === null || !Number.isFinite(ratio)) return { level: 'unknown', basis, ratio: null };
  const level = ratio <= STATE_GREEN ? 'green' : ratio <= STATE_YELLOW ? 'yellow' : 'red';
  return { level, basis, ratio };
}

export function stateLine(st) {
  if (!st || st.level === 'unknown') return `状態: 不明(${st && st.basis === 'budget' ? 'ブラウザのメモリ' : '機械全体の空き'}を計測できず)`;
  const pct = Math.round(st.ratio * 100);
  return `状態: ${LEVEL_JA[st.level]}(${st.basis === 'budget' ? `予算の ${pct}%` : `機械全体の使用 ${pct}%`})`;
}

/**
 * 今回眠らせたタブの節約量。眠らせる直前の実測(summarizeMemory の tabBytes: タブ 1 枚だけのプロセス)が
 * あるものだけを足す。同居プロセスなど実測できないタブは 0 として数え、推定しない。
 * discardedIds: 実際に休眠に成功したタブ id
 */
export function measuredSavings(discardedIds, mem) {
  let bytes = 0, measured = 0;
  const tb = mem && mem.tabBytes;
  for (const id of discardedIds || []) {
    const v = tb && typeof tb.get === 'function' ? tb.get(id) : undefined;
    if (typeof v === 'number' && Number.isFinite(v) && v >= 0) { bytes += v; measured++; }
  }
  return { bytes, measured, tabs: (discardedIds || []).length };
}

/** 累積に足す(storage に入れる形)。prev が無ければ 0 から */
export function addSavings(prev, delta) {
  const p = prev && typeof prev === 'object' ? prev : {};
  const n = x => (typeof x === 'number' && Number.isFinite(x) ? x : 0);
  return { bytes: n(p.bytes) + n(delta && delta.bytes), measured: n(p.measured) + n(delta && delta.measured), tabs: n(p.tabs) + n(delta && delta.tabs) };
}

/** 「休眠で約 N MB 節約」。session=今回起動から、total=累計 */
export function savingsLine(session, total) {
  const s = addSavings(session, null), t = addSavings(total, null);
  const mb = x => Math.round(x / MB);
  return `休眠で約 ${mb(s.bytes)} MB 節約(今回起動から・実測 ${s.measured}/${s.tabs} 枚)/ 累計 約 ${mb(t.bytes)} MB`;
}

// ---- 0.3.0 実機修正(m4): 凍結タブ・タブ ID の入れ替わり ----

/**
 * 凍結中(tab.frozen === true)のタブの判定。凍結中のタブは executeScript に返事をしない(凍結が解けるまで待たされる)ので、
 * main-world.js が凍結の直前に記録した判定(frames: { [frameId]: {playing,editing,capturing,rtc} })で決める。
 * 記録が無い凍結タブ(導入前から開いていた等)は、中身が分からないので眠らせない(入力途中を消さない側に倒す)。
 */
export function frozenBusy(frames) {
  const list = frames && typeof frames === 'object' ? Object.values(frames) : [];
  if (!list.length) return { busy: true, reasons: ['frozenNoRecord'] };
  return probeBusy(list.map(result => ({ result })));
}

/** bridge.js からの知らせ(frozen/resumed)を、タブ→フレーム→判定 の記録に反映する(元の記録は変えずに新しいものを返す) */
export function applyFrozenMessage(store, tabId, frameId, msg) {
  const next = { ...(store || {}) };
  const key = String(tabId), fk = String(frameId ?? 0);
  const frames = { ...(next[key] || {}) };
  if (msg && msg.idaten === 'frozen' && msg.snap && typeof msg.snap === 'object') frames[fk] = msg.snap;
  else if (msg && msg.idaten === 'resumed') delete frames[fk];
  else return next;
  if (Object.keys(frames).length) next[key] = frames; else delete next[key];
  return next;
}

/**
 * chrome.tabs.discard の失敗の分類。"No tab with id" は、選んでから眠らせるまでの間にそのタブが閉じられたか、
 * 他の休眠(組み込み版の拡張・Chromium 本体)に先に眠らされて ID が入れ替わったもの。失敗ではなく「もう無い」として数える
 */
export function classifyDiscardError(e) {
  const s = String((e && e.message) || e);
  return /No tab with id/i.test(s) ? 'gone' : 'failed';
}
