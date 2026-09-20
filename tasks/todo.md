# Karu — 軽量・広告カット・エンジン切替ブラウザ

計画の正本: `~/.claude/plans/compiled-percolating-crescent.md`(2026-09-19 承認)
状態の書き方: 完成しても運用実績が無いうちは「稼働中」と書かない。

## Phase 0 — 計器
- [x] `tools/footprint/` footprint-cli(`ri_phys_footprint`、子プロセス込み、1秒間隔、CSV+中央値/ピーク)— 09-19 ビルド緑
- [x] 自己検査: `/usr/bin/footprint` と同一pidで突き合わせ(誤差5%以内)— 09-19 29プロセス照合、合計差0.016%・プロセス単位の最大差3.03%(測定時刻のずれ)
  - 基準値: 現行Chrome = 30プロセス 4,365MB(1回の瞬間値。シナリオ固定の計測ではない)
  - 未検査: WebKitのWebContent(ppid=1)を responsible pid で拾えるか → Karu本体が動いてから対照つきで確認
- [ ] `config/scenario.json`(20タブ固定シナリオ)
- [ ] シナリオ実行器(起動→閲覧→放置→再訪、CPU時間・起動時間・swap差分も記録)

## Phase 1 — Chromium系候補の実測 ※HeliumをPhase 2の既定エンジンに採用(09-19)
- [x] ディスクゲート — 導入時に発動(9.5GB)。原因はKaru無関係の外部要因と判明(導入後30分弱で7.2GB→30GBまで自然回復)。本人の指示で運用は継続
- [x] Helium導入(v0.17.2.1 arm64、347MB)。Developer ID署名+公証を`codesign`/`spctl`で確認、dmgサイズも公式値と一致(CRC32検証込み)
- [~] Chrome(専用プロファイル)とHeliumを同一4タブ(example.org+ITmedia+Yahoo!ニュース+Wikipedia)で1回ずつ比較:
      | | プロセス数 | 合計footprint |
      |---|---|---|
      | Chrome | 25 | 1,513.8 MB |
      | Helium | 11 | 461.2 MB |
      主因はレンダラープロセス数の差(Chrome約15 vs Helium約5)。広告/計測iframeをHeliumの内蔵遮断が読み込み前に止めていると見られる。
      **n=1のため確定結論にしない。** ①Chrome+uBO Lite単体 ②Brave ③3回×20タブの本シナリオ は未実施(スキップを明記)
- [x] Karu側: `ChromiumProcessEngine.resolve()` を修正、`/Applications` と `~/Applications` の両方を探すように(Heliumは後者に入った)
- [ ] 軽量化ポリシーが `chrome://policy` に出るか — 未確認(研究で`defaults write`はrecommended止まりと判明済みなので優先度低)
- [ ] 必須拡張の動作表(Claude in Chrome / OneTab / Stylus)— 本人の実機確認が必要(ログイン要)
- [x] 採否記録: 段Aの既定候補はHelium(candidates順: Helium→Brave→Chrome、Engines.swiftの既定のまま)

## Phase 2 — Chromiumエンジン層
- [ ] `TabEngine` プロトコル / `ChromiumProcessEngine`(段A)
- [ ] `config/policies.json` `config/flags.txt` 外出し
- [ ] サイト別ルール `engine_rules.json`
- [ ] 段B: CEF埋め込み実験(1日で打ち切り・採否理由を記録)

## Phase 3 — Karu本体(Swift+WebKit) ※完成・運用実績ゼロ
- [x] タブ / URLバー / 戻る進む再読込 / ショートカット — 09-19 `--selftest` で描画確認(ui.png / web.png)。手での操作確認は未
- [x] 履歴(SQLite)/ ダウンロード — 実装済。ダウンロードと履歴補完UIは未検証(補完は記録のみでUIなし)
- [~] 広告遮断 — 種リスト38ドメインは実測で効いた(ITmedia 231→122・広告系38→0 / Yahoo!ニュース 128→108・8→0、各1回)。
      EasyList+AdGuard Japanese の変換は未着手。調査結果(09-19): SafariConverterLib(GPL-3.0、活発)/ adblock-rust(MPL-2.0、Rust+FFI要)の二択。
      配布ライセンスを先に決めるまでは**外部プロセスとして変換だけ使い、コードは混ぜない**(取り込むとGPL-3.0が波及する)。
      YouTube広告はルールリストだけでは部分的(AdGuard公式の立場)→ 別途スクリプト注入 or Chromiumタブへ回す判断が要る。`rules/*.json` の口は実装済
- [x] タブ休眠 — 09-19 `webView.interactionState` 退避方式に変更(Kestrel/DuckDuckGoと同型)。
      実測: Wikipedia random で休眠→復帰後、URL・スクロール位置(1500px)とも完全一致(`--selftest-hibernate`)。
      メモリ逼迫時(`DispatchSource.makeMemoryPressureSource`)も選択中以外を眠らせるよう追加(DuckDuckGoのTabSuspensionServiceと同じ契機)
- [x] エンジン切替(段A)— 09-19 テストルールで確認: Karu の子として Chrome が `--user-data-dir=…/Karu/chromium-profile` で起動、既存Chrome(別pid)は無傷。⌘⇧E のダイアログ経路は手での確認が未
- [x] 計器の WebKit 対応 — WebContent/GPU/Networking(ppid=1)3つを responsible pid で全数捕捉(/bin/ps の全数と照合)
- [ ] 実験: WKWebExtensionController
- [x] `make_app.sh` — build/Karu.app 392K。`--install` は未実行(~/Applications へは置いていない)

## 注意(09-19)
- ディスク空きが 16GB → 10GB に減った(私の成果物は約100MB。原因は別プロセスで未特定)。Phase 1 のエンジン導入(約1.5GB)はゲート8GBに近いので保留。
- safety-guard が PID 直指定の kill を止める。テストで開いた Karu 管理下の Chrome(専用プロファイル、pid 7773, example.org)を**本人が手で閉じるか、killしてよいと承認するまで開いたまま**。既存の本チャンChrome(pid 32082)は無傷。

## OSS/類似事例 調査(09-19、10エージェント・反証込み、40件中28件が反証を通過)
- **段Aの第一候補はHelium**(imputnet/helium-macos)。arm64 dmg 120MB・広告遮断内蔵・CWS拡張フル対応・2026-09-18リリース・GPL-3.0(同梱せず検出起動なので波及しない)。Brave/ungoogled-chromium/Thoriumはそれぞれ機能無効化に管理者権限が要る/CWS直接不可/主メンテナ不在で劣る。
- **`defaults write`での軽量化は不採用**(反証で判明)。Chromium公式が recommendedレベル止まり・本番非推奨と明記。専用プロファイルの起動フラグ+初期Preferencesで代替。
- **段B(CEF同一ウィンドウ埋め込み)は優先度を下げる**。唯一の実例 cmux(★2.7万)のPRは当日revertされWebKit専用に戻った。Chrome style限定で拡張が動く点はCEF公式どおりだが「成立した前例」は無い。実験は最後に回す。
- **WKWebExtensionでの拡張全対応は狙わない**(既定方針の再確認)。Kagi Orion(6人・6年・非OSS)でも公式値で約70%対応。declarativeNetRequestは0%。この限界の上でも段A/段Bの分担は妥当。
- 需要の傍証: cmuxに「WebKit⇔Chromiumのタブ切替が欲しい」という要望issueが立っている(#2803、Open)。同種のOSSは見つからなかった=Karuの立ち位置に競合なし。
- 詳細と全URL(発見40件+反証40件、[OK]/[NG]/[??]付き): `docs/prior-art-research-2026-09-19.txt`

## Phase 4 — 比較と報告
- [ ] 現行Chrome / Karu(WebKit)/ Karu(混在)の比較表
- [ ] crosscheck.sh でCodexに反証させる
- [ ] レビュー欄を書く

## レビュー
(未記入)
