// Idaten: 隔離ワールド(ISOLATED)で document_start・全フレームに入る。main-world.js(MAIN world)は chrome.runtime を使えないので、
// 凍結の直前/解凍の知らせを DOM イベントで受け取り、background に転送するだけ。ページの動作には触れない
(() => {
  if (globalThis.__idatenBridge) return;
  globalThis.__idatenBridge = true;   // 隔離ワールドの window なのでページからは見えない
  const relay = (type, withSnap) => e => {
    try {
      let snap = null;
      if (withSnap) { try { snap = JSON.parse(e.detail || 'null'); } catch {} }
      chrome.runtime.sendMessage({ idaten: type, snap }).catch(() => {});
    } catch {}
  };
  document.addEventListener('idaten:frozen', relay('frozen', true), true);
  document.addEventListener('idaten:resumed', relay('resumed', false), true);
})();
