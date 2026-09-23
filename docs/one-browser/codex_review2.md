codex
**11件中、(a)直った＝5件、(b)部分的＝5件、(c)直っていない＝1件です。** 静的レビューによる判定です。書き換え・ビルド・アプリ起動は行っていません。行番号は現在の作業ツリーです。

以下、`B`＝`BrowserWindowController.swift`、`C`＝`ChromiumDock.swift`です。

| # | 前回の指摘 | 判定 | 根拠 |
|---|---|---|---|
| 1 | FIFOによるtargetの二重所有 | **(a)直った** | 応答IDを`known`に登録し、同じIDを`stash`から除去してから要求元へ渡す。[C:239](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:239)。イベント先行・応答先行の両方で、元の取り違えを防いでいる。ただし新しい保留処理には下記の問題がある。 |
| 2 | 生成待ち中の閉鎖・WebKit切替 | **(a)直った** | 閉鎖・切替でトークンを無効化し、完了時にトークン・所属・エンジンを確認。不一致なら生成targetを閉じる。[B:393](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:393)、[B:621](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:621)、[B:647](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:647)。 |
| 3 | 終了とタブ閉鎖の時間による誤判定 | **(c)直っていない** | 0.7秒が1秒／1.5秒に変わっただけで、両方向の誤判定が残る。[B:697](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:697)、[B:708](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:708)。具体例は下記。 |
| 4 | SIGPIPEでIdaten終了 | **(a)直った** | 書込み開始前に`F_SETNOSIGPIPE`を設定。読取り・書込みの`EINTR`も再試行する。[C:56](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:56)、[C:70](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:70)、[C:135](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:135)。 |
| 5 | `flush()`の無期限メインスレッド停止 | **(a)直った** | セマフォ待機に1秒の期限がある。[C:147](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:147)。ただし書込み自体のブロック解除・Helium終了保証はない。 |
| 6 | fdリーク・子プロセス未回収 | **(b)部分的** | 通常EOF時の書込みfd closeと`waitpid`は追加された。[C:86](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:86)、[C:100](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:100)。ただし`shutdown()`が先に所有権を捨てる経路ではcloseが保証されない。 |
| 7 | 起動確認前のWebKit破棄・復帰不在 | **(b)部分的** | `interactionState`退避は追加。ただしspawnだけで成功とし、WebViewを破棄・セッション保存する構造は同じ。[B:557](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:557)、[C:184](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:184)。追加された切断時復帰も、下記のコールバック順序で機能しない。 |
| 8 | 古い`show()`による前面化 | **(a)直った** | 前面化直前に選択タブを再確認するため、前回の「別のWebKitタブへ選択を切り替える」経路は防げる。[B:614](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:614)、[C:264](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:264)。位置合わせ自体はキャンセルされない。 |
| 9 | WebKitへ戻してもルールで再移行 | **(b)部分的** | `forceWebKit`で初回ロード・ページ内ナビゲーションは防げる。[B:655](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:655)、[B:1057](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1057)。URLバー経路はこれを見ず、既存ページがあれば新しいChromiumタブを開く。[B:797](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:797)。指定はセッションにも保存されない。[B:1010](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1010)。 |
| 10 | 生成中に入力したURLの消失 | **(b)部分的** | 最新URLへの`navigate`は追加された。[B:637](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:637)。しかし生成元URLの遅延`targetInfoChanged`が最新URLを再上書きできる。[B:679](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:679)。実ページの移動要求は出ても、表示・保存URLの整合性が保証されない。 |
| 11 | 背景WebKitからの移行で選択を奪う | **(b)部分的** | `handOff`にタブが渡れば背景を維持する。しかし呼出側は`webView.url != nil`なら`nil`を渡すため、既にURLを持つ背景ページのリダイレクト等では新規タブを選択する。[B:1062](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1062)、[B:568](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:568)。 |

**残存する重大な破綻**

- **P1：時間判定は「曖昧なら残す」になっていない。**  
  target破棄を時刻0とすると、Helium終了による切断が**1.2秒後**なら`dockDisconnected()`が通常閉鎖として削除する。**1.5秒超**なら遅延処理が`cdp != nil`を根拠に先に削除する。逆に通常のタブ閉鎖から**0.5秒後**にHeliumを終了すると、IDと`pendingDestroy`が消され、閉じたタブが保存される。[B:699](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:699)、[B:712](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:712)。  
  `isRunning`は実プロセス状態でも終了意図でもなく、単なる`cdp != nil`。[C:175](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:175)。

- **P1：切断時のWebKit復帰条件が、復帰判定前に消される。**  
  `closed()`は全要求へ失敗を返してから`onClose`を呼ぶ。[C:106](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:106)。生成完了側は失敗でも先に`pendingCreate = nil`として戻る。[B:633](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:633)。その後の`dockDisconnected()`は`pendingCreate != nil`を条件にしているため、通常の生成待ち切断では復帰しない。[B:720](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:720)。  
  結果はWebViewなし・targetなし・Chromium扱い・穴が開いたまま。パイプを保ったまま`createTarget`がエラーになった場合も同様に放置される。

- **P2：fd closeのキュー順序は改善したが、寿命管理が未完。**  
  メインスレッドからの`send`という契約を守る限り、`isClosed`設定→既存write→closeの順序なので、**今回の`closed()`から「close後に後続writeが走る」とは判定しない**。[C:100](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:100)、[C:123](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:123)。  
  ただし`shutdown()`は送信・flush直後に`cdp = nil`にする。[C:329](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:329)。読取りスレッドは`weak self`なので、他の強参照がなければEOF後の`closed()`が実行されず、書込みfdが残る。[C:66](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:66)、[C:82](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:82)。別プロファイル窓を残して一つだけ閉じる場合に問題になる。また、ブロックしたwriteの後ろへcloseを積んでも、そのブロックは解消しない。

**修正で新たに入った問題**

1. **P2：`stash`中のURL・タイトル変更を失う。**  
   別target Aの生成待ち中に外部target Eが作られると、Eの初期情報だけを保留する。その後Eが遷移しても、変更通知はまだタブのないdelegateへ送られて捨てられる。Aの完了後には古い情報でEを登録・保存する。[C:225](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:225)、[C:229](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:229)、[C:251](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:251)、[B:679](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:679)。  
   また一件でも生成応答が返らなければ、後から開いた外部タブ全部が期限なしで保留される。切断時には失敗コールバックからstashを外部タブとして公開してしまい、切断したtargetのタブを増やす経路もある。

2. **P2：一度WebKitへ戻すと、そのタブで明示的なChromium切替ができない。**  
   `moveBackToWebKit`が立てた`forceWebKit`を解除する処理がなく、利用者が再び切替操作を承認しても`handOff`冒頭で拒否される。[B:655](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:655)、[B:531](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:531)、[B:558](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:558)。

3. **P2：WebKit復帰時に、現在のChromium URLではなく移行前のページを復元する。**  
   Aで移行した際の`interactionState`が残り、ChromiumでBまで移動しても更新されない。WebKitへ戻すと`select()`が現在URLより古いstateを優先する。[B:563](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:563)、[B:367](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:367)。

4. **P2：マウス透過の更新待ちで、ツールバークリックを下の窓へ落とせる。**  
   穴の上で`ignoresMouseEvents = true`になった後、ツールバーへ移動して次のタイマー実行前に押すと、窓全体が透過したまま。さらにボタン押下中は更新を拒否するため、誤った状態をドラッグ終了まで保持する。[B:22](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:22)、[B:35](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:35)。  
   これは60Hzでも消えない競合で、タイマーはdefault modeなので実行間隔の上限も保証されない。[Apple Timer資料](https://developer.apple.com/documentation/foundation/timer)。

キー窓・ドラッグ・スクロールについては、次を区別する必要があります。

- **キー窓：** `ignoresMouseEvents`切替にはキー窓・first responderの同期処理がない。「マウスがHeliumへ届く」と「キー入力もHeliumへ届く」は別で、現在の実装から後者の成立は確認できない。
- **ドラッグ：** 通常更新のボタン押下ガードはあるが、`hole = nil`経由の`stopPassThrough()`は押下状態を見ずに強制解除する。[B:26](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:26)。操作途中の状態固定は一貫していない。
- **スクロール：** `pressedMouseButtons`ではスクロール・慣性フェーズを検出できない。継続中でも境界通過で窓全体の透過設定が切り替わる。実際にどの窓へ各イベントが届くかは実機検証が必要で、**スクロール断絶やキー窓喪失まで確定バグとは断定しない**。

したがって、クリック透過は今回も検証済みとは扱えません。特に「ボタン押下直前の境界通過」は、追加実装そのものに存在する具体的な競合です。
tokens used
46,483
**11件中、(a)直った＝5件、(b)部分的＝5件、(c)直っていない＝1件です。** 静的レビューによる判定です。書き換え・ビルド・アプリ起動は行っていません。行番号は現在の作業ツリーです。

以下、`B`＝`BrowserWindowController.swift`、`C`＝`ChromiumDock.swift`です。

| # | 前回の指摘 | 判定 | 根拠 |
|---|---|---|---|
| 1 | FIFOによるtargetの二重所有 | **(a)直った** | 応答IDを`known`に登録し、同じIDを`stash`から除去してから要求元へ渡す。[C:239](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:239)。イベント先行・応答先行の両方で、元の取り違えを防いでいる。ただし新しい保留処理には下記の問題がある。 |
| 2 | 生成待ち中の閉鎖・WebKit切替 | **(a)直った** | 閉鎖・切替でトークンを無効化し、完了時にトークン・所属・エンジンを確認。不一致なら生成targetを閉じる。[B:393](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:393)、[B:621](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:621)、[B:647](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:647)。 |
| 3 | 終了とタブ閉鎖の時間による誤判定 | **(c)直っていない** | 0.7秒が1秒／1.5秒に変わっただけで、両方向の誤判定が残る。[B:697](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:697)、[B:708](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:708)。具体例は下記。 |
| 4 | SIGPIPEでIdaten終了 | **(a)直った** | 書込み開始前に`F_SETNOSIGPIPE`を設定。読取り・書込みの`EINTR`も再試行する。[C:56](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:56)、[C:70](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:70)、[C:135](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:135)。 |
| 5 | `flush()`の無期限メインスレッド停止 | **(a)直った** | セマフォ待機に1秒の期限がある。[C:147](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:147)。ただし書込み自体のブロック解除・Helium終了保証はない。 |
| 6 | fdリーク・子プロセス未回収 | **(b)部分的** | 通常EOF時の書込みfd closeと`waitpid`は追加された。[C:86](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:86)、[C:100](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:100)。ただし`shutdown()`が先に所有権を捨てる経路ではcloseが保証されない。 |
| 7 | 起動確認前のWebKit破棄・復帰不在 | **(b)部分的** | `interactionState`退避は追加。ただしspawnだけで成功とし、WebViewを破棄・セッション保存する構造は同じ。[B:557](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:557)、[C:184](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:184)。追加された切断時復帰も、下記のコールバック順序で機能しない。 |
| 8 | 古い`show()`による前面化 | **(a)直った** | 前面化直前に選択タブを再確認するため、前回の「別のWebKitタブへ選択を切り替える」経路は防げる。[B:614](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:614)、[C:264](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:264)。位置合わせ自体はキャンセルされない。 |
| 9 | WebKitへ戻してもルールで再移行 | **(b)部分的** | `forceWebKit`で初回ロード・ページ内ナビゲーションは防げる。[B:655](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:655)、[B:1057](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1057)。URLバー経路はこれを見ず、既存ページがあれば新しいChromiumタブを開く。[B:797](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:797)。指定はセッションにも保存されない。[B:1010](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1010)。 |
| 10 | 生成中に入力したURLの消失 | **(b)部分的** | 最新URLへの`navigate`は追加された。[B:637](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:637)。しかし生成元URLの遅延`targetInfoChanged`が最新URLを再上書きできる。[B:679](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:679)。実ページの移動要求は出ても、表示・保存URLの整合性が保証されない。 |
| 11 | 背景WebKitからの移行で選択を奪う | **(b)部分的** | `handOff`にタブが渡れば背景を維持する。しかし呼出側は`webView.url != nil`なら`nil`を渡すため、既にURLを持つ背景ページのリダイレクト等では新規タブを選択する。[B:1062](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1062)、[B:568](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:568)。 |

**残存する重大な破綻**

- **P1：時間判定は「曖昧なら残す」になっていない。**  
  target破棄を時刻0とすると、Helium終了による切断が**1.2秒後**なら`dockDisconnected()`が通常閉鎖として削除する。**1.5秒超**なら遅延処理が`cdp != nil`を根拠に先に削除する。逆に通常のタブ閉鎖から**0.5秒後**にHeliumを終了すると、IDと`pendingDestroy`が消され、閉じたタブが保存される。[B:699](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:699)、[B:712](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:712)。  
  `isRunning`は実プロセス状態でも終了意図でもなく、単なる`cdp != nil`。[C:175](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:175)。

- **P1：切断時のWebKit復帰条件が、復帰判定前に消される。**  
  `closed()`は全要求へ失敗を返してから`onClose`を呼ぶ。[C:106](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:106)。生成完了側は失敗でも先に`pendingCreate = nil`として戻る。[B:633](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:633)。その後の`dockDisconnected()`は`pendingCreate != nil`を条件にしているため、通常の生成待ち切断では復帰しない。[B:720](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:720)。  
  結果はWebViewなし・targetなし・Chromium扱い・穴が開いたまま。パイプを保ったまま`createTarget`がエラーになった場合も同様に放置される。

- **P2：fd closeのキュー順序は改善したが、寿命管理が未完。**  
  メインスレッドからの`send`という契約を守る限り、`isClosed`設定→既存write→closeの順序なので、**今回の`closed()`から「close後に後続writeが走る」とは判定しない**。[C:100](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:100)、[C:123](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:123)。  
  ただし`shutdown()`は送信・flush直後に`cdp = nil`にする。[C:329](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:329)。読取りスレッドは`weak self`なので、他の強参照がなければEOF後の`closed()`が実行されず、書込みfdが残る。[C:66](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:66)、[C:82](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:82)。別プロファイル窓を残して一つだけ閉じる場合に問題になる。また、ブロックしたwriteの後ろへcloseを積んでも、そのブロックは解消しない。

**修正で新たに入った問題**

1. **P2：`stash`中のURL・タイトル変更を失う。**  
   別target Aの生成待ち中に外部target Eが作られると、Eの初期情報だけを保留する。その後Eが遷移しても、変更通知はまだタブのないdelegateへ送られて捨てられる。Aの完了後には古い情報でEを登録・保存する。[C:225](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:225)、[C:229](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:229)、[C:251](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:251)、[B:679](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:679)。  
   また一件でも生成応答が返らなければ、後から開いた外部タブ全部が期限なしで保留される。切断時には失敗コールバックからstashを外部タブとして公開してしまい、切断したtargetのタブを増やす経路もある。

2. **P2：一度WebKitへ戻すと、そのタブで明示的なChromium切替ができない。**  
   `moveBackToWebKit`が立てた`forceWebKit`を解除する処理がなく、利用者が再び切替操作を承認しても`handOff`冒頭で拒否される。[B:655](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:655)、[B:531](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:531)、[B:558](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:558)。

3. **P2：WebKit復帰時に、現在のChromium URLではなく移行前のページを復元する。**  
   Aで移行した際の`interactionState`が残り、ChromiumでBまで移動しても更新されない。WebKitへ戻すと`select()`が現在URLより古いstateを優先する。[B:563](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:563)、[B:367](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:367)。

4. **P2：マウス透過の更新待ちで、ツールバークリックを下の窓へ落とせる。**  
   穴の上で`ignoresMouseEvents = true`になった後、ツールバーへ移動して次のタイマー実行前に押すと、窓全体が透過したまま。さらにボタン押下中は更新を拒否するため、誤った状態をドラッグ終了まで保持する。[B:22](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:22)、[B:35](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:35)。  
   これは60Hzでも消えない競合で、タイマーはdefault modeなので実行間隔の上限も保証されない。[Apple Timer資料](https://developer.apple.com/documentation/foundation/timer)。

キー窓・ドラッグ・スクロールについては、次を区別する必要があります。

- **キー窓：** `ignoresMouseEvents`切替にはキー窓・first responderの同期処理がない。「マウスがHeliumへ届く」と「キー入力もHeliumへ届く」は別で、現在の実装から後者の成立は確認できない。
- **ドラッグ：** 通常更新のボタン押下ガードはあるが、`hole = nil`経由の`stopPassThrough()`は押下状態を見ずに強制解除する。[B:26](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:26)。操作途中の状態固定は一貫していない。
- **スクロール：** `pressedMouseButtons`ではスクロール・慣性フェーズを検出できない。継続中でも境界通過で窓全体の透過設定が切り替わる。実際にどの窓へ各イベントが届くかは実機検証が必要で、**スクロール断絶やキー窓喪失まで確定バグとは断定しない**。

したがって、クリック透過は今回も検証済みとは扱えません。特に「ボタン押下直前の境界通過」は、追加実装そのものに存在する具体的な競合です。
