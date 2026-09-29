// node extension/policy.test.mjs — 休眠の判断(policy.js)の試験。chrome.* を使わないので node だけで回る
import assert from 'node:assert/strict';
import { pickTabsToDiscard, hostMatches, summarizeMemory, pickTabsForMemoryBudget, countTabs, badgeText, overBudget, statusLine, MEMORY_MAX_PER_RUN } from './policy.js';
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
console.log('policy: 14 cases ok');
