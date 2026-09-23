codex
**修正が必要な経路を11件確認しました。** 読み取りのみの静的レビューです。ファイル変更・ビルド・アプリ起動はしていません。以下の再現条件はコードから導いたもので、実機再現は未実施です。重大度はP1＝クラッシュ・データ消失・主要機能不全、P2＝限定条件の不具合です。

1. **P1：`targetCreated`のFIFO引き取りで、同じtargetを2タブが所有する**
   
   [BrowserWindowController.swift:607](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:607)、[同:579](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:579)。
   再現条件：Aの`createTarget`待機中、拡張などが別target Eを作る。EのイベントがAに割り当てられ、続く本来のtarget Xのイベントで別タブBが追加される。その後Aの応答がXを代入し、**AとBが同じXを持ち、Eは管理外になる**。片方を閉じると他方のページまで消える。
   修正案：生成イベントをtarget IDごとに一時保管し、`createTarget`の応答IDで要求元と対応付ける。未対応イベントだけを外部生成タブとして確定する。単一要求でイベント／応答が前後するだけなら、現状でも重複しません。

2. **P1：生成待ち中のタブ閉鎖・WebKitへの切替がキャンセルされない**
   
   [BrowserWindowController.swift:359](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:359)、[同:579](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:579)、[同:592](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:592)。
   再現条件：target IDが未確定のうちにタブを閉じる、またはWebKitへ戻す。`pendingAdopt`が残り、遅延応答はタブの所属・エンジンを確認せずIDを代入する。**閉じたタブのHelium targetが残る／タブが再追加される／WebKitへ戻した後にHeliumが前面化する**経路がある。
   修正案：要求に世代・キャンセル状態を持たせ、閉鎖・エンジン変更時に無効化する。キャンセル済み要求の成功応答は、返されたtargetを閉じる。

3. **P1：0.7秒の判定で終了時のタブ消失と、閉じたタブの復活が起きる**
   
   [BrowserWindowController.swift:641](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:641)、[同:652](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:652)。
   再現条件は両方向にある。
   - Heliumの⌘Qでtargetが破棄された後、終了処理が0.7秒以上続くと、`cdp != nil`なので通常のタブ閉鎖と判定される。`close()`がセッションを保存し、復元すべきタブを失う。
   - 通常のタブ閉鎖直後、0.7秒以内にHeliumを終了すると、`dockDisconnected()`がIDを消す。遅延処理はタブを見つけられず、閉じたタブが保存・復元される。
   
   修正案：終了意図とtarget破棄を別状態として扱い、削除前のセッションを保持する。**外部Heliumの終了意図を取得できないまま、待ち時間だけで完全に区別することはできない**ため、曖昧時の保持方針も必要。

4. **P1：パイプ切断との競合でIdaten自身がSIGPIPE終了する**
   
   [ChromiumDock.swift:111](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:111)。
   再現条件：Helium終了後、読取側の`closed()`がメインスレッドで処理される前、または既にキューに入った書込みが実行される。SIGPIPEが既定動作ならIdatenも終了する。ソース内にはSIGPIPE抑止がなく、`n <= 0`ではシグナルを防げない。[Appleのpipe(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/pipe.2.html)
   修正案：書込みfdに`F_SETNOSIGPIPE`を設定し、`EPIPE`を接続終了として処理する。併せて、現在は切断扱いになる読取りの`EINTR`、要求を途中放棄する書込みの`EINTR`を再試行する。

5. **P1：終了時の`flush()`が無期限にメインスレッドを止める**
   
   [ChromiumDock.swift:125](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:125)、[同:272](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:272)。
   再現条件：Heliumが停止・ハングして読取りをしなくなり、パイプが満杯になる。ウィンドウ追従などの書込みがブロックした状態でIdatenを終了すると、`writeQueue.sync {}`も戻らない。
   修正案：非ブロッキングI/Oと期限付きの非同期終了処理にする。`flush()`完了はHeliumの正常終了確認でもないため、子プロセス終了を別途監視する。

6. **P2：書込みfdの確実なリークと、子プロセス回収の欠落**
   
   [ChromiumDock.swift:56](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:56)、[同:83](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:83)、[同:272](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:272)。
   再現条件：Idatenを残してHelium終了・再起動を繰り返す。`writeFD`を閉じる経路がなく、起動ごとに1本残る。`waitpid`等もなく、既定の子プロセス処理では終了した子が未回収になる。後者の実プロセス状態は未確認。
   修正案：接続の所有者が両fdと読取り処理を一度だけ終了させ、生成したPIDを非同期に回収する。書込み中のfdを無秩序に閉じないよう、終了処理を直列化する。

7. **P1：spawn成功を接続成功と扱い、失敗前にWebKit状態を破棄する**
   
   [ChromiumDock.swift:153](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:153)、[BrowserWindowController.swift:517](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:517)。
   再現条件：同じプロファイルのHeliumが既に動いていて新プロセスが終了する、または起動後にCDPが利用不能になる。`ensureStarted()`は応答確認前に成功し、`handOff()`はWebKitと`interactionState`を破棄してChromiumとして保存する。切断時はタブバー更新だけで、画面・入力状態を戻さない。
   修正案：CDP疎通とtarget生成成功まで元のタブ状態を保持し、成功時に切替を確定する。復元時の起動失敗にも明示的な再試行・エラー表示を設ける。

8. **P2：古い`show()`の完了が、切替後のWebKitを覆う**
   
   [ChromiumDock.swift:215](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:215)。
   再現条件：Chromiumを選択し、位置合わせの複数往復が終わる前にWebKitへ切り替える。古い完了処理は選択状態を再確認せず`Target.activateTarget`を送る。コードの想定どおり前面化すれば、選択表示はWebKitなのにHeliumが覆う。
   修正案：表示要求に世代番号を付け、前面化直前に現在の選択targetと一致するか確認する。WebKit選択時は保留中の前面化を無効化する。

9. **P2：「WebKitへ戻す」がプロファイル既定・親ドメイン指定に負ける**
   
   [BrowserWindowController.swift:592](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:592)、[同:950](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:950)。
   再現条件：プロファイル既定がChromium、または`example.com`の指定を`sub.example.com`が継承している。完全一致のドメイン例外だけを消しても実効エンジンはChromiumのままなので、WebKitの初回ロードがキャンセルされ、再びChromiumへ渡される。
   修正案：タブ単位の明示的WebKit指定を持ち、ナビゲーション判定でドメイン・プロファイル既定より優先する。

10. **P2：target生成中に入力した新しいURLが失われる**
    
    [BrowserWindowController.swift:715](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:715)、[同:577](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:577)。
    再現条件：URL Aで生成要求を送った後、応答前にURL Bを入力する。モデルのURLはBになるが、`pendingAdopt`のguardで送信されず、生成完了後にもBへのナビゲーションがない。実ページはAになる。
    修正案：生成中の最新ナビゲーションを保留し、target確定後に適用する。

11. **P2：バックグラウンドのWebKitタブからのChromium移行が選択を奪う**
    
    [BrowserWindowController.swift:955](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:955)、[同:526](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:526)。
    再現条件：WebKitの⌘クリックで裏に開いたページが、読み込み途中にChromium指定ドメインへリダイレクトする。`handOff()`は対象タブが背景でも無条件に`select(t)`するため、元のタブから選択が移る。
    修正案：背景／前景の意図を移行要求へ引き継ぎ、背景なら生成・登録だけ行う。通常のWebKit内で完結する⌘クリック経路自体は変更されていません。

**クリック透過は未確認です。**

対象は[BrowserWindowController.swift:5](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:5)、[同:57](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:57)、同66–68行です。Appleの一次資料で確認できたのは、[`isOpaque`](https://developer.apple.com/documentation/appkit/nswindow/isopaque)が不透明性、[`fullSizeContentView`](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/fullsizecontentview)が内容領域の拡張とレイヤー化、[`ignoresMouseEvents`](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents?language=objc)が窓全体のマウス透過を指定することです。**この実装の組合せで、透明画素だけが別アプリの窓へクリックを通す保証は確認できませんでした。** Appleの[透明窓サンプル](https://developer.apple.com/library/archive/samplecode/RoundTransparentWindow/Introduction/Intro.html)もタイトルバーなしの構成です。

重大度は**P1相当の未検証リスク**で、確定バグとは区別します。検証条件はIdatenを前面にした状態で穴越しにリンク・入力欄・ドラッグを操作し、Helium側の受信を確認すること。修正案は断定コメントを改め、この受信検証を追加することです。現行自己検査は座標と`hole`値の確認なので、クリック透過の証拠にはなりません。

休眠については、[BrowserWindowController.swift:422](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:422)が`webView`必須のため、**Chromiumタブは強制休眠・時間休眠・メモリ予算の対象外**です。従来の外部Heliumも管理対象外だったので新規退行とは断定しませんが、「統合された全タブに休眠が効く」仕様ならP2の機能欠落です。Chromium用の休眠・復帰経路、または対象範囲の明示が必要です。
tokens used
77,303
**修正が必要な経路を11件確認しました。** 読み取りのみの静的レビューです。ファイル変更・ビルド・アプリ起動はしていません。以下の再現条件はコードから導いたもので、実機再現は未実施です。重大度はP1＝クラッシュ・データ消失・主要機能不全、P2＝限定条件の不具合です。

1. **P1：`targetCreated`のFIFO引き取りで、同じtargetを2タブが所有する**
   
   [BrowserWindowController.swift:607](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:607)、[同:579](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:579)。
   再現条件：Aの`createTarget`待機中、拡張などが別target Eを作る。EのイベントがAに割り当てられ、続く本来のtarget Xのイベントで別タブBが追加される。その後Aの応答がXを代入し、**AとBが同じXを持ち、Eは管理外になる**。片方を閉じると他方のページまで消える。
   修正案：生成イベントをtarget IDごとに一時保管し、`createTarget`の応答IDで要求元と対応付ける。未対応イベントだけを外部生成タブとして確定する。単一要求でイベント／応答が前後するだけなら、現状でも重複しません。

2. **P1：生成待ち中のタブ閉鎖・WebKitへの切替がキャンセルされない**
   
   [BrowserWindowController.swift:359](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:359)、[同:579](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:579)、[同:592](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:592)。
   再現条件：target IDが未確定のうちにタブを閉じる、またはWebKitへ戻す。`pendingAdopt`が残り、遅延応答はタブの所属・エンジンを確認せずIDを代入する。**閉じたタブのHelium targetが残る／タブが再追加される／WebKitへ戻した後にHeliumが前面化する**経路がある。
   修正案：要求に世代・キャンセル状態を持たせ、閉鎖・エンジン変更時に無効化する。キャンセル済み要求の成功応答は、返されたtargetを閉じる。

3. **P1：0.7秒の判定で終了時のタブ消失と、閉じたタブの復活が起きる**
   
   [BrowserWindowController.swift:641](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:641)、[同:652](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:652)。
   再現条件は両方向にある。
   - Heliumの⌘Qでtargetが破棄された後、終了処理が0.7秒以上続くと、`cdp != nil`なので通常のタブ閉鎖と判定される。`close()`がセッションを保存し、復元すべきタブを失う。
   - 通常のタブ閉鎖直後、0.7秒以内にHeliumを終了すると、`dockDisconnected()`がIDを消す。遅延処理はタブを見つけられず、閉じたタブが保存・復元される。
   
   修正案：終了意図とtarget破棄を別状態として扱い、削除前のセッションを保持する。**外部Heliumの終了意図を取得できないまま、待ち時間だけで完全に区別することはできない**ため、曖昧時の保持方針も必要。

4. **P1：パイプ切断との競合でIdaten自身がSIGPIPE終了する**
   
   [ChromiumDock.swift:111](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:111)。
   再現条件：Helium終了後、読取側の`closed()`がメインスレッドで処理される前、または既にキューに入った書込みが実行される。SIGPIPEが既定動作ならIdatenも終了する。ソース内にはSIGPIPE抑止がなく、`n <= 0`ではシグナルを防げない。[Appleのpipe(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/pipe.2.html)
   修正案：書込みfdに`F_SETNOSIGPIPE`を設定し、`EPIPE`を接続終了として処理する。併せて、現在は切断扱いになる読取りの`EINTR`、要求を途中放棄する書込みの`EINTR`を再試行する。

5. **P1：終了時の`flush()`が無期限にメインスレッドを止める**
   
   [ChromiumDock.swift:125](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:125)、[同:272](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:272)。
   再現条件：Heliumが停止・ハングして読取りをしなくなり、パイプが満杯になる。ウィンドウ追従などの書込みがブロックした状態でIdatenを終了すると、`writeQueue.sync {}`も戻らない。
   修正案：非ブロッキングI/Oと期限付きの非同期終了処理にする。`flush()`完了はHeliumの正常終了確認でもないため、子プロセス終了を別途監視する。

6. **P2：書込みfdの確実なリークと、子プロセス回収の欠落**
   
   [ChromiumDock.swift:56](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:56)、[同:83](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:83)、[同:272](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:272)。
   再現条件：Idatenを残してHelium終了・再起動を繰り返す。`writeFD`を閉じる経路がなく、起動ごとに1本残る。`waitpid`等もなく、既定の子プロセス処理では終了した子が未回収になる。後者の実プロセス状態は未確認。
   修正案：接続の所有者が両fdと読取り処理を一度だけ終了させ、生成したPIDを非同期に回収する。書込み中のfdを無秩序に閉じないよう、終了処理を直列化する。

7. **P1：spawn成功を接続成功と扱い、失敗前にWebKit状態を破棄する**
   
   [ChromiumDock.swift:153](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:153)、[BrowserWindowController.swift:517](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:517)。
   再現条件：同じプロファイルのHeliumが既に動いていて新プロセスが終了する、または起動後にCDPが利用不能になる。`ensureStarted()`は応答確認前に成功し、`handOff()`はWebKitと`interactionState`を破棄してChromiumとして保存する。切断時はタブバー更新だけで、画面・入力状態を戻さない。
   修正案：CDP疎通とtarget生成成功まで元のタブ状態を保持し、成功時に切替を確定する。復元時の起動失敗にも明示的な再試行・エラー表示を設ける。

8. **P2：古い`show()`の完了が、切替後のWebKitを覆う**
   
   [ChromiumDock.swift:215](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:215)。
   再現条件：Chromiumを選択し、位置合わせの複数往復が終わる前にWebKitへ切り替える。古い完了処理は選択状態を再確認せず`Target.activateTarget`を送る。コードの想定どおり前面化すれば、選択表示はWebKitなのにHeliumが覆う。
   修正案：表示要求に世代番号を付け、前面化直前に現在の選択targetと一致するか確認する。WebKit選択時は保留中の前面化を無効化する。

9. **P2：「WebKitへ戻す」がプロファイル既定・親ドメイン指定に負ける**
   
   [BrowserWindowController.swift:592](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:592)、[同:950](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:950)。
   再現条件：プロファイル既定がChromium、または`example.com`の指定を`sub.example.com`が継承している。完全一致のドメイン例外だけを消しても実効エンジンはChromiumのままなので、WebKitの初回ロードがキャンセルされ、再びChromiumへ渡される。
   修正案：タブ単位の明示的WebKit指定を持ち、ナビゲーション判定でドメイン・プロファイル既定より優先する。

10. **P2：target生成中に入力した新しいURLが失われる**
    
    [BrowserWindowController.swift:715](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:715)、[同:577](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:577)。
    再現条件：URL Aで生成要求を送った後、応答前にURL Bを入力する。モデルのURLはBになるが、`pendingAdopt`のguardで送信されず、生成完了後にもBへのナビゲーションがない。実ページはAになる。
    修正案：生成中の最新ナビゲーションを保留し、target確定後に適用する。

11. **P2：バックグラウンドのWebKitタブからのChromium移行が選択を奪う**
    
    [BrowserWindowController.swift:955](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:955)、[同:526](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:526)。
    再現条件：WebKitの⌘クリックで裏に開いたページが、読み込み途中にChromium指定ドメインへリダイレクトする。`handOff()`は対象タブが背景でも無条件に`select(t)`するため、元のタブから選択が移る。
    修正案：背景／前景の意図を移行要求へ引き継ぎ、背景なら生成・登録だけ行う。通常のWebKit内で完結する⌘クリック経路自体は変更されていません。

**クリック透過は未確認です。**

対象は[BrowserWindowController.swift:5](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:5)、[同:57](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:57)、同66–68行です。Appleの一次資料で確認できたのは、[`isOpaque`](https://developer.apple.com/documentation/appkit/nswindow/isopaque)が不透明性、[`fullSizeContentView`](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/fullsizecontentview)が内容領域の拡張とレイヤー化、[`ignoresMouseEvents`](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents?language=objc)が窓全体のマウス透過を指定することです。**この実装の組合せで、透明画素だけが別アプリの窓へクリックを通す保証は確認できませんでした。** Appleの[透明窓サンプル](https://developer.apple.com/library/archive/samplecode/RoundTransparentWindow/Introduction/Intro.html)もタイトルバーなしの構成です。

重大度は**P1相当の未検証リスク**で、確定バグとは区別します。検証条件はIdatenを前面にした状態で穴越しにリンク・入力欄・ドラッグを操作し、Helium側の受信を確認すること。修正案は断定コメントを改め、この受信検証を追加することです。現行自己検査は座標と`hole`値の確認なので、クリック透過の証拠にはなりません。

休眠については、[BrowserWindowController.swift:422](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:422)が`webView`必須のため、**Chromiumタブは強制休眠・時間休眠・メモリ予算の対象外**です。従来の外部Heliumも管理対象外だったので新規退行とは断定しませんが、「統合された全タブに休眠が効く」仕様ならP2の機能欠落です。Chromium用の休眠・復帰経路、または対象範囲の明示が必要です。
