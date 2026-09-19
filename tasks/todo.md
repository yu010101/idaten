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

## Phase 1 — Chromium系3候補の実測
- [ ] ディスクゲート(空き8GB未満で停止)
- [ ] ①Chrome+uBO Lite ②Helium ③Brave を専用 user-data-dir で計測(各3回)
- [ ] 軽量化ポリシーが `chrome://policy` に出るか確認
- [ ] 必須拡張の動作表(Claude in Chrome / OneTab / Stylus / 本人指定)— ログインが要る分は本人へ
- [ ] 採否を記録

## Phase 2 — Chromiumエンジン層
- [ ] `TabEngine` プロトコル / `ChromiumProcessEngine`(段A)
- [ ] `config/policies.json` `config/flags.txt` 外出し
- [ ] サイト別ルール `engine_rules.json`
- [ ] 段B: CEF埋め込み実験(1日で打ち切り・採否理由を記録)

## Phase 3 — Karu本体(Swift+WebKit)
- [ ] タブ / URLバー / 戻る進む再読込 / ショートカット
- [ ] 履歴(SQLite)/ ダウンロード
- [ ] 広告遮断(EasyList+AdGuard Japanese → WKContentRuleList、変換器のライセンス一次確認)
- [ ] タブ休眠
- [ ] エンジン切替 ⌘⇧E + Cookie非共有の明示
- [ ] 実験: WKWebExtensionController
- [ ] `make_app.sh`(~/aiboard から型を流用)

## Phase 4 — 比較と報告
- [ ] 現行Chrome / Karu(WebKit)/ Karu(混在)の比較表
- [ ] crosscheck.sh でCodexに反証させる
- [ ] レビュー欄を書く

## レビュー
(未記入)
