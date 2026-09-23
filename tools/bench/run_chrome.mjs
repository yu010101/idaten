// 比較計測で Chrome を動かし、**実際に何を表示・再生していたか**を記録する。
//
// なぜ必要か(Codex の統計レビュー 2026-09-23): 「同じ作業をさせた」と言うには、同じURLを渡したことだけでなく、
// 両者で同じだけページが読み込まれ、動画が同じように再生されていたことを示す必要がある。
// 記録が無いまま「同じ作業で○GB少ない」とは書けない。
//
// 使い方: node run_chrome.mjs <profile> <秒> <extDirまたは-> <url...>
//   標準出力1行目: {pid, extensionId, workerAlive}
//   終了時:        {pagesAtEnd, loaded, videoPlaying, discarded}
import { spawn } from 'node:child_process';

const [, , profile, seconds, extDir, ...urls] = process.argv;
if (!profile || !seconds || !extDir || urls.length === 0) {
  console.error('使い方: node run_chrome.mjs <profile> <秒> <extDir|-> <url...>');
  process.exit(2);
}
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const args = [
  `--user-data-dir=${profile}`, '--remote-debugging-pipe', '--no-first-run', '--no-default-browser-check',
];
if (extDir !== '-') args.push('--enable-unsafe-extension-debugging');
args.push('about:blank');

const p = spawn(CHROME, args, { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'] });
const errLines = [];
p.stderr.on('data', d => errLines.push(String(d)));
const w = p.stdio[3], r = p.stdio[4];
let id = 0, buf = Buffer.alloc(0);
const pend = new Map();
r.on('data', d => {
  buf = Buffer.concat([buf, d]);
  let z;
  while ((z = buf.indexOf(0)) >= 0) {
    const m = JSON.parse(buf.subarray(0, z));
    buf = buf.subarray(z + 1);
    pend.get(m.id)?.(m);
    pend.delete(m.id);
  }
});
// 休眠したタブに evaluate すると応答が返らないことがある。時間切れを入れて止まらないようにする
// (実測 2026-09-23: 状態確認の途中で計測全体が止まった)
const send = (method, params = {}, sessionId, timeoutMs = 5000) =>
  new Promise(res => {
    const i = ++id;
    const timer = setTimeout(() => { pend.delete(i); res({ id: i, result: null, timedOut: true }); }, timeoutMs);
    pend.set(i, m => { clearTimeout(timer); res(m); });
    w.write(JSON.stringify({ id: i, method, params, sessionId }) + '\0');
  });
const sleep = ms => new Promise(res => setTimeout(res, ms));

await sleep(3000);

let extensionId = null, workerAlive = false;
if (extDir !== '-') {
  const load = await send('Extensions.loadUnpacked', { path: extDir });
  extensionId = load.result?.id ?? null;
  if (!extensionId) {
    console.error('拡張を入れられない:', JSON.stringify(load.error || load), errLines.join('').slice(-300));
    p.kill();
    process.exit(1);
  }
}

for (const url of urls) { await send('Target.createTarget', { url }); await sleep(400); }
await sleep(6000);

const targets0 = (await send('Target.getTargets', { filter: [{}] })).result?.targetInfos ?? [];
workerAlive = extensionId ? targets0.some(t => (t.url || '').includes(extensionId)) : false;
console.log(JSON.stringify({ pid: p.pid, extensionId, workerAlive, pages: targets0.filter(t => t.type === 'page').length }));

// 動画が本当に再生されているか / 各ページが読み終わったかを、ページの中から確かめる
async function inspect() {
  const targets = (await send('Target.getTargets', { filter: [{}] })).result?.targetInfos ?? [];
  const pages = targets.filter(t => t.type === 'page');
  let loaded = 0, videoPlaying = null;
  for (const t of pages) {
    const att = await send('Target.attachToTarget', { targetId: t.targetId, flatten: true });
    const s = att.result?.sessionId;
    if (!s) continue;
    const res = await send('Runtime.evaluate', {
      expression: `(() => { const v = document.querySelector('video');
        return JSON.stringify({ ready: document.readyState, playing: v ? (!v.paused && !v.ended && v.currentTime > 0) : null,
                                t: v ? Math.round(v.currentTime) : null }); })()`,
      returnByValue: true,
    }, s);
    await send('Target.detachFromTarget', { sessionId: s });
    const v = res.result?.result?.value;
    if (!v) continue;
    const info = JSON.parse(v);
    if (info.ready === 'complete') loaded++;
    if (info.playing !== null) videoPlaying = { playing: info.playing, currentTime: info.t };
  }
  return { pages: pages.length, loaded, videoPlaying };
}

const mid = await inspect();
await sleep(Number(seconds) * 1000);
const end = await inspect();
console.log(JSON.stringify({ atLoad: mid, atEnd: end }));
await send('Browser.close');
await sleep(2000);
process.exit(0);
