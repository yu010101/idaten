// Idaten: ページの MAIN world に document_start・全フレームで入る(manifest の content_scripts)。
// 目的は「カメラ・マイク・画面共有・WebRTC 通話・入力途中のフォームがあるか」を記録するだけ。休眠の判断はしない。
// 記録は window[Symbol.for('idaten.live')] に置き、background の pageProbe(policy.js)が MAIN world で live.check() を呼んで読む。
// 凍結(freeze)の直前にも check() して、bridge.js 経由で background に渡す(凍結中のタブは executeScript に返事をしないため)。
//
// ページを壊さないための約束:
//  - 包んだ関数は元の関数を同じ this・同じ引数で呼ぶ。同期の例外はそのまま投げ直る(try で握らない)
//  - getUserMedia / getDisplayMedia は、元の Promise に .then を 1 段つないだものを返す。
//    解決値(同じ MediaStream)と拒否理由(同じ例外オブジェクト)は変わらない。変わるのは Promise の同一性と 1 マイクロタスクの遅れだけ。
//    元の Promise をそのまま返して横で .then(f, noop) すると、ページが拒否を処理していないときの unhandledrejection を
//    こちらが握り潰してしまうので、その方式は採らない
//  - RTCPeerConnection は Reflect.construct で元のコンストラクタを呼ぶ。prototype・静的メソッド・継承(class extends)はそのまま
//  - 記録側で起きた例外はページに漏らさない
(() => {
  const KEY = Symbol.for('idaten.live');
  if (globalThis[KEY]) return;   // 二重に入っても二重に包まない
  const live = { v: 1, streams: new Set(), pcs: new Set(), edited: new Set() };
  try { Object.defineProperty(globalThis, KEY, { value: live }); } catch { return; }

  // --- getUserMedia / getDisplayMedia ---
  const MD = globalThis.MediaDevices;
  const proto = MD && MD.prototype;
  for (const name of ['getUserMedia', 'getDisplayMedia']) {
    try {
      const desc = proto && Object.getOwnPropertyDescriptor(proto, name);
      const orig = desc && desc.value;
      if (typeof orig !== 'function') continue;
      const wrapped = {
        [name](...args) {
          const p = Reflect.apply(orig, this, args);
          if (!p || typeof p.then !== 'function') return p;
          return p.then(s => { try { if (s && typeof s.getTracks === 'function') live.streams.add(s); } catch {} return s; });
        },
      }[name];
      Object.defineProperty(proto, name, { ...desc, value: wrapped });
    } catch {}
  }

  // --- RTCPeerConnection ---
  try {
    const Orig = globalThis.RTCPeerConnection;
    if (typeof Orig === 'function') {
      const W = function RTCPeerConnection(...args) {
        if (!new.target) return Reflect.apply(Orig, this, args);   // new 無しの呼び出しは元と同じ TypeError を投げる
        const pc = Reflect.construct(Orig, args, new.target === W ? Orig : new.target);
        try { live.pcs.add(pc); } catch {}
        return pc;
      };
      Object.setPrototypeOf(W, Orig);                               // generateCertificate などの静的メソッド
      Object.defineProperty(W, 'prototype', { value: Orig.prototype });
      try { Object.defineProperty(Orig.prototype, 'constructor', { value: W, writable: true, configurable: true, enumerable: false }); } catch {}
      for (const g of ['RTCPeerConnection', 'webkitRTCPeerConnection']) {
        const d = Object.getOwnPropertyDescriptor(globalThis, g);
        if (d && d.value === Orig) Object.defineProperty(globalThis, g, { ...d, value: W });
      }
    }
  } catch {}

  // --- 入力途中のフォーム ---
  // 利用者の操作(isTrusted)で変わった input/textarea/select/contenteditable を覚える。
  // 入力途中かどうか(値が残っているか)は check() が読むときに判断する。送信・リセットされたフォームの分は忘れる
  const mark = e => {
    try {
      if (!e.isTrusted) return;
      const t = (typeof e.composedPath === 'function' && e.composedPath()[0]) || e.target;   // 開いた shadow DOM の中の実体
      if (t && t.nodeType === 1) live.edited.add(t);
    } catch {}
  };
  const forget = e => {
    try {
      const f = e.target;
      for (const el of [...live.edited]) if (el.form === f || (f && typeof f.contains === 'function' && f.contains(el))) live.edited.delete(el);
    } catch {}
  };
  try {
    addEventListener('input', mark, { capture: true, passive: true });
    addEventListener('change', mark, { capture: true, passive: true });
    addEventListener('submit', forget, { capture: true, passive: true });
    addEventListener('reset', forget, { capture: true, passive: true });
  } catch {}

  // --- 今この文書が「使用中」か(同期で判定)。pageProbe(background が executeScript で呼ぶ)と、凍結の直前の記録で共用 ---
  const NO_VALUE = ['button', 'submit', 'reset', 'image', 'hidden'];
  const TEXTLIKE = ['text', 'search', 'email', 'url', 'tel', 'password', 'number', ''];
  const dirty = el => {
    if (el.isContentEditable) return (el.textContent || '').trim().length > 0;
    if (el.tagName === 'TEXTAREA') return (el.value || '').length > 0;
    if (el.tagName === 'SELECT') return [...el.options].some(o => o.selected !== o.defaultSelected);
    if (el.tagName !== 'INPUT') return false;
    const type = (el.type || '').toLowerCase();
    if (NO_VALUE.includes(type)) return false;
    if (type === 'checkbox' || type === 'radio') return el.checked !== el.defaultChecked;
    if (type === 'file') return !!(el.files && el.files.length);
    if (TEXTLIKE.includes(type)) return (el.value || '').length > 0;   // 送信後に空へ戻す画面(チャット等)は空なら入力途中でない
    return el.value !== el.defaultValue;                               // range/color/date など、常に値があるもの
  };
  const liveStream = s => { try { return s.getTracks().some(t => t.readyState === 'live'); } catch { return false; } };
  const check = () => {
    const doc = globalThis.document;
    const media = doc ? [...doc.querySelectorAll('video,audio')] : [];
    const playing = media.some(m => !m.paused && !m.ended);
    let capturing = media.some(m => m.srcObject && typeof m.srcObject.getTracks === 'function' && liveStream(m.srcObject));
    for (const s of [...live.streams]) { if (liveStream(s)) capturing = true; else live.streams.delete(s); }
    let rtc = false;
    for (const pc of [...live.pcs]) {
      let st = '';
      try { st = pc.connectionState; } catch {}
      if (st === 'closed' || st === 'failed') live.pcs.delete(pc);
      else if (st === 'connecting' || st === 'connected' || st === 'disconnected') rtc = true;   // 'new' は IP 調べ等で作るだけのものが多いので数えない
    }
    const a = doc && doc.activeElement;
    let editing = !!a && (a.isContentEditable || ((a.tagName === 'TEXTAREA' || a.tagName === 'INPUT') && (a.value || '').length > 0));
    for (const el of [...live.edited]) {
      if (!el.isConnected) { live.edited.delete(el); continue; }
      try { if (dirty(el)) editing = true; } catch {}
    }
    return { playing, editing, capturing, rtc };
  };
  live.check = check;

  // --- 凍結(Page Lifecycle の freeze)---
  // Chromium は隠れた背景タブをすぐ凍結する(実機 m4 で 12 秒後に p1..p4 が frozen=true)。凍結中のタブには
  // chrome.scripting.executeScript が返事をしない(凍結が解けるまで待たされる)ので、凍結の直前にここで判定して、
  // 隔離ワールドの bridge.js 経由で background に渡しておく。凍結中はページが動かないので、この記録は解凍まで正しい。
  // 隔離ワールドとは DOM イベントでしか話せない。detail は文字列で渡す(オブジェクトはワールドをまたげない)
  const tell = (type, snap) => {
    try { globalThis.document.dispatchEvent(new CustomEvent(type, { detail: snap ? JSON.stringify(snap) : '' })); } catch {}
  };
  try {
    globalThis.document.addEventListener('freeze', () => { let snap = null; try { snap = check(); } catch {} tell('idaten:frozen', snap); }, { capture: true });
    globalThis.document.addEventListener('resume', () => tell('idaten:resumed', null), { capture: true });
  } catch {}
})();
