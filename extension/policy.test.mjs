// node extension/policy.test.mjs — 休眠の判断(policy.js)の試験。chrome.* を使わないので node だけで回る
import assert from 'node:assert/strict';
import { pickTabsToDiscard, hostMatches } from './policy.js';
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
console.log('policy: 6 cases ok');
