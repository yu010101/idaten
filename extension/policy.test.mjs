// node extension/policy.test.mjs — 休眠の判断(policy.js)の試験。chrome.* を使わないので node だけで回る
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFileSync } from 'node:fs';
import { pickTabsToDiscard, hostMatches, summarizeMemory, pickTabsForMemoryBudget, countTabs, badgeText, overBudget, statusLine, MEMORY_MAX_PER_RUN,
  debuggerTabIds, probeBusy, pageProbe, memoryState, stateLine, STATE_COLORS, measuredSavings, addSavings, savingsLine,
  frozenBusy, applyFrozenMessage, classifyDiscardError } from './policy.js';
const now = 1_000_000_000;
const tab = (id, o = {}) => ({ id, active: false, pinned: false, discarded: false, audible: false, lastAccessed: now - id * 1000, url: `https://s${id}.example/`, ...o });
const noBusy = new Set();

// 1) 予算内なら何もしない(背景6枚+選択中1枚)
let tabs = [tab(0, { active: true }), ...[1, 2, 3, 4, 5, 6].map(i => tab(i))];
assert.deepEqual(pickTabsToDiscard(tabs, { budget: 6, idleMinutes: 0 }, noBusy, now), []);

// 2) 背景9枚・予算6 → 最後に見たのが古い順に3枚(id 9,8,7)
tabs = [tab(0, { active: true }), ...[1, 2, 3, 4, 5, 6, 7, 8, 9].map(i => tab(i))];
assert.deepEqual(pickTabsToDiscard(tabs, { budget: 6, idleMinutes: 0 }, noBusy, now).sort(), [7, 8, 9]);

// 3) 固定タブは数えない(背景8枚→超過2)。再生中(busy)・音ありは飛ばし、眠らせられる中から古い順に補う
tabs = [tab(0, { active: true }), ...[1, 2, 3, 4, 5, 6, 7].map(i => tab(i)), tab(8, { audible: true }), tab(9, { pinned: true })];
assert.deepEqual(pickTabsToDiscard(tabs, { budget: 6, idleMinutes: 0 }, new Set([7]), now).sort(), [5, 6]);

// 4) 例外ドメイン(サブドメイン含む)は眠らせない / 似た名前は例外にならない
assert.equal(hostMatches('meet.google.com', ['google.com']), true);
assert.equal(hostMatches('notgoogle.com', ['google.com']), false);
tabs = [tab(0, { active: true }), ...[1, 2, 3, 4, 5, 6].map(i => tab(i)), tab(7, { url: 'https://meet.google.com/x' })];
assert.deepEqual(pickTabsToDiscard(tabs, { budget: 6, idleMinutes: 0, neverDiscard: ['google.com'] }, noBusy, now).sort(), [6]);

// 5) 放置時間: 31分見ていない背景タブは予算内でも眠らせる。http(s) 以外は眠らせない
tabs = [tab(0, { active: true }), tab(1, { lastAccessed: now - 31 * 60000 }), tab(2, { lastAccessed: now - 31 * 60000, url: 'chrome://settings' })];
assert.deepEqual(pickTabsToDiscard(tabs, { budget: 6, idleMinutes: 30 }, noBusy, now), [1]);

// 6) 既に休眠中のタブは数にも候補にも入らない
tabs = [tab(0, { active: true }), ...[1, 2, 3, 4, 5, 6].map(i => tab(i)), tab(7, { discarded: true })];
assert.deepEqual(pickTabsToDiscard(tabs, { budget: 6, idleMinutes: 0 }, noBusy, now), []);

// ---- メモリ(見える化・メモリ予算) ----
const MB = 1024 * 1024;
// getProcessInfo(includeMemory) の形: { [id]: { privateMemory, tasks: [{title, tabId?}] } }
const proc = (mb, ...tabIds) => ({ privateMemory: mb * MB, tasks: tabIds.length ? tabIds.map(tabId => ({ title: 't', tabId })) : [{ title: 'browser' }] });

// 7) 合計は実測値の足し算。タブ 1 枚だけのプロセスは tabBytes に載る。同居プロセスは載らない
let mem = summarizeMemory({ 1: proc(500), 2: proc(100, 1), 3: proc(300, 2, 3) });
assert.equal(mem.complete, true);
assert.equal(mem.bytes, 900 * MB);
assert.deepEqual([...mem.tabBytes], [[1, 100 * MB]]);

// 8) 1 つでも取れない(-1・欠落)なら合計を出さない。空でも出さない
mem = summarizeMemory({ 1: proc(500), 2: { privateMemory: -1, tasks: [] }, 3: { tasks: [] } });
assert.equal(mem.complete, false); assert.equal(mem.bytes, null); assert.equal(mem.missing, 2);
assert.equal(summarizeMemory({}).complete, false);
assert.equal(summarizeMemory(undefined).bytes, null);

// 9) 予算 0(無効)・計測できず・90% 以下 → 何もしない
tabs = [tab(0, { active: true }), ...[1, 2, 3].map(i => tab(i))];
const m = (totalMB, per = {}) => summarizeMemory({ 0: proc(totalMB - Object.values(per).reduce((a, b) => a + b, 0)), ...Object.fromEntries(Object.entries(per).map(([id, mb]) => [100 + +id, proc(mb, +id)])) });
assert.deepEqual(pickTabsForMemoryBudget(tabs, { memoryBudgetMB: 0 }, noBusy, m(5000)), []);
assert.deepEqual(pickTabsForMemoryBudget(tabs, { memoryBudgetMB: 2048 }, noBusy, summarizeMemory({ 1: { privateMemory: -1, tasks: [] } })), []);
assert.deepEqual(pickTabsForMemoryBudget(tabs, { memoryBudgetMB: 2048 }, noBusy, m(1843)), []);   // 1843 < 2048*0.9=1843.2

// 10) 90% 超え → 80% まで下げる分だけ、古い順に。実測の解放量で止まる
// 予算 2000MB・合計 1900MB → 1600MB まで 300MB 減らす。古い順 3(200MB),2(150MB) で足りる → [3,2]
tabs = [tab(0, { active: true }), ...[1, 2, 3].map(i => tab(i))];
assert.deepEqual(pickTabsForMemoryBudget(tabs, { memoryBudgetMB: 2000 }, noBusy, m(1900, { 1: 100, 2: 150, 3: 200 })), [3, 2]);

// 11) 再生中・入力中・音あり・固定・選択中・例外ドメインは、メモリ予算でも眠らせない(既存の規則と同じ)
tabs = [tab(0, { active: true }), tab(1), tab(2, { audible: true }), tab(3, { pinned: true }), tab(4), tab(5, { url: 'https://meet.google.com/' })];
assert.deepEqual(pickTabsForMemoryBudget(tabs, { memoryBudgetMB: 1000, neverDiscard: ['google.com'] }, new Set([4]), m(5000, { 1: 10, 2: 10, 3: 10, 4: 10, 5: 10 })), [1]);

// 12) 解放量が実測できない(同居プロセス)タブばかりでも、1 回 MEMORY_MAX_PER_RUN 枚で止める(次の巡回で測り直す)
tabs = [tab(0, { active: true }), ...[1, 2, 3, 4, 5, 6].map(i => tab(i))];
const shared = summarizeMemory({ 0: proc(4000), 9: proc(1000, 1, 2, 3, 4, 5, 6) });
assert.deepEqual(pickTabsForMemoryBudget(tabs, { memoryBudgetMB: 2000 }, noBusy, shared), [6, 5, 4].slice(0, MEMORY_MAX_PER_RUN));

// 13) タブ数の予算ですでに選ばれたタブは二重に選ばず、その実測解放量は差し引く
// 予算 2000MB・合計 1900MB → 要 300MB。タブ数側で 3(250MB) を選んだ → 残り 50MB → 2(150MB) の 1 枚だけ
tabs = [tab(0, { active: true }), ...[1, 2, 3].map(i => tab(i))];
assert.deepEqual(pickTabsForMemoryBudget(tabs, { memoryBudgetMB: 2000 }, noBusy, m(1900, { 1: 100, 2: 150, 3: 250 }), new Set([3])), [2]);

// 14) 見える化: 数・バッジ(4 文字以内)・赤・1 行表示。計測できないときは数字を作らない
tabs = [tab(0, { active: true }), tab(1), tab(2, { discarded: true }), tab(3, { discarded: true, pinned: true })];
assert.deepEqual(countTabs(tabs), { awake: 2, asleep: 2 });
assert.equal(badgeText({ awake: 2 }, m(850)), '850M');
assert.equal(badgeText({ awake: 2 }, m(999.6)), '1.0G');
assert.equal(badgeText({ awake: 2 }, m(1536)), '1.5G');
assert.equal(badgeText({ awake: 2 }, m(12 * 1024)), '12G');
assert.equal(badgeText({ awake: 2 }, null), '2');
for (const mb of [1, 999, 999.6, 1000, 10188, 10189, 102400]) assert.ok(badgeText({ awake: 1 }, m(mb)).length <= 4, `badge ${mb}MB`);
assert.equal(overBudget({ memoryBudgetMB: 2048 }, m(2049)), true);
assert.equal(overBudget({ memoryBudgetMB: 2048 }, m(2048)), false);
assert.equal(overBudget({ memoryBudgetMB: 0 }, m(99999)), false);
assert.equal(statusLine({ awake: 8, asleep: 12 }, m(1432)), '起きている 8 / 眠っている 12 / 1432 MB');
assert.equal(statusLine({ awake: 8, asleep: 12 }, null), '起きている 8 / 眠っている 12 / メモリ計測できず');
assert.equal(statusLine({ awake: 8, asleep: 12 }, summarizeMemory({ 1: proc(5), 2: { privateMemory: -1, tasks: [] } })), '起きている 8 / 眠っている 12 / メモリ計測できず(1/2 プロセス欠測)');

// ==== 0.3.0 ====
// 15) autoDiscardable:false は眠らせない(数には入り、他の古いタブで補う)。undefined(古い Chromium)は従来どおり
tabs = [tab(0, { active: true }), ...[1, 2, 3, 4, 5, 6, 7].map(i => tab(i)), tab(8, { autoDiscardable: false })];
assert.deepEqual(pickTabsToDiscard(tabs, { budget: 6, idleMinutes: 0 }, noBusy, now).sort(), [6, 7]);
tabs = [tab(0, { active: true }), tab(1, { autoDiscardable: false, lastAccessed: now - 99 * 60000 }), tab(2, { autoDiscardable: true, lastAccessed: now - 99 * 60000 })];
assert.deepEqual(pickTabsToDiscard(tabs, { budget: 6, idleMinutes: 30 }, noBusy, now), [2]);
assert.deepEqual(pickTabsForMemoryBudget(tabs, { memoryBudgetMB: 100 }, noBusy, m(5000)), [2]);

// 16) debugger 接続中(attached:true)のタブ id だけを集める。拡張・ワーカー(tabId 無し)や未接続は入らない
assert.deepEqual([...debuggerTabIds([
  { type: 'page', tabId: 3, attached: true }, { type: 'page', tabId: 4, attached: false },
  { type: 'background_page', extensionId: 'x', attached: true }, { type: 'worker', attached: true }, null,
])], [3]);
assert.deepEqual([...debuggerTabIds(null)], []);
// 接続中タブを busy に混ぜると、予算超過でも放置でも眠らない
tabs = [tab(0, { active: true }), ...[1, 2, 3, 4, 5, 6, 7].map(i => tab(i))];
assert.deepEqual(pickTabsToDiscard(tabs, { budget: 6, idleMinutes: 0 }, debuggerTabIds([{ tabId: 7, attached: true }]), now), [6]);

// 17) probeBusy: どれか 1 フレームでも理由があれば busy。理由が全部 false・返事なしは busy でない
assert.deepEqual(probeBusy([{ frameId: 0, result: { playing: false, editing: false, capturing: false, rtc: false, device: false } }]), { busy: false, reasons: [] });
for (const k of ['playing', 'editing', 'capturing', 'rtc', 'device']) {
  const r = probeBusy([{ frameId: 0, result: { [k]: false } }, { frameId: 5, result: { [k]: true } }]);
  assert.deepEqual(r, { busy: true, reasons: [k] }, k);
}
assert.equal(probeBusy([{ result: true }]).busy, true);
assert.equal(probeBusy([{ result: 'yes' }, { result: { device: 1 } }]).busy, false);   // true 以外は数えない
assert.equal(probeBusy(undefined).busy, false);

// 18) main-world.js を偽の window/document で読み込む道具。同期の判定(check)はここにある
const el = (tag, o = {}) => ({ tagName: tag, isConnected: true, isContentEditable: false, ...o });
const track = st => ({ readyState: st });
const stream = (...st) => ({ getTracks: () => st.map(track) });
function loadMainWorld({ media = [], active = null } = {}) {
  const calls = [];
  class MediaDevices {
    getUserMedia(c) { calls.push(['gum', this, c]); if (c === 'sync-throw') throw new TypeError('bad'); return c === 'deny' ? Promise.reject(new Error('NotAllowed')) : Promise.resolve(stream('live')); }
    getDisplayMedia(c) { calls.push(['gdm', this, c]); return Promise.resolve(stream('live')); }
  }
  class RTCPeerConnection { constructor(cfg) { if (!new.target) throw new TypeError('need new'); this.cfg = cfg; this.connectionState = 'new'; } static generateCertificate() { return 'cert'; } }
  class CustomEvent { constructor(type, init = {}) { this.type = type; this.detail = init.detail; } }
  const listeners = {}, docListeners = {}, dispatched = [];
  const document = { querySelectorAll: () => media, activeElement: active,
    addEventListener: (t, f, o) => { docListeners[t] = [f, o]; }, dispatchEvent: e => { dispatched.push(e); return true; } };
  const ctx = { MediaDevices, RTCPeerConnection, webkitRTCPeerConnection: RTCPeerConnection, CustomEvent, document, JSON,
    addEventListener: (t, f, o) => { listeners[t] = [f, o]; }, Symbol, Promise, Reflect, Object, Set, TypeError, Error };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(readFileSync(new URL('./main-world.js', import.meta.url), 'utf8'), ctx);
  return { ctx, calls, listeners, docListeners, dispatched, document, live: ctx[Symbol.for('idaten.live')], MediaDevices, RTCPeerConnection };
}

// 19) pageProbe(executeScript で送る関数)を偽の window/document/navigator で回す。live があれば live.check() を使う
async function probeWith({ media = [], active = null, live = null, nav = {} } = {}) {
  const saved = { window: globalThis.window, document: globalThis.document, nav: Object.getOwnPropertyDescriptor(globalThis, 'navigator') };
  globalThis.window = live ? { [Symbol.for('idaten.live')]: live } : {};
  globalThis.document = { querySelectorAll: () => media, activeElement: active };
  Object.defineProperty(globalThis, 'navigator', { value: nav, configurable: true, writable: true });
  try { return await pageProbe(); } finally {
    globalThis.window = saved.window; globalThis.document = saved.document;
    if (saved.nav) Object.defineProperty(globalThis, 'navigator', saved.nav); else delete globalThis.navigator;
  }
}
let r = await probeWith();
assert.deepEqual([r.playing, r.editing, r.capturing, r.rtc, r.device, r.hooked], [false, false, false, false, false, false]);
assert.deepEqual(r.devices, { usb: null, hid: null, serial: null, bluetooth: null });   // API が無い = 未対応(null)
// main-world.js が無いタブの予備: <video> に映した自分の映像・再生中・焦点のある入力欄
r = await probeWith({ media: [{ paused: true, ended: false, srcObject: stream('live') }] }); assert.equal(r.capturing, true);
r = await probeWith({ media: [{ paused: false, ended: false }] }); assert.equal(r.playing, true);
r = await probeWith({ active: el('INPUT', { value: 'q' }) }); assert.equal(r.editing, true);
// live.check() の結果をそのまま使う(true 以外は false に揃える)。check が例外なら予備に落ちる
r = await probeWith({ live: { check: () => ({ rtc: true, capturing: 1 }) } }); assert.equal(r.rtc, true); assert.equal(r.capturing, false); assert.equal(r.hooked, true);
r = await probeWith({ live: { check: () => { throw new Error('x'); } }, media: [{ paused: false, ended: false }] }); assert.equal(r.playing, true);
// 機器: 許可済み一覧のうち開いているものがあれば device。一覧が空・閉じている・API が拒否 → 接続なし/未対応
const api = (fn, list) => ({ [fn]: async () => list });
r = await probeWith({ nav: { usb: api('getDevices', [{ opened: false }, { opened: true }]) } }); assert.equal(r.device, true); assert.equal(r.devices.usb, true);
r = await probeWith({ nav: { hid: api('getDevices', [{ opened: true }]) } }); assert.equal(r.device, true);
r = await probeWith({ nav: { serial: api('getPorts', [{ readable: {}, writable: null }]) } }); assert.equal(r.device, true);
r = await probeWith({ nav: { bluetooth: api('getDevices', [{ gatt: { connected: true } }]) } }); assert.equal(r.device, true);
r = await probeWith({ nav: { usb: api('getDevices', [{ opened: false }]), serial: api('getPorts', [{ readable: null, writable: null }]) } });
assert.equal(r.device, false); assert.equal(r.devices.usb, false); assert.equal(r.devices.serial, false);
r = await probeWith({ nav: { usb: { getDevices: async () => { throw new Error('SecurityError'); } } } }); assert.equal(r.devices.usb, null); assert.equal(r.device, false);

// 20a) main-world.js の check(): カメラ・WebRTC・入力途中・再生
{
  let w = loadMainWorld();
  const camLive = stream('live', 'ended'), camDead = stream('ended');
  w.live.streams.add(camDead); assert.equal(w.live.check().capturing, false); assert.equal(w.live.streams.size, 0);   // 止めた stream は外す
  w.live.streams.add(camLive); assert.equal(w.live.check().capturing, true);
  assert.equal(loadMainWorld({ media: [{ paused: true, ended: false, srcObject: stream('live') }] }).live.check().capturing, true);
  assert.equal(loadMainWorld({ media: [{ paused: false, ended: false }] }).live.check().playing, true);
  // WebRTC: connecting/connected/disconnected は通話中。new(作っただけ)は数えない。closed/failed は捨てる
  for (const [st, want] of [['new', false], ['connecting', true], ['connected', true], ['disconnected', true], ['closed', false], ['failed', false]]) {
    w = loadMainWorld(); w.live.pcs.add({ connectionState: st });
    assert.equal(w.live.check().rtc, want, st);
    if (st === 'closed' || st === 'failed') assert.equal(w.live.pcs.size, 0);
  }
  // 入力途中のフォーム: 利用者が変えた欄に値が残っていれば editing。空に戻した・外れた欄は数えない
  const cases = [
    [el('INPUT', { type: 'text', value: 'abc' }), true], [el('INPUT', { type: 'text', value: '' }), false],
    [el('TEXTAREA', { value: 'x' }), true], [el('DIV', { isContentEditable: true, textContent: ' hi ' }), true],
    [el('DIV', { isContentEditable: true, textContent: '  ' }), false],
    [el('INPUT', { type: 'checkbox', checked: true, defaultChecked: false }), true], [el('INPUT', { type: 'checkbox', checked: false, defaultChecked: false }), false],
    [el('SELECT', { options: [{ selected: true, defaultSelected: false }] }), true], [el('SELECT', { options: [{ selected: true, defaultSelected: true }] }), false],
    [el('INPUT', { type: 'range', value: '50', defaultValue: '50' }), false], [el('INPUT', { type: 'range', value: '70', defaultValue: '50' }), true],
    [el('INPUT', { type: 'submit', value: '送信' }), false], [el('INPUT', { type: 'file', files: [1] }), true],
    [el('INPUT', { type: 'text', value: 'abc', isConnected: false }), false],
  ];
  for (const [e, want] of cases) { w = loadMainWorld(); w.live.edited.add(e); assert.equal(w.live.check().editing, want, JSON.stringify(e)); }
  // 既存の判定(焦点のある入力欄に文字)
  assert.equal(loadMainWorld({ active: el('INPUT', { value: 'q' }) }).live.check().editing, true);
  // pageProbe 経由でも同じ(executeScript で実際に呼ばれる経路)
  w = loadMainWorld(); w.live.pcs.add({ connectionState: 'connected' });
  r = await probeWith({ live: w.live }); assert.equal(r.rtc, true);
}

// 20b) 凍結の直前に check() して、隔離ワールドへ文字列で知らせる。解凍も知らせる
{
  const w = loadMainWorld();
  w.live.pcs.add({ connectionState: 'connected' });
  const [onFreeze, fo] = w.docListeners.freeze; assert.equal(fo.capture, true);
  onFreeze();
  assert.equal(w.dispatched.length, 1); assert.equal(w.dispatched[0].type, 'idaten:frozen');
  assert.equal(typeof w.dispatched[0].detail, 'string');
  assert.deepEqual(JSON.parse(w.dispatched[0].detail), { playing: false, editing: false, capturing: false, rtc: true });
  w.docListeners.resume[0]();
  assert.equal(w.dispatched[1].type, 'idaten:resumed');
}

// 20c) main-world.js: 元の関数を同じ this・引数で呼び、値と例外を変えない。生きている stream / 接続を記録する
{
  const w = loadMainWorld();
  assert.ok(w.live, 'live record installed');
  const md = new w.ctx.MediaDevices();
  const s1 = await md.getUserMedia({ video: true });
  assert.equal(w.calls[0][1], md); assert.deepEqual(w.calls[0][2], { video: true });   // 同じ this・引数
  assert.equal(typeof s1.getTracks, 'function'); assert.ok(w.live.streams.has(s1));        // 同じ stream が返り、記録される
  const s2 = await md.getDisplayMedia({}); assert.ok(w.live.streams.has(s2));
  await assert.rejects(md.getUserMedia('deny'), { message: 'NotAllowed' });              // 拒否理由はそのまま
  assert.throws(() => md.getUserMedia('sync-throw'), { name: 'TypeError', message: 'bad' }); // 同期例外もそのまま
  assert.equal(w.live.streams.size, 2);
  // RTCPeerConnection
  const PC = w.ctx.RTCPeerConnection;
  assert.notEqual(PC, w.RTCPeerConnection); assert.equal(w.ctx.webkitRTCPeerConnection, PC);
  const pc = new PC({ iceServers: [] });
  assert.ok(pc instanceof w.RTCPeerConnection); assert.ok(pc instanceof PC); assert.deepEqual(pc.cfg, { iceServers: [] });
  assert.equal(pc.constructor, PC); assert.equal(PC.generateCertificate(), 'cert');
  assert.ok(w.live.pcs.has(pc));
  class Sub extends PC { hello() { return 'hi'; } }
  const sp = new Sub({}); assert.equal(sp.hello(), 'hi'); assert.ok(w.live.pcs.has(sp));
  assert.throws(() => PC({}), { name: 'TypeError' });
  // 二重に入れても二重に包まない
  vm.runInContext(readFileSync(new URL('./main-world.js', import.meta.url), 'utf8'), w.ctx);
  assert.equal(w.ctx.RTCPeerConnection, PC);
  // 入力: 利用者の操作だけ記録し、フォームを送信したら忘れる。受け身(passive)・capture で登録
  const [onInput, opt] = w.listeners.input; assert.equal(opt.capture, true); assert.equal(opt.passive, true);
  const form = { contains: x => x === inp };
  const inp = { nodeType: 1, form };
  onInput({ isTrusted: false, target: inp }); assert.equal(w.live.edited.size, 0);
  onInput({ isTrusted: true, target: { nodeType: 1 }, composedPath: () => [inp] }); assert.ok(w.live.edited.has(inp));
  w.listeners.submit[0]({ target: form }); assert.equal(w.live.edited.size, 0);
}

// 20d) 凍結タブの判定: 凍結直前の記録で決める。記録が無ければ眠らせない
assert.deepEqual(frozenBusy(undefined), { busy: true, reasons: ['frozenNoRecord'] });
assert.deepEqual(frozenBusy({}), { busy: true, reasons: ['frozenNoRecord'] });
assert.deepEqual(frozenBusy({ 0: { playing: false, editing: false, capturing: false, rtc: false } }), { busy: false, reasons: [] });
assert.deepEqual(frozenBusy({ 0: { rtc: false }, 3: { editing: true } }), { busy: true, reasons: ['editing'] });
let fs = applyFrozenMessage({}, 7, 0, { idaten: 'frozen', snap: { rtc: true } });
fs = applyFrozenMessage(fs, 7, 2, { idaten: 'frozen', snap: { editing: false } });
assert.deepEqual(fs, { 7: { 0: { rtc: true }, 2: { editing: false } } });
assert.deepEqual(applyFrozenMessage(fs, 7, 0, { idaten: 'resumed' }), { 7: { 2: { editing: false } } });
assert.deepEqual(applyFrozenMessage(applyFrozenMessage(fs, 7, 0, { idaten: 'resumed' }), 7, 2, { idaten: 'resumed' }), {});
assert.deepEqual(applyFrozenMessage(fs, 7, 0, { idaten: 'other' }), fs);
assert.deepEqual(applyFrozenMessage(fs, 7, 0, { idaten: 'frozen', snap: null }), fs);   // 判定の無い知らせは無視
assert.deepEqual(fs[7][0], { rtc: true });   // 元の記録は書き換えない
// discard の失敗の分類: "No tab with id" は閉じた/入れ替わった(失敗ではない)
assert.equal(classifyDiscardError(new Error('No tab with id: 1196063688.')), 'gone');
assert.equal(classifyDiscardError('Error: Cannot discard tab'), 'failed');

// 20) 状態: 予算があれば予算比、無ければ機械全体の空き。〜70% 緑、〜90% 黄、超えたら赤。測れなければ不明
assert.deepEqual(memoryState({ memoryBudgetMB: 1000 }, m(700), null), { level: 'green', basis: 'budget', ratio: 0.7 });
assert.equal(memoryState({ memoryBudgetMB: 1000 }, m(701), null).level, 'yellow');
assert.equal(memoryState({ memoryBudgetMB: 1000 }, m(900), null).level, 'yellow');
assert.equal(memoryState({ memoryBudgetMB: 1000 }, m(901), null).level, 'red');
assert.equal(memoryState({ memoryBudgetMB: 1000 }, null, { capacity: 100, availableCapacity: 99 }).level, 'unknown');   // 予算ありなら機械全体に逃げない
const GB = 1024 * MB;
assert.deepEqual(memoryState({ memoryBudgetMB: 0 }, m(99999), { capacity: 16 * GB, availableCapacity: 8 * GB }), { level: 'green', basis: 'system', ratio: 0.5 });
assert.equal(memoryState({}, null, { capacity: 100, availableCapacity: 20 }).level, 'yellow');
assert.equal(memoryState({}, null, { capacity: 100, availableCapacity: 5 }).level, 'red');
for (const bad of [null, {}, { capacity: 0, availableCapacity: 0 }, { capacity: 100, availableCapacity: -1 }, { capacity: 100, availableCapacity: 101 }])
  assert.equal(memoryState({}, null, bad).level, 'unknown', JSON.stringify(bad));
assert.equal(stateLine(memoryState({ memoryBudgetMB: 1000 }, m(620), null)), '状態: 緑(予算の 62%)');
assert.equal(stateLine(memoryState({}, null, { capacity: 100, availableCapacity: 15 })), '状態: 黄(機械全体の使用 85%)');
assert.equal(stateLine(memoryState({}, null, null)), '状態: 不明(機械全体の空きを計測できず)');
assert.equal(STATE_COLORS.red, '#c62828');

// 21) 効果: 眠らせたタブのうち、直前にタブ 1 枚だけのプロセスで実測できたものだけを足す(同居・未計測は 0、推定しない)
const pre = summarizeMemory({ 0: proc(500), 11: proc(120, 1), 12: proc(80, 2), 13: proc(300, 3, 4) });
assert.deepEqual(measuredSavings([1, 2, 3, 99], pre), { bytes: 200 * MB, measured: 2, tabs: 4 });
assert.deepEqual(measuredSavings([1], null), { bytes: 0, measured: 0, tabs: 1 });
// 欠測プロセスがあって合計が出せないときでも、タブ単独プロセスの実測は使える
const partial = summarizeMemory({ 0: { privateMemory: -1, tasks: [] }, 11: proc(120, 1) });
assert.equal(partial.complete, false); assert.equal(measuredSavings([1], partial).bytes, 120 * MB);
let acc = addSavings(undefined, measuredSavings([1, 2, 3], pre));
acc = addSavings(acc, { bytes: 50 * MB, measured: 1, tabs: 1 });
assert.deepEqual(acc, { bytes: 250 * MB, measured: 3, tabs: 4 });
assert.equal(savingsLine(acc, addSavings(acc, { bytes: 1000 * MB, measured: 5, tabs: 5 })), '休眠で約 250 MB 節約(今回起動から・実測 3/4 枚)/ 累計 約 1250 MB');
assert.equal(savingsLine(undefined, undefined), '休眠で約 0 MB 節約(今回起動から・実測 0/0 枚)/ 累計 約 0 MB');

// 22) manifest: 版と権限・MAIN world の注入
const mf = JSON.parse(readFileSync(new URL('./manifest.json', import.meta.url), 'utf8'));
assert.equal(mf.version, '0.3.0');
for (const p of ['system.memory', 'debugger']) assert.ok(mf.permissions.includes(p), p);
assert.deepEqual(mf.content_scripts.map(c => [c.js[0], c.world, c.run_at, c.all_frames]), [['main-world.js', 'MAIN', 'document_start', true], ['bridge.js', undefined, 'document_start', true]]);

console.log('policy: 22 cases + 0.3.0 実機修正 ok');
