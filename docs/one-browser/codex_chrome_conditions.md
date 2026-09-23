codex
**実行条件は、Memory Saverを `Local State` で明示設定し、自然発動・拡張による自動休眠・指定タブの強制破棄を別試験に分けるのが妥当です。** 拡張導入は、公式Chromeの `--load-extension` に依存しない実装が必要です。

指定の3資料と関連コードを読みました。ブラウザ起動・ファイル変更・計測はしていません。ローカルの `Info.plist` が示すChrome版は **153.0.8010.54** です。ただし、この版と一致する公開ソースタグは取得できなかったため、以下では「公開資料・ソースで確認済み」と「153版での実動確認が必要」を区別します。コード例は実行担当向けの提案で、今回未実行です。

**1．Memory Saverを起動時に設定する**

**確認済み：設定ファイルと値**

`--user-data-dir="$PROFILE"` とした場合、設定先は次のとおりです。

| ファイル | JSON上のパス | 値 |
|---|---|---|
| `$PROFILE/Local State` | `performance_tuning.high_efficiency_mode.state` | **0＝OFF、2＝ON**。1は旧実験値なので使用しない |
| 同上 | `performance_tuning.high_efficiency_mode.aggressiveness` | **0＝Moderate、1＝Balanced、2＝Maximum** |
| `$PROFILE/Default/Preferences` | `performance_tuning.tab_discarding.exceptions` | 旧形式の文字列配列 |
| 同上 | `performance_tuning.tab_discarding.exceptions_with_time` | 現行の例外辞書 |
| 同上 | `performance_tuning.tab_discarding.exceptions_managed` | ポリシー由来の例外。手書きで管理ポリシーを代用しない |

ON/OFF・強度はブラウザ単位のLocal State、例外はプロファイル単位です。[設定キー・列挙値](https://chromium.googlesource.com/chromium/src/+/main/components/performance_manager/public/user_tuning/prefs.h)、[登録先・移行処理](https://raw.githubusercontent.com/chromium/chromium/main/components/performance_manager/user_tuning/prefs.cc)

新品の専用ディレクトリに、起動前に以下を用意します。

`Local State`：ON・Balancedの例。

```json
{
  "performance_tuning": {
    "high_efficiency_mode": {
      "state": 2,
      "aggressiveness": 1
    }
  }
}
```

`Default/Preferences`：例外なし。

```json
{
  "performance_tuning": {
    "tab_discarding": {
      "exceptions": [],
      "exceptions_with_time": {}
    }
  }
}
```

OFF条件は `state` だけを `0` に変更します。古い `high_efficiency_mode.enabled` は書かず、既存テンプレートからも除去します。ドットを含む単一JSONキーではなく、上記の入れ子構造です。

**`time_before_discard_in_minutes` に短い値を書いて短縮試験を作る方法は採用しません。** 公開ソースでは起動時移行でこのprefをクリアします。現在確認できるタイマー実装はModerate＝6時間、Balanced＝4時間、Maximum＝2時間です。別のメモリ圧迫経路もあるため、「それまでは絶対に破棄されない」という意味ではありません。[移行処理](https://raw.githubusercontent.com/chromium/chromium/main/components/performance_manager/user_tuning/prefs.cc)、[タイマー実装](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/performance_manager/policies/memory_saver_mode_policy.cc)

**確認済み：ポリシー**

| ポリシー名 | 値 | 対応開始・意味 |
|---|---|---|
| `HighEfficiencyModeEnabled` | Boolean `true` / `false` | Chrome 108以降。Memory SaverのON/OFF |
| `MemorySaverModeSavings` | Integer `0` / `1` / `2` | Chrome 126以降。強度。ONにする効果はない |
| `TabDiscardingExceptions` | URLパターンの配列 | Chrome 108以降。Memory Saver・メモリ圧迫による破棄の例外 |

一次資料：[ON/OFF定義](https://raw.githubusercontent.com/chromium/chromium/main/components/policy/resources/templates/policy_definitions/Miscellaneous/HighEfficiencyModeEnabled.yaml)、[強度定義](https://chromium.googlesource.com/chromium/src/+/HEAD/components/policy/resources/templates/policy_definitions/Miscellaneous/MemorySaverModeSavings.yaml)、[例外定義](https://raw.githubusercontent.com/chromium/chromium/main/components/policy/resources/templates/policy_definitions/Miscellaneous/TabDiscardingExceptions.yaml)

管理済みMacに配布する `com.google.Chrome` ポリシーの内容は、例えば次です。

```xml
<key>HighEfficiencyModeEnabled</key>
<true/>
<key>MemorySaverModeSavings</key>
<integer>1</integer>
<key>TabDiscardingExceptions</key>
<array/>
```

これは構成プロファイルの**設定部分**であり、完全な `.mobileconfig` ではありません。通常利用のChromeにも作用し得るため、今回の専用プロファイル比較にはLocal State方式が扱いやすいです。どちらの方式でも、起動後に `chrome://policy` の有効ポリシーを確認し、競合・未知のポリシー・適用エラーを検出します。

**フラグの扱い**

| 指定 | 判定 |
|---|---|
| `--enable-features=HighEfficiencyModeAvailable` | 過去の正確なfeature名。ただし「機能を利用可能にする」と「ユーザー設定をONにする」は別 |
| `--disable-features=HighEfficiencyModeAvailable` | 過去の同featureを無効化する指定 |
| `--enable-features=HighEfficiencyModeAvailable:default_state/true` | 過去実装のパラメーターに対応する指定。現行試験には採用しない |
| `--enable-features=MemorySaver` 等 | 今回、現行の有効なON/OFF指定として確認できず |
| `--disable-features=UrgentPageDiscarding` | メモリ圧迫時の別機能を変更する。Memory Saver OFFの代用品にしない |

過去実装には `HighEfficiencyModeAvailable` と `default_state` が存在しますが、現在の公開 `features.cc` には同定義がありません。**153版に対する有効なMemory Saver切替フラグは、今回確定できていません。** Local Stateまたはポリシーを使ってください。[過去のfeature定義](https://chromium.googlesource.com/chromium/src/+/8ba1bad80dc22235693a0dd41fe55c0fd2dbdabd/components/performance_manager/features.cc)、[現在のfeature定義](https://raw.githubusercontent.com/chromium/chromium/main/components/performance_manager/features.cc)

**既定ON/OFFの履歴：確認できた範囲**

| 時期・版 | 確認結果 |
|---|---|
| Chrome 108 | Memory Saver導入。公式告知は段階的ロールアウト |
| 初期実装 | `default_state` パラメーターがあり、ON/OFF双方の実験設定が存在 |
| Chrome 126.0.6478.126 | pref登録時の既定はOFF、強度はBalanced |
| 現在の公開HEAD | 同じくpref登録時の既定はOFF |
| ローカル153版・新品プロファイル | 実際の有効な既定値は未確認 |

一次資料：[108導入の公式説明](https://developer.chrome.com/blog/memory-and-energy-saver-mode)、[導入告知](https://blog.google/products-and-platforms/products/chrome/new-chrome-features-to-save-battery-and-make-browsing-smoother/)、[初期ON実験](https://chromium.googlesource.com/chromium/src/+/11057b006d94e3cb22df8b0149837dfc92afd56a/testing/variations/fieldtrial_testing_config.json)、[126のpref登録](https://chromium.googlesource.com/chromium/src/+/126.0.6478.126/components/performance_manager/user_tuning/prefs.cc)

**「110で全員既定ON、その後の特定版で全員OFFへ変更」という完全な履歴は、一次資料で確認できませんでした。** バージョンだけで既定値を推定しないでください。

実行器の合格条件は次です。

1. 設定ファイル生成はChrome終了中に行う。
2. 起動後、設定画面の実効値が予定のON/OFF・強度になっていることを検証する。
3. ポリシー、例外、バージョン、コマンドラインを保存する。
4. 設定確認タブを閉じてから試験シナリオを開始する。
5. 終了後のLocal Stateも保存する。ただし、**ディスク上の値だけを実効値の証明にしない**。

なお、**Memory Saver OFFでも、メモリ圧迫による破棄まで無効になるわけではありません。** [Chrome公式説明](https://developer.chrome.com/blog/memory-and-energy-saver-mode)

**2．タブの破棄を決定的に起こす**

**確認済み：第一候補は `chrome.tabs.discard(tabId)`**

Chrome 54以降の公開APIです。IDを省略するとChromeが対象を選ぶため、再現試験では必ず指定します。アクティブなタブは破棄できず、破棄後に選択すると再読み込みされます。[Tabs API](https://developer.chrome.com/docs/extensions/reference/api/tabs#method-discard)

拡張のservice workerまたは拡張ページのコンテキストで、次のように実行します。

```js
async function discardExact(tabIds) {
  const results = [];

  for (const id of tabIds) {
    const before = await chrome.tabs.get(id);
    if (before.active) throw new Error(`active tab: ${id}`);
    if (before.discarded) throw new Error(`already discarded: ${id}`);

    const result = await chrome.tabs.discard(id);
    const after = await chrome.tabs.get(id);

    if (!result || !after.discarded) {
      throw new Error(`discard failed: ${id}`);
    }

    results.push({id, url: before.url, discarded: after.discarded});
  }
  return results;
}
```

再現手順：

1. 13タブを同じ順序で実際に読み込む。各URLの読込成功を記録する。
2. 最後に動画タブを選択し、背景12タブのURLとタブIDの対応を保存する。
3. 同一ルールで決めた対象IDだけを破棄する。
4. 全対象の `discarded === true` を確認する。失敗はその回を不成立とする。
5. 破棄完了時刻をイベントログに保存し、固定の観測区間を採る。
6. 復帰時間の試験はメモリ観測後に行う。途中で対象タブを選択しない。

API成功はメモリ会計の即時安定を保証しません。状態確認後も時系列で測ります。また、この操作は**強制破棄条件**であり、Memory Saver自然発動の代用ではありません。

**確認済み：`chrome://discards`**

公式説明は、対象行の **Urgent Discard** を使う方法です。公開実装にはUrgent／Proactiveの操作があり、最低背景待機時間を無視する要求を送っています。自然なMemory Saverの待機試験とは区別します。[公式手順](https://developer.chrome.com/blog/memory-and-energy-saver-mode#testing_your_site_in_memory_saver_mode)、[バックエンド](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/ui/webui/discards/discards_ui.cc)

無人化する場合は、CDPでこの内部ページのUIを操作できます。ただしこれは公開の「discard用CDPコマンド」ではありません。

- 行番号ではなく完全URLで対象を照合する。
- 内部IDは一覧更新で変わり得るため、毎回取り直す。
- クリック完了ではなく `discarded` 状態への変化を待つ。
- このページは定期更新するため、計測前に閉じる。
- DOMや内部Mojo APIはバージョン依存。153版でのセレクターは未検証。

このため、固定版の診断用には使えても、主実行経路には拡張APIを勧めます。[UI実装](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/resources/discards/discards_tab.ts)

**CDPそのもの**

確認した公開プロトコルに、指定タブを通常のdiscard状態にする専用コマンドは見つかりませんでした。

- `Page.setWebLifecycleState` は `frozen` / `active`。**freezeは破棄ではない**。
- `Memory.simulatePressureNotification` は圧迫通知の模擬。対象タブ・実際の解放量を固定できない。
- `Page.crash` や `Target.closeTarget` も目的の代用にならない。

一次資料：[Page定義](https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/pdl/domains/Page.pdl)、[Memory定義](https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/pdl/domains/Memory.pdl)

**3．拡張を無人で導入・有効化する**

**確認済み：導入経路**

| 経路 | 判定 |
|---|---|
| 公式Chromeで `--load-extension=/path` | **137以降は使用不可**という公式告知 |
| Chrome for Testing／Chromiumで同フラグ | 公式告知では継続対応 |
| CDP `Extensions.loadUnpacked` | 公開されたexperimentalコマンド。絶対パスを渡し、拡張IDが返る |
| `ExtensionInstallForcelist` | 無人導入・権限付与に対応。ただし管理環境の条件あり |
| macOSのExternal Extensions用JSON | 通常の外部導入には有効化確認があり、完全無人の代用にならない |
| `Preferences` の `extensions.settings` を手書き | 現行Chromeへの確実な導入方法として確認できず。採用しない |

一次資料：[137の変更告知](https://groups.google.com/a/chromium.org/g/chromium-extensions/c/1-g8EFx2BBY/m/S0ET5wPjCAAJ)、[CDP定義](https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/pdl/domains/Extensions.pdl)、[外部導入の制約](https://developer.chrome.com/docs/extensions/how-to/distribute/install-extensions)

**公式Chromeを使う実行経路案**

まず専用プロファイルで、browser targetに対して次を呼びます。

```json
{
  "id": 1,
  "method": "Extensions.loadUnpacked",
  "params": {
    "path": "/absolute/path/to/extension"
  }
}
```

対応版なら続いて：

```json
{
  "id": 2,
  "method": "Extensions.getExtensions",
  "params": {}
}
```

返った `id`、`version`、`path`、`enabled` を検証します。コマンド成功だけでなく、その拡張コンテキストから `chrome.tabs.query()` と設定読込が成功することも確認します。[導入・有効状態取得の実装](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/devtools/protocol/extensions_handler.cc)

**接続条件には版差があります。** 140版では `--enable-unsafe-extension-debugging` とunsafe操作を許可する接続条件があり、公式開発者の例は `--remote-debugging-pipe` を使用しています。一方、現在の公開mainでは同じ条件式ではありません。**153版で「ポート接続だけで必ず導入できる」とは断定できません。** [140版の条件](https://raw.githubusercontent.com/chromium/chromium/140.0.7339.80/chrome/browser/devtools/chrome_devtools_session.cc)、[公式開発者の自動導入例](https://groups.google.com/a/chromium.org/g/chromium-extensions/c/1-g8EFx2BBY)、[現在の条件](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/devtools/chrome_devtools_session.cc)

実装は次の二段階が安全です。

1. **準備工程**：pipe接続できる自動化ランチャーで専用プロファイルを起動し、拡張導入・設定・正常終了を行う。
2. **計測工程**：同じ専用プロファイルを `open -n -a` で起動し、拡張が有効なことを確認して測定する。

この方法では「新品プロファイル」ではなく、**拡張準備済み・ベンチ対象サイト未訪問のプロファイル**と記載します。再起動後の有効性は153版での予備試験が必要です。導入に失敗したら、その条件を中止し、拡張なしのまま測定を続けないでください。

CDPのremote debuggingには専用の非標準 `--user-data-dir` を使います。Chrome 136以降の制約とも一致します。[公式変更説明](https://developer.chrome.com/blog/remote-debugging-port)

**確実な代替候補：Chrome for Testing**

```sh
open -n -a "$CFT_APP" --args \
  --user-data-dir="$PROFILE" \
  --no-first-run \
  --no-default-browser-check \
  --load-extension="$EXTENSION_DIR" \
  about:blank
```

これは公式に案内された経路ですが、今回未実行です。使用した場合、結果名は **Chrome for Testing〈完全版番号〉＋Idaten拡張** とし、通常配布Chromeの結果と混ぜません。

**管理ポリシーの代替**

```json
{
  "ExtensionInstallForcelist": [
    "<固定ID>;https://example.test/extension/update.xml"
  ]
}
```

自前CRXなら署名鍵・CRX・更新XMLを固定します。macOSでWeb Store外拡張を強制導入するには、MDM、MCXドメイン参加、Chrome Enterprise Core登録のいずれかが必要です。未管理MacへJSONを置くだけの手順ではありません。[公式ポリシー定義](https://raw.githubusercontent.com/chromium/chromium/main/components/policy/resources/templates/policy_definitions/Extensions/ExtensionInstallForcelist.yaml)

**拡張IDの固定**

現在の [manifest.json](/Users/yu01/idaten-browser/extension/manifest.json) には `key` がありません。試験用の同一成果物に、固定公開鍵を指定してください。

```json
{
  "key": "<同じ公開鍵のDERをBase64化した文字列>"
}
```

公式にはmanifestの `key` による開発時ID固定が案内されています。秘密鍵はmanifestへ入れません。全試行で拡張全体のハッシュ、ID、版、設定を保存します。[公式key仕様](https://developer.chrome.com/docs/extensions/reference/manifest/key)

**「同じ休眠規則」には現コードの差分処理が必要**

[policy.js](/Users/yu01/idaten-browser/extension/policy.js) と [Swift側](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:746) は同一ではありません。

| 条件 | 拡張 | Swift |
|---|---|---|
| 背景予算 | 全ウィンドウを集計 | ウィンドウごと |
| 最古候補が保護対象 | 他候補で補充する | 超過枚数分だけ見てスキップ |
| JS判定失敗・タイムアウト | busyとして保護 | 休眠へ進む経路あり |
| 固定タブ・例外ドメイン | 対応 | 同じ仕組みではない |
| メモリ圧迫 | Chrome側の機構が別途作用 | Swift側にも即時休眠処理 |

最初の比較は、**1ウィンドウ・固定タブなし・例外なし・背景は静的文書・動画は前景・入力なし・メモリ圧迫なし**に限定してください。それでも「完全に同じアルゴリズム」ではなく、「背景予算6・アイドル10分を揃えた条件」です。

拡張設定は `chrome.storage.sync` へ次を設定し、読み戻します。

```js
await chrome.storage.sync.set({
  budget: 6,
  idleMinutes: 10,
  neverDiscard: []
});
```

`runtime.sendMessage("enforce")` は既存拡張で使えますが、自動運用試験で毎回送ると手動トリガー条件になります。また、既存実装は処理中なら即座に戻るため、返信 `true` だけを休眠完了判定にできません。`storage.local.lastRun` と実際のタブ状態を照合します。[background.js](/Users/yu01/idaten-browser/extension/background.js)

**4．動画タブを固定する**

**確認済みの仕様に基づく提案：単一MP4をローカルHTTP配信する**

初期条件は以下が扱いやすいです。

| 項目 | 固定値の提案 |
|---|---|
| 映像 | H.264、1920×1080、30fps固定、8bit、4:2:0、SDR |
| 音声 | 初期試験は音声トラックなし。音声ありは別条件 |
| 再生 | 同じMP4、同じ開始位置、`playbackRate=1` |
| 配信 | `http://127.0.0.1:<固定port>/video.html` |
| ページ | 同一HTML、単一`video`、広告・外部通信・MSE・DRMなし |
| 表示 | 同じCSS寸法、ズーム、DPR、ディスプレイ・リフレッシュレート |
| 状態 | 前景・可視・最小化なし。`open -g` 任せにしない |

素材は一度だけ生成し、以後は**ファイルのSHA-256を固定**します。例えばFFmpegのテスト映像を使えます。[FFmpeg公式フィルター資料](https://ffmpeg.org/ffmpeg-filters.html#testsrc_002c-testsrc2)

```sh
ffmpeg -f lavfi -i 'testsrc2=size=1920x1080:rate=30' \
  -t 120 -an \
  -c:v libx264 -profile:v high -level:v 4.0 \
  -pix_fmt yuv420p -preset medium -crf 20 \
  -g 60 -keyint_min 60 -sc_threshold 0 \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -movflags +faststart fixture.mp4
```

FFmpeg・encoder版と `ffprobe` の出力も保存します。これは合成動画条件です。実写負荷の主張には、利用権のある実写素材を別途固定してください。

15分観測なら120秒素材のloopを全試行で統一できます。ただしloop境界の負荷も測定に含まれることを明記します。

配信サーバーは `Content-Type: video/mp4`、正しい `Content-Length`、Range要求と `206` に対応させます。測定前に `Range: bytes=0-1023` への応答を確認します。単に「HTTPサーバーが起動した」で合格にしません。[HTTP Range仕様](https://www.rfc-editor.org/rfc/rfc9110.html#name-range-requests)

**無人での再生確認**

1. メタデータ読込を待つ。
2. `currentTime=0`、`playbackRate=1`、ミュート条件を設定。
3. `play()` のPromise成功を待つ。必要なら両者で同じ開始ボタン操作を行う。
4. `playing` と再生時刻の進行を確認して `t0` を記録。
5. 同じページ内コードで、低頻度に再生状態を記録する。

保存する最低項目：

```js
const q = video.getVideoPlaybackQuality();
({
  currentSrc: video.currentSrc,
  currentTime: video.currentTime,
  videoWidth: video.videoWidth,
  videoHeight: video.videoHeight,
  paused: video.paused,
  ended: video.ended,
  playbackRate: video.playbackRate,
  readyState: video.readyState,
  visibility: document.visibilityState,
  totalFrames: q.totalVideoFrames,
  droppedFrames: q.droppedVideoFrames
});
```

フレーム品質APIの一次資料：[Media Playback Quality](https://w3c.github.io/media-playback-quality/)

**確認できないもの：同じデコーダー内部状態の強制**

同一MP4でも、ChromeとWKWebViewのデコーダー、バッファ戦略、GPUへの転送経路まで同一にはできません。

- 両者とも標準のハードウェアアクセラレーションを使用し、Chromeだけ `--disable-gpu` にしない。
- Chromeでは予備走行でMediaパネル等からデコーダー情報を記録する。計測中はDevToolsを閉じる。[Chrome Mediaパネル](https://developer.chrome.com/docs/devtools/media-panel)
- `navigator.mediaCapabilities.decodingInfo()` の `supported` / `smooth` / `powerEfficient` を両者で保存する。ただし `powerEfficient=true` は、その再生がハードウェアデコードされた証明ではありません。[W3C仕様](https://www.w3.org/TR/media-capabilities/)
- WKWebView側の実デコーダー経路が未確認なら、公開表現は「同一符号化素材・同一表示再生条件」に限定する。

バッファ量は観測値として残します。全量をBlobへ読み込んで揃えると、別のメモリ負荷を追加してしまいます。

**5．区間中央値・ピークと、10組のAB/BA設計**

**確認済み：既存計器の制約**

[footprint-cli](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift) のCSVは次の列です。

```text
t_sec,nprocs,footprint_bytes,cpu_nanos
```

実務上、次を補う必要があります。

- `--interval 1` は厳密な1Hzではなく、**採取処理時間＋1秒sleep**。
- CSVは正常終了時に書かれる。途中で計器をkillすると残らない可能性がある。
- 表示される中央値は偶数件で中央2値の平均にならない。CSVから再集計する。
- PID別採取失敗を黙って除外する。公開用には失敗PID・対象PID集合の監査が必要。
- 1秒採取の最大値は**観測ピーク**。瞬間的な真の最大値ではない。
- PID取得後に計器を開始する現構成では、それ以前の起動ピークは取れない。

**採取手順案**

固定のシナリオ準備枠を180秒とし、その間に読込・操作・動画準備を終えます。間に合わなければ失敗にします。最後の操作・動画再生開始を `t0` として900秒観測します。

```sh
"$FP" --pid "$ROOT_PID" \
  --interval 1 \
  --duration 1090 \
  --csv "$RUN_DIR/footprint.csv" \
  > "$RUN_DIR/footprint-summary.txt" \
  2> "$RUN_DIR/footprint-errors.txt"
```

計器開始から `t0` までのオフセットを別ログへ保存します。1090秒は「準備180秒＋観測900秒＋余裕」の例です。集計対象はログで区切ります。

| 指標 | `t0` 相対の対象区間 |
|---|---|
| 60秒値 | `[30,60)` 秒の中央値 |
| 5分値 | `[270,300)` 秒の中央値 |
| 15分値 | `[870,900)` 秒の中央値 |
| シナリオピーク | 計器の最初のサンプルから `t0+900` までの最大値 |
| 放置中ピーク | `[0,900)` 秒の最大値 |

集計の核は以下です。

```python
from statistics import median

def window_stats(rows, t0_offset, start, end):
    selected = [
        r for r in rows
        if start <= float(r["t_sec"]) - t0_offset < end
    ]
    if not selected:
        raise ValueError("empty window")

    values = [int(r["footprint_bytes"]) for r in selected]
    return {
        "samples": len(values),
        "median_mib": median(values) / 1048576,
        "sampled_peak_mib": max(values) / 1048576,
    }
```

サンプル数だけでなく、区間の端まで観測できているか、最大サンプル間隔、プロセス取得失敗も検査します。欠測をゼロで補間しません。

**交互測定前のリセット条件：以下は提案する事前登録ルール**

1. 前試行の本体・Helper・WebKit・管理下Heliumが終了したことを確認する。固定5秒sleepだけで済ませない。
2. 最低120秒待機し、その後60秒連続で開始条件を満たすことを確認する。
3. AC電源、低電力モードOFF、同じ画面状態。thermal stateは `nominal`。
4. 開始前60秒の全体CPUアイドル率を例えば90%以上とする。
5. メモリ圧迫はnormal。`vm_stat` のpageout／swapout増分が開始前60秒でゼロ。
6. 条件を10分以内に満たせなければ、そのペアを保留。待機時間も保存する。

thermal stateはAppleの公開APIで取得できます。数値閾値と待機時間はApple推奨値ではなく、今回の実験設計案です。[Apple ThermalState](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum)

swap使用量がゼロへ戻るまで待つ設計は避けます。使用量と増分を記録し、残留状態が大きく変わった場合はペアをやり直す、または再起動を含む別ブロックにします。

**試験中にそのブラウザ自身が起こしたメモリ圧迫は結果です。** 都合の悪い回として除外しません。開始前の汚染、外部アプリの割込み、動画再生失敗などと区別します。

キャッシュ条件は以下のどちらかを選んで固定します。

- **アプリキャッシュ冷**：試行ごとに未訪問プロファイル／データストア。OSファイルキャッシュは別物として記録。
- **アプリキャッシュ温**：同一の予備走行を行い、正常終了後の状態から開始。

新規プロファイルだけで「完全な冷キャッシュ」と呼ばず、片側だけ `purge` する処理も入れません。

**10組の具体的順序**

A＝Chromeの**一つの固定条件**、B＝Idatenの対応条件です。次の順序を測定前に保存します。

| 組 | 実行順 |
|---:|---|
| 1 | A → B |
| 2 | B → A |
| 3 | B → A |
| 4 | A → B |
| 5 | A → B |
| 6 | B → A |
| 7 | B → A |
| 8 | A → B |
| 9 | A → B |
| 10 | B → A |

AB／BAは各5組。隣接する2組でも均等です。各矢印の間、組の間の両方でリセット条件を適用します。ペアをブロックとして扱う設計は、時間経過などの外乱を抑えるためです。[NISTのブロック化実験設計](https://www.itl.nist.gov/div898/handbook/pri/section3/pri332.htm)

```python
orders = [
    ("A", "B"), ("B", "A"),
    ("B", "A"), ("A", "B"),
    ("A", "B"), ("B", "A"),
    ("B", "A"), ("A", "B"),
    ("A", "B"), ("B", "A"),
]
```

片側に測定失敗があれば、生データと理由を残し、**ペア全体を同じ順序で再実行**します。1秒サンプルを独立した反復数には数えません。

各ペア・各観測点で次を計算します。

```text
差_i     = Chrome中央値_i − Idaten中央値_i
削減率_i = 1 − Idaten中央値_i / Chrome中央値_i
```

10個の対応差・削減率の中央値、ばらつき、ペア単位の信頼区間を報告します。ピークは中央値と別集計にします。

**実行条件として分けておくべき系列**

| 系列 | Chrome側 | 解釈 |
|---|---|---|
| 製品既定 | 設定を変更せず実効値を記録 | 既定の製品比較 |
| Memory Saver ON | `state=2`、強度明示、拡張なし | 自然発動を含む比較 |
| 拡張休眠 | `state=0`、拡張budget＝6・idle＝10分 | 背景予算・時間条件を揃える比較 |
| 強制破棄 | 指定IDを明示discard | 同じ稼働タブ集合での機構比較 |

**各系列・各キャッシュ条件について10組**です。60秒・5分・15分の系列だけでは、数時間のMemory Saverタイマーによる効果を評価し切れません。自然発動の効果を公開主張するなら、確認した版の待機時間を超える長時間系列を追加し、実際の破棄時刻を記録してください。
tokens used
179,557
**実行条件は、Memory Saverを `Local State` で明示設定し、自然発動・拡張による自動休眠・指定タブの強制破棄を別試験に分けるのが妥当です。** 拡張導入は、公式Chromeの `--load-extension` に依存しない実装が必要です。

指定の3資料と関連コードを読みました。ブラウザ起動・ファイル変更・計測はしていません。ローカルの `Info.plist` が示すChrome版は **153.0.8010.54** です。ただし、この版と一致する公開ソースタグは取得できなかったため、以下では「公開資料・ソースで確認済み」と「153版での実動確認が必要」を区別します。コード例は実行担当向けの提案で、今回未実行です。

**1．Memory Saverを起動時に設定する**

**確認済み：設定ファイルと値**

`--user-data-dir="$PROFILE"` とした場合、設定先は次のとおりです。

| ファイル | JSON上のパス | 値 |
|---|---|---|
| `$PROFILE/Local State` | `performance_tuning.high_efficiency_mode.state` | **0＝OFF、2＝ON**。1は旧実験値なので使用しない |
| 同上 | `performance_tuning.high_efficiency_mode.aggressiveness` | **0＝Moderate、1＝Balanced、2＝Maximum** |
| `$PROFILE/Default/Preferences` | `performance_tuning.tab_discarding.exceptions` | 旧形式の文字列配列 |
| 同上 | `performance_tuning.tab_discarding.exceptions_with_time` | 現行の例外辞書 |
| 同上 | `performance_tuning.tab_discarding.exceptions_managed` | ポリシー由来の例外。手書きで管理ポリシーを代用しない |

ON/OFF・強度はブラウザ単位のLocal State、例外はプロファイル単位です。[設定キー・列挙値](https://chromium.googlesource.com/chromium/src/+/main/components/performance_manager/public/user_tuning/prefs.h)、[登録先・移行処理](https://raw.githubusercontent.com/chromium/chromium/main/components/performance_manager/user_tuning/prefs.cc)

新品の専用ディレクトリに、起動前に以下を用意します。

`Local State`：ON・Balancedの例。

```json
{
  "performance_tuning": {
    "high_efficiency_mode": {
      "state": 2,
      "aggressiveness": 1
    }
  }
}
```

`Default/Preferences`：例外なし。

```json
{
  "performance_tuning": {
    "tab_discarding": {
      "exceptions": [],
      "exceptions_with_time": {}
    }
  }
}
```

OFF条件は `state` だけを `0` に変更します。古い `high_efficiency_mode.enabled` は書かず、既存テンプレートからも除去します。ドットを含む単一JSONキーではなく、上記の入れ子構造です。

**`time_before_discard_in_minutes` に短い値を書いて短縮試験を作る方法は採用しません。** 公開ソースでは起動時移行でこのprefをクリアします。現在確認できるタイマー実装はModerate＝6時間、Balanced＝4時間、Maximum＝2時間です。別のメモリ圧迫経路もあるため、「それまでは絶対に破棄されない」という意味ではありません。[移行処理](https://raw.githubusercontent.com/chromium/chromium/main/components/performance_manager/user_tuning/prefs.cc)、[タイマー実装](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/performance_manager/policies/memory_saver_mode_policy.cc)

**確認済み：ポリシー**

| ポリシー名 | 値 | 対応開始・意味 |
|---|---|---|
| `HighEfficiencyModeEnabled` | Boolean `true` / `false` | Chrome 108以降。Memory SaverのON/OFF |
| `MemorySaverModeSavings` | Integer `0` / `1` / `2` | Chrome 126以降。強度。ONにする効果はない |
| `TabDiscardingExceptions` | URLパターンの配列 | Chrome 108以降。Memory Saver・メモリ圧迫による破棄の例外 |

一次資料：[ON/OFF定義](https://raw.githubusercontent.com/chromium/chromium/main/components/policy/resources/templates/policy_definitions/Miscellaneous/HighEfficiencyModeEnabled.yaml)、[強度定義](https://chromium.googlesource.com/chromium/src/+/HEAD/components/policy/resources/templates/policy_definitions/Miscellaneous/MemorySaverModeSavings.yaml)、[例外定義](https://raw.githubusercontent.com/chromium/chromium/main/components/policy/resources/templates/policy_definitions/Miscellaneous/TabDiscardingExceptions.yaml)

管理済みMacに配布する `com.google.Chrome` ポリシーの内容は、例えば次です。

```xml
<key>HighEfficiencyModeEnabled</key>
<true/>
<key>MemorySaverModeSavings</key>
<integer>1</integer>
<key>TabDiscardingExceptions</key>
<array/>
```

これは構成プロファイルの**設定部分**であり、完全な `.mobileconfig` ではありません。通常利用のChromeにも作用し得るため、今回の専用プロファイル比較にはLocal State方式が扱いやすいです。どちらの方式でも、起動後に `chrome://policy` の有効ポリシーを確認し、競合・未知のポリシー・適用エラーを検出します。

**フラグの扱い**

| 指定 | 判定 |
|---|---|
| `--enable-features=HighEfficiencyModeAvailable` | 過去の正確なfeature名。ただし「機能を利用可能にする」と「ユーザー設定をONにする」は別 |
| `--disable-features=HighEfficiencyModeAvailable` | 過去の同featureを無効化する指定 |
| `--enable-features=HighEfficiencyModeAvailable:default_state/true` | 過去実装のパラメーターに対応する指定。現行試験には採用しない |
| `--enable-features=MemorySaver` 等 | 今回、現行の有効なON/OFF指定として確認できず |
| `--disable-features=UrgentPageDiscarding` | メモリ圧迫時の別機能を変更する。Memory Saver OFFの代用品にしない |

過去実装には `HighEfficiencyModeAvailable` と `default_state` が存在しますが、現在の公開 `features.cc` には同定義がありません。**153版に対する有効なMemory Saver切替フラグは、今回確定できていません。** Local Stateまたはポリシーを使ってください。[過去のfeature定義](https://chromium.googlesource.com/chromium/src/+/8ba1bad80dc22235693a0dd41fe55c0fd2dbdabd/components/performance_manager/features.cc)、[現在のfeature定義](https://raw.githubusercontent.com/chromium/chromium/main/components/performance_manager/features.cc)

**既定ON/OFFの履歴：確認できた範囲**

| 時期・版 | 確認結果 |
|---|---|
| Chrome 108 | Memory Saver導入。公式告知は段階的ロールアウト |
| 初期実装 | `default_state` パラメーターがあり、ON/OFF双方の実験設定が存在 |
| Chrome 126.0.6478.126 | pref登録時の既定はOFF、強度はBalanced |
| 現在の公開HEAD | 同じくpref登録時の既定はOFF |
| ローカル153版・新品プロファイル | 実際の有効な既定値は未確認 |

一次資料：[108導入の公式説明](https://developer.chrome.com/blog/memory-and-energy-saver-mode)、[導入告知](https://blog.google/products-and-platforms/products/chrome/new-chrome-features-to-save-battery-and-make-browsing-smoother/)、[初期ON実験](https://chromium.googlesource.com/chromium/src/+/11057b006d94e3cb22df8b0149837dfc92afd56a/testing/variations/fieldtrial_testing_config.json)、[126のpref登録](https://chromium.googlesource.com/chromium/src/+/126.0.6478.126/components/performance_manager/user_tuning/prefs.cc)

**「110で全員既定ON、その後の特定版で全員OFFへ変更」という完全な履歴は、一次資料で確認できませんでした。** バージョンだけで既定値を推定しないでください。

実行器の合格条件は次です。

1. 設定ファイル生成はChrome終了中に行う。
2. 起動後、設定画面の実効値が予定のON/OFF・強度になっていることを検証する。
3. ポリシー、例外、バージョン、コマンドラインを保存する。
4. 設定確認タブを閉じてから試験シナリオを開始する。
5. 終了後のLocal Stateも保存する。ただし、**ディスク上の値だけを実効値の証明にしない**。

なお、**Memory Saver OFFでも、メモリ圧迫による破棄まで無効になるわけではありません。** [Chrome公式説明](https://developer.chrome.com/blog/memory-and-energy-saver-mode)

**2．タブの破棄を決定的に起こす**

**確認済み：第一候補は `chrome.tabs.discard(tabId)`**

Chrome 54以降の公開APIです。IDを省略するとChromeが対象を選ぶため、再現試験では必ず指定します。アクティブなタブは破棄できず、破棄後に選択すると再読み込みされます。[Tabs API](https://developer.chrome.com/docs/extensions/reference/api/tabs#method-discard)

拡張のservice workerまたは拡張ページのコンテキストで、次のように実行します。

```js
async function discardExact(tabIds) {
  const results = [];

  for (const id of tabIds) {
    const before = await chrome.tabs.get(id);
    if (before.active) throw new Error(`active tab: ${id}`);
    if (before.discarded) throw new Error(`already discarded: ${id}`);

    const result = await chrome.tabs.discard(id);
    const after = await chrome.tabs.get(id);

    if (!result || !after.discarded) {
      throw new Error(`discard failed: ${id}`);
    }

    results.push({id, url: before.url, discarded: after.discarded});
  }
  return results;
}
```

再現手順：

1. 13タブを同じ順序で実際に読み込む。各URLの読込成功を記録する。
2. 最後に動画タブを選択し、背景12タブのURLとタブIDの対応を保存する。
3. 同一ルールで決めた対象IDだけを破棄する。
4. 全対象の `discarded === true` を確認する。失敗はその回を不成立とする。
5. 破棄完了時刻をイベントログに保存し、固定の観測区間を採る。
6. 復帰時間の試験はメモリ観測後に行う。途中で対象タブを選択しない。

API成功はメモリ会計の即時安定を保証しません。状態確認後も時系列で測ります。また、この操作は**強制破棄条件**であり、Memory Saver自然発動の代用ではありません。

**確認済み：`chrome://discards`**

公式説明は、対象行の **Urgent Discard** を使う方法です。公開実装にはUrgent／Proactiveの操作があり、最低背景待機時間を無視する要求を送っています。自然なMemory Saverの待機試験とは区別します。[公式手順](https://developer.chrome.com/blog/memory-and-energy-saver-mode#testing_your_site_in_memory_saver_mode)、[バックエンド](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/ui/webui/discards/discards_ui.cc)

無人化する場合は、CDPでこの内部ページのUIを操作できます。ただしこれは公開の「discard用CDPコマンド」ではありません。

- 行番号ではなく完全URLで対象を照合する。
- 内部IDは一覧更新で変わり得るため、毎回取り直す。
- クリック完了ではなく `discarded` 状態への変化を待つ。
- このページは定期更新するため、計測前に閉じる。
- DOMや内部Mojo APIはバージョン依存。153版でのセレクターは未検証。

このため、固定版の診断用には使えても、主実行経路には拡張APIを勧めます。[UI実装](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/resources/discards/discards_tab.ts)

**CDPそのもの**

確認した公開プロトコルに、指定タブを通常のdiscard状態にする専用コマンドは見つかりませんでした。

- `Page.setWebLifecycleState` は `frozen` / `active`。**freezeは破棄ではない**。
- `Memory.simulatePressureNotification` は圧迫通知の模擬。対象タブ・実際の解放量を固定できない。
- `Page.crash` や `Target.closeTarget` も目的の代用にならない。

一次資料：[Page定義](https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/pdl/domains/Page.pdl)、[Memory定義](https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/pdl/domains/Memory.pdl)

**3．拡張を無人で導入・有効化する**

**確認済み：導入経路**

| 経路 | 判定 |
|---|---|
| 公式Chromeで `--load-extension=/path` | **137以降は使用不可**という公式告知 |
| Chrome for Testing／Chromiumで同フラグ | 公式告知では継続対応 |
| CDP `Extensions.loadUnpacked` | 公開されたexperimentalコマンド。絶対パスを渡し、拡張IDが返る |
| `ExtensionInstallForcelist` | 無人導入・権限付与に対応。ただし管理環境の条件あり |
| macOSのExternal Extensions用JSON | 通常の外部導入には有効化確認があり、完全無人の代用にならない |
| `Preferences` の `extensions.settings` を手書き | 現行Chromeへの確実な導入方法として確認できず。採用しない |

一次資料：[137の変更告知](https://groups.google.com/a/chromium.org/g/chromium-extensions/c/1-g8EFx2BBY/m/S0ET5wPjCAAJ)、[CDP定義](https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/pdl/domains/Extensions.pdl)、[外部導入の制約](https://developer.chrome.com/docs/extensions/how-to/distribute/install-extensions)

**公式Chromeを使う実行経路案**

まず専用プロファイルで、browser targetに対して次を呼びます。

```json
{
  "id": 1,
  "method": "Extensions.loadUnpacked",
  "params": {
    "path": "/absolute/path/to/extension"
  }
}
```

対応版なら続いて：

```json
{
  "id": 2,
  "method": "Extensions.getExtensions",
  "params": {}
}
```

返った `id`、`version`、`path`、`enabled` を検証します。コマンド成功だけでなく、その拡張コンテキストから `chrome.tabs.query()` と設定読込が成功することも確認します。[導入・有効状態取得の実装](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/devtools/protocol/extensions_handler.cc)

**接続条件には版差があります。** 140版では `--enable-unsafe-extension-debugging` とunsafe操作を許可する接続条件があり、公式開発者の例は `--remote-debugging-pipe` を使用しています。一方、現在の公開mainでは同じ条件式ではありません。**153版で「ポート接続だけで必ず導入できる」とは断定できません。** [140版の条件](https://raw.githubusercontent.com/chromium/chromium/140.0.7339.80/chrome/browser/devtools/chrome_devtools_session.cc)、[公式開発者の自動導入例](https://groups.google.com/a/chromium.org/g/chromium-extensions/c/1-g8EFx2BBY)、[現在の条件](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/devtools/chrome_devtools_session.cc)

実装は次の二段階が安全です。

1. **準備工程**：pipe接続できる自動化ランチャーで専用プロファイルを起動し、拡張導入・設定・正常終了を行う。
2. **計測工程**：同じ専用プロファイルを `open -n -a` で起動し、拡張が有効なことを確認して測定する。

この方法では「新品プロファイル」ではなく、**拡張準備済み・ベンチ対象サイト未訪問のプロファイル**と記載します。再起動後の有効性は153版での予備試験が必要です。導入に失敗したら、その条件を中止し、拡張なしのまま測定を続けないでください。

CDPのremote debuggingには専用の非標準 `--user-data-dir` を使います。Chrome 136以降の制約とも一致します。[公式変更説明](https://developer.chrome.com/blog/remote-debugging-port)

**確実な代替候補：Chrome for Testing**

```sh
open -n -a "$CFT_APP" --args \
  --user-data-dir="$PROFILE" \
  --no-first-run \
  --no-default-browser-check \
  --load-extension="$EXTENSION_DIR" \
  about:blank
```

これは公式に案内された経路ですが、今回未実行です。使用した場合、結果名は **Chrome for Testing〈完全版番号〉＋Idaten拡張** とし、通常配布Chromeの結果と混ぜません。

**管理ポリシーの代替**

```json
{
  "ExtensionInstallForcelist": [
    "<固定ID>;https://example.test/extension/update.xml"
  ]
}
```

自前CRXなら署名鍵・CRX・更新XMLを固定します。macOSでWeb Store外拡張を強制導入するには、MDM、MCXドメイン参加、Chrome Enterprise Core登録のいずれかが必要です。未管理MacへJSONを置くだけの手順ではありません。[公式ポリシー定義](https://raw.githubusercontent.com/chromium/chromium/main/components/policy/resources/templates/policy_definitions/Extensions/ExtensionInstallForcelist.yaml)

**拡張IDの固定**

現在の [manifest.json](/Users/yu01/idaten-browser/extension/manifest.json) には `key` がありません。試験用の同一成果物に、固定公開鍵を指定してください。

```json
{
  "key": "<同じ公開鍵のDERをBase64化した文字列>"
}
```

公式にはmanifestの `key` による開発時ID固定が案内されています。秘密鍵はmanifestへ入れません。全試行で拡張全体のハッシュ、ID、版、設定を保存します。[公式key仕様](https://developer.chrome.com/docs/extensions/reference/manifest/key)

**「同じ休眠規則」には現コードの差分処理が必要**

[policy.js](/Users/yu01/idaten-browser/extension/policy.js) と [Swift側](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:746) は同一ではありません。

| 条件 | 拡張 | Swift |
|---|---|---|
| 背景予算 | 全ウィンドウを集計 | ウィンドウごと |
| 最古候補が保護対象 | 他候補で補充する | 超過枚数分だけ見てスキップ |
| JS判定失敗・タイムアウト | busyとして保護 | 休眠へ進む経路あり |
| 固定タブ・例外ドメイン | 対応 | 同じ仕組みではない |
| メモリ圧迫 | Chrome側の機構が別途作用 | Swift側にも即時休眠処理 |

最初の比較は、**1ウィンドウ・固定タブなし・例外なし・背景は静的文書・動画は前景・入力なし・メモリ圧迫なし**に限定してください。それでも「完全に同じアルゴリズム」ではなく、「背景予算6・アイドル10分を揃えた条件」です。

拡張設定は `chrome.storage.sync` へ次を設定し、読み戻します。

```js
await chrome.storage.sync.set({
  budget: 6,
  idleMinutes: 10,
  neverDiscard: []
});
```

`runtime.sendMessage("enforce")` は既存拡張で使えますが、自動運用試験で毎回送ると手動トリガー条件になります。また、既存実装は処理中なら即座に戻るため、返信 `true` だけを休眠完了判定にできません。`storage.local.lastRun` と実際のタブ状態を照合します。[background.js](/Users/yu01/idaten-browser/extension/background.js)

**4．動画タブを固定する**

**確認済みの仕様に基づく提案：単一MP4をローカルHTTP配信する**

初期条件は以下が扱いやすいです。

| 項目 | 固定値の提案 |
|---|---|
| 映像 | H.264、1920×1080、30fps固定、8bit、4:2:0、SDR |
| 音声 | 初期試験は音声トラックなし。音声ありは別条件 |
| 再生 | 同じMP4、同じ開始位置、`playbackRate=1` |
| 配信 | `http://127.0.0.1:<固定port>/video.html` |
| ページ | 同一HTML、単一`video`、広告・外部通信・MSE・DRMなし |
| 表示 | 同じCSS寸法、ズーム、DPR、ディスプレイ・リフレッシュレート |
| 状態 | 前景・可視・最小化なし。`open -g` 任せにしない |

素材は一度だけ生成し、以後は**ファイルのSHA-256を固定**します。例えばFFmpegのテスト映像を使えます。[FFmpeg公式フィルター資料](https://ffmpeg.org/ffmpeg-filters.html#testsrc_002c-testsrc2)

```sh
ffmpeg -f lavfi -i 'testsrc2=size=1920x1080:rate=30' \
  -t 120 -an \
  -c:v libx264 -profile:v high -level:v 4.0 \
  -pix_fmt yuv420p -preset medium -crf 20 \
  -g 60 -keyint_min 60 -sc_threshold 0 \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -movflags +faststart fixture.mp4
```

FFmpeg・encoder版と `ffprobe` の出力も保存します。これは合成動画条件です。実写負荷の主張には、利用権のある実写素材を別途固定してください。

15分観測なら120秒素材のloopを全試行で統一できます。ただしloop境界の負荷も測定に含まれることを明記します。

配信サーバーは `Content-Type: video/mp4`、正しい `Content-Length`、Range要求と `206` に対応させます。測定前に `Range: bytes=0-1023` への応答を確認します。単に「HTTPサーバーが起動した」で合格にしません。[HTTP Range仕様](https://www.rfc-editor.org/rfc/rfc9110.html#name-range-requests)

**無人での再生確認**

1. メタデータ読込を待つ。
2. `currentTime=0`、`playbackRate=1`、ミュート条件を設定。
3. `play()` のPromise成功を待つ。必要なら両者で同じ開始ボタン操作を行う。
4. `playing` と再生時刻の進行を確認して `t0` を記録。
5. 同じページ内コードで、低頻度に再生状態を記録する。

保存する最低項目：

```js
const q = video.getVideoPlaybackQuality();
({
  currentSrc: video.currentSrc,
  currentTime: video.currentTime,
  videoWidth: video.videoWidth,
  videoHeight: video.videoHeight,
  paused: video.paused,
  ended: video.ended,
  playbackRate: video.playbackRate,
  readyState: video.readyState,
  visibility: document.visibilityState,
  totalFrames: q.totalVideoFrames,
  droppedFrames: q.droppedVideoFrames
});
```

フレーム品質APIの一次資料：[Media Playback Quality](https://w3c.github.io/media-playback-quality/)

**確認できないもの：同じデコーダー内部状態の強制**

同一MP4でも、ChromeとWKWebViewのデコーダー、バッファ戦略、GPUへの転送経路まで同一にはできません。

- 両者とも標準のハードウェアアクセラレーションを使用し、Chromeだけ `--disable-gpu` にしない。
- Chromeでは予備走行でMediaパネル等からデコーダー情報を記録する。計測中はDevToolsを閉じる。[Chrome Mediaパネル](https://developer.chrome.com/docs/devtools/media-panel)
- `navigator.mediaCapabilities.decodingInfo()` の `supported` / `smooth` / `powerEfficient` を両者で保存する。ただし `powerEfficient=true` は、その再生がハードウェアデコードされた証明ではありません。[W3C仕様](https://www.w3.org/TR/media-capabilities/)
- WKWebView側の実デコーダー経路が未確認なら、公開表現は「同一符号化素材・同一表示再生条件」に限定する。

バッファ量は観測値として残します。全量をBlobへ読み込んで揃えると、別のメモリ負荷を追加してしまいます。

**5．区間中央値・ピークと、10組のAB/BA設計**

**確認済み：既存計器の制約**

[footprint-cli](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift) のCSVは次の列です。

```text
t_sec,nprocs,footprint_bytes,cpu_nanos
```

実務上、次を補う必要があります。

- `--interval 1` は厳密な1Hzではなく、**採取処理時間＋1秒sleep**。
- CSVは正常終了時に書かれる。途中で計器をkillすると残らない可能性がある。
- 表示される中央値は偶数件で中央2値の平均にならない。CSVから再集計する。
- PID別採取失敗を黙って除外する。公開用には失敗PID・対象PID集合の監査が必要。
- 1秒採取の最大値は**観測ピーク**。瞬間的な真の最大値ではない。
- PID取得後に計器を開始する現構成では、それ以前の起動ピークは取れない。

**採取手順案**

固定のシナリオ準備枠を180秒とし、その間に読込・操作・動画準備を終えます。間に合わなければ失敗にします。最後の操作・動画再生開始を `t0` として900秒観測します。

```sh
"$FP" --pid "$ROOT_PID" \
  --interval 1 \
  --duration 1090 \
  --csv "$RUN_DIR/footprint.csv" \
  > "$RUN_DIR/footprint-summary.txt" \
  2> "$RUN_DIR/footprint-errors.txt"
```

計器開始から `t0` までのオフセットを別ログへ保存します。1090秒は「準備180秒＋観測900秒＋余裕」の例です。集計対象はログで区切ります。

| 指標 | `t0` 相対の対象区間 |
|---|---|
| 60秒値 | `[30,60)` 秒の中央値 |
| 5分値 | `[270,300)` 秒の中央値 |
| 15分値 | `[870,900)` 秒の中央値 |
| シナリオピーク | 計器の最初のサンプルから `t0+900` までの最大値 |
| 放置中ピーク | `[0,900)` 秒の最大値 |

集計の核は以下です。

```python
from statistics import median

def window_stats(rows, t0_offset, start, end):
    selected = [
        r for r in rows
        if start <= float(r["t_sec"]) - t0_offset < end
    ]
    if not selected:
        raise ValueError("empty window")

    values = [int(r["footprint_bytes"]) for r in selected]
    return {
        "samples": len(values),
        "median_mib": median(values) / 1048576,
        "sampled_peak_mib": max(values) / 1048576,
    }
```

サンプル数だけでなく、区間の端まで観測できているか、最大サンプル間隔、プロセス取得失敗も検査します。欠測をゼロで補間しません。

**交互測定前のリセット条件：以下は提案する事前登録ルール**

1. 前試行の本体・Helper・WebKit・管理下Heliumが終了したことを確認する。固定5秒sleepだけで済ませない。
2. 最低120秒待機し、その後60秒連続で開始条件を満たすことを確認する。
3. AC電源、低電力モードOFF、同じ画面状態。thermal stateは `nominal`。
4. 開始前60秒の全体CPUアイドル率を例えば90%以上とする。
5. メモリ圧迫はnormal。`vm_stat` のpageout／swapout増分が開始前60秒でゼロ。
6. 条件を10分以内に満たせなければ、そのペアを保留。待機時間も保存する。

thermal stateはAppleの公開APIで取得できます。数値閾値と待機時間はApple推奨値ではなく、今回の実験設計案です。[Apple ThermalState](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum)

swap使用量がゼロへ戻るまで待つ設計は避けます。使用量と増分を記録し、残留状態が大きく変わった場合はペアをやり直す、または再起動を含む別ブロックにします。

**試験中にそのブラウザ自身が起こしたメモリ圧迫は結果です。** 都合の悪い回として除外しません。開始前の汚染、外部アプリの割込み、動画再生失敗などと区別します。

キャッシュ条件は以下のどちらかを選んで固定します。

- **アプリキャッシュ冷**：試行ごとに未訪問プロファイル／データストア。OSファイルキャッシュは別物として記録。
- **アプリキャッシュ温**：同一の予備走行を行い、正常終了後の状態から開始。

新規プロファイルだけで「完全な冷キャッシュ」と呼ばず、片側だけ `purge` する処理も入れません。

**10組の具体的順序**

A＝Chromeの**一つの固定条件**、B＝Idatenの対応条件です。次の順序を測定前に保存します。

| 組 | 実行順 |
|---:|---|
| 1 | A → B |
| 2 | B → A |
| 3 | B → A |
| 4 | A → B |
| 5 | A → B |
| 6 | B → A |
| 7 | B → A |
| 8 | A → B |
| 9 | A → B |
| 10 | B → A |

AB／BAは各5組。隣接する2組でも均等です。各矢印の間、組の間の両方でリセット条件を適用します。ペアをブロックとして扱う設計は、時間経過などの外乱を抑えるためです。[NISTのブロック化実験設計](https://www.itl.nist.gov/div898/handbook/pri/section3/pri332.htm)

```python
orders = [
    ("A", "B"), ("B", "A"),
    ("B", "A"), ("A", "B"),
    ("A", "B"), ("B", "A"),
    ("B", "A"), ("A", "B"),
    ("A", "B"), ("B", "A"),
]
```

片側に測定失敗があれば、生データと理由を残し、**ペア全体を同じ順序で再実行**します。1秒サンプルを独立した反復数には数えません。

各ペア・各観測点で次を計算します。

```text
差_i     = Chrome中央値_i − Idaten中央値_i
削減率_i = 1 − Idaten中央値_i / Chrome中央値_i
```

10個の対応差・削減率の中央値、ばらつき、ペア単位の信頼区間を報告します。ピークは中央値と別集計にします。

**実行条件として分けておくべき系列**

| 系列 | Chrome側 | 解釈 |
|---|---|---|
| 製品既定 | 設定を変更せず実効値を記録 | 既定の製品比較 |
| Memory Saver ON | `state=2`、強度明示、拡張なし | 自然発動を含む比較 |
| 拡張休眠 | `state=0`、拡張budget＝6・idle＝10分 | 背景予算・時間条件を揃える比較 |
| 強制破棄 | 指定IDを明示discard | 同じ稼働タブ集合での機構比較 |

**各系列・各キャッシュ条件について10組**です。60秒・5分・15分の系列だけでは、数時間のMemory Saverタイマーによる効果を評価し切れません。自然発動の効果を公開主張するなら、確認した版の待機時間を超える長時間系列を追加し、実際の破棄時刻を記録してください。
