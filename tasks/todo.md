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

## Chromium系エンジンでの拡張機能の実動作確認(09-20)— 完了
- [x] **確認できた最大の未検証項目が解消した。** Idaten管理下のHeliumプロファイルで、Chrome Web Storeから
      実際に拡張をインストールし、Secure Preferencesで動作を直接確認した。
- 経緯: 当初OneTabのCWSインストールが「Download interrupted」で失敗。原因はHelium公式の既知仕様
  (拡張ダウンロードは「Helium Services」という自社プロキシのセットアップ完了が前提、
  imputnet/helium#343参照)。本人が`chrome://settings/privacy/services`で同意・セットアップを完了したところ、
  Googleアカウント同期と手動インストールの両方で計12個の拡張が入った:
  uBlock Origin(同梱)・JSONVue・**OneTab**・Microsoft Clarity Live・**Claude(Claude in Chrome)**・
  GoFullPage・Chrome Remote Desktop・Save Image As PNG・RSS Subscription Extension・Evernote Web Clipper・
  extstore-fixups・Chromium PDF Viewer
- Claude拡張(`fcoeoabgfenejglbffodgkkbkcdhcgfn`)をSecure Preferencesで直接検証:
  `from_webstore: true` / `has_started_service_worker: true`(実際にコードが起動した証拠) /
  `granted_permissions` = `active_permissions`(全権限付与済み、withholding無し) /
  `disable_reasons` 無し(有効)。activeTab・tabs・scripting・sidePanel・debugger・nativeMessaging等、
  Claude in Chromeが必要とする権限が全て揃っている
- **結論: 「拡張が全部動く」の核心部分(実際のCWS拡張がKaru管理下のChromiumエンジンで動く)を実証できた。**
- [x] **Stylus・1Passwordも追加検証、全て正常動作を確認(09-20続き)。**
      Stylus: from_webstore=true, has_started_service_worker=true, disable_reasons=[]
      1Password: 同上(1回目はCWS側の「Chromeに切り替えてください」バナーで失敗、再読み込みで成功。
      同一拡張・同一環境でも再現しないことがある = CWSのブラウザ判定に多少の揺らぎがある模様)
      これで対象4拡張(Claude in Chrome・OneTab・Stylus・1Password)全てが実機で動作確認済み。
      「拡張が全部動く」の実証範囲を拡大できた

## AI提案機能の実機検証(09-20)— 既定OFFに変更
- [x] 機構自体は実機で正しく発火することを確認(拡張前提を明記したテストページで正しくYES判定・ダイアログ表示)
- [x] **しかし2つの重大な問題があり既定を無効化した**:
      ①誤検知——完全に無関係なexample.comに対し「Chrome拡張前提」という捏造理由付きでYES判定。
      ②可用性——起動直後は`isAvailable=true`だったが、数回の呼び出し後に`unavailable(appleIntelligenceNotEnabled)`へ
      変化し使用不能に(設定は変えていない、原因未確認)。
- [ ] 原因調査: モデル利用のクールダーム/上限の有無、プロンプトの改善(few-shot例の追加等)で誤検知率を下げられるか

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

## Karu.app を ~/Applications へ導入(09-19/20)
- [x] `make_app.sh --install` 実行。416KB。起動確認(クリーン状態、1タブ79.1MB: WebContent/GPU/Networking込み5プロセス)
- [x] テスト時のセッション・エンジンルール・Chromiumプロファイル・履歴(example.com等4件)を消去し、本人の初回起動をきれいにした
- 分かったこと(調査中に遭遇): 復元セッションの「選択中でない休眠タブ」はWKWebViewを作らないため、chromium対象ドメインでもナビゲーションが起きずChromiumへは渡らない(意図通り、コードを再現テストで確認)。
  「選択中タブ」はload()するので、対象ドメインならdecidePolicyForが正しく検知してhandOffする。手動での混同(複数のテスト起動が残っていた)で一時的に誤作動に見えたが、クリーンな再現では発生せず

## 大量タブ+動画+Web会議シナリオ(09-20、Codexと協働)
- [x] Codexへ独立依頼: 「常駐タブ数の制御が最優先」で私の結論と一致。Zoomは「常にWASM」ではなく
      2026-03のMeeting SDK更新でWebRTC優先+失敗時WASMフォールバックに変更されていたと判明(私の主張を訂正)。
      → **ネイティブZoomアプリへのURLスキーム誘導機能は根拠不十分のため実装しない(撤回)**
- [x] `enforceAwakeBudget()`: アイドル時間でなく「起きている背景タブの数」に上限(既定6)を設ける方式を追加。
      タブ切替/新規作成のたびに即時適用(60秒の定期チェックを待たない)。force:falseなので再生中/入力中タブは
      予算超過でも強制終了しない
- [x] 実測(13タブ=背景12+YouTube動画1、同一シナリオ):
      | | プロセス数 | メモリ |
      |---|---|---|
      | Chrome(通常運用) | 52 | 3,036.0 MB |
      | Karu(手動`hibernateOthers`) | 6 | 901.6 MB |
      | Karu(自動予算のみ、待機後) | 12 | 1,504.9 MB |
      自動の方が手動より多く残る(期待7個→実測8個、+1)。手動テストでも同じ+1パターンが出た
      (`hibernateOthers`実行2秒後の測定でWebContentが2個残存)。**JS評価(evaluateJavaScript)の完了待ちが
      測定タイミングに間に合わない非同期の取りこぼしと推測、要調査**(hibernate()のguard節 or 特定サイトの
      JS応答遅延の可能性)。ロジックの誤りではなく取りこぼしと見ているが未確認
- [ ] YouTube動画自体の重さはコーデック/動画依存で不安定(1本目Karu有利、2本目Chrome有利)。エンジン側の
      対策は保留。Codexの助言通り「大量タブの制御」に絞るのが正しい判断
- [ ] Google Meet/Teamsの実機負荷は未測定(実会議に入れないため)。WASM依存という根拠は無い(Codex確認済み)
- [x] hibernate()の非同期取りこぼし(+1個)を修正: force経路はJS応答を待たず即座に破棄。
      通常経路は「判定中フラグ」で二重発行を防ぎ、3秒でタイムアウトして次回に回す
- [x] **重大バグを発見・修正: `restoreSession()`が起動のたびに2回呼ばれ、セッションが倍々に膨張していた。**
      原因: マルチプロファイル対応の際、`main.swift`の`openWindow()`が内部で`controller.start()`を呼び、
      直後に`applicationDidFinishLaunching`がもう一度`browser.start()`を呼んでいた(見落とし)。
      実機再現: 200件→1回目で60件[暴走ガード]→保存→2回目の復元で120件、という倍増パターンをファイルログで確定。
      修正: `openWindow(autoStart: Bool)`を追加し、起動時はautoStart:falseにして明示的に1回だけstart()する。
      合わせて`restoreSession()`に**暴走ガード(直近60件のみ復元)**を恒久的に追加、超過時はNSLogで警告。
      さらに`newTab(skipUIRebuild:)`で復元ループ中の`rebuildTabBar()`/`saveSession()`をO(N²)からO(N)に修正
      (どちらか片方だけでも実際に本体が数GBまで膨張してクラッシュする事故だった。原因は動画・エンジンとは無関係)

## 1ブラウザで完結(09-22、本人決定: 重ね窓 → Heliumフォークの二段)— 第1段は実装済・運用実績ゼロ
経緯と一次資料: `docs/one-browser/`(Codex調査・Jev判定・Codexレビュー2回・差分)
- [x] Codex調査: SwiftのNSViewへ拡張全対応のChromiumを埋め込む公式手段はmacOSに無い(CEFは親NSView指定でAlloyに落ちる、cef_types_mac.h)
- [x] Jev判定(順番3通り入替・対照は両順正解): 今着手すべき=重ね窓 0.68〜0.84 / フォーク 0.02〜0.03。
      ただし「内容領域クリックでメニューバーがHeliumになる状態を完結と感じるか」= 感じない 1.00 → 第2段が要る
- [x] 第1段 実装: `ChromiumDock.swift`(Heliumを `--remote-debugging-pipe` で子起動・ポートは開けない)+
      Chromiumタブを Idaten のタブバーに並べ、Heliumの窓を内容領域へ重ねて追従、内容領域は透明の穴(HoledRootView)
- [x] 機械検査 `--selftest-dock`: 窓位置(CDPの実値)と内容領域が 開いた直後/窓の移動+縮小後/WebKit往復後 の3点で完全一致(3回実行)。
      Heliumは必要時のみ起動(起動前pid=-1)、Idaten終了で約20秒後にHeliumも正常終了、"Could not write into pipe" 0件
- [x] Codexレビュー11件のうち10件を修正(作成要求の取り違え・取消・SIGPIPE・flush無期限待ち・fd/子プロセス回収・
      起動直後の切断で状態消失・古い前面化・WebKitへ戻すが負ける・作成中のURL入力・背景タブの選択奪取)。
      Codex再レビュー(docs/one-browser/codex_review2.md): 完全5・部分5・未解決1+修正で入った問題4 → 全部に手を入れた:
      作成失敗時はWebKitへ戻し外のHeliumへ渡す / Heliumで閉じたタブは一旦外して10秒以内に切断されたら戻す(迷ったら残す)/
      WebKitへ戻したタブは明示の⌘⇧Eで再度切替可・古い状態を捨てる / 保留中の外部タブの題名更新 / shutdown後もfdを後始末 /
      マウス素通しの切替をイベント駆動に。この3回目の修正後の再レビューはまだ(自己検査は2回とも全段一致)
- [ ] **未検証: 穴越しのクリックがHeliumへ届くか・見た目(穴・タイトルバー)**。合成クリックは全画面のiTerm2に落ちて無効だった。
      画面収録の権限が無く撮影もできない → 本人の目で確認が要る
- [ ] Chromiumタブは休眠・常駐予算の対象外(従来の外部Heliumと同じ。統合するなら別途)
- [ ] Helium側の自分のタブ切替(⌃Tab等)は Idaten の選択に反映されない(CDPにタブ活性化イベントが無い)
- [ ] 拡張UI(Claudeのサイドパネル等)は重ねたHeliumの窓の中にそのまま出る想定。重ねた状態での実動作は未確認

### 第2段(Heliumフォーク)— 09-23: ビルド場所は **GitHub Actions(無料)** に変更
- **Helium 本体が GitHub Actions の macOS ランナーでビルドしている**(.github/workflows/build.yml → building.yml → build-phase.yml)。
  6時間のジョブ上限を、成果物を受け渡して最大10ジョブに分けて再開する方式で越えている。sccache も使用。
  署名の秘密が無ければ `codesign --sign -`(アドホック)に落ちるので、秘密なしでも完走する作り。
  → **Macを借りる必要も外付けSSDも不要。公開リポジトリならランナーは無料**
- [x] フォーク作成: yu010101/helium-macos・yu010101/helium。main を arm64 のみに変更(x86_64 は作らない)
- [x] 無改造のビルドを起動(run 35807801715, macos-latest, arm64)。まず「フォークでも完走するか」を確かめる
      → 失敗。build_job_01 で sccache が「gha cache の URL が無い」で起動できず全コンパイルが落ちた
- [~] sccache をローカルディスクのキャッシュにして再実行(run 35810642178)。09-23 15:49 時点で build_job_01 が
      3時間47分走行中(落ちていない)。1ジョブ6時間で切れて次のジョブへ引き継ぐ作り。完走は未確認
- [x] run 35810642178 は 09-23 19:4x に本人承認で取り消し。最後の梱包で落ちる見込みだった(19:20 判明)。`github_prepare_artifacts.sh` が証明書の有無を見ずに
      `security import` する。空の p12 の import は rc=1(一時キーチェーンで実測)で、`bash -e` により止まり、成果物のアップロードも行われない
- [~] `idaten` ブランチ(31ab862)で名前・アイコン入りのビルドを起動(run 35861397971、09-23 19:4x)。sanity 合格(全パッチ適用・offset なし・gn gen 成功)を確認してから
- [!] **run 35861397971 は終わらない**(09-24 08:50 判明)。siso が時間切れの打ち切り後、次の段で前の段の成果物をほぼ全部作り直す
      (2段目のコンパイル 19,750 個のうち 17,306 個が1段目と同じ)。段ごとに約2千個しか進まず、10段(上限)では 8.4万個に届かない
- [~] 修正(1da4977): sccache のキャッシュ(2段目の終わりで 1GiB)もビルド途中のファイルと一緒に段から段へ渡す。
      (run 35935724048 は下準備の段階で取り消し)**2段目のログで Cache hits が数千〜万単位になっていれば効いている**。未確認
- [~] **真因の最有力(Codex 指摘・手元で実証)**: 既定の tar 形式が更新時刻の1秒未満を切り捨て、siso がナノ秒で照合して全部作り直していた。
      f950834 で `tar --format=pax`(pax+zstd+展開の往復でナノ秒一致を確認)+ pipefail。run 35936651056 で検証中(09-24 09:1x 起動)。
      判定: 2段目で「1段目で完了した部品の作り直し」がほぼ0になるか / Cache hits。run 35861397971 は Codex の推奨で取り消し
- macmini-m4: Xcode は ~/Applications に2つあるが未選択(xcode-select は CommandLineTools)。**空き 18GB に減少中**(09-23 32GB → 09-24 18GB)
- [x] **フォーク版 Idaten のビルドが完走**(run 35936651056、f950834、09-25 13:36)。7ジョブ・作り直し0。dmg 112.4MB(sha256 9694…2aaa、hashes.md と一致)
      → `~/idaten-fork/dist/Idaten.app`(344MB、アドホック署名し直して codesign --verify --deep --strict 合格)
      実機確認(09-25 21:4x): CFBundleName/Display=Idaten・ID dev.idaten.chromium・メニューバーのアプリ名=Idaten・アイコン=Idaten・
      プロファイルは `~/Library/Application Support/dev.idaten.chromium` に新規作成、`net.imput.helium` は起動前後で不変(ls -laR の sha 一致)・
      キーチェーンは「Idaten Storage Key」で別。Sparkle は同梱されていない
      **未解決**: アプリメニューの項目は「Helium について」「Helium を隠す」「Helium を終了」のまま(Helium の文言置換)。拡張の動作は未確認。
      Swift 版 Idaten.app と同名(ID は別)なので ~/Applications には入れていない
- [~] アプリメニューの「Helium について/を隠す/を終了」→ `patches/idaten/core/idaten-product-name.patch`(641533c)。
      IDS_PRODUCT_NAME / IDS_SHORT_PRODUCT_NAME / IDS_APP_MENU_PRODUCT_NAME(3つとも translateable=false)を Idaten に。
      sanity 合格(run 36136887906)。ビルド run 36138082313 を 09-25 起動(約1日)
- [x] フォーク版で拡張が動く(09-25): 拡張入りプロファイルの**コピー**で起動し、CDP で service worker を確認。
      Claude・OneTab・Stylus・1Password・GoFullPage・Evernote 等 + uBO(component)が起動、wikipedia.org 表示可
- [x] Swift 版の接続先(45f7d4a): Idaten Engine.app を最優先、フォーク版は chromium-profile-idaten(初回だけ元をコピー)。
      --selftest-dock をフォーク版と Helium で同条件実行し結果が完全一致。**未導入**(~/Applications/Idaten Engine.app は置いていない)。
      導入するとログイン(Cookie)はやり直し(キーチェーンの鍵が別)。本人判断待ち
- [ ] 窓の重ね合わせが内容領域より上に 70px ずれる(dockChromiumWindow=true。Helium でも同じ。以前は完全一致だった)→ 別途調査
- [x] 下ごしらえ: フォークのブランチ `idaten`(31ab862)
      - `patches/idaten/macos/idaten-branding.patch`: 名前 Idaten / バンドルID・プロファイル置き場 `dev.idaten.chromium` / キーチェーン `Idaten Storage Key`
        (本物の Helium とプロファイル・キーチェーンを共有しないため)。同じ3ファイルに触る6本を series の順で当てて最終値まで確認
      - アイコン: Idaten の AppIcon.icns から actool で Assets.car(AppIcon/Icon)と app.icns を生成
      - 梱包: 証明書が無いときはキーチェーンを作らない / Sparkle の差分は作らない / アプリ名は `resources/product_name.txt`
      - Sparkle はフォークに鍵が無いのでビルドされない → 本家 Helium に「更新」されて置き換わる心配はない
      - lint 合格。sanity(本物の Chromium にパッチを当てて gn まで)は実行中
- 休眠拡張の同梱は Chromium の C++ パッチにしない(uBO 方式は9ファイル・手元でコンパイル確認できない)。
  Idaten 本体が CDP の `Extensions.loadUnpacked` で起動のたびに読み込む方式にする
- 既知の制約: 設定画面などの文言は「Helium」のまま(Helium の name_substitution が翻訳IDと連動しているので触らない)
- キャッシュは次の実行へ引き継がれない(sccache をランナーの一時ディスクに置いているだけ)。**毎回約14時間のフルビルド**
- [ ] 1Password 連携は Developer ID 署名が要る(アドホック署名では不可)
### (旧案・保留) M4 mini + 外付けSSD / クラウドMac
- 実測(09-22): このMac 空き24GiB・外付けなし / macmini-m4 = M4・24GB RAM・空き51GB・**brew も Xcode も無し** /
  macmini-m2 = 3TB外付け(空き2.5TB・大文字小文字区別APFS・USB)だが ssh から TCC で読み書き不可、8GB RAM
- 09-23 Scaleway を試した結果: 支払い+本人確認で M1-M/M2-M/M2-L の枠は付いたが **全機種 在庫切れ**、M4系は **枠0(要申請)**。
  サーバーは1台も作っていない(課金ゼロ)。GitHub Actions で済むならこの経路は不要
- 手元のビルド用スクリプト `tools/cloudbuild/build_helium.sh` は、借りたMacで走らせる場合に使える(Codexレビュー9件を反映済み)
- [x] 中間形: `extension/`(MV3「Idaten」)= Swift版の休眠規則を移植(背景タブ上限6・放置10分・再生中/入力中は除外・例外ドメイン)。
      判断は policy.js の純関数で node 試験6件合格(`node extension/policy.test.mjs`)。フォーク時はそのまま同梱できる
- [x] 実物のHelium(一時プロファイル)で3つの規則を確認(09-23):
      ①上限: 背景12枚+選択1枚 → 起きている背景タブ=6・休眠7
      ②例外ドメイン: 上限2で背景4枚を休眠させても example.org だけ起きたまま
      ③入力中: textarea に書きかけがあるタブは起きたまま、同条件の他タブは休眠(記録に busy:1)
      途中で「1枚しか眠らない」と誤読した。実際はタブ作成のたびに少しずつ適用される動きだった。
      追跡できるよう `lastRun` に background/busy/picked/discarded/failed を残すようにした(握り潰していた discard の失敗も記録する)
- [x] Claude連携の検証B(Codex手順書 docs/one-browser/codex_claude_verify.md): Helium上のClaude拡張→Claude Code用ネイティブホストへ ping → **pong**。
      manifestのコピー不要(HeliumがChrome側の登録を探す)。プロファイルのコピーで実施(本人のプロファイルは本人が使用中だったので触らず)
- [ ] 検証D(`claude -p --chrome` でページを実際に読む)は未実施 — 本人の通常Chromeにも繋がる恐れがあるので、本人がいる時に対話で
- [ ] 1Password: ネイティブホストの登録が見つからない(入っているのは 1Password 7)。最新版+「Add Browser」が要る
- Jev(09-22、対照は両順正解): 中間形で要望は満たされたか = 満たされた 0.62〜0.74 / 次の一手 = ビルド環境 0.57〜0.64(3順とも1位)
- Codex調査(docs/one-browser/codex_fork_answer.md): helium-macos は quilt パッチ方式。この Mac(M1 Pro/16GB/空き24GiB)では不足、
  作業予算 200〜300GB を推奨(公式の最低値は無い)。1Password はDeveloper ID署名が要る。Heliumは Chrome の NativeMessagingHosts も探すパッチ持ち
- [ ] 置き場所を決める(外付けSSD or 別Mac)
- [ ] 1日検証: 既存HeliumでClaude Code ↔ Claude拡張の往復を1本通す(`claude --chrome` → `/chrome`)

## Chrome に対する差別化(09-23、Jev+Codex+サブエージェントと並走)

### 判定
- Jev(順番3通り入替で一致・対照も両順正解): 本人が「圧倒的に良い」と感じるのは **メモリ 0.96**
  (広告遮断・タブ・プライバシーはほぼ0)。乗り換えを阻む最大の理由は **拡張が既定エンジンで動かない 0.42〜0.65**、次に同期 0.24〜0.37
- Codex: Chrome の Memory Saver は **タイマーが2〜6時間**。15分以内の計測では絶対に働かない
  → 公平な対照は「Chrome に同じ休眠拡張を入れた条件」。設定は Local State の performance_tuning.high_efficiency_mode
- サブエージェント: **既定では CDP が立たず、Chromium タブを取り込む実装が丸ごと死んでいた**。
  実測で Idaten の履歴34件 / Helium 1,218件、ブックマーク 0件 / 842件

### 入れたもの(すべて実測で確認、本人のデータには触らない隔離環境)
- [x] Chromium タブの取り込み(窓は重ねない。mirrorChromiumTabs 既定 true)。Helium 側で開いたタブが Idaten に出る
- [x] 拡張を1手で起動(⌥⌘E)。CDP Extensions.triggerAction。**Claude のサイドパネルが実際に開くことを確認**。
      存在しない ID を渡すとブラウザが落ちうるので、ディスクの manifest に載っている ID しか渡さない
- [x] Chromium 側のブックマーク・履歴の取り込み(読むだけ・片方向)。実測 801件 / 1,212 URL
- [x] ドメイン規則の一覧(追加・削除)。これまで「規則があるサイトは Chromium で開くので Idaten で開けず、
      規則を消せない」片道切符だった
- [x] 受け渡しでスクロール位置を持っていく(1500px → 1500px)。戻すときに interactionState を捨てない
- [x] 設定の読み戻しの不具合(dockChromiumWindow / bookmarkBarVisible が復号されず毎回リセット)
- [x] 外部へ渡したタブで ⌘⇧E を再度押すと2枚開く問題
- [x] 現在のメモリ・プロセス数・タブの状態をツールバーに表示(推定や他ブラウザとの比較は出さない)
- [x] タブを失わない: 復元で60件超を捨てていたのをやめ全件復元。判定できないときは眠らせない側へ。
      200件の保存→復元で URL・順序・選択位置が完全一致(0.55秒)

### 計測
- [x] 第1版(12ページ・3回): 放置60秒後の中央値で Chrome 104プロセス 6,250 MiB / Idaten 11プロセス 881 MiB
- [x] 第2版: 観測点60s/300s/900s・区間中央値とピーク・固定動画・両者とも新品プロファイル・順序効果の相殺
- [~] bench4(09-23 15:03、`measurements/bench4-ext-150306`)は **4組中3組目の途中で止まった**(idaten-3 が空)。
      拡張は3組とも生きていた(workerAlive)が、**動画が読み込み時点で再生されていたのは3組目だけ**
      (1・2組目は playing:false)→ 条件がそろっていないので結論には使わない。参考値(300s中央値): Chrome+拡張 2,701〜3,694 MiB / Idaten 259〜579 MiB
- [ ] **chrome_ext 条件はやり直しが必要**。CDP で入れた拡張は起動し直すと消えるため、
      測っていたのは実質「拡張なしの Chrome」だった(実測で確認)。同じプロセス内で
      「入れる→開く→測り終わるまで生かす」形に作り直し済み(run_chrome_ext.mjs)。拡張が動いていることを確かめてから測る
- [ ] 公開主張には条件ごと10組。20/60/200タブ版

### 訂正
- 「1Password はネイティブホストの登録が見つからない」は**誤り**。登録は両方ある。
  原因は 1Password 7 の Extension Helper が起動していないこと。1Password 8 を入れるか 7 の Helper を有効にする

### 手を付けていない
- Cookie の移送(ログイン状態の持ち込み)。サイトによって効くかが変わるので、
  「本人が普段ログインしている10サイトで何割効いたか」を測ってから決める

## Phase 4 — 比較と報告
- [ ] 現行Chrome / Karu(WebKit)/ Karu(混在)の比較表
- [ ] crosscheck.sh でCodexに反証させる
- [ ] レビュー欄を書く

## レビュー
(未記入)
