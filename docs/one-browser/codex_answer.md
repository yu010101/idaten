codex
**結論：既存のSwift製IdatenのNSViewへ、拡張対応のCEF Chrome styleをそのまま埋め込む方法は、2026年9月22日時点でも公式には対応していません。** 親NSViewを指定するとAlloy styleになる制約が現行ヘッダに残っています。[CEF公式ヘッダ](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types_mac.h)

「1ウィンドウ・共通タブバー・必須拡張」を優先するなら、**Heliumを基盤としてIdatenの操作体系を移植する案**を推します。ただし、これはブラウザ基盤の変更です。**現在のSwiftウィンドウを維持する条件まで固定すると、短期間で壊れにくく実現できる完成解は今回確認できませんでした。** 以下、確認事項と推測を分けます。

コード変更・アプリ起動・拡張インストールは行っていません。過去調査の訂正部分を先に確認し、現状が専用プロファイル付き外部プロセス起動であることも確認しました。[過去調査:347](/Users/yu01/idaten-browser/docs/prior-art-research-2026-09-19.txt:347)、[Engines.swift:106](/Users/yu01/idaten-browser/Sources/Idaten/Engines.swift:106)

**1. CEF Chrome styleを既存NSViewの子にできるか**

| 項目 | 判定・根拠 |
|---|---|
| macOSの`SetAsChild`相当 | **APIは存在する。** `CefWindowInfo::SetAsChild`は`parent_view`へ親を設定する。[cef_mac.h](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_mac.h) |
| そのままChrome styleで動くか | **公式仕様上できない。** macOSでは`parent_view`指定、またはwindowless指定でAlloy styleになる。[cef_types_mac.h](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types_mac.h) |
| Alloyとの違い | Chrome styleはChrome UI層、Alloy styleはChromium content層を基盤とする。Alloyは追加コールバックとOSRを提供するが、標準ブラウザ機能が少ない。[runtime style定義](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types_runtime.h) |
| 対応したバージョン | **macOSのChrome style＋外部NSView親に対応したリリースは確認できない。** 関連する[#3294](https://github.com/chromiumembedded/cef/issues/3294)はOpen。公式の外部native parent対応表はChrome styleについてWindows/Linuxのみを挙げる。[#3685](https://github.com/chromiumembedded/cef/issues/3685) |
| 混同しやすいバージョン | **125.0.8以降**はChrome bootstrap上でAlloy styleを利用可能。**M128**で削除されたのはAlloy **bootstrap**と旧Alloy拡張APIであり、Alloy **style**ではない。[#3685](https://github.com/chromiumembedded/cef/issues/3685) |

CEF Viewsを使う構成は別です。Chrome styleの`CefWindow`と`CefBrowserView`は利用できますが、既存AppKitビューへの埋め込み対応を意味しません。また、公式定義では**1つのChrome style WindowがホストできるChrome style BrowserViewは最大1つ**です。「CEF Viewsへ移れば独自タブバー配下に複数のChrome BrowserViewを簡単に置ける」とも判断できません。[CEF runtime style定義](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types_runtime.h)

**2. その状態でChrome Web Store拡張が動くか**

まず、**「既存NSViewに埋め込まれたChrome style」という前提が成立しません。** 実際に成立するAlloy埋め込みと、Chrome styleウィンドウを分ける必要があります。[macOS公式仕様](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types_mac.h)

| 機能 | 確認できたこと | 確認できないこと |
|---|---|---|
| content script | cmuxのCEF 151・Chrome style試作で、unpacked MV3拡張のcontent script実行を作者が報告。[PR #10197](https://github.com/manaflow-ai/cmux/pull/10197) | それをAlloy埋め込みや必須4拡張の完全動作へ一般化する根拠。 |
| extension service worker | ChromeにはMV3 workerの登録・実行機構がある。[Chrome公式](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/basics) | macOSの当該埋め込み構成での起動・休止・再開・イベント配送の実証。content script成功だけでは証明できない。 |
| `sidePanel` | ブラウザ側のサイドパネルへ拡張ページを表示するAPI。[Chrome公式](https://developer.chrome.com/docs/extensions/reference/api/sidePanel) | Alloy埋め込みで同等UIが使える根拠。Chrome styleでも、ツールバーを隠した今回の構成でClaudeが完全動作する実証。 |
| action popup | Chromiumにはブラウザウィンドウ・タブモデルに接続する専用popup実装がある。[Chromium実装](https://github.com/chromium/chromium/blob/main/chrome/browser/ui/views/extensions/extension_popup.cc) | 独自Swiftタブバーへ自動的にpopupの起点・フォーカス・寿命が接続される根拠。 |
| `chrome.debugger` | 拡張から対象タブへattachするChrome APIは存在。[Chrome公式](https://developer.chrome.com/docs/extensions/reference/api/debugger) | CEF埋め込み構成でClaudeのattach・操作が成功する実証。外部CDPが使えるだけでは証明にならない。 |
| `nativeMessaging` | ホストmanifest、`allowed_origins`、実行ファイルとの通信が必要。macOSではブラウザによってmanifest探索先が異なる。[Chrome公式](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) | CEF／IdatenでClaude・1Passwordのホストが正しく検出され、相手側にも受け入れられる実証。 |

**Alloyで拡張が一切動かない、と断定するのも不正確です。** 過去調査には、RequestContextレベルの機能は動作し得るがChrome UI依存機能は対応しない、というメンテナ発言の検証記録があります。今回、そのGitHubコメント本文・フォーラム本文は再取得できなかったため、これは**ローカル調査記録での確認**として扱います。[過去調査:262](/Users/yu01/idaten-browser/docs/prior-art-research-2026-09-19.txt:262)、[対象issue #3859](https://github.com/chromiumembedded/cef/issues/3859)

また、**CWSで配布される拡張を展開して読み込むこと**と、**CWSから直接インストール・更新できること**は別です。cmuxで確認できる経路は`--load-extension`によるunpacked読み込みです。今回、CEFの該当macOS構成についてCWS直接導入・更新の保証は確認できませんでした。[cmux PR](https://github.com/manaflow-ai/cmux/pull/10197)

必須拡張への影響は次のとおりです。

- **Claude in Chrome：最大の障害。** 公式に`sidePanel`・`debugger`・`nativeMessaging`に加え`tabs`・`tabGroups`等を要求します。さらに公式は**他のChromium系ブラウザをサポート対象外**としています。Helium／CEFで「動作する可能性」と「公式サポート」は分ける必要があります。[Claude公式](https://support.claude.com/en/articles/12012173-get-started-with-claude-in-chrome)
- **OneTab：タブモデルの統合が必要。** 主機能はタブの回収・復元です。**推測：** Swift側だけに存在するWKWebViewタブは、通常のChrome拡張APIから自動的には見えず、見た目を統一してもOneTabの操作対象は統一されません。[OneTab公式](https://www.one-tab.com/)、[tabs API](https://developer.chrome.com/docs/extensions/reference/api/tabs)
- **Stylus：CSS適用だけでは合格にならない。** 作者資料にはcontent scriptだけでなくpopup・管理機能もあります。CEFでの設定・編集・保存を含む完全動作は未確認です。[Stylus公式リポジトリ](https://github.com/openstyles/stylus)
- **1Password：拡張とデスクトップ連携を別々に検証する必要があります。** macOSでは追加ブラウザの登録制度があり、公式手順はApplications内のAppleコード署名済みブラウザを要求しています。自作CEFアプリでの連携成功は未確認です。[1Password公式](https://support.1password.com/additional-browsers/)

**3a. HeliumをCDPで制御し、ウィンドウを重ねる案**

**確認できた範囲では、タブ制御と位置追従の試作は可能です。** CDPには`Target.getTargets`、`createTarget`、`activateTarget`、`closeTarget`、`Browser.getWindowForTarget`、`setWindowBounds`があります。[Target仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Target.pdl)、[Browser仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Browser.pdl)

ただし、**位置・サイズ制御はウィンドウの所有関係の統合ではありません。** AppKitの`addChildWindow`は`NSWindow`オブジェクトを受け取るAPIで、CDPのwindow IDを渡して外部アプリの窓を取り込むAPIではありません。今回、これを実現する公開APIは確認できませんでした。[Apple公式](https://developer.apple.com/documentation/appkit/nswindow/addchildwindow%28_%3Aordered%3A%29)

致命的な欠点は以下です。

- **推測：フォーカスとウィンドウ順序が二重管理になる。** 内容領域はHelium、タブバーはIdatenに属するため、クリック・キーボード操作・最小化・Spaces・フルスクリーン・モーダル表示を一体として扱う追加制御が必要になります。CDPのbounds制御には、その統合契約がありません。[CDP Browser仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Browser.pdl)、[NSWindowの役割](https://developer.apple.com/documentation/appkit/nswindow)
- **`--app`は埋め込みAPIではない。** ChromiumにはURLをapp modeで起動する経路がありますが、外部NSViewへのparent指定や、完全な枠なし表示を保証するものではありません。Heliumの当該モードでClaudeのsidePanel・各拡張の起動UIを維持できるかも未確認です。[Chromium起動API](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/shell_integration.h)、[sidePanel仕様](https://developer.chrome.com/docs/extensions/reference/api/sidePanel)
- **推測：拡張が生成したタブ・窓まで追従させる必要がある。** `createTarget`は新規ページを作るAPIで、既存app windowへ任意タブを挿入する汎用window指定は確認できません。OneTabの一括復元やClaudeのタブ生成まで含めた表示先統合が残ります。[Target仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Target.pdl)

cmuxの試作は**同一アプリ内のCEFウィンドウ**を重ねる方式であり、外部Heliumを取り込んだ前例ではありません。それでもSwiftUIオーバーレイが下に隠れる問題が記載され、当日revertされています。revert理由自体は確認できないため、「方式が原因で撤回された」とは断定しません。[実装PR](https://github.com/manaflow-ai/cmux/pull/10197)、[revert PR](https://github.com/manaflow-ai/cmux/pull/11966)

**3b. `Page.startScreencast`で映像を転送する案**

**ページ画像と入力転送の仕組みは存在します。** ScreencastはJPEG／PNGフレームを送り、Inputにはマウス・キー・文字入力・IME compositionのAPIがあります。[Page仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Page.pdl)、[Input仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Input.pdl)

ただし、日常用ブラウザとしては次が重大です。

| 対象 | 欠点・判定 |
|---|---|
| 拡張UI | **通常ページのscreencastだけでは、ブラウザ側のsidePanelや別popupを一緒に表示できない。** それらはページとは別のUIです。別ターゲットの映像を取得できても、配置・フォーカス・開閉を再構成する必要があります。後半は**推測**。[Page仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Page.pdl)、[sidePanel](https://developer.chrome.com/docs/extensions/reference/api/sidePanel)、[popup実装](https://github.com/chromium/chromium/blob/main/chrome/browser/ui/views/extensions/extension_popup.cc) |
| 日本語IME | **不可能ではないが、キー転送だけでは完成しない。** Idaten側でmarked text・選択範囲・候補位置などを扱い、CDPへcompositionを橋渡しする必要がある、という**推測**。任意のWebエディタでの再変換・候補位置の正常動作は未確認。[Input仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Input.pdl)、[Apple NSTextInputClient](https://developer.apple.com/documentation/appkit/nstextinputclient?changes=_10%2C_10%2C_10%2C_10) |
| 動画・音声 | 映像は圧縮静止画列で、音声転送はこのAPIに含まれない。**推測：** エンコード・デコード負荷と表示遅延が加わり、Heliumから直接出る音声との同期も課題になる。動画のfps・DRM・最小化時挙動は未検証。[Page仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Page.pdl) |

**今回の要件で特に致命的なのは、ClaudeのsidePanelを含むブラウザUIが、通常ページの映像一本では完結しないことです。** 画面を表示する試作の成功を、拡張付きブラウザの完成とみなせません。[Claude公式](https://support.claude.com/en/articles/12012173-get-started-with-claude-in-chrome)、[CDP Page仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Page.pdl)

**4. 推す案と却下理由**

**推奨は、Heliumをフォークし、Chromium自身のウィンドウ・タブモデル・拡張UIを維持しながらIdatenの操作体系を移植する案です。これは設計判断・推測です。** HeliumにはCWS拡張対応、タブグループ等があり、macOS向けの開発環境も公開されています。[Helium公式](https://helium.computer/)、[開発資料](https://github.com/imputnet/helium-macos/blob/main/docs/building.md)

最初の到達点を「全タブをChromiumに統一した1つのIdatenアプリ」とし、既存の拡張UI・タブモデルを残す方針です。**推測：** これなら、外部ウィンドウ追従、IMEの再実装、映像への拡張UI合成、SwiftタブとChromeタブの対応付けを避けられ、完成までの不確実性を減らせます。根拠は上記のCEF制約・CDPの範囲・Chromiumのpopup実装です。[CEF制約](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types_mac.h)、[CDP](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Browser.pdl)、[popup実装](https://github.com/chromium/chromium/blob/main/chrome/browser/ui/views/extensions/extension_popup.cc)

ただし、**最短工期を実証した比較資料はありません。** 自前ビルドと更新追従は必要で、現在のSwift UIの維持にもなりません。したがって「小変更で完成する案」ではなく、**要件を満たすまでの手戻りを減らす案としての推奨**です。[Helium開発資料](https://github.com/imputnet/helium-macos/blob/main/docs/building.md)、[Chromium macOSビルド資料](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md)

推さない案の理由は明確です。

- **Alloy NSView埋め込み：** 必須のChrome UI依存機能を満たす根拠がない。[CEF #3685](https://github.com/chromiumembedded/cef/issues/3685)
- **CEF Chrome styleの重ね窓：** 試作には近いが、オーバーレイ問題と必須4拡張の未検証が残る。[cmux PR](https://github.com/manaflow-ai/cmux/pull/10197)
- **外部Heliumの重ね窓：** 位置制御はできても、アプリ・フォーカス・ウィンドウ所有関係を統合できない。[CDP Browser](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Browser.pdl)、[AppKit](https://developer.apple.com/documentation/appkit/nswindow/addchildwindow%28_%3Aordered%3A%29)
- **CDP映像転送：** 拡張UIとIMEを含むブラウザ表示系の再構築になる。[Page](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Page.pdl)、[Input](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Input.pdl)

なお、推奨案でも**ClaudeのHelium上の実動作と、1Passwordの署名・native連携は採用前に実機確認が必要**です。公式サポートまで必須なら、今回の資料から「独自Idatenで必須4拡張を保証できる」と言える案はありません。[Claude対応範囲](https://support.claude.com/en/articles/12012173-get-started-with-claude-in-chrome)、[1Password追加ブラウザ](https://support.1password.com/additional-browsers/)
tokens used
121,976
**結論：既存のSwift製IdatenのNSViewへ、拡張対応のCEF Chrome styleをそのまま埋め込む方法は、2026年9月22日時点でも公式には対応していません。** 親NSViewを指定するとAlloy styleになる制約が現行ヘッダに残っています。[CEF公式ヘッダ](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types_mac.h)

「1ウィンドウ・共通タブバー・必須拡張」を優先するなら、**Heliumを基盤としてIdatenの操作体系を移植する案**を推します。ただし、これはブラウザ基盤の変更です。**現在のSwiftウィンドウを維持する条件まで固定すると、短期間で壊れにくく実現できる完成解は今回確認できませんでした。** 以下、確認事項と推測を分けます。

コード変更・アプリ起動・拡張インストールは行っていません。過去調査の訂正部分を先に確認し、現状が専用プロファイル付き外部プロセス起動であることも確認しました。[過去調査:347](/Users/yu01/idaten-browser/docs/prior-art-research-2026-09-19.txt:347)、[Engines.swift:106](/Users/yu01/idaten-browser/Sources/Idaten/Engines.swift:106)

**1. CEF Chrome styleを既存NSViewの子にできるか**

| 項目 | 判定・根拠 |
|---|---|
| macOSの`SetAsChild`相当 | **APIは存在する。** `CefWindowInfo::SetAsChild`は`parent_view`へ親を設定する。[cef_mac.h](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_mac.h) |
| そのままChrome styleで動くか | **公式仕様上できない。** macOSでは`parent_view`指定、またはwindowless指定でAlloy styleになる。[cef_types_mac.h](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types_mac.h) |
| Alloyとの違い | Chrome styleはChrome UI層、Alloy styleはChromium content層を基盤とする。Alloyは追加コールバックとOSRを提供するが、標準ブラウザ機能が少ない。[runtime style定義](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types_runtime.h) |
| 対応したバージョン | **macOSのChrome style＋外部NSView親に対応したリリースは確認できない。** 関連する[#3294](https://github.com/chromiumembedded/cef/issues/3294)はOpen。公式の外部native parent対応表はChrome styleについてWindows/Linuxのみを挙げる。[#3685](https://github.com/chromiumembedded/cef/issues/3685) |
| 混同しやすいバージョン | **125.0.8以降**はChrome bootstrap上でAlloy styleを利用可能。**M128**で削除されたのはAlloy **bootstrap**と旧Alloy拡張APIであり、Alloy **style**ではない。[#3685](https://github.com/chromiumembedded/cef/issues/3685) |

CEF Viewsを使う構成は別です。Chrome styleの`CefWindow`と`CefBrowserView`は利用できますが、既存AppKitビューへの埋め込み対応を意味しません。また、公式定義では**1つのChrome style WindowがホストできるChrome style BrowserViewは最大1つ**です。「CEF Viewsへ移れば独自タブバー配下に複数のChrome BrowserViewを簡単に置ける」とも判断できません。[CEF runtime style定義](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types_runtime.h)

**2. その状態でChrome Web Store拡張が動くか**

まず、**「既存NSViewに埋め込まれたChrome style」という前提が成立しません。** 実際に成立するAlloy埋め込みと、Chrome styleウィンドウを分ける必要があります。[macOS公式仕様](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types_mac.h)

| 機能 | 確認できたこと | 確認できないこと |
|---|---|---|
| content script | cmuxのCEF 151・Chrome style試作で、unpacked MV3拡張のcontent script実行を作者が報告。[PR #10197](https://github.com/manaflow-ai/cmux/pull/10197) | それをAlloy埋め込みや必須4拡張の完全動作へ一般化する根拠。 |
| extension service worker | ChromeにはMV3 workerの登録・実行機構がある。[Chrome公式](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/basics) | macOSの当該埋め込み構成での起動・休止・再開・イベント配送の実証。content script成功だけでは証明できない。 |
| `sidePanel` | ブラウザ側のサイドパネルへ拡張ページを表示するAPI。[Chrome公式](https://developer.chrome.com/docs/extensions/reference/api/sidePanel) | Alloy埋め込みで同等UIが使える根拠。Chrome styleでも、ツールバーを隠した今回の構成でClaudeが完全動作する実証。 |
| action popup | Chromiumにはブラウザウィンドウ・タブモデルに接続する専用popup実装がある。[Chromium実装](https://github.com/chromium/chromium/blob/main/chrome/browser/ui/views/extensions/extension_popup.cc) | 独自Swiftタブバーへ自動的にpopupの起点・フォーカス・寿命が接続される根拠。 |
| `chrome.debugger` | 拡張から対象タブへattachするChrome APIは存在。[Chrome公式](https://developer.chrome.com/docs/extensions/reference/api/debugger) | CEF埋め込み構成でClaudeのattach・操作が成功する実証。外部CDPが使えるだけでは証明にならない。 |
| `nativeMessaging` | ホストmanifest、`allowed_origins`、実行ファイルとの通信が必要。macOSではブラウザによってmanifest探索先が異なる。[Chrome公式](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) | CEF／IdatenでClaude・1Passwordのホストが正しく検出され、相手側にも受け入れられる実証。 |

**Alloyで拡張が一切動かない、と断定するのも不正確です。** 過去調査には、RequestContextレベルの機能は動作し得るがChrome UI依存機能は対応しない、というメンテナ発言の検証記録があります。今回、そのGitHubコメント本文・フォーラム本文は再取得できなかったため、これは**ローカル調査記録での確認**として扱います。[過去調査:262](/Users/yu01/idaten-browser/docs/prior-art-research-2026-09-19.txt:262)、[対象issue #3859](https://github.com/chromiumembedded/cef/issues/3859)

また、**CWSで配布される拡張を展開して読み込むこと**と、**CWSから直接インストール・更新できること**は別です。cmuxで確認できる経路は`--load-extension`によるunpacked読み込みです。今回、CEFの該当macOS構成についてCWS直接導入・更新の保証は確認できませんでした。[cmux PR](https://github.com/manaflow-ai/cmux/pull/10197)

必須拡張への影響は次のとおりです。

- **Claude in Chrome：最大の障害。** 公式に`sidePanel`・`debugger`・`nativeMessaging`に加え`tabs`・`tabGroups`等を要求します。さらに公式は**他のChromium系ブラウザをサポート対象外**としています。Helium／CEFで「動作する可能性」と「公式サポート」は分ける必要があります。[Claude公式](https://support.claude.com/en/articles/12012173-get-started-with-claude-in-chrome)
- **OneTab：タブモデルの統合が必要。** 主機能はタブの回収・復元です。**推測：** Swift側だけに存在するWKWebViewタブは、通常のChrome拡張APIから自動的には見えず、見た目を統一してもOneTabの操作対象は統一されません。[OneTab公式](https://www.one-tab.com/)、[tabs API](https://developer.chrome.com/docs/extensions/reference/api/tabs)
- **Stylus：CSS適用だけでは合格にならない。** 作者資料にはcontent scriptだけでなくpopup・管理機能もあります。CEFでの設定・編集・保存を含む完全動作は未確認です。[Stylus公式リポジトリ](https://github.com/openstyles/stylus)
- **1Password：拡張とデスクトップ連携を別々に検証する必要があります。** macOSでは追加ブラウザの登録制度があり、公式手順はApplications内のAppleコード署名済みブラウザを要求しています。自作CEFアプリでの連携成功は未確認です。[1Password公式](https://support.1password.com/additional-browsers/)

**3a. HeliumをCDPで制御し、ウィンドウを重ねる案**

**確認できた範囲では、タブ制御と位置追従の試作は可能です。** CDPには`Target.getTargets`、`createTarget`、`activateTarget`、`closeTarget`、`Browser.getWindowForTarget`、`setWindowBounds`があります。[Target仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Target.pdl)、[Browser仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Browser.pdl)

ただし、**位置・サイズ制御はウィンドウの所有関係の統合ではありません。** AppKitの`addChildWindow`は`NSWindow`オブジェクトを受け取るAPIで、CDPのwindow IDを渡して外部アプリの窓を取り込むAPIではありません。今回、これを実現する公開APIは確認できませんでした。[Apple公式](https://developer.apple.com/documentation/appkit/nswindow/addchildwindow%28_%3Aordered%3A%29)

致命的な欠点は以下です。

- **推測：フォーカスとウィンドウ順序が二重管理になる。** 内容領域はHelium、タブバーはIdatenに属するため、クリック・キーボード操作・最小化・Spaces・フルスクリーン・モーダル表示を一体として扱う追加制御が必要になります。CDPのbounds制御には、その統合契約がありません。[CDP Browser仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Browser.pdl)、[NSWindowの役割](https://developer.apple.com/documentation/appkit/nswindow)
- **`--app`は埋め込みAPIではない。** ChromiumにはURLをapp modeで起動する経路がありますが、外部NSViewへのparent指定や、完全な枠なし表示を保証するものではありません。Heliumの当該モードでClaudeのsidePanel・各拡張の起動UIを維持できるかも未確認です。[Chromium起動API](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/shell_integration.h)、[sidePanel仕様](https://developer.chrome.com/docs/extensions/reference/api/sidePanel)
- **推測：拡張が生成したタブ・窓まで追従させる必要がある。** `createTarget`は新規ページを作るAPIで、既存app windowへ任意タブを挿入する汎用window指定は確認できません。OneTabの一括復元やClaudeのタブ生成まで含めた表示先統合が残ります。[Target仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Target.pdl)

cmuxの試作は**同一アプリ内のCEFウィンドウ**を重ねる方式であり、外部Heliumを取り込んだ前例ではありません。それでもSwiftUIオーバーレイが下に隠れる問題が記載され、当日revertされています。revert理由自体は確認できないため、「方式が原因で撤回された」とは断定しません。[実装PR](https://github.com/manaflow-ai/cmux/pull/10197)、[revert PR](https://github.com/manaflow-ai/cmux/pull/11966)

**3b. `Page.startScreencast`で映像を転送する案**

**ページ画像と入力転送の仕組みは存在します。** ScreencastはJPEG／PNGフレームを送り、Inputにはマウス・キー・文字入力・IME compositionのAPIがあります。[Page仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Page.pdl)、[Input仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Input.pdl)

ただし、日常用ブラウザとしては次が重大です。

| 対象 | 欠点・判定 |
|---|---|
| 拡張UI | **通常ページのscreencastだけでは、ブラウザ側のsidePanelや別popupを一緒に表示できない。** それらはページとは別のUIです。別ターゲットの映像を取得できても、配置・フォーカス・開閉を再構成する必要があります。後半は**推測**。[Page仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Page.pdl)、[sidePanel](https://developer.chrome.com/docs/extensions/reference/api/sidePanel)、[popup実装](https://github.com/chromium/chromium/blob/main/chrome/browser/ui/views/extensions/extension_popup.cc) |
| 日本語IME | **不可能ではないが、キー転送だけでは完成しない。** Idaten側でmarked text・選択範囲・候補位置などを扱い、CDPへcompositionを橋渡しする必要がある、という**推測**。任意のWebエディタでの再変換・候補位置の正常動作は未確認。[Input仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Input.pdl)、[Apple NSTextInputClient](https://developer.apple.com/documentation/appkit/nstextinputclient?changes=_10%2C_10%2C_10%2C_10) |
| 動画・音声 | 映像は圧縮静止画列で、音声転送はこのAPIに含まれない。**推測：** エンコード・デコード負荷と表示遅延が加わり、Heliumから直接出る音声との同期も課題になる。動画のfps・DRM・最小化時挙動は未検証。[Page仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Page.pdl) |

**今回の要件で特に致命的なのは、ClaudeのsidePanelを含むブラウザUIが、通常ページの映像一本では完結しないことです。** 画面を表示する試作の成功を、拡張付きブラウザの完成とみなせません。[Claude公式](https://support.claude.com/en/articles/12012173-get-started-with-claude-in-chrome)、[CDP Page仕様](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Page.pdl)

**4. 推す案と却下理由**

**推奨は、Heliumをフォークし、Chromium自身のウィンドウ・タブモデル・拡張UIを維持しながらIdatenの操作体系を移植する案です。これは設計判断・推測です。** HeliumにはCWS拡張対応、タブグループ等があり、macOS向けの開発環境も公開されています。[Helium公式](https://helium.computer/)、[開発資料](https://github.com/imputnet/helium-macos/blob/main/docs/building.md)

最初の到達点を「全タブをChromiumに統一した1つのIdatenアプリ」とし、既存の拡張UI・タブモデルを残す方針です。**推測：** これなら、外部ウィンドウ追従、IMEの再実装、映像への拡張UI合成、SwiftタブとChromeタブの対応付けを避けられ、完成までの不確実性を減らせます。根拠は上記のCEF制約・CDPの範囲・Chromiumのpopup実装です。[CEF制約](https://github.com/chromiumembedded/cef/blob/master/include/internal/cef_types_mac.h)、[CDP](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Browser.pdl)、[popup実装](https://github.com/chromium/chromium/blob/main/chrome/browser/ui/views/extensions/extension_popup.cc)

ただし、**最短工期を実証した比較資料はありません。** 自前ビルドと更新追従は必要で、現在のSwift UIの維持にもなりません。したがって「小変更で完成する案」ではなく、**要件を満たすまでの手戻りを減らす案としての推奨**です。[Helium開発資料](https://github.com/imputnet/helium-macos/blob/main/docs/building.md)、[Chromium macOSビルド資料](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md)

推さない案の理由は明確です。

- **Alloy NSView埋め込み：** 必須のChrome UI依存機能を満たす根拠がない。[CEF #3685](https://github.com/chromiumembedded/cef/issues/3685)
- **CEF Chrome styleの重ね窓：** 試作には近いが、オーバーレイ問題と必須4拡張の未検証が残る。[cmux PR](https://github.com/manaflow-ai/cmux/pull/10197)
- **外部Heliumの重ね窓：** 位置制御はできても、アプリ・フォーカス・ウィンドウ所有関係を統合できない。[CDP Browser](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Browser.pdl)、[AppKit](https://developer.apple.com/documentation/appkit/nswindow/addchildwindow%28_%3Aordered%3A%29)
- **CDP映像転送：** 拡張UIとIMEを含むブラウザ表示系の再構築になる。[Page](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Page.pdl)、[Input](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Input.pdl)

なお、推奨案でも**ClaudeのHelium上の実動作と、1Passwordの署名・native連携は採用前に実機確認が必要**です。公式サポートまで必須なら、今回の資料から「独自Idatenで必須4拡張を保証できる」と言える案はありません。[Claude対応範囲](https://support.claude.com/en/articles/12012173-get-started-with-claude-in-chrome)、[1Password追加ブラウザ](https://support.1password.com/additional-browsers/)
