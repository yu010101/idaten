codex
**修正が必要です。特に、別窓設定の無視、無効な拡張IDによるクラッシュ経路、ブックマークの並行更新、Cookie許可範囲の拡大が重大です。**

読み取りのみで確認しました。ファイル変更・ブラウザ起動・自己検査実行はしていません。以下の再現条件はコードから導いたものです。

対象4コミットは `69644a3 / 7d3f95c / 8fe8a42 / 792ce06`。`git diff HEAD~4` での機能追加は主にCookie持ち込みです。(1)(2)は `8a8c52a`、(3)は `3fd9d82` 由来なので、以下では直近差分の問題と既存問題を区別します。

1. **P1・既存：`dockChromiumWindow=false` でも窓を重ねる**

   場所：[BrowserWindowController.swift:1191](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1191)、[同:1309](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1309)、[同:1335](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1335)。

   再現条件：既定設定で選択中のWebKitタブをChromiumへ渡す。作成完了時に設定を確認せず `dockedTargetId` を設定し、`dock.show` を呼びます。その後、Idatenの移動・リサイズで `followWindow` が透明領域を作り、Heliumを追従させます。最小化解除も無条件に `dock.show`。`windowDidBecomeKey` にも設定ガードがありません。

   修正案：作成完了時も `showChromium` と同じ設定分岐へ集約し、位置合わせ・透明領域・前面化連携・最小化連携の全入口を設定で制御する。

2. **P1・既存：ディスク上のmanifestは「実行可能な拡張ID」の保証にならない**

   場所：[ChromiumExtensions.swift:16](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumExtensions.swift:16)、[ChromiumDock.swift:321](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:321)。

   再現条件：アクション付き拡張をインストール後、Chromium側で無効化してIdatenから起動する。ファイルは残るのでメニューに載り、実行中のアクションの存在を確認せず送信します。メニュー表示後のアンインストールでも同じ問題があります。

   Chromium一次実装は `GetActionForId` の結果をnull確認せず参照しています。したがってクラッシュ経路は成立します。ただし手元のHeliumビルドでのクラッシュは未実測です。[Chromium実装](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/devtools/protocol/extensions_handler.cc)

   修正案：ブラウザ側で存在・有効状態・アクションを検査してエラーを返す。manifest再読込だけでは競合を防げません。安全なブラウザ側検査がない版では、この起動経路を無効にする。

3. **P1・既存：自動取り込みがブックマークを別スレッドから変更する**

   場所：[BrowserWindowController.swift:1282](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1282)、[Bookmark.swift:25](/Users/yu01/idaten-browser/Sources/Idaten/Bookmark.swift:25)。

   再現条件：起動時の取り込み中に⌘Dで追加・削除する、または取り込み完了前にChromiumが切断され再取り込みが走る。共有 `BookmarkStore.items` に対する検索・append・remove・JSON化が無同期です。

   データ競合は確定です。重複、クラッシュ、古いスナップショットによる保存内容の巻き戻りは競合順序次第で発生し得ます。`.atomic` はこの排他制御になりません。

   修正案：ファイル解析だけを背景処理にし、共有ストアへのマージと保存をMainActorまたは専用直列処理に集約する。取り込みも同時実行させない。

4. **P2・既存：履歴は取り込むたびに重複する**

   場所：[ChromeImport.swift:86](/Users/yu01/idaten-browser/Sources/Idaten/ChromeImport.swift:86)、[同:102](/Users/yu01/idaten-browser/Sources/Idaten/ChromeImport.swift:102)。

   再現条件：Chromium履歴を変更せずIdatenを再起動する、またはChromiumを終了して再度取り込ませる。毎回、全URLを無条件 `INSERT` します。「重複は増やさない」というコメントは履歴には成立しません。履歴一覧が重複し、`COUNT(*)` を使う候補順位も膨らみます。

   また、別接続でのインポート中に通常の `History.record` が書くと、ロックエラーを無視して訪問記録を失う可能性があります。

   修正案：取り込み元識別子を保持した冪等な更新にし、通常の履歴書き込みと直列化する。BEGIN・INSERT・COMMITの失敗を確認する。

5. **P1・直近差分：許可したサイト以外のCookieまで許可リストへ入る**

   場所：[CookieShare.swift:65](/Users/yu01/idaten-browser/Sources/Idaten/CookieShare.swift:65)。

   再現条件：`example.com` を許可するとき、ストアに `notexample.com` や `example.com.attacker.test` のCookieがある。`c.domain.contains(host)` が真になり、その別サイトのルールも保存します。後でその別サイトへ渡す際には `matches` が一致し、個別に許可していないCookieを移します。

   修正案：host-onlyは完全一致、domain Cookieは先頭ドットを除いたドメインへの完全一致または `"." + domain` の境界付き末尾一致だけにする。Cookie側の除外対象判定も行う。

6. **P2・直近差分：許可ルールの `path` が送信時に無視される**

   場所：[BrowserWindowController.swift:1122](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1122)。

   再現条件：`sid`・`example.com`・`/app` を許可後、同名・同ドメインで `/admin` のCookieが追加される。送信フィルタは名前とドメインだけを見るため、未許可の `/admin` も移します。

   修正案：保存済みのpathを一致条件に含める。path省略を全path許可とするなら、その意味を明示し、通常の登録では完全なCookie識別子を保存する。

7. **P2・直近差分：`pendingCreate` はCookie書き込みを取り消さない**

   場所：[BrowserWindowController.swift:1120](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1120)、[同:1154](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1154)。

   再現条件：持ち込み開始後、`getAllCookies` の応答前にタブを閉じる、またはWebKitへ戻す。トークン確認はCookie送信と読戻しの**後**なので、ページ作成は止まってもChromiumの共有Cookieストアは変更されます。続けて同サイトを再度渡すと、新旧処理が並行して古い値を再投入する可能性もあります。

   修正案：Cookie取得後・各送信前にも要求トークンと許可状態を確認する。同じCookieを変更する持ち込み処理を直列化し、古い要求を失効させる。

8. **P2・直近差分：待機中にURLを変更すると、新URLのCookie準備を飛ばす**

   場所：[BrowserWindowController.swift:1180](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1180)、[同:1546](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1546)。

   再現条件：AへのCookie持ち込み待機中にURLバーでBを入力する。AのCookieだけ準備してAのターゲットを作り、直後にBへ `navigate`。Bも持ち込み許可済みでも、Bの準備は呼ばれません。

   修正案：URL変更時に要求世代を更新し、最新URLのCookie準備からやり直す。少なくとも別ホストへの遷移前に同じ準備処理を通す。

9. **P2・直近差分：失敗しても続行し、「入った」の確認も誤判定する**

   場所：[BrowserWindowController.swift:1131](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1131)、[ChromiumDock.swift:281](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:281)。

   再現条件：Chromiumに同じ名前・ドメイン・pathの古いCookieがあり、新しいCookieの保存が拒否される。キーだけの読戻しは古いCookieを成功として数えます。さらに先頭ドットの有無を同一視するため、host-onlyとdomain Cookieを取り違えます。失敗数にかかわらず `done()` でページを開きます。

   修正案：値・属性をメモリ内だけで照合し、ログには集計だけを出す。ドメインは厳密に照合する。部分失敗を呼出元へ返し、持ち込み失敗を利用者に示す。応答が来ない場合のタイムアウトも必要です。

10. **P2・既存＋直近差分：Cookieドメインがファイルへ残る経路がある**

    場所：[BrowserWindowController.swift:2088](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:2088)、[main.swift:39](/Users/yu01/idaten-browser/Sources/Idaten/main.swift:39)、[CookieShare.swift:87](/Users/yu01/idaten-browser/Sources/Idaten/CookieShare.swift:87)。

    再現条件：通常プロファイルで `--selftest <dir>` を実行する。この経路は本人のデータストアを使い、**全Cookieドメインと件数を `report.json` に保存**します。また、持ち込み許可時にはドメイン・名前・pathを `cookie_share.json` に平文保存します。後者は設定として意図的でも、「ドメインがファイルに残らない」は成立しません。

    修正案：一般自己検査も空の専用プロファイルへ隔離し、ドメイン別出力を廃止する。許可設定の平文保存は診断出力と区別して仕様化する。

11. **P2・直近差分：期限切れCookieをセッションCookieへ変えてしまう**

    場所：[CookieShare.swift:105](/Users/yu01/idaten-browser/Sources/Idaten/CookieShare.swift:105)。

    再現条件：取得直後から変換までに期限を迎えたCookie、または期限切れの `HTTPCookie` を渡す。未来でないexpiresを省略して返すため、期限切れではなくセッションCookieになります。実ストアから期限切れCookieが返る頻度は未確認ですが、変換関数の誤りは明確です。

    修正案：期限切れは `nil` を返す。送信待ち中に期限切れになった場合も除外する。

Cookie属性の一次資料照合では、次の区別が必要です。

- **先頭ドット・秒単位・expires=0の説明は正しい。** CDP実装はドットなしdomainをhost-onlyとして扱い、expiresはUnix秒、0はUnix epoch、省略はセッションです。「`__Host-` にCDPのdomainを渡すだけで違反」という指摘は成立しません。ドットなしなら内部でDomain属性が空になります。[Chromium変換実装](https://raw.githubusercontent.com/chromium/chromium/main/content/browser/devtools/protocol/network_handler.cc)
- **`__Host-` のSecure検査は不足。** [CookieShare.swift:94](/Users/yu01/idaten-browser/Sources/Idaten/CookieShare.swift:94) は非Secureを通します。ただしChromium側が拒否するため、直ちに防御が破られる問題ではありません。`__Secure-` と同様に事前拒否すべきです。[Chromium検証実装](https://raw.githubusercontent.com/chromium/chromium/main/net/cookies/canonical_cookie.cc)
- **SameSite=Noneの互換性は未検証。** [CookieShare.swift:111](/Users/yu01/idaten-browser/Sources/Idaten/CookieShare.swift:111) は明示Noneも省略します。元が明示Noneならクロスサイト送信条件が変わり、ログインが壊れ得ます。しかも自己検査の `probe_none` は [BrowserWindowController.swift:1691](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1691) で **Strictを設定**しています。WebKit一次実装にはnilと `"none"` を同じ内部値へ変換する経路もあり、この検査だけでは区別可能性を証明できません。対象OSでサーバー由来の未指定・None・Lax・Strictを検証し、曖昧なものは成功扱いせず除外すべきです。[WebKit実装](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/platform/network/cocoa/CookieCocoa.mm)
- **partitionKeyを省略するだけでは、partitioned Cookieの安全な除外にならない。** 仮に `getAllCookies` がpartitioned Cookieを返す環境なら、現行コードは通常Cookieとして投入します。これは分離範囲を変える **P1相当の条件付きリスク**です。対象環境で返却されるかは未実測。WebKit内部にはpartition情報がありますが、本コードは確認しません。非partitionedと確認できないCookieは持ち込み対象外にする必要があります。[WebKit実装](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/platform/network/cocoa/CookieCocoa.mm)

追加で、拡張の対象タブも誤ります。[ChromiumDock.swift:308](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:308) はURLでpageとtabを対応付け、見つからなければ先頭tabへフォールバックします。同じURLの2タブ、遷移中、対象を閉じた直後には別タブで拡張が動く **P2・既存問題**です。対象を一意に確認できなければ送信を中止し、ブラウザ側の確実な対応付けを使うべきです。

漏えい経路と退行について、確認できた限界も記します。

- Cookie持ち込みの `NSLog` と `state.jsonl` は集計値だけで、Cookie値・ドメインの直接出力はありません。Cookie用CDP要求は専用callbackを渡すため、汎用エラーログにも直接流れません。
- `debug_dump.txt` は全URLを保存します。Cookieの直接ダンプではありませんが、閲覧先ドメインとURL中のトークンは残ります。一般自己検査の画像出力も、ページがCookie値を表示すれば写ります。
- `cookieKeys` の「値は読まない」というコメントは誤りです。`Storage.getCookies` の応答には値も入り、その後キーだけを抽出しています。直接のファイル出力は見つかりませんでした。
- Chromiumのstdout/stderrは無加工で `chromium.log` に保存されます。そこからCookie値が漏れる具体的経路までは確認できず、「絶対に漏れない」とは判定できません。
- 通常の `targetCreated` と作成応答の順序違いによる二重登録には、`inFlight / stash / known` の対策があります。その単純な再現条件では二重登録を指摘できません。
- 休眠処理は `webView != nil` のタブだけが対象です。取り込んだChromiumタブは自動休眠・強制休眠・背景タブ予算の対象外です。タブ取り込みによってChromiumも休眠管理される、という主張は成立しません。
tokens used
86,395
**修正が必要です。特に、別窓設定の無視、無効な拡張IDによるクラッシュ経路、ブックマークの並行更新、Cookie許可範囲の拡大が重大です。**

読み取りのみで確認しました。ファイル変更・ブラウザ起動・自己検査実行はしていません。以下の再現条件はコードから導いたものです。

対象4コミットは `69644a3 / 7d3f95c / 8fe8a42 / 792ce06`。`git diff HEAD~4` での機能追加は主にCookie持ち込みです。(1)(2)は `8a8c52a`、(3)は `3fd9d82` 由来なので、以下では直近差分の問題と既存問題を区別します。

1. **P1・既存：`dockChromiumWindow=false` でも窓を重ねる**

   場所：[BrowserWindowController.swift:1191](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1191)、[同:1309](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1309)、[同:1335](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1335)。

   再現条件：既定設定で選択中のWebKitタブをChromiumへ渡す。作成完了時に設定を確認せず `dockedTargetId` を設定し、`dock.show` を呼びます。その後、Idatenの移動・リサイズで `followWindow` が透明領域を作り、Heliumを追従させます。最小化解除も無条件に `dock.show`。`windowDidBecomeKey` にも設定ガードがありません。

   修正案：作成完了時も `showChromium` と同じ設定分岐へ集約し、位置合わせ・透明領域・前面化連携・最小化連携の全入口を設定で制御する。

2. **P1・既存：ディスク上のmanifestは「実行可能な拡張ID」の保証にならない**

   場所：[ChromiumExtensions.swift:16](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumExtensions.swift:16)、[ChromiumDock.swift:321](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:321)。

   再現条件：アクション付き拡張をインストール後、Chromium側で無効化してIdatenから起動する。ファイルは残るのでメニューに載り、実行中のアクションの存在を確認せず送信します。メニュー表示後のアンインストールでも同じ問題があります。

   Chromium一次実装は `GetActionForId` の結果をnull確認せず参照しています。したがってクラッシュ経路は成立します。ただし手元のHeliumビルドでのクラッシュは未実測です。[Chromium実装](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/devtools/protocol/extensions_handler.cc)

   修正案：ブラウザ側で存在・有効状態・アクションを検査してエラーを返す。manifest再読込だけでは競合を防げません。安全なブラウザ側検査がない版では、この起動経路を無効にする。

3. **P1・既存：自動取り込みがブックマークを別スレッドから変更する**

   場所：[BrowserWindowController.swift:1282](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1282)、[Bookmark.swift:25](/Users/yu01/idaten-browser/Sources/Idaten/Bookmark.swift:25)。

   再現条件：起動時の取り込み中に⌘Dで追加・削除する、または取り込み完了前にChromiumが切断され再取り込みが走る。共有 `BookmarkStore.items` に対する検索・append・remove・JSON化が無同期です。

   データ競合は確定です。重複、クラッシュ、古いスナップショットによる保存内容の巻き戻りは競合順序次第で発生し得ます。`.atomic` はこの排他制御になりません。

   修正案：ファイル解析だけを背景処理にし、共有ストアへのマージと保存をMainActorまたは専用直列処理に集約する。取り込みも同時実行させない。

4. **P2・既存：履歴は取り込むたびに重複する**

   場所：[ChromeImport.swift:86](/Users/yu01/idaten-browser/Sources/Idaten/ChromeImport.swift:86)、[同:102](/Users/yu01/idaten-browser/Sources/Idaten/ChromeImport.swift:102)。

   再現条件：Chromium履歴を変更せずIdatenを再起動する、またはChromiumを終了して再度取り込ませる。毎回、全URLを無条件 `INSERT` します。「重複は増やさない」というコメントは履歴には成立しません。履歴一覧が重複し、`COUNT(*)` を使う候補順位も膨らみます。

   また、別接続でのインポート中に通常の `History.record` が書くと、ロックエラーを無視して訪問記録を失う可能性があります。

   修正案：取り込み元識別子を保持した冪等な更新にし、通常の履歴書き込みと直列化する。BEGIN・INSERT・COMMITの失敗を確認する。

5. **P1・直近差分：許可したサイト以外のCookieまで許可リストへ入る**

   場所：[CookieShare.swift:65](/Users/yu01/idaten-browser/Sources/Idaten/CookieShare.swift:65)。

   再現条件：`example.com` を許可するとき、ストアに `notexample.com` や `example.com.attacker.test` のCookieがある。`c.domain.contains(host)` が真になり、その別サイトのルールも保存します。後でその別サイトへ渡す際には `matches` が一致し、個別に許可していないCookieを移します。

   修正案：host-onlyは完全一致、domain Cookieは先頭ドットを除いたドメインへの完全一致または `"." + domain` の境界付き末尾一致だけにする。Cookie側の除外対象判定も行う。

6. **P2・直近差分：許可ルールの `path` が送信時に無視される**

   場所：[BrowserWindowController.swift:1122](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1122)。

   再現条件：`sid`・`example.com`・`/app` を許可後、同名・同ドメインで `/admin` のCookieが追加される。送信フィルタは名前とドメインだけを見るため、未許可の `/admin` も移します。

   修正案：保存済みのpathを一致条件に含める。path省略を全path許可とするなら、その意味を明示し、通常の登録では完全なCookie識別子を保存する。

7. **P2・直近差分：`pendingCreate` はCookie書き込みを取り消さない**

   場所：[BrowserWindowController.swift:1120](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1120)、[同:1154](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1154)。

   再現条件：持ち込み開始後、`getAllCookies` の応答前にタブを閉じる、またはWebKitへ戻す。トークン確認はCookie送信と読戻しの**後**なので、ページ作成は止まってもChromiumの共有Cookieストアは変更されます。続けて同サイトを再度渡すと、新旧処理が並行して古い値を再投入する可能性もあります。

   修正案：Cookie取得後・各送信前にも要求トークンと許可状態を確認する。同じCookieを変更する持ち込み処理を直列化し、古い要求を失効させる。

8. **P2・直近差分：待機中にURLを変更すると、新URLのCookie準備を飛ばす**

   場所：[BrowserWindowController.swift:1180](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1180)、[同:1546](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1546)。

   再現条件：AへのCookie持ち込み待機中にURLバーでBを入力する。AのCookieだけ準備してAのターゲットを作り、直後にBへ `navigate`。Bも持ち込み許可済みでも、Bの準備は呼ばれません。

   修正案：URL変更時に要求世代を更新し、最新URLのCookie準備からやり直す。少なくとも別ホストへの遷移前に同じ準備処理を通す。

9. **P2・直近差分：失敗しても続行し、「入った」の確認も誤判定する**

   場所：[BrowserWindowController.swift:1131](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1131)、[ChromiumDock.swift:281](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:281)。

   再現条件：Chromiumに同じ名前・ドメイン・pathの古いCookieがあり、新しいCookieの保存が拒否される。キーだけの読戻しは古いCookieを成功として数えます。さらに先頭ドットの有無を同一視するため、host-onlyとdomain Cookieを取り違えます。失敗数にかかわらず `done()` でページを開きます。

   修正案：値・属性をメモリ内だけで照合し、ログには集計だけを出す。ドメインは厳密に照合する。部分失敗を呼出元へ返し、持ち込み失敗を利用者に示す。応答が来ない場合のタイムアウトも必要です。

10. **P2・既存＋直近差分：Cookieドメインがファイルへ残る経路がある**

    場所：[BrowserWindowController.swift:2088](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:2088)、[main.swift:39](/Users/yu01/idaten-browser/Sources/Idaten/main.swift:39)、[CookieShare.swift:87](/Users/yu01/idaten-browser/Sources/Idaten/CookieShare.swift:87)。

    再現条件：通常プロファイルで `--selftest <dir>` を実行する。この経路は本人のデータストアを使い、**全Cookieドメインと件数を `report.json` に保存**します。また、持ち込み許可時にはドメイン・名前・pathを `cookie_share.json` に平文保存します。後者は設定として意図的でも、「ドメインがファイルに残らない」は成立しません。

    修正案：一般自己検査も空の専用プロファイルへ隔離し、ドメイン別出力を廃止する。許可設定の平文保存は診断出力と区別して仕様化する。

11. **P2・直近差分：期限切れCookieをセッションCookieへ変えてしまう**

    場所：[CookieShare.swift:105](/Users/yu01/idaten-browser/Sources/Idaten/CookieShare.swift:105)。

    再現条件：取得直後から変換までに期限を迎えたCookie、または期限切れの `HTTPCookie` を渡す。未来でないexpiresを省略して返すため、期限切れではなくセッションCookieになります。実ストアから期限切れCookieが返る頻度は未確認ですが、変換関数の誤りは明確です。

    修正案：期限切れは `nil` を返す。送信待ち中に期限切れになった場合も除外する。

Cookie属性の一次資料照合では、次の区別が必要です。

- **先頭ドット・秒単位・expires=0の説明は正しい。** CDP実装はドットなしdomainをhost-onlyとして扱い、expiresはUnix秒、0はUnix epoch、省略はセッションです。「`__Host-` にCDPのdomainを渡すだけで違反」という指摘は成立しません。ドットなしなら内部でDomain属性が空になります。[Chromium変換実装](https://raw.githubusercontent.com/chromium/chromium/main/content/browser/devtools/protocol/network_handler.cc)
- **`__Host-` のSecure検査は不足。** [CookieShare.swift:94](/Users/yu01/idaten-browser/Sources/Idaten/CookieShare.swift:94) は非Secureを通します。ただしChromium側が拒否するため、直ちに防御が破られる問題ではありません。`__Secure-` と同様に事前拒否すべきです。[Chromium検証実装](https://raw.githubusercontent.com/chromium/chromium/main/net/cookies/canonical_cookie.cc)
- **SameSite=Noneの互換性は未検証。** [CookieShare.swift:111](/Users/yu01/idaten-browser/Sources/Idaten/CookieShare.swift:111) は明示Noneも省略します。元が明示Noneならクロスサイト送信条件が変わり、ログインが壊れ得ます。しかも自己検査の `probe_none` は [BrowserWindowController.swift:1691](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:1691) で **Strictを設定**しています。WebKit一次実装にはnilと `"none"` を同じ内部値へ変換する経路もあり、この検査だけでは区別可能性を証明できません。対象OSでサーバー由来の未指定・None・Lax・Strictを検証し、曖昧なものは成功扱いせず除外すべきです。[WebKit実装](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/platform/network/cocoa/CookieCocoa.mm)
- **partitionKeyを省略するだけでは、partitioned Cookieの安全な除外にならない。** 仮に `getAllCookies` がpartitioned Cookieを返す環境なら、現行コードは通常Cookieとして投入します。これは分離範囲を変える **P1相当の条件付きリスク**です。対象環境で返却されるかは未実測。WebKit内部にはpartition情報がありますが、本コードは確認しません。非partitionedと確認できないCookieは持ち込み対象外にする必要があります。[WebKit実装](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/platform/network/cocoa/CookieCocoa.mm)

追加で、拡張の対象タブも誤ります。[ChromiumDock.swift:308](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:308) はURLでpageとtabを対応付け、見つからなければ先頭tabへフォールバックします。同じURLの2タブ、遷移中、対象を閉じた直後には別タブで拡張が動く **P2・既存問題**です。対象を一意に確認できなければ送信を中止し、ブラウザ側の確実な対応付けを使うべきです。

漏えい経路と退行について、確認できた限界も記します。

- Cookie持ち込みの `NSLog` と `state.jsonl` は集計値だけで、Cookie値・ドメインの直接出力はありません。Cookie用CDP要求は専用callbackを渡すため、汎用エラーログにも直接流れません。
- `debug_dump.txt` は全URLを保存します。Cookieの直接ダンプではありませんが、閲覧先ドメインとURL中のトークンは残ります。一般自己検査の画像出力も、ページがCookie値を表示すれば写ります。
- `cookieKeys` の「値は読まない」というコメントは誤りです。`Storage.getCookies` の応答には値も入り、その後キーだけを抽出しています。直接のファイル出力は見つかりませんでした。
- Chromiumのstdout/stderrは無加工で `chromium.log` に保存されます。そこからCookie値が漏れる具体的経路までは確認できず、「絶対に漏れない」とは判定できません。
- 通常の `targetCreated` と作成応答の順序違いによる二重登録には、`inFlight / stash / known` の対策があります。その単純な再現条件では二重登録を指摘できません。
- 休眠処理は `webView != nil` のタブだけが対象です。取り込んだChromiumタブは自動休眠・強制休眠・背景タブ予算の対象外です。タブ取り込みによってChromiumも休眠管理される、という主張は成立しません。
