codex
**結論：最初は manifest をコピーせず、既存の Chrome 用登録を使って検証してください。** Chromium のユーザー用 Native Messaging 探索先は `--user-data-dir` に追従しますが、Helium のパッチは Chrome の既定領域を別途探索します。ただし、今回取得できたパッチは `main` であり、**インストール済み 0.17.2.2 の探索動作は実行確認が必要**です。[Chromium実装](https://github.com/chromium/chromium/blob/main/chrome/common/chrome_paths.cc#L458)、[Heliumパッチ](https://github.com/imputnet/helium/blob/main/patches/helium/core/scan-chrome-native-messaging-hosts.patch)

以下は実行担当者向けの手順書です。今回、アプリ起動・拡張導入・ファイル変更・`claude` 実行はしていません。

**1. ローカルで確認できた前提**

| 項目 | 読み取り結果・根拠 |
|---|---|
| Helium | `~/Applications/Helium.app`、**0.17.2.2**。[Info.plist:171](/Users/yu01/Applications/Helium.app/Contents/Info.plist:171) |
| Claude Code 用ホスト | `com.anthropic.claude_code_browser_extension`。`type: stdio`、実行先は `/Users/yu01/.claude/chrome/chrome-native-host`。[manifest:2](</Users/yu01/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json:2>) |
| 許可された拡張 | `chrome-extension://fcoeoabgfenejglbffodgkkbkcdhcgfn/`。[manifest:6](</Users/yu01/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json:6>) |
| ホストの実体 | ラッパーは `/Users/yu01/.local/bin/claude --chrome-native-host` を `exec` する。[ラッパー:4](/Users/yu01/.claude/chrome/chrome-native-host:4) |
| 既存の検証候補プロファイル | `044F76FC-7238-4683-9D87-2F51396DE649` の `chromium-profile/Default` 内に対象拡張 **1.0.94** が存在。ファイルの存在確認であり、有効化・ログイン状態は未確認。[拡張manifest:54](</Users/yu01/Library/Application Support/Idaten/Profiles/044F76FC-7238-4683-9D87-2F51396DE649/chromium-profile/Default/Extensions/fcoeoabgfenejglbffodgkkbkcdhcgfn/1.0.94_0/manifest.json:54>) |
| 拡張権限 | `nativeMessaging`、`tabs`、`scripting`、`debugger` 等を宣言。[拡張manifest:49](</Users/yu01/Library/Application Support/Idaten/Profiles/044F76FC-7238-4683-9D87-2F51396DE649/chromium-profile/Default/Extensions/fcoeoabgfenejglbffodgkkbkcdhcgfn/1.0.94_0/manifest.json:49>) |

**2. 接続先の検出と Native Messaging の関係**

公式資料では、Claude Code は複数の Chromium 系ブラウザに対応し、`/chrome` で接続状態の確認・再接続・接続先選択を行います。**Helium を明示した対応保証や、ブラウザ探索アルゴリズム全体の説明はありません。** [Claude Code公式](https://code.claude.com/docs/en/chrome)

ローカル実物から確認できる Native Messaging 経路は次です。

```text
Helium 上の Claude 拡張
  → runtime.connectNative("com.anthropic.claude_code_browser_extension")
  → Helium がホスト manifest を探索
  → ~/.claude/chrome/chrome-native-host
  → /Users/yu01/.local/bin/claude --chrome-native-host
  ↔ 拡張との stdio 通信
```

ブラウザが manifest の実行先を起動する仕組みです。`~/.claude/chrome/` 自体がブラウザの manifest 探索先になるわけではありません。[Chrome仕様](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)、[ローカルmanifest:4](</Users/yu01/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json:4>)

**現在の拡張には、これとは別にクラウドブリッジ経路もあります。** ローカル 1.0.94 の service worker は、`wss://bridge.claudeusercontent.com` に接続し、`device_id`、表示名、拡張バージョン等を送信します。Native Messaging 側では Desktop 用ホスト、Code 用ホストの順に `ping` を送り、最初に `pong` を返したホストを使用するコードがあります。[service worker:1](</Users/yu01/Library/Application Support/Idaten/Profiles/044F76FC-7238-4683-9D87-2F51396DE649/chromium-profile/Default/Extensions/fcoeoabgfenejglbffodgkkbkcdhcgfn/1.0.94_0/assets/service-worker.ts-HKLyjT1Y.js:1>)

したがって、検証結果は次のように区別します。

- **CLI→Helium→ページ読取成功**：今回の主目的を満たす。
- **Code 用ホストへの直接 `ping` 成功**：Helium から当該 Native Messaging ホストに到達できる。
- 両方成功しても、**ページ読取自体が Native Messaging 経由だったことまでは確定しない**。その主張には接続ログとの対応付けが必要。

これは上記の複数経路を持つ実装からの検証上の判断です。

**3. `--user-data-dir` による manifest 探索先の変化**

Chromium は `--user-data-dir` を `chrome::DIR_USER_DATA` に反映し、ユーザー用ホストの探索先を、その直下の `NativeMessagingHosts` とします。`Default` や `Profile 1` の直下ではありません。[起動引数の反映](https://github.com/chromium/chromium/blob/main/chrome/app/chrome_main_delegate.cc#L607)、[探索先の組立](https://github.com/chromium/chromium/blob/main/chrome/common/chrome_paths.cc#L458)

Idaten は実際に、プロファイルごとの `chromium-profile` を `--user-data-dir` に渡しています。[Profile.swift:100](/Users/yu01/idaten-browser/Sources/Idaten/Profile.swift:100)、[ChromiumDock.swift:190](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:190)

Helium パッチ適用時の探索順は次です。各ディレクトリの下で、`com.anthropic.claude_code_browser_extension.json` を探します。[探索順とChrome固定領域](https://github.com/imputnet/helium/blob/main/patches/helium/core/scan-chrome-native-messaging-hosts.patch)

| 順序 | Idaten 起動時の探索先 |
|---|---|
| 1 | `~/Library/Application Support/Idaten/Profiles/<id>/chromium-profile/NativeMessagingHosts/` |
| 2 | `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/` |
| 3 | 自ブラウザのシステム用 `DIR_NATIVE_MESSAGING`。これはユーザーデータ指定では移動しない |
| 4 | `/Library/Google/Chrome/NativeMessagingHosts/` |

ユーザー用の 1・2 は、ユーザー用ホストが許可されている場合に探索します。Chrome 側の 2 は `GetDefaultUserDataDirectoryForProduct("Google/Chrome", …)` で組み立てられるため、**Helium の `--user-data-dir` には追従しません**。[Heliumパッチ](https://github.com/imputnet/helium/blob/main/patches/helium/core/scan-chrome-native-messaging-hosts.patch)

**実行方針：まずコピーなし。** 既存の Chrome 側 manifest でホストに到達するかを確認します。失敗時だけ、選択したユーザーデータ直下への配置を比較試験に使います。先行する同名 manifest が存在すると、後順位の正常な manifest を隠す可能性があります。[manifest探索](https://github.com/chromium/chromium/blob/main/chrome/browser/extensions/api/messaging/launch_context_posix.cc)、[取得後の検証処理](https://github.com/chromium/chromium/blob/main/chrome/browser/extensions/api/messaging/launch_context.cc)

**4. 実行手順：既存プロファイルで1本通す**

以下のコマンド・ブラウザ操作は、すべて**実行担当者が今後行うもの**です。

**A. 検証対象を固定する**

既存拡張を利用する場合の対象：

```sh
HELIUM_TEST_UDD="$HOME/Library/Application Support/Idaten/Profiles/044F76FC-7238-4683-9D87-2F51396DE649/chromium-profile"
```

Idaten と対象 Helium を通常終了してから、単体 Helium で同じデータ領域を開きます。同じユーザーデータを別プロセスと同時使用しない構成にします。ユーザーデータ指定によるインスタンス分離は [Chromium公式資料](https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md) を参照。

```sh
"$HOME/Applications/Helium.app/Contents/MacOS/Helium" \
  "--user-data-dir=$HELIUM_TEST_UDD" \
  --profile-directory=Default \
  --enable-logging=stderr \
  --log-level=1
```

ログ指定は Native Messaging の探索・起動エラーを観測するためです。[Chrome診断手順](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging#debug-native-messaging)

ブラウザ内で次を確認します。

1. `chrome://version` の Profile Path が対象の `chromium-profile/Default` である。
2. `chrome://extensions` に対象 ID があり、有効になっている。
3. Claude 拡張のログイン・初回設定を完了する。

Profile Path の確認方法は [Chromium資料](https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md)、拡張の確認は [Claude Code公式](https://code.claude.com/docs/en/chrome#extension-not-detected) に基づきます。

**B. Code 用 Native Messaging ホストを直接確認する**

`chrome://extensions` で対象拡張の service worker の検証画面を開き、Console で次を実行します。通常のWebページのConsoleでは実行できません。[APIを使用できるコンテキスト](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging#connecting-to-a-native-application)

```js
await new Promise((resolve) => {
  const port = chrome.runtime.connectNative(
    "com.anthropic.claude_code_browser_extension"
  );
  let finished = false;
  let timer;
  const finish = (result) => {
    if (finished) return;
    finished = true;
    clearTimeout(timer);
    resolve(result);
    port.disconnect();
  };
  port.onMessage.addListener((message) => {
    if (message.type === "pong") finish({ ok: true, type: "pong" });
  });
  port.onDisconnect.addListener(() => {
    const error = chrome.runtime.lastError?.message;
    finish({ ok: false, error: error || "disconnected" });
  });
  timer = setTimeout(() => finish({ ok: false, error: "timeout" }), 10000);
  port.postMessage({ type: "ping" });
});
```

`ping`／`pong` と10秒待機は、ローカル拡張自身の接続処理に合わせています。この操作は**ホスト経由で `claude --chrome-native-host` を起動します**。[service worker:1](</Users/yu01/Library/Application Support/Idaten/Profiles/044F76FC-7238-4683-9D87-2F51396DE649/chromium-profile/Default/Extensions/fcoeoabgfenejglbffodgkkbkcdhcgfn/1.0.94_0/assets/service-worker.ts-HKLyjT1Y.js:1>)

合格値は `{ok: true, type: "pong"}`。これは Code 用ホストを明示するため、Desktop 用ホストの成功との混同を避けられます。

**C. 初回だけ対話で接続・権限を準備する**

```sh
"$HOME/.local/bin/claude" --chrome
```

- `/login` による直接 Anthropic アカウント認証を使う。APIキーや `setup-token` 認証では現行の Chrome 連携は無効になる。
- `/chrome` で接続先を確認し、複数候補があれば検証用 Helium を選ぶ。
- `/mcp` → `claude-in-chrome` → View tools で実際のツール名を確認する。
- `https://example.com/` の読取に必要なサイト権限を準備する。

以上は [Claude Code Chrome連携の公式手順](https://code.claude.com/docs/en/chrome) に基づきます。候補の表示名だけで判別できなければ、Helium にタブが作られることと Profile Path を照合してください。

**D. 非対話でページタイトルを読む**

**初回設定後なら `claude -p --chrome` による試験を構成できます。** ただし、未ログイン・初回許可・接続先選択待ちまで無人で解決する手順ではありません。以下は公式の `-p`／ツール許可／JSONストリーム機能を組み合わせた**未実行の検証案**です。[非対話実行](https://code.claude.com/docs/en/headless)、[CLI引数](https://code.claude.com/docs/en/cli-reference)

```sh
"$HOME/.local/bin/claude" \
  --chrome \
  --print \
  --tools "" \
  --allowedTools \
  "mcp__claude-in-chrome__tabs_context_mcp,mcp__claude-in-chrome__tabs_create_mcp,mcp__claude-in-chrome__navigate,mcp__claude-in-chrome__javascript_tool" \
  --max-turns 12 \
  --output-format stream-json \
  --verbose \
  '接続済みの検証用Heliumでブラウザ読取試験を行う。
claude-in-chromeのMCPツールだけを使用する。
tabs_context_mcpでこのセッションのタブを確認し、必要なら作成する。
対象タブを https://example.com/ にnavigateする。
javascript_toolで JSON.stringify({title:document.title,url:location.href}) を実行する。
読取に成功したら取得した値をそのまま報告する。
接続・権限・ブラウザ選択の問題があれば失敗として報告し、代替手段は使わない。'
```

`--tools ""` は組み込みツールを無効化し、MCPツールは残します。`--allowedTools` は許可設定であり、MCPツール全体の限定ではありません。[CLI仕様](https://code.claude.com/docs/en/cli-reference)

ツール名はローカル拡張でも確認できていますが、実際の公開ツール一覧と違う場合は C の一覧を優先します。[ローカルのツール名・タブ制約:2](</Users/yu01/Library/Application Support/Idaten/Profiles/044F76FC-7238-4683-9D87-2F51396DE649/chromium-profile/Default/Extensions/fcoeoabgfenejglbffodgkkbkcdhcgfn/1.0.94_0/assets/mcpPermissions-tSjXinpi.js:2>)

**機械判定は、終了コードや最終文章だけでなくツール結果を見る設計にしてください。**

合格条件として、JSONストリームから次を照合します。

1. `mcp__claude-in-chrome__javascript_tool` の `tool_use` がある。
2. 対応する `tool_use_id` の `tool_result` がエラーではない。
3. その結果に、実際に取得された `title` と `https://example.com/` の URL がある。
4. 最後の `result` が成功で、CLI の終了コードも0。
5. 同じ試験タブが検証用 Helium に現れたことを初回に確認する。

JSONストリームと最終 `result` は [公式の出力仕様](https://code.claude.com/docs/en/headless#stream-responses) に基づきます。上記の合格条件は、モデルの回答だけを通信成功と誤認しないための提案です。**既知のタイトル文字列を回答しただけ、タブ一覧だけ取得できた、は不合格**とします。

**E. Idaten 経由で再確認する**

単体試験後に Helium を通常終了し、Idaten で同じプロファイルの Chromium タブを開いて D を再実行します。Idaten は `--remote-debugging-pipe` と `--no-startup-window` を追加して起動するため、単体起動と分けて結果を記録します。[起動実装:190](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:190)

**5. 失敗時の切り分け表**

| 症状 | 確認・次の試験 | 根拠 |
|---|---|---|
| `Specified native messaging host not found` | 選択した UDD 直下と Chrome 固定領域の manifest を確認。`Default/NativeMessagingHosts` への誤配置を確認 | [探索実装](https://github.com/chromium/chromium/blob/main/chrome/common/chrome_paths.cc#L458) |
| Chrome 側にあるのに見つからない | 既存版のパッチ動作、ユーザー用ホストの許可を疑う。比較試験として UDD 直下に同じ manifest を配置して再試験 | [Heliumパッチ](https://github.com/imputnet/helium/blob/main/patches/helium/core/scan-chrome-native-messaging-hosts.patch) |
| JSON解析・manifest不正 | UDD 側の同名ファイルも確認。先に見つかった不正ファイルが Chrome 側を隠していないか調べる | [探索](https://github.com/chromium/chromium/blob/main/chrome/browser/extensions/api/messaging/launch_context_posix.cc)、[解析](https://github.com/chromium/chromium/blob/main/chrome/browser/extensions/api/messaging/launch_context.cc) |
| `Access ... forbidden` | `allowed_origins` の拡張ID、Native Messaging 関連ポリシーを確認 | [Chrome診断](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging#common-errors) |
| `Failed to start native messaging host` | manifest の絶対パス、ラッパーと CLI の実行権限、CLIリンク先の存在を確認 | [Chrome診断](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging#common-errors)、[ラッパー:4](/Users/yu01/.claude/chrome/chrome-native-host:4) |
| `Native host has exited`／通信形式エラー | ブラウザstderrを見る。ホストの早期終了やstdoutへの余分な出力を調べる | [Native Messaging仕様・診断](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) |
| `ping` は成功、CLIにはブラウザが出ない | manifest探索は通過済み。CLIの認証、拡張ログイン、ブリッジ接続、選択状態を確認 | [公式トラブルシュート](https://code.claude.com/docs/en/chrome#troubleshooting) |
| `--chrome` でもツールがない／403 | `/login` 認証か確認。APIキー・長期トークン・第三者プロバイダー認証を切り分ける | [公式前提条件](https://code.claude.com/docs/en/chrome#prerequisites) |
| `Browser extension is not connected` | 再接続。ブリッジ宛通信が組織ネットワークで拒否されていないか確認 | [公式エラー一覧](https://code.claude.com/docs/en/chrome#common-error-messages) |
| `No tab available`／タブがセッション外 | `tabs_context_mcp` と `tabs_create_mcp` で当該セッションのタブを使う | [ローカル制約:2](</Users/yu01/Library/Application Support/Idaten/Profiles/044F76FC-7238-4683-9D87-2F51396DE649/chromium-profile/Default/Extensions/fcoeoabgfenejglbffodgkkbkcdhcgfn/1.0.94_0/assets/mcpPermissions-tSjXinpi.js:2>) |
| `-p` だけ失敗 | サイト権限・ブラウザ選択が未完了か確認。対話モードで準備してから再試験 | [Chrome連携](https://code.claude.com/docs/en/chrome)、[非対話実行](https://code.claude.com/docs/en/headless) |
| 放置後に切断 | `/chrome` から再接続。service worker の休止を確認 | [公式切断対策](https://code.claude.com/docs/en/chrome#connection-drops-during-long-sessions) |
| Chromeで成功してHeliumで失敗 | 同じ拡張版・認証・ページ・試験内容で比較し、Helium側のホスト探索と拡張APIの問題を分離 | [Chrome仕様](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)、[Heliumパッチ](https://github.com/imputnet/helium/blob/main/patches/helium/core/scan-chrome-native-messaging-hosts.patch) |

記録する結果は、**使用UDD／拡張版／Codeホストのpong有無／選択したブラウザ／ページ読取のtool result／CLI終了コード／単体とIdaten経由の差**です。manifest を追加した場合は「コピーなしで成功」と混同しないよう、その条件も残してください。
tokens used
91,480
**結論：最初は manifest をコピーせず、既存の Chrome 用登録を使って検証してください。** Chromium のユーザー用 Native Messaging 探索先は `--user-data-dir` に追従しますが、Helium のパッチは Chrome の既定領域を別途探索します。ただし、今回取得できたパッチは `main` であり、**インストール済み 0.17.2.2 の探索動作は実行確認が必要**です。[Chromium実装](https://github.com/chromium/chromium/blob/main/chrome/common/chrome_paths.cc#L458)、[Heliumパッチ](https://github.com/imputnet/helium/blob/main/patches/helium/core/scan-chrome-native-messaging-hosts.patch)

以下は実行担当者向けの手順書です。今回、アプリ起動・拡張導入・ファイル変更・`claude` 実行はしていません。

**1. ローカルで確認できた前提**

| 項目 | 読み取り結果・根拠 |
|---|---|
| Helium | `~/Applications/Helium.app`、**0.17.2.2**。[Info.plist:171](/Users/yu01/Applications/Helium.app/Contents/Info.plist:171) |
| Claude Code 用ホスト | `com.anthropic.claude_code_browser_extension`。`type: stdio`、実行先は `/Users/yu01/.claude/chrome/chrome-native-host`。[manifest:2](</Users/yu01/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json:2>) |
| 許可された拡張 | `chrome-extension://fcoeoabgfenejglbffodgkkbkcdhcgfn/`。[manifest:6](</Users/yu01/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json:6>) |
| ホストの実体 | ラッパーは `/Users/yu01/.local/bin/claude --chrome-native-host` を `exec` する。[ラッパー:4](/Users/yu01/.claude/chrome/chrome-native-host:4) |
| 既存の検証候補プロファイル | `044F76FC-7238-4683-9D87-2F51396DE649` の `chromium-profile/Default` 内に対象拡張 **1.0.94** が存在。ファイルの存在確認であり、有効化・ログイン状態は未確認。[拡張manifest:54](</Users/yu01/Library/Application Support/Idaten/Profiles/044F76FC-7238-4683-9D87-2F51396DE649/chromium-profile/Default/Extensions/fcoeoabgfenejglbffodgkkbkcdhcgfn/1.0.94_0/manifest.json:54>) |
| 拡張権限 | `nativeMessaging`、`tabs`、`scripting`、`debugger` 等を宣言。[拡張manifest:49](</Users/yu01/Library/Application Support/Idaten/Profiles/044F76FC-7238-4683-9D87-2F51396DE649/chromium-profile/Default/Extensions/fcoeoabgfenejglbffodgkkbkcdhcgfn/1.0.94_0/manifest.json:49>) |

**2. 接続先の検出と Native Messaging の関係**

公式資料では、Claude Code は複数の Chromium 系ブラウザに対応し、`/chrome` で接続状態の確認・再接続・接続先選択を行います。**Helium を明示した対応保証や、ブラウザ探索アルゴリズム全体の説明はありません。** [Claude Code公式](https://code.claude.com/docs/en/chrome)

ローカル実物から確認できる Native Messaging 経路は次です。

```text
Helium 上の Claude 拡張
  → runtime.connectNative("com.anthropic.claude_code_browser_extension")
  → Helium がホスト manifest を探索
  → ~/.claude/chrome/chrome-native-host
  → /Users/yu01/.local/bin/claude --chrome-native-host
  ↔ 拡張との stdio 通信
```

ブラウザが manifest の実行先を起動する仕組みです。`~/.claude/chrome/` 自体がブラウザの manifest 探索先になるわけではありません。[Chrome仕様](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)、[ローカルmanifest:4](</Users/yu01/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json:4>)

**現在の拡張には、これとは別にクラウドブリッジ経路もあります。** ローカル 1.0.94 の service worker は、`wss://bridge.claudeusercontent.com` に接続し、`device_id`、表示名、拡張バージョン等を送信します。Native Messaging 側では Desktop 用ホスト、Code 用ホストの順に `ping` を送り、最初に `pong` を返したホストを使用するコードがあります。[service worker:1](</Users/yu01/Library/Application Support/Idaten/Profiles/044F76FC-7238-4683-9D87-2F51396DE649/chromium-profile/Default/Extensions/fcoeoabgfenejglbffodgkkbkcdhcgfn/1.0.94_0/assets/service-worker.ts-HKLyjT1Y.js:1>)

したがって、検証結果は次のように区別します。

- **CLI→Helium→ページ読取成功**：今回の主目的を満たす。
- **Code 用ホストへの直接 `ping` 成功**：Helium から当該 Native Messaging ホストに到達できる。
- 両方成功しても、**ページ読取自体が Native Messaging 経由だったことまでは確定しない**。その主張には接続ログとの対応付けが必要。

これは上記の複数経路を持つ実装からの検証上の判断です。

**3. `--user-data-dir` による manifest 探索先の変化**

Chromium は `--user-data-dir` を `chrome::DIR_USER_DATA` に反映し、ユーザー用ホストの探索先を、その直下の `NativeMessagingHosts` とします。`Default` や `Profile 1` の直下ではありません。[起動引数の反映](https://github.com/chromium/chromium/blob/main/chrome/app/chrome_main_delegate.cc#L607)、[探索先の組立](https://github.com/chromium/chromium/blob/main/chrome/common/chrome_paths.cc#L458)

Idaten は実際に、プロファイルごとの `chromium-profile` を `--user-data-dir` に渡しています。[Profile.swift:100](/Users/yu01/idaten-browser/Sources/Idaten/Profile.swift:100)、[ChromiumDock.swift:190](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:190)

Helium パッチ適用時の探索順は次です。各ディレクトリの下で、`com.anthropic.claude_code_browser_extension.json` を探します。[探索順とChrome固定領域](https://github.com/imputnet/helium/blob/main/patches/helium/core/scan-chrome-native-messaging-hosts.patch)

| 順序 | Idaten 起動時の探索先 |
|---|---|
| 1 | `~/Library/Application Support/Idaten/Profiles/<id>/chromium-profile/NativeMessagingHosts/` |
| 2 | `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/` |
| 3 | 自ブラウザのシステム用 `DIR_NATIVE_MESSAGING`。これはユーザーデータ指定では移動しない |
| 4 | `/Library/Google/Chrome/NativeMessagingHosts/` |

ユーザー用の 1・2 は、ユーザー用ホストが許可されている場合に探索します。Chrome 側の 2 は `GetDefaultUserDataDirectoryForProduct("Google/Chrome", …)` で組み立てられるため、**Helium の `--user-data-dir` には追従しません**。[Heliumパッチ](https://github.com/imputnet/helium/blob/main/patches/helium/core/scan-chrome-native-messaging-hosts.patch)

**実行方針：まずコピーなし。** 既存の Chrome 側 manifest でホストに到達するかを確認します。失敗時だけ、選択したユーザーデータ直下への配置を比較試験に使います。先行する同名 manifest が存在すると、後順位の正常な manifest を隠す可能性があります。[manifest探索](https://github.com/chromium/chromium/blob/main/chrome/browser/extensions/api/messaging/launch_context_posix.cc)、[取得後の検証処理](https://github.com/chromium/chromium/blob/main/chrome/browser/extensions/api/messaging/launch_context.cc)

**4. 実行手順：既存プロファイルで1本通す**

以下のコマンド・ブラウザ操作は、すべて**実行担当者が今後行うもの**です。

**A. 検証対象を固定する**

既存拡張を利用する場合の対象：

```sh
HELIUM_TEST_UDD="$HOME/Library/Application Support/Idaten/Profiles/044F76FC-7238-4683-9D87-2F51396DE649/chromium-profile"
```

Idaten と対象 Helium を通常終了してから、単体 Helium で同じデータ領域を開きます。同じユーザーデータを別プロセスと同時使用しない構成にします。ユーザーデータ指定によるインスタンス分離は [Chromium公式資料](https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md) を参照。

```sh
"$HOME/Applications/Helium.app/Contents/MacOS/Helium" \
  "--user-data-dir=$HELIUM_TEST_UDD" \
  --profile-directory=Default \
  --enable-logging=stderr \
  --log-level=1
```

ログ指定は Native Messaging の探索・起動エラーを観測するためです。[Chrome診断手順](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging#debug-native-messaging)

ブラウザ内で次を確認します。

1. `chrome://version` の Profile Path が対象の `chromium-profile/Default` である。
2. `chrome://extensions` に対象 ID があり、有効になっている。
3. Claude 拡張のログイン・初回設定を完了する。

Profile Path の確認方法は [Chromium資料](https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md)、拡張の確認は [Claude Code公式](https://code.claude.com/docs/en/chrome#extension-not-detected) に基づきます。

**B. Code 用 Native Messaging ホストを直接確認する**

`chrome://extensions` で対象拡張の service worker の検証画面を開き、Console で次を実行します。通常のWebページのConsoleでは実行できません。[APIを使用できるコンテキスト](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging#connecting-to-a-native-application)

```js
await new Promise((resolve) => {
  const port = chrome.runtime.connectNative(
    "com.anthropic.claude_code_browser_extension"
  );
  let finished = false;
  let timer;
  const finish = (result) => {
    if (finished) return;
    finished = true;
    clearTimeout(timer);
    resolve(result);
    port.disconnect();
  };
  port.onMessage.addListener((message) => {
    if (message.type === "pong") finish({ ok: true, type: "pong" });
  });
  port.onDisconnect.addListener(() => {
    const error = chrome.runtime.lastError?.message;
    finish({ ok: false, error: error || "disconnected" });
  });
  timer = setTimeout(() => finish({ ok: false, error: "timeout" }), 10000);
  port.postMessage({ type: "ping" });
});
```

`ping`／`pong` と10秒待機は、ローカル拡張自身の接続処理に合わせています。この操作は**ホスト経由で `claude --chrome-native-host` を起動します**。[service worker:1](</Users/yu01/Library/Application Support/Idaten/Profiles/044F76FC-7238-4683-9D87-2F51396DE649/chromium-profile/Default/Extensions/fcoeoabgfenejglbffodgkkbkcdhcgfn/1.0.94_0/assets/service-worker.ts-HKLyjT1Y.js:1>)

合格値は `{ok: true, type: "pong"}`。これは Code 用ホストを明示するため、Desktop 用ホストの成功との混同を避けられます。

**C. 初回だけ対話で接続・権限を準備する**

```sh
"$HOME/.local/bin/claude" --chrome
```

- `/login` による直接 Anthropic アカウント認証を使う。APIキーや `setup-token` 認証では現行の Chrome 連携は無効になる。
- `/chrome` で接続先を確認し、複数候補があれば検証用 Helium を選ぶ。
- `/mcp` → `claude-in-chrome` → View tools で実際のツール名を確認する。
- `https://example.com/` の読取に必要なサイト権限を準備する。

以上は [Claude Code Chrome連携の公式手順](https://code.claude.com/docs/en/chrome) に基づきます。候補の表示名だけで判別できなければ、Helium にタブが作られることと Profile Path を照合してください。

**D. 非対話でページタイトルを読む**

**初回設定後なら `claude -p --chrome` による試験を構成できます。** ただし、未ログイン・初回許可・接続先選択待ちまで無人で解決する手順ではありません。以下は公式の `-p`／ツール許可／JSONストリーム機能を組み合わせた**未実行の検証案**です。[非対話実行](https://code.claude.com/docs/en/headless)、[CLI引数](https://code.claude.com/docs/en/cli-reference)

```sh
"$HOME/.local/bin/claude" \
  --chrome \
  --print \
  --tools "" \
  --allowedTools \
  "mcp__claude-in-chrome__tabs_context_mcp,mcp__claude-in-chrome__tabs_create_mcp,mcp__claude-in-chrome__navigate,mcp__claude-in-chrome__javascript_tool" \
  --max-turns 12 \
  --output-format stream-json \
  --verbose \
  '接続済みの検証用Heliumでブラウザ読取試験を行う。
claude-in-chromeのMCPツールだけを使用する。
tabs_context_mcpでこのセッションのタブを確認し、必要なら作成する。
対象タブを https://example.com/ にnavigateする。
javascript_toolで JSON.stringify({title:document.title,url:location.href}) を実行する。
読取に成功したら取得した値をそのまま報告する。
接続・権限・ブラウザ選択の問題があれば失敗として報告し、代替手段は使わない。'
```

`--tools ""` は組み込みツールを無効化し、MCPツールは残します。`--allowedTools` は許可設定であり、MCPツール全体の限定ではありません。[CLI仕様](https://code.claude.com/docs/en/cli-reference)

ツール名はローカル拡張でも確認できていますが、実際の公開ツール一覧と違う場合は C の一覧を優先します。[ローカルのツール名・タブ制約:2](</Users/yu01/Library/Application Support/Idaten/Profiles/044F76FC-7238-4683-9D87-2F51396DE649/chromium-profile/Default/Extensions/fcoeoabgfenejglbffodgkkbkcdhcgfn/1.0.94_0/assets/mcpPermissions-tSjXinpi.js:2>)

**機械判定は、終了コードや最終文章だけでなくツール結果を見る設計にしてください。**

合格条件として、JSONストリームから次を照合します。

1. `mcp__claude-in-chrome__javascript_tool` の `tool_use` がある。
2. 対応する `tool_use_id` の `tool_result` がエラーではない。
3. その結果に、実際に取得された `title` と `https://example.com/` の URL がある。
4. 最後の `result` が成功で、CLI の終了コードも0。
5. 同じ試験タブが検証用 Helium に現れたことを初回に確認する。

JSONストリームと最終 `result` は [公式の出力仕様](https://code.claude.com/docs/en/headless#stream-responses) に基づきます。上記の合格条件は、モデルの回答だけを通信成功と誤認しないための提案です。**既知のタイトル文字列を回答しただけ、タブ一覧だけ取得できた、は不合格**とします。

**E. Idaten 経由で再確認する**

単体試験後に Helium を通常終了し、Idaten で同じプロファイルの Chromium タブを開いて D を再実行します。Idaten は `--remote-debugging-pipe` と `--no-startup-window` を追加して起動するため、単体起動と分けて結果を記録します。[起動実装:190](/Users/yu01/idaten-browser/Sources/Idaten/ChromiumDock.swift:190)

**5. 失敗時の切り分け表**

| 症状 | 確認・次の試験 | 根拠 |
|---|---|---|
| `Specified native messaging host not found` | 選択した UDD 直下と Chrome 固定領域の manifest を確認。`Default/NativeMessagingHosts` への誤配置を確認 | [探索実装](https://github.com/chromium/chromium/blob/main/chrome/common/chrome_paths.cc#L458) |
| Chrome 側にあるのに見つからない | 既存版のパッチ動作、ユーザー用ホストの許可を疑う。比較試験として UDD 直下に同じ manifest を配置して再試験 | [Heliumパッチ](https://github.com/imputnet/helium/blob/main/patches/helium/core/scan-chrome-native-messaging-hosts.patch) |
| JSON解析・manifest不正 | UDD 側の同名ファイルも確認。先に見つかった不正ファイルが Chrome 側を隠していないか調べる | [探索](https://github.com/chromium/chromium/blob/main/chrome/browser/extensions/api/messaging/launch_context_posix.cc)、[解析](https://github.com/chromium/chromium/blob/main/chrome/browser/extensions/api/messaging/launch_context.cc) |
| `Access ... forbidden` | `allowed_origins` の拡張ID、Native Messaging 関連ポリシーを確認 | [Chrome診断](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging#common-errors) |
| `Failed to start native messaging host` | manifest の絶対パス、ラッパーと CLI の実行権限、CLIリンク先の存在を確認 | [Chrome診断](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging#common-errors)、[ラッパー:4](/Users/yu01/.claude/chrome/chrome-native-host:4) |
| `Native host has exited`／通信形式エラー | ブラウザstderrを見る。ホストの早期終了やstdoutへの余分な出力を調べる | [Native Messaging仕様・診断](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) |
| `ping` は成功、CLIにはブラウザが出ない | manifest探索は通過済み。CLIの認証、拡張ログイン、ブリッジ接続、選択状態を確認 | [公式トラブルシュート](https://code.claude.com/docs/en/chrome#troubleshooting) |
| `--chrome` でもツールがない／403 | `/login` 認証か確認。APIキー・長期トークン・第三者プロバイダー認証を切り分ける | [公式前提条件](https://code.claude.com/docs/en/chrome#prerequisites) |
| `Browser extension is not connected` | 再接続。ブリッジ宛通信が組織ネットワークで拒否されていないか確認 | [公式エラー一覧](https://code.claude.com/docs/en/chrome#common-error-messages) |
| `No tab available`／タブがセッション外 | `tabs_context_mcp` と `tabs_create_mcp` で当該セッションのタブを使う | [ローカル制約:2](</Users/yu01/Library/Application Support/Idaten/Profiles/044F76FC-7238-4683-9D87-2F51396DE649/chromium-profile/Default/Extensions/fcoeoabgfenejglbffodgkkbkcdhcgfn/1.0.94_0/assets/mcpPermissions-tSjXinpi.js:2>) |
| `-p` だけ失敗 | サイト権限・ブラウザ選択が未完了か確認。対話モードで準備してから再試験 | [Chrome連携](https://code.claude.com/docs/en/chrome)、[非対話実行](https://code.claude.com/docs/en/headless) |
| 放置後に切断 | `/chrome` から再接続。service worker の休止を確認 | [公式切断対策](https://code.claude.com/docs/en/chrome#connection-drops-during-long-sessions) |
| Chromeで成功してHeliumで失敗 | 同じ拡張版・認証・ページ・試験内容で比較し、Helium側のホスト探索と拡張APIの問題を分離 | [Chrome仕様](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)、[Heliumパッチ](https://github.com/imputnet/helium/blob/main/patches/helium/core/scan-chrome-native-messaging-hosts.patch) |

記録する結果は、**使用UDD／拡張版／Codeホストのpong有無／選択したブラウザ／ページ読取のtool result／CLI終了コード／単体とIdaten経由の差**です。manifest を追加した場合は「コピーなしで成功」と混同しないよう、その条件も残してください。
