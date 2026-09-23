// Chrome の専用プロファイルに Idaten 拡張を入れて、有効になったことを確かめて閉じる。
// Chrome 137 以降 --load-extension は使えないので、CDP の Extensions.loadUnpacked を使う。
// 接続は --remote-debugging-pipe(fd 3/4)。ポートを開けない。
import { spawn } from 'node:child_process';
const [, , profile, extDir] = process.argv;
if (!profile || !extDir) { console.error('使い方: node prepare_chrome_ext.mjs <profile> <extDir>'); process.exit(2); }
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const p = spawn(CHROME, [
  `--user-data-dir=${profile}`, '--remote-debugging-pipe', '--no-first-run', '--no-default-browser-check',
  '--enable-unsafe-extension-debugging', '--no-startup-window',
], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'] });
const err = []; p.stderr.on('data', d => err.push(String(d)));
const w = p.stdio[3], r = p.stdio[4];
let id = 0, buf = Buffer.alloc(0); const pend = new Map();
r.on('data', d => { buf = Buffer.concat([buf, d]); let z; while ((z = buf.indexOf(0)) >= 0) { const m = JSON.parse(buf.subarray(0, z)); buf = buf.subarray(z + 1); pend.get(m.id)?.(m); pend.delete(m.id); } });
const send = (method, params = {}) => new Promise(res => { const i = ++id; pend.set(i, res); w.write(JSON.stringify({ id: i, method, params }) + '\0'); });
const sleep = ms => new Promise(r2 => setTimeout(r2, ms));
await sleep(3000);
const load = await send('Extensions.loadUnpacked', { path: extDir });
if (!load.result?.id) { console.error('導入できない:', JSON.stringify(load.error || load), err.join('').slice(-400)); process.exit(1); }
const list = await send('Extensions.getExtensions');
console.log(JSON.stringify({ id: load.result.id, extensions: list.result?.extensions ?? [] }));
await send('Browser.close');
await sleep(2000);
process.exit(0);
