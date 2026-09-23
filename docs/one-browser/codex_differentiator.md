codex
**現時点で最も有望なのは「多数のタブを残したまま、使っていないページのメモリを減らす」です。ただし、「Chromeより約70%省メモリ」を製品全般の性能として主張できる証拠はまだありません。** 901.6MBは手動休眠時、自動制御では1,504.9MBという記録です。Chrome側にも休眠機能があるため、設定を揃えた比較が必要です。[実測記録:106](/Users/yu01/idaten-browser/tasks/todo.md:106)、[Chrome公式](https://support.google.com/chrome/answer/12929150?hl=en)

読み取りのみで分析しました。ファイル変更・ブラウザ起動・新しい負荷計測はしていません。以下の既存実測は記録からの引用、工数・優先順位・合格基準は私の提案です。

**まず、評価の前提となる現状を訂正します。**

- **Chromiumは現在、既定では別窓です。** 重ね窓は操作上の問題を受けて既定OFFになっています。「一つのウィンドウで拡張とWebKitを自然に使える」は現状の売りにできません。[Settings.swift:32](/Users/yu01/idaten-browser/Sources/Idaten/Settings.swift:32)、[引渡し処理:839](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:839)
- **広告遮断は種リストだけではありません。** todoの「変換未着手」は古く、現在はEasyList変換JSONの同梱・読込経路があります。私の読み取り集計では79,091ルール。ただし、ルール数は遮断成功数ではありません。[同梱処理:19](/Users/yu01/idaten-browser/make_app.sh:19)、[読込処理:51](/Users/yu01/idaten-browser/Sources/Idaten/AdBlock.swift:51)、[変換範囲:12](/Users/yu01/idaten-browser/rules/NOTICE.md:12)
- **「拡張が全部動く」は証拠より強い表現です。** インストール・worker起動・権限付与、Claudeのnative hostへのpongは確認記録がありますが、ページ操作の往復と1Passwordのデスクトップ連携は未完です。[導入検証:60](/Users/yu01/idaten-browser/tasks/todo.md:60)、[残る検証:174](/Users/yu01/idaten-browser/tasks/todo.md:174)

**1．差別化候補の評価**

工数は、現コードに詳しい開発者1人による追加実装と検証の概算です。小＝数日、中＝1〜3週間、大＝数週間以上。実測に基づく見積もりではありません。

| 候補・判断 | この実装で出せる価値 | 嘘にならない測り方 | 追加コスト | Chromeでもできるか |
|---|---|---|---|---|
| **メモリ：最有力、数値は未確定** | WebKit主体＋背景WebViewの破棄で、保持するページを減らす。13タブの既存記録は有望。[休眠実装:741](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:741) | Idaten・WebKit関連・Helium関連の**全体**を合算。自動運用と手動強制を別集計し、再訪待ち時間も併記する。 | 中。計器は既存、比較条件と全プロセス捕捉の整備が必要。 | **休眠による削減はできる。** Memory Saverと拡張によるdiscardがある。WebKitとの基礎負荷差がどれだけ残るかは未測定。[標準機能](https://support.google.com/chrome/answer/12929150?hl=en)、[API](https://developer.chrome.com/docs/extensions/reference/api/tabs) |
| **起動時間：候補、優位未実証** | 復元時に選択タブ以外のWebViewを作らない。ただし起動は広告ルールの読込完了を待つ。[復元:1590](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1590)、[起動:288](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:288) | 起動要求→①URL欄操作可能、②選択ページ表示、③そのページで操作成功を別測定。初回・再起動・Helium初回起動を分ける。 | 計測は小、改善は中。 | **追随可能性が高いという推測。** 遅延復元だけで独占的な優位とはいえない。同一セッションで実測が必要。 |
| **広告遮断：最も目で分かりやすい補助価値** | 初期設定で種リスト＋EasyList変換ルールを適用。[既定設定:31](/Users/yu01/idaten-browser/Sources/Idaten/Settings.swift:31) | 同じページで広告の表示、実際に到達した通信、転送量、表示時間、サイト破損を比較。自製ページの陽性対照と実サイトを併用する。 | 中。更新・サイト別解除・破損対応まで必要。同梱更新は現在サイズ比較。[更新処理:35](/Users/yu01/idaten-browser/Sources/Idaten/AdBlock.swift:35) | **できる。** Chrome＋uBO Liteを対照に入れる。差は主に「導入不要」。変換で落ちるルールもあり、遮断品質で勝つとは未証明。[uBO Lite公式](https://github.com/uBlockOrigin/uBOL-home)、[変換制約:12](/Users/yu01/idaten-browser/rules/NOTICE.md:12) |
| **タブ大量運用：本命だが、現状のまま宣伝不可** | 背景WebKitタブを6枚目安に減らし、休眠状態から復帰する。[予算制御:723](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:723) | 20・60・200タブでメモリ、切替応答、復帰時間、再起動後の件数、入力保持を測る。**残ったタブ数だけでなく失った作業も数える。** | 中〜大。後述する60件切捨てと保護判定の修正が先。 | **大半はできる。** このリポジトリの拡張自体がChrome APIで予算休眠を実装している。Chromeでの実動作は別途検証。[policy.js:16](/Users/yu01/idaten-browser/extension/policy.js:16)、[discard呼出し:44](/Users/yu01/idaten-browser/extension/background.js:44) |
| **プライバシー：限定した主張なら可能** | 特定の第三者広告・計測ドメイン遮断と、プロファイル別データ分離。[遮断対象:14](/Users/yu01/idaten-browser/Sources/Idaten/AdBlock.swift:14)、[データストア:143](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:143) | 空白起動・閲覧・検索・拡張利用時の送信先、送信項目、Cookie分離を検査。「追跡ゼロ」という総称は使わない。 | 中〜大。WebKit外の通信とHelium・拡張も対象。 | **相当部分はできる。** 第三者Cookie設定と遮断拡張がある。Idaten固有のプライバシー優位は未実証。[Chrome公式](https://support.google.com/chrome/answer/95647?hl=en) |
| **拡張との両立：乗換え条件であり、単独の優位ではない** | 拡張不要の閲覧をWebKitへ、必要な作業を専用Heliumへ分けられる。[Engines.swift:104](/Users/yu01/idaten-browser/Sources/Idaten/Engines.swift:104) | 拡張ごとの実作業を、導入→利用→休眠／再起動→再利用まで確認。混在時の総メモリと切替手数も測る。 | 別窓運用の整備は中。完全な一体化は大。 | **拡張利用はChromeの方が自然。** Idatenが勝てる可能性は、拡張を維持しつつ普段の負荷を減らせる場合に限る。これは未検証の仮説。 |

「使った瞬間に分かる」という条件では、**広告が消えることは直接見えるが模倣されやすい。メモリ差は有望だが、現在量と休眠状態を見せないと伝わりにくい**、という評価です。

なお、プライバシーについては、faviconを`URLSession.shared`で取得する経路があり、WebKitのルール適用経路を通りません。これが実際に追跡を起こすとは未確認ですが、「すべての通信に同じ保護が効く」とはいえません。[favicon取得:1674](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1674)

**2．既存のメモリ比較の穴と、公平な再測定条件**

既存数字を計算すると、手動休眠時は**70.30%減**、自動制御時は**50.43%減**です。しかし、これは記録値同士の算術であり、期待削減率の推定ではありません。[元の数字:106](/Users/yu01/idaten-browser/tasks/todo.md:106)

読み取れる範囲の穴は以下です。条件が記録されていないものは、「違っていた」と断定せず「揃っていたと確認できない」と判定しています。

| 穴 | 比較への影響 |
|---|---|
| **手動強制休眠と通常Chromeの比較** | 自動的な製品性能と、利用者が意図的に停止した効果が混在する。force経路は再生・入力保護も迂回する。[実装:741](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:741) |
| **Chromeの省メモリ設定が不明** | Memory Saverの有無・強度・例外次第で背景タブの保持状態が変わる。[Chrome公式](https://support.google.com/chrome/answer/12929150?hl=en) |
| **同じ13タブの中身・操作履歴を再現できない** | URLだけでなく、リダイレクト、スクロール、読み込み成功、広告配信、タブを見た順序が負荷を変える。固定シナリオはtodoで未完。[todo:11](/Users/yu01/idaten-browser/tasks/todo.md:11) |
| **Chrome通常プロファイルとIdatenの条件差** | 拡張、ログイン、他ウィンドウ、同期、worker、長期運用による状態が混ざる。「通常運用」としか記録されていない。[todo:109](/Users/yu01/idaten-browser/tasks/todo.md:109) |
| **広告遮断の差** | エンジン差・休眠差・読み込んだ広告の差を分離できない。製品既定比較としては有効でも、WebKit自体の優位の証拠にはならない。[遮断読込:51](/Users/yu01/idaten-browser/Sources/Idaten/AdBlock.swift:51) |
| **動画の実条件が未固定** | 同じURLでもコーデック、解像度、fps、再生位置、広告、バッファ、停止状態が違い得る。既存記録でも動画によって優劣が逆転。[todo:116](/Users/yu01/idaten-browser/tasks/todo.md:116) |
| **待機時間・採取時点が不十分** | 休眠要求から解放まで非同期。記録には手動実行2秒後の残存がある。一瞬の値では安定状態もピークも分からない。[todo:112](/Users/yu01/idaten-browser/tasks/todo.md:112) |
| **各1回、順序効果とばらつきが不明** | キャッシュ、温度、メモリ圧迫、バックグラウンド処理の影響を切り分けられない。最大差の回だけを代表にはできない。[記録:106](/Users/yu01/idaten-browser/tasks/todo.md:106) |
| **キャッシュ・初回処理・版の不明確さ** | Webキャッシュ、ルールコンパイルキャッシュ、ブラウザ／OS版、測定時のコード修正前後が再現条件に必要。[ルールキャッシュ:68](/Users/yu01/idaten-browser/Sources/Idaten/AdBlock.swift:68)、[修正記録:119](/Users/yu01/idaten-browser/tasks/todo.md:119) |
| **プロセス集合の正しさは別問題** | 29プロセスで数値が一致しても、対象を全部拾った保証ではない。WebKitのresponsible PID、既存Heliumへの転送、複数プロファイル、native hostの帰属を別検査する必要がある。[計器:74](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift:74)、[転送仕様:104](/Users/yu01/idaten-browser/Sources/Idaten/Engines.swift:104) |
| **計測失敗が合計から黙って落ちる** | `proc_pid_rusage`失敗はnil、集計は`compactMap`。取得成功したプロセス数だけでは「対象が少ない」のか「取りこぼし」か分からない。プロセス列挙と採取も同時ではない。[計器:64](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift:64)、[集計:147](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift:147) |
| **メモリ以外の対価を測っていない** | 再訪時の再読込、入力消失、CPU、通信量、動画品質が悪化していれば「圧倒的に良い」とは限らない。現計器のCPU差分も、終了プロセスを含む厳密積算ではない。[計器:164](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift:164) |

さらに、表示単位は修正が必要です。計器は1,048,576で割っているため、現在の「MB」は正確には**MiB**です。footprintは圧縮・swapを含む会計値であり、「今その分のRAMが空いた」とは同義ではありません。[単位処理:96](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift:96)、[Appleの説明](https://developer.apple.com/videos/play/wwdc2022/10106/)

**推奨する比較は「製品の既定比較」と「差の原因を調べる比較」の二本です。**

- 製品比較：新規Chromeの既定設定と、Idatenの既定設定。組込み遮断などの差は残し、明記する。
- 原因比較：広告遮断を両方OFF、ChromeのMemory Saverを明示設定し、Chrome＋Idaten休眠拡張も追加する。Helium単体を加えると、二重エンジン構成の価値も判断できる。休眠拡張は既存実装を利用可能。[extension/background.js:32](/Users/yu01/idaten-browser/extension/background.js:32)

具体条件は次を提案します。

| 条件 | 固定方法 |
|---|---|
| URL集合 | まず**背景12＋固定動画1の13件**をファイル化。別に20・60・200件。広告サイトだけに偏らず文書・業務アプリも含め、シナリオ別に報告。失敗・リダイレクトも記録する。 |
| 同じ操作 | 同じ順序で各タブを選択し、読込確認後に同じ操作を行う。最後は同じ動画タブ。大量同時起動は別シナリオにする。 |
| 同じ待機 | 最後の操作から**60秒・5分・15分**を共通観測点にする。起動から全期間1秒間隔で採取。各観測点の直前30秒の中央値と、全期間のピークを残す。 |
| 動画 | 同じ素材・再生位置・解像度・fps・再生時間。実際のコーデック、フレーム落ち、広告有無を記録。厳密対照用の固定動画とYouTube実利用を分ける。 |
| 拡張 | 拡張なし試験と、同じID・版・設定・認証・実作業の試験を分離。Idatenでは必要タブをHeliumに置く。**WebKit上で実行されない拡張を「同じ拡張条件」と数えない。** |
| キャッシュ | 空の専用データストア／プロファイルと、同じ予備走行をした温キャッシュを別集計。ブラウザキャッシュとOSキャッシュは区別。初回ルールコンパイルも別記。 |
| 起動状態 | 両者とも対象ブラウザプロセスが存在しない状態から開始。常駐済み起動は別枠。起動方法を揃え、responsible PIDを確認する。[計器の起動注意:6](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift:6) |
| マシン条件 | 同一Mac・OS、電源・低電力設定・画面サイズ・ネットワーク・他アプリ負荷を固定。メモリ圧迫とswapも記録。比較対象は同時実行しない。 |
| 反復 | 機構確認3回、公開判断には**条件ごとに最低10組**を提案。AB／BAを均等にし、できれば複数日に分散。中央値、ばらつき、対応する差の信頼区間を報告する。1秒サンプルを独立反復として数えない。 |
| 公開範囲 | 単一Macの結果は、その機種・OS・シナリオに限定。広い製品主張には別メモリ容量・別機種でも再確認する。 |

読み取り時点で`tools/bench/`も存在しましたが、**まだこの条件を満たしません**。固定順の3回、瞬間値2点で、URL一覧にはコメントにある動画がありません。また、`--bench`設定前に通常プロファイルのデータストアを作るため、Chrome側の新品プロファイルと同じキャッシュ条件とはいえません。実行せず、静的に確認した指摘です。[bench.sh:16](/Users/yu01/idaten-browser/tools/bench/bench.sh:16)、[測定:31](/Users/yu01/idaten-browser/tools/bench/bench.sh:31)、[URL一覧:1](/Users/yu01/idaten-browser/tools/bench/urls.txt:1)、[main.swift:39](/Users/yu01/idaten-browser/Sources/Idaten/main.swift:39)、[データストア:143](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:143)

**3．製品内で嘘にならない「軽さ」の表示**

最初に実装するなら、**現在の合計footprintと、管理できているタブの状態**です。

| 表示案 | 判定・条件 |
|---|---|
| 「現在のメモリ負荷：○MiB」 | **可。** Idaten本体＋関連WebKit＋管理下Heliumの合計、最終更新時刻、測定範囲を表示。取得漏れがあれば「一部未取得」とする。root PIDだけの既存集計を無条件に「全体」と呼ばない。[計器:74](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift:74) |
| 「読み込み中／稼働中／休眠中／未読込／Chromiumへ引渡し済み」 | **可。** 実状態から集計する。現在の`isHibernated`は「WebViewなし＋URLあり」なので、未読込の復元タブまで含む。WebViewを持つ引渡し元とHeliumの実タブも区別が必要。[Tab.swift:26](/Users/yu01/idaten-browser/Sources/Idaten/Tab.swift:26)、[判定:36](/Users/yu01/idaten-browser/Sources/Idaten/Tab.swift:36) |
| 「背景タブ上限6」 | **現状では不正確。** 「背景WebKitタブの目標6、保護対象を除く」なら妥当。予算はウィンドウ単位で、眠らせられない候補の補充探索もない。[制御:727](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:727) |
| 「休眠操作の前後で○MiB減少」 | **条件付きで可。** 操作前後の固定窓の中央値差、時刻、対象範囲を示す。ほかの変化も含む観測差であり、休眠だけの因果効果とは表示しない。 |
| 「推定○MiB節約」 | **条件付きで可だが、初期版では非推奨。** 下記の推定条件が必要。 |
| 「Chromeなら○GB」「常に70%節約」「休眠1枚＝○MB」 | **現状不可。** 対照条件もタブごとの帰属も成立していない。共有プロセスや残る`interactionState`があるので、休眠タブの使用量をゼロとも呼べない。[状態保持:14](/Users/yu01/idaten-browser/Sources/Idaten/Tab.swift:14) |

推定節約量を出すなら、少なくとも次を満たす必要があります。これは表示設計の提案です。

- 同じエンジン・サイト種別・状態について、**休眠あり／なしの対応試験**でモデルを作る。
- 共有プロセスをタブごとに重複計上しない。過去の削減量を足し続けて「累計でRAMを節約」としない。
- 推定であること、比較基準、測定日、適用範囲、不確実性の幅を表示する。
- 未読込タブ、未測定サイト、古い測定、混在エンジンなど、適用できない状態では数値を出さない。
- 復帰時の待ち時間も併記する。

広告についても、現在の仕組みから**正確な「○件ブロック」カウンタを出す根拠はありません**。読み込んだルール数や、ON/OFF時のリソース数の差をブロック件数に置き換えないでください。[AdBlock.swift:9](/Users/yu01/idaten-browser/Sources/Idaten/AdBlock.swift:9)

**4．乗換えの最大障害3つ**

順位はユーザー調査による確定順位ではなく、現実装と対象拡張からの私の判断です。Jevの選択確率も、実利用者の離脱率としては扱いません。[Jev出力](/Users/yu01/idaten-browser/docs/one-browser/jev_answers3.json:1)

| 障害 | 現実装で潰せるか |
|---|---|
| **① 必須拡張を、普段の全タブで使えない** | **部分的。** Heliumに渡したタブでは検証を進められるが、通常のChrome拡張APIからSwiftのWKWebViewタブを一括管理する統合はない。OneTab・Stylus・Claude・1Passwordの用途によっては、多くのタブをHeliumへ寄せる必要がある。そうなったときの省メモリ効果は再測定が必要。[タブ構造:9](/Users/yu01/idaten-browser/Sources/Idaten/Tab.swift:9)、[Chrome tabs API](https://developer.chrome.com/docs/extensions/reference/api/tabs) |
| **② ログイン・パスワード・同期・作業環境を持ち込めない** | **部分的。** ブックマーク・履歴の移行はあるが、パスワードは対象外、拡張は再導入。WebKit→ChromiumでCookie・ログインは引き継がれない。継続的な端末間同期を提供する実装も今回の読取範囲では確認できない。[ChromeImport.swift:4](/Users/yu01/idaten-browser/Sources/Idaten/ChromeImport.swift:4)、[拡張移行:108](/Users/yu01/idaten-browser/Sources/Idaten/ChromeImport.swift:108)、[切替説明:824](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:824) |
| **③ 作業を失わず、Chromeと同じように操作できるという信頼** | **データ保全は修正可能。一体的操作は現構成で未解決。** 60件超の復元切捨て、入力保護の限界、別窓への移動が障害になる。[復元:1597](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1597)、[入力判定:753](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:753)、[重ね窓評価:32](/Users/yu01/idaten-browser/Sources/Idaten/Settings.swift:32) |

①の合格条件は拡張の起動ではなく、実作業の完了です。Claudeは公式資料でも、拡張ヘルプの他Chromium非対応と、Claude Code資料の複数Chromium接続説明が併存しています。**Heliumで動作した事実と、公式対応保証を区別**してください。[拡張ヘルプ](https://support.claude.com/en/articles/12012173-get-started-with-claude-in-chrome)、[Claude Code公式](https://code.claude.com/docs/en/chrome)

1Passwordも導入成功だけでは不十分で、追加ブラウザ登録・署名条件と、解除・保存・自動入力の確認が必要です。[1Password公式](https://support.1password.com/additional-browsers/)

③には具体的な修正点があります。現在の休眠判定は、フォーカスのある入力欄とトップ文書の音声・動画要素を見ています。フォーカスを外した下書き、iframe内の編集、WebRTC送信・画面共有などを網羅していません。また、JS評価エラー時は既定値falseで休眠する経路があり、応答待ちの間に選択されたタブかどうかの再確認もありません。これは静的コードからの指摘で、実機での作業消失再現はしていません。[休眠処理:753](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:753)

**5．次に実装すべき3つと完成の定義**

以下の数値は、既に達成した性能ではなく、提案する合格基準です。

| 優先順 | 実装するもの | 測定可能な完成の定義 |
|---|---|---|
| **1** | **タブを失わない保存・復元と、安全な休眠**。60件超を消す処理をなくし、遅延復元で負荷を抑える。選択状態を休眠確定直前に再確認し、判定失敗は保護。下書き・会議・サイト例外を扱い、保護対象を飛ばした後も候補を探す。 | 200タブを保存→再起動する試験を10回行い、URL・順序・選択タブの欠落／増殖ゼロ。強制終了後は最後に保存完了した状態を回収。入力・iframe・再生・会議・JSエラー・判定中タブ切替の試験で、保護対象の誤休眠ゼロ。休眠可能な背景タブだけなら操作終了5秒以内に目標6以下。根拠となる現欠陥：[復元:1597](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1597)、[予算:728](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:728)、[判定:753](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:753) |
| **2** | **隔離された比較実行器＋現在量・休眠状態の表示**。既存benchを拡張し、Chrome／Idaten自動／混在／Chrome＋同じ休眠拡張を比較。PID一覧と取得失敗を記録する。 | 通常利用者のCookie・履歴・設定・セッションに変更なし。前述の冷／温キャッシュ条件を各10組完走し、生データから集計を再生成可能。代表状態でApple計器との合計差5%以内を再確認し、対象プロセスの取りこぼしゼロ。UIは同じ集計値を表示し、欠測を明示。**差が出なかった結果も合格した測定結果として残す。** [既存計器検証:8](/Users/yu01/idaten-browser/tasks/todo.md:8)、[現在のbench:31](/Users/yu01/idaten-browser/tools/bench/bench.sh:31) |
| **3** | **必須拡張と移行の完了を確認できる導線**。プロファイルごとの移行結果、Heliumへの明示的引渡し、再ログイン案内、拡張別の確認状態を設ける。 | 指定4拡張で、Claudeのページ読取・操作、OneTabの回収／復元、Stylusの保存／再適用、1Passwordの解除／保存／入力が各10回成功し、再起動後も成功。Chrome元データに変更なし。ブックマーク移行件数が一致し、再移行で重複しない。WebKitで非対応の機能と別窓動作を明示。混在状態でも第2項の計測を完了する。[残る拡張試験:174](/Users/yu01/idaten-browser/tasks/todo.md:174)、[移行実装:30](/Users/yu01/idaten-browser/Sources/Idaten/ChromeImport.swift:30) |

Heliumフォークへ全面移行する場合は、**WebKit主体で得た901.6MBという結果を引き継げません**。休眠方針は移植できますが、性能の根拠は新しい構成で取り直す必要があります。[フォーク計画:151](/Users/yu01/idaten-browser/tasks/todo.md:151)
tokens used
121,135
**現時点で最も有望なのは「多数のタブを残したまま、使っていないページのメモリを減らす」です。ただし、「Chromeより約70%省メモリ」を製品全般の性能として主張できる証拠はまだありません。** 901.6MBは手動休眠時、自動制御では1,504.9MBという記録です。Chrome側にも休眠機能があるため、設定を揃えた比較が必要です。[実測記録:106](/Users/yu01/idaten-browser/tasks/todo.md:106)、[Chrome公式](https://support.google.com/chrome/answer/12929150?hl=en)

読み取りのみで分析しました。ファイル変更・ブラウザ起動・新しい負荷計測はしていません。以下の既存実測は記録からの引用、工数・優先順位・合格基準は私の提案です。

**まず、評価の前提となる現状を訂正します。**

- **Chromiumは現在、既定では別窓です。** 重ね窓は操作上の問題を受けて既定OFFになっています。「一つのウィンドウで拡張とWebKitを自然に使える」は現状の売りにできません。[Settings.swift:32](/Users/yu01/idaten-browser/Sources/Idaten/Settings.swift:32)、[引渡し処理:839](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:839)
- **広告遮断は種リストだけではありません。** todoの「変換未着手」は古く、現在はEasyList変換JSONの同梱・読込経路があります。私の読み取り集計では79,091ルール。ただし、ルール数は遮断成功数ではありません。[同梱処理:19](/Users/yu01/idaten-browser/make_app.sh:19)、[読込処理:51](/Users/yu01/idaten-browser/Sources/Idaten/AdBlock.swift:51)、[変換範囲:12](/Users/yu01/idaten-browser/rules/NOTICE.md:12)
- **「拡張が全部動く」は証拠より強い表現です。** インストール・worker起動・権限付与、Claudeのnative hostへのpongは確認記録がありますが、ページ操作の往復と1Passwordのデスクトップ連携は未完です。[導入検証:60](/Users/yu01/idaten-browser/tasks/todo.md:60)、[残る検証:174](/Users/yu01/idaten-browser/tasks/todo.md:174)

**1．差別化候補の評価**

工数は、現コードに詳しい開発者1人による追加実装と検証の概算です。小＝数日、中＝1〜3週間、大＝数週間以上。実測に基づく見積もりではありません。

| 候補・判断 | この実装で出せる価値 | 嘘にならない測り方 | 追加コスト | Chromeでもできるか |
|---|---|---|---|---|
| **メモリ：最有力、数値は未確定** | WebKit主体＋背景WebViewの破棄で、保持するページを減らす。13タブの既存記録は有望。[休眠実装:741](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:741) | Idaten・WebKit関連・Helium関連の**全体**を合算。自動運用と手動強制を別集計し、再訪待ち時間も併記する。 | 中。計器は既存、比較条件と全プロセス捕捉の整備が必要。 | **休眠による削減はできる。** Memory Saverと拡張によるdiscardがある。WebKitとの基礎負荷差がどれだけ残るかは未測定。[標準機能](https://support.google.com/chrome/answer/12929150?hl=en)、[API](https://developer.chrome.com/docs/extensions/reference/api/tabs) |
| **起動時間：候補、優位未実証** | 復元時に選択タブ以外のWebViewを作らない。ただし起動は広告ルールの読込完了を待つ。[復元:1590](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1590)、[起動:288](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:288) | 起動要求→①URL欄操作可能、②選択ページ表示、③そのページで操作成功を別測定。初回・再起動・Helium初回起動を分ける。 | 計測は小、改善は中。 | **追随可能性が高いという推測。** 遅延復元だけで独占的な優位とはいえない。同一セッションで実測が必要。 |
| **広告遮断：最も目で分かりやすい補助価値** | 初期設定で種リスト＋EasyList変換ルールを適用。[既定設定:31](/Users/yu01/idaten-browser/Sources/Idaten/Settings.swift:31) | 同じページで広告の表示、実際に到達した通信、転送量、表示時間、サイト破損を比較。自製ページの陽性対照と実サイトを併用する。 | 中。更新・サイト別解除・破損対応まで必要。同梱更新は現在サイズ比較。[更新処理:35](/Users/yu01/idaten-browser/Sources/Idaten/AdBlock.swift:35) | **できる。** Chrome＋uBO Liteを対照に入れる。差は主に「導入不要」。変換で落ちるルールもあり、遮断品質で勝つとは未証明。[uBO Lite公式](https://github.com/uBlockOrigin/uBOL-home)、[変換制約:12](/Users/yu01/idaten-browser/rules/NOTICE.md:12) |
| **タブ大量運用：本命だが、現状のまま宣伝不可** | 背景WebKitタブを6枚目安に減らし、休眠状態から復帰する。[予算制御:723](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:723) | 20・60・200タブでメモリ、切替応答、復帰時間、再起動後の件数、入力保持を測る。**残ったタブ数だけでなく失った作業も数える。** | 中〜大。後述する60件切捨てと保護判定の修正が先。 | **大半はできる。** このリポジトリの拡張自体がChrome APIで予算休眠を実装している。Chromeでの実動作は別途検証。[policy.js:16](/Users/yu01/idaten-browser/extension/policy.js:16)、[discard呼出し:44](/Users/yu01/idaten-browser/extension/background.js:44) |
| **プライバシー：限定した主張なら可能** | 特定の第三者広告・計測ドメイン遮断と、プロファイル別データ分離。[遮断対象:14](/Users/yu01/idaten-browser/Sources/Idaten/AdBlock.swift:14)、[データストア:143](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:143) | 空白起動・閲覧・検索・拡張利用時の送信先、送信項目、Cookie分離を検査。「追跡ゼロ」という総称は使わない。 | 中〜大。WebKit外の通信とHelium・拡張も対象。 | **相当部分はできる。** 第三者Cookie設定と遮断拡張がある。Idaten固有のプライバシー優位は未実証。[Chrome公式](https://support.google.com/chrome/answer/95647?hl=en) |
| **拡張との両立：乗換え条件であり、単独の優位ではない** | 拡張不要の閲覧をWebKitへ、必要な作業を専用Heliumへ分けられる。[Engines.swift:104](/Users/yu01/idaten-browser/Sources/Idaten/Engines.swift:104) | 拡張ごとの実作業を、導入→利用→休眠／再起動→再利用まで確認。混在時の総メモリと切替手数も測る。 | 別窓運用の整備は中。完全な一体化は大。 | **拡張利用はChromeの方が自然。** Idatenが勝てる可能性は、拡張を維持しつつ普段の負荷を減らせる場合に限る。これは未検証の仮説。 |

「使った瞬間に分かる」という条件では、**広告が消えることは直接見えるが模倣されやすい。メモリ差は有望だが、現在量と休眠状態を見せないと伝わりにくい**、という評価です。

なお、プライバシーについては、faviconを`URLSession.shared`で取得する経路があり、WebKitのルール適用経路を通りません。これが実際に追跡を起こすとは未確認ですが、「すべての通信に同じ保護が効く」とはいえません。[favicon取得:1674](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1674)

**2．既存のメモリ比較の穴と、公平な再測定条件**

既存数字を計算すると、手動休眠時は**70.30%減**、自動制御時は**50.43%減**です。しかし、これは記録値同士の算術であり、期待削減率の推定ではありません。[元の数字:106](/Users/yu01/idaten-browser/tasks/todo.md:106)

読み取れる範囲の穴は以下です。条件が記録されていないものは、「違っていた」と断定せず「揃っていたと確認できない」と判定しています。

| 穴 | 比較への影響 |
|---|---|
| **手動強制休眠と通常Chromeの比較** | 自動的な製品性能と、利用者が意図的に停止した効果が混在する。force経路は再生・入力保護も迂回する。[実装:741](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:741) |
| **Chromeの省メモリ設定が不明** | Memory Saverの有無・強度・例外次第で背景タブの保持状態が変わる。[Chrome公式](https://support.google.com/chrome/answer/12929150?hl=en) |
| **同じ13タブの中身・操作履歴を再現できない** | URLだけでなく、リダイレクト、スクロール、読み込み成功、広告配信、タブを見た順序が負荷を変える。固定シナリオはtodoで未完。[todo:11](/Users/yu01/idaten-browser/tasks/todo.md:11) |
| **Chrome通常プロファイルとIdatenの条件差** | 拡張、ログイン、他ウィンドウ、同期、worker、長期運用による状態が混ざる。「通常運用」としか記録されていない。[todo:109](/Users/yu01/idaten-browser/tasks/todo.md:109) |
| **広告遮断の差** | エンジン差・休眠差・読み込んだ広告の差を分離できない。製品既定比較としては有効でも、WebKit自体の優位の証拠にはならない。[遮断読込:51](/Users/yu01/idaten-browser/Sources/Idaten/AdBlock.swift:51) |
| **動画の実条件が未固定** | 同じURLでもコーデック、解像度、fps、再生位置、広告、バッファ、停止状態が違い得る。既存記録でも動画によって優劣が逆転。[todo:116](/Users/yu01/idaten-browser/tasks/todo.md:116) |
| **待機時間・採取時点が不十分** | 休眠要求から解放まで非同期。記録には手動実行2秒後の残存がある。一瞬の値では安定状態もピークも分からない。[todo:112](/Users/yu01/idaten-browser/tasks/todo.md:112) |
| **各1回、順序効果とばらつきが不明** | キャッシュ、温度、メモリ圧迫、バックグラウンド処理の影響を切り分けられない。最大差の回だけを代表にはできない。[記録:106](/Users/yu01/idaten-browser/tasks/todo.md:106) |
| **キャッシュ・初回処理・版の不明確さ** | Webキャッシュ、ルールコンパイルキャッシュ、ブラウザ／OS版、測定時のコード修正前後が再現条件に必要。[ルールキャッシュ:68](/Users/yu01/idaten-browser/Sources/Idaten/AdBlock.swift:68)、[修正記録:119](/Users/yu01/idaten-browser/tasks/todo.md:119) |
| **プロセス集合の正しさは別問題** | 29プロセスで数値が一致しても、対象を全部拾った保証ではない。WebKitのresponsible PID、既存Heliumへの転送、複数プロファイル、native hostの帰属を別検査する必要がある。[計器:74](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift:74)、[転送仕様:104](/Users/yu01/idaten-browser/Sources/Idaten/Engines.swift:104) |
| **計測失敗が合計から黙って落ちる** | `proc_pid_rusage`失敗はnil、集計は`compactMap`。取得成功したプロセス数だけでは「対象が少ない」のか「取りこぼし」か分からない。プロセス列挙と採取も同時ではない。[計器:64](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift:64)、[集計:147](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift:147) |
| **メモリ以外の対価を測っていない** | 再訪時の再読込、入力消失、CPU、通信量、動画品質が悪化していれば「圧倒的に良い」とは限らない。現計器のCPU差分も、終了プロセスを含む厳密積算ではない。[計器:164](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift:164) |

さらに、表示単位は修正が必要です。計器は1,048,576で割っているため、現在の「MB」は正確には**MiB**です。footprintは圧縮・swapを含む会計値であり、「今その分のRAMが空いた」とは同義ではありません。[単位処理:96](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift:96)、[Appleの説明](https://developer.apple.com/videos/play/wwdc2022/10106/)

**推奨する比較は「製品の既定比較」と「差の原因を調べる比較」の二本です。**

- 製品比較：新規Chromeの既定設定と、Idatenの既定設定。組込み遮断などの差は残し、明記する。
- 原因比較：広告遮断を両方OFF、ChromeのMemory Saverを明示設定し、Chrome＋Idaten休眠拡張も追加する。Helium単体を加えると、二重エンジン構成の価値も判断できる。休眠拡張は既存実装を利用可能。[extension/background.js:32](/Users/yu01/idaten-browser/extension/background.js:32)

具体条件は次を提案します。

| 条件 | 固定方法 |
|---|---|
| URL集合 | まず**背景12＋固定動画1の13件**をファイル化。別に20・60・200件。広告サイトだけに偏らず文書・業務アプリも含め、シナリオ別に報告。失敗・リダイレクトも記録する。 |
| 同じ操作 | 同じ順序で各タブを選択し、読込確認後に同じ操作を行う。最後は同じ動画タブ。大量同時起動は別シナリオにする。 |
| 同じ待機 | 最後の操作から**60秒・5分・15分**を共通観測点にする。起動から全期間1秒間隔で採取。各観測点の直前30秒の中央値と、全期間のピークを残す。 |
| 動画 | 同じ素材・再生位置・解像度・fps・再生時間。実際のコーデック、フレーム落ち、広告有無を記録。厳密対照用の固定動画とYouTube実利用を分ける。 |
| 拡張 | 拡張なし試験と、同じID・版・設定・認証・実作業の試験を分離。Idatenでは必要タブをHeliumに置く。**WebKit上で実行されない拡張を「同じ拡張条件」と数えない。** |
| キャッシュ | 空の専用データストア／プロファイルと、同じ予備走行をした温キャッシュを別集計。ブラウザキャッシュとOSキャッシュは区別。初回ルールコンパイルも別記。 |
| 起動状態 | 両者とも対象ブラウザプロセスが存在しない状態から開始。常駐済み起動は別枠。起動方法を揃え、responsible PIDを確認する。[計器の起動注意:6](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift:6) |
| マシン条件 | 同一Mac・OS、電源・低電力設定・画面サイズ・ネットワーク・他アプリ負荷を固定。メモリ圧迫とswapも記録。比較対象は同時実行しない。 |
| 反復 | 機構確認3回、公開判断には**条件ごとに最低10組**を提案。AB／BAを均等にし、できれば複数日に分散。中央値、ばらつき、対応する差の信頼区間を報告する。1秒サンプルを独立反復として数えない。 |
| 公開範囲 | 単一Macの結果は、その機種・OS・シナリオに限定。広い製品主張には別メモリ容量・別機種でも再確認する。 |

読み取り時点で`tools/bench/`も存在しましたが、**まだこの条件を満たしません**。固定順の3回、瞬間値2点で、URL一覧にはコメントにある動画がありません。また、`--bench`設定前に通常プロファイルのデータストアを作るため、Chrome側の新品プロファイルと同じキャッシュ条件とはいえません。実行せず、静的に確認した指摘です。[bench.sh:16](/Users/yu01/idaten-browser/tools/bench/bench.sh:16)、[測定:31](/Users/yu01/idaten-browser/tools/bench/bench.sh:31)、[URL一覧:1](/Users/yu01/idaten-browser/tools/bench/urls.txt:1)、[main.swift:39](/Users/yu01/idaten-browser/Sources/Idaten/main.swift:39)、[データストア:143](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:143)

**3．製品内で嘘にならない「軽さ」の表示**

最初に実装するなら、**現在の合計footprintと、管理できているタブの状態**です。

| 表示案 | 判定・条件 |
|---|---|
| 「現在のメモリ負荷：○MiB」 | **可。** Idaten本体＋関連WebKit＋管理下Heliumの合計、最終更新時刻、測定範囲を表示。取得漏れがあれば「一部未取得」とする。root PIDだけの既存集計を無条件に「全体」と呼ばない。[計器:74](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift:74) |
| 「読み込み中／稼働中／休眠中／未読込／Chromiumへ引渡し済み」 | **可。** 実状態から集計する。現在の`isHibernated`は「WebViewなし＋URLあり」なので、未読込の復元タブまで含む。WebViewを持つ引渡し元とHeliumの実タブも区別が必要。[Tab.swift:26](/Users/yu01/idaten-browser/Sources/Idaten/Tab.swift:26)、[判定:36](/Users/yu01/idaten-browser/Sources/Idaten/Tab.swift:36) |
| 「背景タブ上限6」 | **現状では不正確。** 「背景WebKitタブの目標6、保護対象を除く」なら妥当。予算はウィンドウ単位で、眠らせられない候補の補充探索もない。[制御:727](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:727) |
| 「休眠操作の前後で○MiB減少」 | **条件付きで可。** 操作前後の固定窓の中央値差、時刻、対象範囲を示す。ほかの変化も含む観測差であり、休眠だけの因果効果とは表示しない。 |
| 「推定○MiB節約」 | **条件付きで可だが、初期版では非推奨。** 下記の推定条件が必要。 |
| 「Chromeなら○GB」「常に70%節約」「休眠1枚＝○MB」 | **現状不可。** 対照条件もタブごとの帰属も成立していない。共有プロセスや残る`interactionState`があるので、休眠タブの使用量をゼロとも呼べない。[状態保持:14](/Users/yu01/idaten-browser/Sources/Idaten/Tab.swift:14) |

推定節約量を出すなら、少なくとも次を満たす必要があります。これは表示設計の提案です。

- 同じエンジン・サイト種別・状態について、**休眠あり／なしの対応試験**でモデルを作る。
- 共有プロセスをタブごとに重複計上しない。過去の削減量を足し続けて「累計でRAMを節約」としない。
- 推定であること、比較基準、測定日、適用範囲、不確実性の幅を表示する。
- 未読込タブ、未測定サイト、古い測定、混在エンジンなど、適用できない状態では数値を出さない。
- 復帰時の待ち時間も併記する。

広告についても、現在の仕組みから**正確な「○件ブロック」カウンタを出す根拠はありません**。読み込んだルール数や、ON/OFF時のリソース数の差をブロック件数に置き換えないでください。[AdBlock.swift:9](/Users/yu01/idaten-browser/Sources/Idaten/AdBlock.swift:9)

**4．乗換えの最大障害3つ**

順位はユーザー調査による確定順位ではなく、現実装と対象拡張からの私の判断です。Jevの選択確率も、実利用者の離脱率としては扱いません。[Jev出力](/Users/yu01/idaten-browser/docs/one-browser/jev_answers3.json:1)

| 障害 | 現実装で潰せるか |
|---|---|
| **① 必須拡張を、普段の全タブで使えない** | **部分的。** Heliumに渡したタブでは検証を進められるが、通常のChrome拡張APIからSwiftのWKWebViewタブを一括管理する統合はない。OneTab・Stylus・Claude・1Passwordの用途によっては、多くのタブをHeliumへ寄せる必要がある。そうなったときの省メモリ効果は再測定が必要。[タブ構造:9](/Users/yu01/idaten-browser/Sources/Idaten/Tab.swift:9)、[Chrome tabs API](https://developer.chrome.com/docs/extensions/reference/api/tabs) |
| **② ログイン・パスワード・同期・作業環境を持ち込めない** | **部分的。** ブックマーク・履歴の移行はあるが、パスワードは対象外、拡張は再導入。WebKit→ChromiumでCookie・ログインは引き継がれない。継続的な端末間同期を提供する実装も今回の読取範囲では確認できない。[ChromeImport.swift:4](/Users/yu01/idaten-browser/Sources/Idaten/ChromeImport.swift:4)、[拡張移行:108](/Users/yu01/idaten-browser/Sources/Idaten/ChromeImport.swift:108)、[切替説明:824](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:824) |
| **③ 作業を失わず、Chromeと同じように操作できるという信頼** | **データ保全は修正可能。一体的操作は現構成で未解決。** 60件超の復元切捨て、入力保護の限界、別窓への移動が障害になる。[復元:1597](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1597)、[入力判定:753](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:753)、[重ね窓評価:32](/Users/yu01/idaten-browser/Sources/Idaten/Settings.swift:32) |

①の合格条件は拡張の起動ではなく、実作業の完了です。Claudeは公式資料でも、拡張ヘルプの他Chromium非対応と、Claude Code資料の複数Chromium接続説明が併存しています。**Heliumで動作した事実と、公式対応保証を区別**してください。[拡張ヘルプ](https://support.claude.com/en/articles/12012173-get-started-with-claude-in-chrome)、[Claude Code公式](https://code.claude.com/docs/en/chrome)

1Passwordも導入成功だけでは不十分で、追加ブラウザ登録・署名条件と、解除・保存・自動入力の確認が必要です。[1Password公式](https://support.1password.com/additional-browsers/)

③には具体的な修正点があります。現在の休眠判定は、フォーカスのある入力欄とトップ文書の音声・動画要素を見ています。フォーカスを外した下書き、iframe内の編集、WebRTC送信・画面共有などを網羅していません。また、JS評価エラー時は既定値falseで休眠する経路があり、応答待ちの間に選択されたタブかどうかの再確認もありません。これは静的コードからの指摘で、実機での作業消失再現はしていません。[休眠処理:753](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:753)

**5．次に実装すべき3つと完成の定義**

以下の数値は、既に達成した性能ではなく、提案する合格基準です。

| 優先順 | 実装するもの | 測定可能な完成の定義 |
|---|---|---|
| **1** | **タブを失わない保存・復元と、安全な休眠**。60件超を消す処理をなくし、遅延復元で負荷を抑える。選択状態を休眠確定直前に再確認し、判定失敗は保護。下書き・会議・サイト例外を扱い、保護対象を飛ばした後も候補を探す。 | 200タブを保存→再起動する試験を10回行い、URL・順序・選択タブの欠落／増殖ゼロ。強制終了後は最後に保存完了した状態を回収。入力・iframe・再生・会議・JSエラー・判定中タブ切替の試験で、保護対象の誤休眠ゼロ。休眠可能な背景タブだけなら操作終了5秒以内に目標6以下。根拠となる現欠陥：[復元:1597](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1597)、[予算:728](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:728)、[判定:753](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:753) |
| **2** | **隔離された比較実行器＋現在量・休眠状態の表示**。既存benchを拡張し、Chrome／Idaten自動／混在／Chrome＋同じ休眠拡張を比較。PID一覧と取得失敗を記録する。 | 通常利用者のCookie・履歴・設定・セッションに変更なし。前述の冷／温キャッシュ条件を各10組完走し、生データから集計を再生成可能。代表状態でApple計器との合計差5%以内を再確認し、対象プロセスの取りこぼしゼロ。UIは同じ集計値を表示し、欠測を明示。**差が出なかった結果も合格した測定結果として残す。** [既存計器検証:8](/Users/yu01/idaten-browser/tasks/todo.md:8)、[現在のbench:31](/Users/yu01/idaten-browser/tools/bench/bench.sh:31) |
| **3** | **必須拡張と移行の完了を確認できる導線**。プロファイルごとの移行結果、Heliumへの明示的引渡し、再ログイン案内、拡張別の確認状態を設ける。 | 指定4拡張で、Claudeのページ読取・操作、OneTabの回収／復元、Stylusの保存／再適用、1Passwordの解除／保存／入力が各10回成功し、再起動後も成功。Chrome元データに変更なし。ブックマーク移行件数が一致し、再移行で重複しない。WebKitで非対応の機能と別窓動作を明示。混在状態でも第2項の計測を完了する。[残る拡張試験:174](/Users/yu01/idaten-browser/tasks/todo.md:174)、[移行実装:30](/Users/yu01/idaten-browser/Sources/Idaten/ChromeImport.swift:30) |

Heliumフォークへ全面移行する場合は、**WebKit主体で得た901.6MBという結果を引き継げません**。休眠方針は移植できますが、性能の根拠は新しい構成で取り直す必要があります。[フォーク計画:151](/Users/yu01/idaten-browser/tasks/todo.md:151)
