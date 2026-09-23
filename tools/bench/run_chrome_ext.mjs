// Chrome に Idaten の休眠拡張を入れた状態で、URL を開いて待つ。
//
// なぜ専用の起動器が要るか: `Extensions.loadUnpacked` で入れた拡張は **その起動の間しか残らない**
// (実測 2026-09-23: 準備してから Chrome を開き直すと、拡張のターゲットが消えていた)。
// Chrome 137 以降 `--load-extension` は使えないので、同じプロセスの中で
// 「入れる → 開く → 測り終わるまで生かす」までを一続きにする。
//
// 使い方: node run_chrome_ext.mjs <profile> <extDir> <秒> <url...>
//   標準出力の1行目に Chrome の pid を出す(測る側がこれを使う)
import { spawn } from 'node:child_process';

const [, , profile, extDir, seconds, ...urls] = process.argv;
if (!profile || !extDir || !seconds || urls.length === 0) {
  console.error('使い方: node run_chrome_ext.mjs <profile> <extDir> <秒> <url...>');
  process.exit(2);
}
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const p = spawn(CHROME, [
  `--user-data-dir=${profile}`, '--remote-debugging-pipe', '--no-first-run', '--no-default-browser-check',
  '--enable-unsafe-extension-debugging', 'about:blank',
], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'] });

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
const send = (method, params = {}) => new Promise(res => { const i = ++id; pend.set(i, res); w.write(JSON.stringify({ id: i, method, params }) + '\0'); });
const sleep = ms => new Promise(res => setTimeout(res, ms));

await sleep(3000);
const load = await send('Extensions.loadUnpacked', { path: extDir });
if (!load.result?.id) {
  console.error('拡張を入れられない:', JSON.stringify(load.error || load), errLines.join('').slice(-300));
  p.kill();
  process.exit(1);
}
// 同じ規則で比べるため、Idaten の既定(背景タブ上限6・放置10分)に合わせる
const extId = load.result.id;
for (const url of urls) { await send('Target.createTarget', { url }); await sleep(400); }
await sleep(4000);

// 拡張が本当に動いているか(service worker が居るか)を確かめてから測る。
// 「入れたつもりで測っていた」を防ぐ
const targets = (await send('Target.getTargets', { filter: [{}] })).result?.targetInfos ?? [];
const worker = targets.find(t => (t.url || '').includes(extId));
console.log(JSON.stringify({ pid: p.pid, extensionId: extId, workerAlive: !!worker, tabs: targets.filter(t => t.type === 'page').length }));

await sleep(Number(seconds) * 1000);

// 測り終わり。何枚眠ったかを記録してから閉じる
const after = (await send('Target.getTargets', { filter: [{}] })).result?.targetInfos ?? [];
console.log(JSON.stringify({ pagesAtEnd: after.filter(t => t.type === 'page').length }));
await send('Browser.close');
await sleep(2000);
process.exit(0);
