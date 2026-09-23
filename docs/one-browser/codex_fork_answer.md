codex
**このMacでの自前ビルドは、まずディスク容量の確保が必要です。** 実測はM1 Pro・16 GB RAM・空き24 GiB・Xcode 26.5でした。CPUとXcodeは候補になりますが、現在の空き容量で着手するのは勧めません。以下、**確認済み／未確認／設計判断・推測**を分けます。

前回の[codex_answer.md](/Users/yu01/idaten-browser/docs/one-browser/codex_answer.md:1)を読み、調査しました。ダウンロード、ビルド、インストール、ファイル編集はしていません。以下の構築コマンドも未実行です。

**1. helium-macosの構築手順とパッチ構造**

**確認済み：** `helium-macos`はmacOS向けのビルド・配布用リポジトリで、`helium-chromium`サブモジュールとして`imputnet/helium`を参照します。Chromium本体を丸ごとこのリポジトリで管理する構成ではありません。[README](https://github.com/imputnet/helium-macos/blob/main/README.md)、[.gitmodules](https://github.com/imputnet/helium-macos/blob/main/.gitmodules)

| 項目 | 確認結果 |
|---|---|
| OS・Xcode | Heliumの記載はmacOS 12以上、Xcode 26。実際には、そのXcodeが動くmacOSも必要。[構築資料](https://raw.githubusercontent.com/imputnet/helium-macos/main/docs/building.md) |
| 依存ツール | Homebrew、Python 3.13、`httplib2==0.22.0 requests pillow`、Metal Toolchain、wget、GNU coreutils、readline。DMG生成はPerl、パッチ開発はquilt。[構築資料](https://raw.githubusercontent.com/imputnet/helium-macos/main/docs/building.md) |
| SDK | Chromiumの現行`main`は公式ビルド用SDKを**26.5、build 25F70**に固定。これは最低バージョンではなく完全一致指定。ただし、採用するHeliumの固定リビジョンにも同じ値が適用されるかは別途確認が必要。[mac_sdk.gni](https://github.com/chromium/chromium/blob/main/build/config/mac/mac_sdk.gni) |
| 必要ディスク | **Heliumの構築資料に数値の保証なし。** ChromiumのMac向け資料にも現在、最低容量の明示はない。[Helium](https://raw.githubusercontent.com/imputnet/helium-macos/main/docs/building.md)、[Chromium](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md) |
| 所要時間 | Heliumは提供された高性能ランナーでビルド・梱包・リリースを「数時間」と説明。**このM1 Pro・16 GBでの所要時間は未確認**であり、同じ時間とは言えない。[README](https://github.com/imputnet/helium-macos/blob/main/README.md) |

将来実行する基本手順は次です。Python依存は専用仮想環境に入れる構成にしています。

```sh
# 依存準備
brew install python@3.13 wget coreutils readline quilt
python3.13 -m venv /任意の場所/helium-venv
source /任意の場所/helium-venv/bin/activate
python -m pip install httplib2==0.22.0 requests pillow
xcodebuild -downloadComponent MetalToolchain

# Homebrewのbinutilsを導入している場合
brew unlink binutils

# 取得・バージョン固定
git clone --recurse-submodules https://github.com/imputnet/helium-macos.git
cd helium-macos
git checkout <採用するタグまたはコミット>
git submodule update --init --recursive

# 開発版
source dev.sh
he setup
he build
he run
```

依存準備後はターミナルを開き直し、仮想環境を再度有効にします。配布用DMGを作る経路は、Xcodeを開いた状態で`./build.sh arm64`。Intel向けは`./build.sh x86_64`です。[構築資料](https://raw.githubusercontent.com/imputnet/helium-macos/main/docs/building.md)、[build.sh](https://github.com/imputnet/helium-macos/blob/main/build.sh)

**手順の注意点：**

- 手順書は引数なしでホストと同じアーキテクチャになるように説明していますが、取得した`build.sh`の既定値は**arm64固定**です。明示指定を勧めます。[build.sh](https://github.com/imputnet/helium-macos/blob/main/build.sh)
- Web上の資料に更新時差があり、古い表示には`brew install ninja`がある一方、取得した最新raw資料にはありません。固定したコミットの資料・スクリプトを組で使う必要があります。また、参照先`devutils/shared.sh`の本文は今回取得できず、構築成功までは検証していません。[GitHub表示](https://github.com/imputnet/helium-macos/blob/main/docs/building.md)、[raw資料](https://raw.githubusercontent.com/imputnet/helium-macos/main/docs/building.md)、[dev.sh](https://github.com/imputnet/helium-macos/blob/main/dev.sh)
- `he run`は専用データディレクトリと`--use-mock-keychain`を使います。日常運用・資格情報連携の最終試験は、開発起動とは分けるべきです。後半は**設計判断**。[dev.sh](https://github.com/imputnet/helium-macos/blob/main/dev.sh)

**差分パッチ方式の構造：**

```text
helium-macos
├─ helium-chromium → imputnet/helium
│  ├─ Chromiumのバージョン・依存定義
│  └─ 共通パッチ群＋適用順序 series
├─ macOS用パッチ・リソース・署名／梱包処理
└─ build/src
   └─ 取得したChromium＋上記パッチの適用結果
```

`he setup`はソース・ツールチェーンを準備し、共通／プラットフォームのパッチを統合してquiltで適用します。編集対象を`quilt add`し、`quilt refresh`、`he unmerge`で差分と適用順を各リポジトリへ戻す流れです。[dev.sh](https://github.com/imputnet/helium-macos/blob/main/dev.sh)、[パッチ統合](https://github.com/imputnet/helium-macos/blob/main/devutils/update_patches.sh)、[series](https://github.com/imputnet/helium/blob/main/patches/series)

**設計判断：** Idaten共通機能は`imputnet/helium`側のパッチ、macOS固有UI・署名・配布設定は`helium-macos`側に置くのが自然です。実質的には**両リポジトリのフォークとサブモジュール参照の管理**が必要になります。更新時はChromium更新に合わせてパッチの衝突修正・再検証を行います。[更新手順](https://github.com/imputnet/helium-macos/blob/main/docs/building.md#updating-for-a-new-chromium-release)

**2. このMacで足りるか**

以下は**2026年9月22日の実測コマンド出力**です。指示に従いログファイルは作成していません。

| 実行コマンド | 結果 |
|---|---|
| `df -h` | Dataボリューム：総容量926 GiB、使用866 GiB、**空き24 GiB** |
| `sysctl hw.memsize` | `Operation not permitted`で取得不可 |
| `sysctl -n machdep.cpu.brand_string` | 同じく取得不可 |
| `xcodebuild -version` | **Xcode 26.5 / Build 17F42** |
| 代替：`system_profiler SPHardwareDataType` | **MacBook Pro / M1 Pro / 10コア / 16 GB RAM** |
| `sw_vers` | macOS 26.5 / 25F71 |
| SDKのplist読み取り | macOS SDK **26.5 / 25F70** |
| `xcode-select -p` | `/Applications/Xcode.app/Contents/Developer` |

`xcodebuild`はキャッシュ作成を試みましたが、読み取り専用環境により拒否され、バージョン表示は返りました。`sysctl`の数値を取得できたことにはしていません。

**判定・推測：**

- **ディスク：不足と判断。** 正確なHelium必要量は未確認ですが、ChromiumではM1 Macの100 GBでも不足した実例があります。24 GiBを構築可能量として扱う根拠はありません。[開発者本人の報告とChromium開発者の回答](https://groups.google.com/a/chromium.org/g/chromium-dev/c/oItm01_yPLc)
- **RAM：16 GBで不可能とは断定できないが、余裕は小さい。** 並列数・リンク設定・同時使用アプリによってswapが増える可能性があります。この機種での実測ビルドはしていません。
- **Xcode／SDK：取得した現行要件とは整合。** ただしMetal Toolchainと全依存の準備完了、固定したHelium版での成功までは未確認です。[Helium要件](https://raw.githubusercontent.com/imputnet/helium-macos/main/docs/building.md)、[SDK指定](https://github.com/chromium/chromium/blob/main/build/config/mac/mac_sdk.gni)

**容量計画の提案：** 単一アーキテクチャ・単一出力でも、まず**空き200～300 GB程度を作業予算**として確保する案です。これは公式最低要件でも成功保証でもなく、ソース、依存、キャッシュ、出力、再試行の余裕を含む私の見積もりです。正確な時間・ピーク容量は最初の完走時に測る必要があります。**初回ビルドを「必ず1日で終わる検証」に選ぶのは避けます。** [容量の実例](https://groups.google.com/a/chromium.org/g/chromium-dev/c/oItm01_yPLc)、[Heliumの構築構成](https://github.com/imputnet/helium-macos/blob/main/dev.sh)

外付け／別Macの場合の注意は次です。

| 項目 | 確認事項・判断 |
|---|---|
| ファイルシステム | Chromiumは**APFS**を要求。**大文字小文字を区別するAPFSが必須、という記載はありません。** 通常のAPFSを第一候補にできます。[Chromium](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md)、[Appleの形式説明](https://support.apple.com/guide/disk-utility/file-system-formats-dsku19ed921c/mac) |
| 外付けの配置 | **提案：** リポジトリ全体を外付けSSDに置き、`build/src`・ダウンロードキャッシュ・出力も外付けに載せる。出力だけ移しても内蔵のソース領域が残ります。[パス実装](https://github.com/imputnet/helium-macos/blob/main/retrieve_and_unpack_resource.sh) |
| パス名 | ボリューム名を含むフルパスに空白を入れない。[Chromium](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md) |
| Spotlight | ソース／ビルドディレクトリを検索対象外にすることをChromiumが推奨。大量ファイルの索引作成によるCPU消費を抑えるため。[公式手順](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md#exclude-checkout-from-spotlight-indexing) |
| 内蔵の空き | **推測：** 外付けに移してもOSのswapやユーザー領域のキャッシュは内蔵を使い得るため、内蔵24 GiBの逼迫自体は解消したい。 |
| 別Mac | 同じ親コミット・サブモジュール・SDKを固定し、このMac向けには**arm64**を生成。開発ディレクトリの共有より、別Macでビルド・署名した完成アプリを持ち帰る構成を推奨。[build.sh](https://github.com/imputnet/helium-macos/blob/main/build.sh)、[署名・梱包](https://github.com/imputnet/helium-macos/blob/main/sign_and_package_app.sh) |

**3. 独自機能をどこに実装するか**

表の「仕分け」は**設計判断**です。根拠となる現行実装・利用可能APIを併記します。

| 機能 | 拡張・標準機能・ポリシーで済む範囲 | パッチにする範囲 |
|---|---|---|
| 予算制のタブ休眠 | 現状は**背景6タブを目安に古い順で休眠、再生・入力中は超過を許す**方式。拡張の`tabs.query`、`lastAccessed`、`tabs.discard`で近い試作が可能。[Idaten:374](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:374)、[tabs API](https://developer.chrome.com/docs/extensions/reference/api/tabs) | 製品の中核にするなら、標準の休眠判断と統合する本体パッチを推奨。全プロファイル共通予算、起動復元時からの制御、保護条件の一貫性を持たせやすい。 |
| プロファイル別データ分離 | Chromium標準プロファイルで履歴・Cookie等を分離可能。現行Idatenも履歴・セッション・ルール・Chromiumデータを分けている。[Chromiumデータ構造](https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md)、[Idaten:95](/Users/yu01/idaten-browser/Sources/Idaten/Profile.swift:95) | **同じタブバーに異なるプロファイルを混在**させるなら本体変更。標準Browserはウィンドウに単一の`Profile`を持つ。まず「1アプリ、プロファイル別ウィンドウ」で始めると変更範囲が小さい。[browser.h](https://github.com/chromium/chromium/blob/main/chrome/browser/ui/browser.h) |
| ドメイン別ルール | 現行は主に**WebKit／Chromiumの選択**。全Chromium化ではこの用途は不要。休眠除外なら`TabDiscardingExceptions`、広告例外ならuBlock側で扱える。[Idaten:8](/Users/yu01/idaten-browser/Sources/Idaten/Engines.swift:8)、[ポリシー定義](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/components/policy/resources/templates/policy_definitions/Miscellaneous/TabDiscardingExceptions.yaml) | ドメインからプロファイルを選び直して開く機能や、独自の優先順位・設定UIを標準UIへ組み込む場合。 |
| EasyList | **Helium内蔵uBlock Originを利用。** HeliumはuBOをcomponent extensionとして組み込むパッチを既に持ち、uBOはEasyList対応。[Helium実装](https://github.com/imputnet/helium/blob/main/patches/helium/core/ublock-install-as-component.patch)、[uBO公式](https://github.com/gorhill/uBlock) | 独自広告遮断エンジンの追加は不要。必要なら初期設定・設定UIの接続だけを変更する。 |

休眠については、次の違いを残しておく必要があります。

- `HighEfficiencyModeEnabled`は背景滞在時間などに基づく省メモリ設定で、**「起きている背景タブを6個にする」ポリシーではありません**。[定義](https://github.com/chromium/chromium/blob/main/components/policy/resources/templates/policy_definitions/Miscellaneous/HighEfficiencyModeEnabled.yaml)
- `frozen`はメモリ上にページを残します。IdatenのWebView破棄に近いのは`discard`です。ただし再表示は再読み込みであり、WebKitの`interactionState`と同じ復元保証ではありません。[tabs API](https://developer.chrome.com/docs/extensions/reference/api/tabs)、[Idaten:392](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:392)
- 拡張の`audible`だけでは無音動画や入力途中を完全には判定できません。試作と同等品質の移植は分けるべきです。[APIの定義](https://developer.chrome.com/docs/extensions/reference/api/tabs)、[現行保護判定:404](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:404)

現在のEasyList JSONは`WKContentRuleList`向けです。Chromiumへそのまま渡すのではなく、内蔵uBOの購読設定を利用します。[AdBlock.swift:35](/Users/yu01/idaten-browser/Sources/Idaten/AdBlock.swift:35)

**4. 1PasswordとClaudeのネイティブ連携**

**まず重要な確認：HeliumにはChrome用ホストmanifestも探すパッチがあります。**

探索順は、概ね「自ブラウザのユーザー領域 → Chromeのユーザー領域 → 自ブラウザのシステム領域 → Chromeのシステム領域」です。したがって、**最初からmanifestのコピーやシンボリックリンクが必須とは限りません。** フォークでもこのパッチを維持する価値があります。[scan-chrome-native-messaging-hosts.patch](https://github.com/imputnet/helium/blob/main/patches/helium/core/scan-chrome-native-messaging-hosts.patch)

**1Password：確認済みの条件**

1. CWS等から1Password拡張を導入できること。
2. macOSではAppleのコード署名要件を満たすブラウザをApplicationsから選び、1Passwordの**Settings → Browser → Add Browser**で登録すること。
3. デスクトップ側と拡張側の連携設定が有効であること。[追加ブラウザ公式手順](https://support.1password.com/additional-browsers/)、[接続確認](https://support.1password.com/connect-1password-browser-app/)

**フォークへの適用判断：** 自分のDeveloper IDで、ヘルパー等を含むアプリ全体を正しく署名し、登録する構成を推奨します。Heliumの署名スクリプトは証明書なしだと`codesign --sign -`の**ad-hoc署名**になります。これは上記要件を満たす署名として扱えません。[署名スクリプト](https://github.com/imputnet/helium-macos/blob/main/sign_and_package_app.sh)

公証と署名は別です。1Passwordの追加ブラウザ資料から「公証そのものが接続の必須条件」とまでは確認できません。一方、Heliumの標準配布スクリプトはDeveloper ID指定時に公証まで実行する構成です。[1Password要件](https://support.1password.com/additional-browsers/)、[Helium実装](https://github.com/imputnet/helium-macos/blob/main/sign_and_package_app.sh)

**このMac固有の未解決点：** `/Applications/1Password 7.app`は実測で**7.9.11**でした。現行の「Add Browser」手順をその版で使えるかは未確認です。まず対応するデスクトップ版かどうかを確認する必要があります。現行サポートはアプリ・拡張の最新版利用を求めています。[ローカルInfo.plist](</Applications/1Password 7.app/Contents/Info.plist>)、[公式接続案内](https://support.1password.com/connect-1password-browser-app/)

**Claude：確認済みの条件**

- 拡張側の`nativeMessaging`権限。
- 呼び出すホスト名とmanifestの`name`が一致。
- `allowed_origins`に**実際の拡張ID**を含むこと。
- `path`が実在・実行可能な絶対パスであること。
- manifest探索先が合い、ネイティブ通信をポリシーが妨げないこと。[Chrome公式仕様](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)、[ポリシー確認例](https://support.1password.com/connect-1password-browser-app/)

このMacには、Chrome用の次の2種類が既に存在します。

| 用途 | ホスト名と実行先 |
|---|---|
| Claude Desktop | `com.anthropic.claude_browser_extension` → `/Applications/Claude.app/Contents/Helpers/chrome-native-host`。[manifest:2](</Users/yu01/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.anthropic.claude_browser_extension.json:2>) |
| Claude Code | `com.anthropic.claude_code_browser_extension` → `~/.claude/chrome/chrome-native-host`。ラッパーは`claude --chrome-native-host`を実行。[manifest:2](</Users/yu01/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json:2>)、[ラッパー:4](/Users/yu01/.claude/chrome/chrome-native-host:4) |

両manifestにはCWS版Claude拡張のID `fcoeoabgfenejglbffodgkkbkcdhcgfn`が登録されており、参照するホストファイルには実行権限がありました。**通信成功は未検証**です。Heliumの上記探索パッチを維持すれば、既存登録を利用できる可能性があります。[探索パッチ](https://github.com/imputnet/helium/blob/main/patches/helium/core/scan-chrome-native-messaging-hosts.patch)

**前回調査からの補足：公式資料の対応範囲が一致していません。**

- Claude in Chromeのヘルプは、他のChromiumブラウザをサポート対象外と記載。[拡張ヘルプ](https://support.claude.com/en/articles/12012173-get-started-with-claude-in-chrome)
- 現行Claude Code資料はChrome・Edgeに加え、Brave・Arc・Vivaldi・Opera等の検出・接続を説明。拡張1.0.36以上、対象プラン、`/login`での認証が条件です。[Claude Code資料](https://code.claude.com/docs/en/chrome)

したがって「Claude連携はChromium派生では一律不可」という説明は広すぎます。ただし**独自Idatenの公式対応を保証する記載もありません**。nativeMessaging成功、サイドパネル表示、ページ操作成功をそれぞれ確認する必要があります。1Passwordと同じDeveloper ID要件がClaudeにもある、という一次資料は今回確認できませんでした。

**5. 最小の第一歩：既存HeliumでClaude連携を1本通す**

**提案は1つです。既にある`~/Applications/Helium.app`を使い、Claude Code → Claude拡張 → 公開ページ読取の往復を確認する。** 自前ビルド前に、必要な連携経路を絞って検証できます。アプリの存在とバージョン**0.17.2.2**は読み取りで確認しました。[ローカルInfo.plist](/Users/yu01/Applications/Helium.app/Contents/Info.plist)

将来の検証を半日～1日に時間制限して、次を確認します。

1. 専用の検証プロファイルで正規Claude拡張を有効にする。
2. `claude --chrome`から`/chrome`でHeliumへの接続を確認する。
3. 公開ページのタブを作成し、ページ内容の読取を1回成功させる。
4. 再起動後も接続できるか確認する。[公式接続・診断手順](https://code.claude.com/docs/en/chrome)

**合格条件：Heliumを接続先として使い、実際のページ読取が成功すること。** 失敗時も、ホスト未検出・起動失敗・通信拒否・拡張APIの問題のどこまで進んだかを確定できれば、1日の検証成果になります。[ネイティブ通信の診断分類](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)

これは今後の実行提案です。今回はアプリ起動や拡張導入も行っていません。また、成功しても、将来の独自署名版Idatenにおける1Password連携まで証明するものではありません。
tokens used
120,986
**このMacでの自前ビルドは、まずディスク容量の確保が必要です。** 実測はM1 Pro・16 GB RAM・空き24 GiB・Xcode 26.5でした。CPUとXcodeは候補になりますが、現在の空き容量で着手するのは勧めません。以下、**確認済み／未確認／設計判断・推測**を分けます。

前回の[codex_answer.md](/Users/yu01/idaten-browser/docs/one-browser/codex_answer.md:1)を読み、調査しました。ダウンロード、ビルド、インストール、ファイル編集はしていません。以下の構築コマンドも未実行です。

**1. helium-macosの構築手順とパッチ構造**

**確認済み：** `helium-macos`はmacOS向けのビルド・配布用リポジトリで、`helium-chromium`サブモジュールとして`imputnet/helium`を参照します。Chromium本体を丸ごとこのリポジトリで管理する構成ではありません。[README](https://github.com/imputnet/helium-macos/blob/main/README.md)、[.gitmodules](https://github.com/imputnet/helium-macos/blob/main/.gitmodules)

| 項目 | 確認結果 |
|---|---|
| OS・Xcode | Heliumの記載はmacOS 12以上、Xcode 26。実際には、そのXcodeが動くmacOSも必要。[構築資料](https://raw.githubusercontent.com/imputnet/helium-macos/main/docs/building.md) |
| 依存ツール | Homebrew、Python 3.13、`httplib2==0.22.0 requests pillow`、Metal Toolchain、wget、GNU coreutils、readline。DMG生成はPerl、パッチ開発はquilt。[構築資料](https://raw.githubusercontent.com/imputnet/helium-macos/main/docs/building.md) |
| SDK | Chromiumの現行`main`は公式ビルド用SDKを**26.5、build 25F70**に固定。これは最低バージョンではなく完全一致指定。ただし、採用するHeliumの固定リビジョンにも同じ値が適用されるかは別途確認が必要。[mac_sdk.gni](https://github.com/chromium/chromium/blob/main/build/config/mac/mac_sdk.gni) |
| 必要ディスク | **Heliumの構築資料に数値の保証なし。** ChromiumのMac向け資料にも現在、最低容量の明示はない。[Helium](https://raw.githubusercontent.com/imputnet/helium-macos/main/docs/building.md)、[Chromium](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md) |
| 所要時間 | Heliumは提供された高性能ランナーでビルド・梱包・リリースを「数時間」と説明。**このM1 Pro・16 GBでの所要時間は未確認**であり、同じ時間とは言えない。[README](https://github.com/imputnet/helium-macos/blob/main/README.md) |

将来実行する基本手順は次です。Python依存は専用仮想環境に入れる構成にしています。

```sh
# 依存準備
brew install python@3.13 wget coreutils readline quilt
python3.13 -m venv /任意の場所/helium-venv
source /任意の場所/helium-venv/bin/activate
python -m pip install httplib2==0.22.0 requests pillow
xcodebuild -downloadComponent MetalToolchain

# Homebrewのbinutilsを導入している場合
brew unlink binutils

# 取得・バージョン固定
git clone --recurse-submodules https://github.com/imputnet/helium-macos.git
cd helium-macos
git checkout <採用するタグまたはコミット>
git submodule update --init --recursive

# 開発版
source dev.sh
he setup
he build
he run
```

依存準備後はターミナルを開き直し、仮想環境を再度有効にします。配布用DMGを作る経路は、Xcodeを開いた状態で`./build.sh arm64`。Intel向けは`./build.sh x86_64`です。[構築資料](https://raw.githubusercontent.com/imputnet/helium-macos/main/docs/building.md)、[build.sh](https://github.com/imputnet/helium-macos/blob/main/build.sh)

**手順の注意点：**

- 手順書は引数なしでホストと同じアーキテクチャになるように説明していますが、取得した`build.sh`の既定値は**arm64固定**です。明示指定を勧めます。[build.sh](https://github.com/imputnet/helium-macos/blob/main/build.sh)
- Web上の資料に更新時差があり、古い表示には`brew install ninja`がある一方、取得した最新raw資料にはありません。固定したコミットの資料・スクリプトを組で使う必要があります。また、参照先`devutils/shared.sh`の本文は今回取得できず、構築成功までは検証していません。[GitHub表示](https://github.com/imputnet/helium-macos/blob/main/docs/building.md)、[raw資料](https://raw.githubusercontent.com/imputnet/helium-macos/main/docs/building.md)、[dev.sh](https://github.com/imputnet/helium-macos/blob/main/dev.sh)
- `he run`は専用データディレクトリと`--use-mock-keychain`を使います。日常運用・資格情報連携の最終試験は、開発起動とは分けるべきです。後半は**設計判断**。[dev.sh](https://github.com/imputnet/helium-macos/blob/main/dev.sh)

**差分パッチ方式の構造：**

```text
helium-macos
├─ helium-chromium → imputnet/helium
│  ├─ Chromiumのバージョン・依存定義
│  └─ 共通パッチ群＋適用順序 series
├─ macOS用パッチ・リソース・署名／梱包処理
└─ build/src
   └─ 取得したChromium＋上記パッチの適用結果
```

`he setup`はソース・ツールチェーンを準備し、共通／プラットフォームのパッチを統合してquiltで適用します。編集対象を`quilt add`し、`quilt refresh`、`he unmerge`で差分と適用順を各リポジトリへ戻す流れです。[dev.sh](https://github.com/imputnet/helium-macos/blob/main/dev.sh)、[パッチ統合](https://github.com/imputnet/helium-macos/blob/main/devutils/update_patches.sh)、[series](https://github.com/imputnet/helium/blob/main/patches/series)

**設計判断：** Idaten共通機能は`imputnet/helium`側のパッチ、macOS固有UI・署名・配布設定は`helium-macos`側に置くのが自然です。実質的には**両リポジトリのフォークとサブモジュール参照の管理**が必要になります。更新時はChromium更新に合わせてパッチの衝突修正・再検証を行います。[更新手順](https://github.com/imputnet/helium-macos/blob/main/docs/building.md#updating-for-a-new-chromium-release)

**2. このMacで足りるか**

以下は**2026年9月22日の実測コマンド出力**です。指示に従いログファイルは作成していません。

| 実行コマンド | 結果 |
|---|---|
| `df -h` | Dataボリューム：総容量926 GiB、使用866 GiB、**空き24 GiB** |
| `sysctl hw.memsize` | `Operation not permitted`で取得不可 |
| `sysctl -n machdep.cpu.brand_string` | 同じく取得不可 |
| `xcodebuild -version` | **Xcode 26.5 / Build 17F42** |
| 代替：`system_profiler SPHardwareDataType` | **MacBook Pro / M1 Pro / 10コア / 16 GB RAM** |
| `sw_vers` | macOS 26.5 / 25F71 |
| SDKのplist読み取り | macOS SDK **26.5 / 25F70** |
| `xcode-select -p` | `/Applications/Xcode.app/Contents/Developer` |

`xcodebuild`はキャッシュ作成を試みましたが、読み取り専用環境により拒否され、バージョン表示は返りました。`sysctl`の数値を取得できたことにはしていません。

**判定・推測：**

- **ディスク：不足と判断。** 正確なHelium必要量は未確認ですが、ChromiumではM1 Macの100 GBでも不足した実例があります。24 GiBを構築可能量として扱う根拠はありません。[開発者本人の報告とChromium開発者の回答](https://groups.google.com/a/chromium.org/g/chromium-dev/c/oItm01_yPLc)
- **RAM：16 GBで不可能とは断定できないが、余裕は小さい。** 並列数・リンク設定・同時使用アプリによってswapが増える可能性があります。この機種での実測ビルドはしていません。
- **Xcode／SDK：取得した現行要件とは整合。** ただしMetal Toolchainと全依存の準備完了、固定したHelium版での成功までは未確認です。[Helium要件](https://raw.githubusercontent.com/imputnet/helium-macos/main/docs/building.md)、[SDK指定](https://github.com/chromium/chromium/blob/main/build/config/mac/mac_sdk.gni)

**容量計画の提案：** 単一アーキテクチャ・単一出力でも、まず**空き200～300 GB程度を作業予算**として確保する案です。これは公式最低要件でも成功保証でもなく、ソース、依存、キャッシュ、出力、再試行の余裕を含む私の見積もりです。正確な時間・ピーク容量は最初の完走時に測る必要があります。**初回ビルドを「必ず1日で終わる検証」に選ぶのは避けます。** [容量の実例](https://groups.google.com/a/chromium.org/g/chromium-dev/c/oItm01_yPLc)、[Heliumの構築構成](https://github.com/imputnet/helium-macos/blob/main/dev.sh)

外付け／別Macの場合の注意は次です。

| 項目 | 確認事項・判断 |
|---|---|
| ファイルシステム | Chromiumは**APFS**を要求。**大文字小文字を区別するAPFSが必須、という記載はありません。** 通常のAPFSを第一候補にできます。[Chromium](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md)、[Appleの形式説明](https://support.apple.com/guide/disk-utility/file-system-formats-dsku19ed921c/mac) |
| 外付けの配置 | **提案：** リポジトリ全体を外付けSSDに置き、`build/src`・ダウンロードキャッシュ・出力も外付けに載せる。出力だけ移しても内蔵のソース領域が残ります。[パス実装](https://github.com/imputnet/helium-macos/blob/main/retrieve_and_unpack_resource.sh) |
| パス名 | ボリューム名を含むフルパスに空白を入れない。[Chromium](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md) |
| Spotlight | ソース／ビルドディレクトリを検索対象外にすることをChromiumが推奨。大量ファイルの索引作成によるCPU消費を抑えるため。[公式手順](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md#exclude-checkout-from-spotlight-indexing) |
| 内蔵の空き | **推測：** 外付けに移してもOSのswapやユーザー領域のキャッシュは内蔵を使い得るため、内蔵24 GiBの逼迫自体は解消したい。 |
| 別Mac | 同じ親コミット・サブモジュール・SDKを固定し、このMac向けには**arm64**を生成。開発ディレクトリの共有より、別Macでビルド・署名した完成アプリを持ち帰る構成を推奨。[build.sh](https://github.com/imputnet/helium-macos/blob/main/build.sh)、[署名・梱包](https://github.com/imputnet/helium-macos/blob/main/sign_and_package_app.sh) |

**3. 独自機能をどこに実装するか**

表の「仕分け」は**設計判断**です。根拠となる現行実装・利用可能APIを併記します。

| 機能 | 拡張・標準機能・ポリシーで済む範囲 | パッチにする範囲 |
|---|---|---|
| 予算制のタブ休眠 | 現状は**背景6タブを目安に古い順で休眠、再生・入力中は超過を許す**方式。拡張の`tabs.query`、`lastAccessed`、`tabs.discard`で近い試作が可能。[Idaten:374](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:374)、[tabs API](https://developer.chrome.com/docs/extensions/reference/api/tabs) | 製品の中核にするなら、標準の休眠判断と統合する本体パッチを推奨。全プロファイル共通予算、起動復元時からの制御、保護条件の一貫性を持たせやすい。 |
| プロファイル別データ分離 | Chromium標準プロファイルで履歴・Cookie等を分離可能。現行Idatenも履歴・セッション・ルール・Chromiumデータを分けている。[Chromiumデータ構造](https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md)、[Idaten:95](/Users/yu01/idaten-browser/Sources/Idaten/Profile.swift:95) | **同じタブバーに異なるプロファイルを混在**させるなら本体変更。標準Browserはウィンドウに単一の`Profile`を持つ。まず「1アプリ、プロファイル別ウィンドウ」で始めると変更範囲が小さい。[browser.h](https://github.com/chromium/chromium/blob/main/chrome/browser/ui/browser.h) |
| ドメイン別ルール | 現行は主に**WebKit／Chromiumの選択**。全Chromium化ではこの用途は不要。休眠除外なら`TabDiscardingExceptions`、広告例外ならuBlock側で扱える。[Idaten:8](/Users/yu01/idaten-browser/Sources/Idaten/Engines.swift:8)、[ポリシー定義](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/components/policy/resources/templates/policy_definitions/Miscellaneous/TabDiscardingExceptions.yaml) | ドメインからプロファイルを選び直して開く機能や、独自の優先順位・設定UIを標準UIへ組み込む場合。 |
| EasyList | **Helium内蔵uBlock Originを利用。** HeliumはuBOをcomponent extensionとして組み込むパッチを既に持ち、uBOはEasyList対応。[Helium実装](https://github.com/imputnet/helium/blob/main/patches/helium/core/ublock-install-as-component.patch)、[uBO公式](https://github.com/gorhill/uBlock) | 独自広告遮断エンジンの追加は不要。必要なら初期設定・設定UIの接続だけを変更する。 |

休眠については、次の違いを残しておく必要があります。

- `HighEfficiencyModeEnabled`は背景滞在時間などに基づく省メモリ設定で、**「起きている背景タブを6個にする」ポリシーではありません**。[定義](https://github.com/chromium/chromium/blob/main/components/policy/resources/templates/policy_definitions/Miscellaneous/HighEfficiencyModeEnabled.yaml)
- `frozen`はメモリ上にページを残します。IdatenのWebView破棄に近いのは`discard`です。ただし再表示は再読み込みであり、WebKitの`interactionState`と同じ復元保証ではありません。[tabs API](https://developer.chrome.com/docs/extensions/reference/api/tabs)、[Idaten:392](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:392)
- 拡張の`audible`だけでは無音動画や入力途中を完全には判定できません。試作と同等品質の移植は分けるべきです。[APIの定義](https://developer.chrome.com/docs/extensions/reference/api/tabs)、[現行保護判定:404](/Users/yu01/idaten-browser/Sources/Idaten/BrowserWindowController.swift:404)

現在のEasyList JSONは`WKContentRuleList`向けです。Chromiumへそのまま渡すのではなく、内蔵uBOの購読設定を利用します。[AdBlock.swift:35](/Users/yu01/idaten-browser/Sources/Idaten/AdBlock.swift:35)

**4. 1PasswordとClaudeのネイティブ連携**

**まず重要な確認：HeliumにはChrome用ホストmanifestも探すパッチがあります。**

探索順は、概ね「自ブラウザのユーザー領域 → Chromeのユーザー領域 → 自ブラウザのシステム領域 → Chromeのシステム領域」です。したがって、**最初からmanifestのコピーやシンボリックリンクが必須とは限りません。** フォークでもこのパッチを維持する価値があります。[scan-chrome-native-messaging-hosts.patch](https://github.com/imputnet/helium/blob/main/patches/helium/core/scan-chrome-native-messaging-hosts.patch)

**1Password：確認済みの条件**

1. CWS等から1Password拡張を導入できること。
2. macOSではAppleのコード署名要件を満たすブラウザをApplicationsから選び、1Passwordの**Settings → Browser → Add Browser**で登録すること。
3. デスクトップ側と拡張側の連携設定が有効であること。[追加ブラウザ公式手順](https://support.1password.com/additional-browsers/)、[接続確認](https://support.1password.com/connect-1password-browser-app/)

**フォークへの適用判断：** 自分のDeveloper IDで、ヘルパー等を含むアプリ全体を正しく署名し、登録する構成を推奨します。Heliumの署名スクリプトは証明書なしだと`codesign --sign -`の**ad-hoc署名**になります。これは上記要件を満たす署名として扱えません。[署名スクリプト](https://github.com/imputnet/helium-macos/blob/main/sign_and_package_app.sh)

公証と署名は別です。1Passwordの追加ブラウザ資料から「公証そのものが接続の必須条件」とまでは確認できません。一方、Heliumの標準配布スクリプトはDeveloper ID指定時に公証まで実行する構成です。[1Password要件](https://support.1password.com/additional-browsers/)、[Helium実装](https://github.com/imputnet/helium-macos/blob/main/sign_and_package_app.sh)

**このMac固有の未解決点：** `/Applications/1Password 7.app`は実測で**7.9.11**でした。現行の「Add Browser」手順をその版で使えるかは未確認です。まず対応するデスクトップ版かどうかを確認する必要があります。現行サポートはアプリ・拡張の最新版利用を求めています。[ローカルInfo.plist](</Applications/1Password 7.app/Contents/Info.plist>)、[公式接続案内](https://support.1password.com/connect-1password-browser-app/)

**Claude：確認済みの条件**

- 拡張側の`nativeMessaging`権限。
- 呼び出すホスト名とmanifestの`name`が一致。
- `allowed_origins`に**実際の拡張ID**を含むこと。
- `path`が実在・実行可能な絶対パスであること。
- manifest探索先が合い、ネイティブ通信をポリシーが妨げないこと。[Chrome公式仕様](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)、[ポリシー確認例](https://support.1password.com/connect-1password-browser-app/)

このMacには、Chrome用の次の2種類が既に存在します。

| 用途 | ホスト名と実行先 |
|---|---|
| Claude Desktop | `com.anthropic.claude_browser_extension` → `/Applications/Claude.app/Contents/Helpers/chrome-native-host`。[manifest:2](</Users/yu01/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.anthropic.claude_browser_extension.json:2>) |
| Claude Code | `com.anthropic.claude_code_browser_extension` → `~/.claude/chrome/chrome-native-host`。ラッパーは`claude --chrome-native-host`を実行。[manifest:2](</Users/yu01/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json:2>)、[ラッパー:4](/Users/yu01/.claude/chrome/chrome-native-host:4) |

両manifestにはCWS版Claude拡張のID `fcoeoabgfenejglbffodgkkbkcdhcgfn`が登録されており、参照するホストファイルには実行権限がありました。**通信成功は未検証**です。Heliumの上記探索パッチを維持すれば、既存登録を利用できる可能性があります。[探索パッチ](https://github.com/imputnet/helium/blob/main/patches/helium/core/scan-chrome-native-messaging-hosts.patch)

**前回調査からの補足：公式資料の対応範囲が一致していません。**

- Claude in Chromeのヘルプは、他のChromiumブラウザをサポート対象外と記載。[拡張ヘルプ](https://support.claude.com/en/articles/12012173-get-started-with-claude-in-chrome)
- 現行Claude Code資料はChrome・Edgeに加え、Brave・Arc・Vivaldi・Opera等の検出・接続を説明。拡張1.0.36以上、対象プラン、`/login`での認証が条件です。[Claude Code資料](https://code.claude.com/docs/en/chrome)

したがって「Claude連携はChromium派生では一律不可」という説明は広すぎます。ただし**独自Idatenの公式対応を保証する記載もありません**。nativeMessaging成功、サイドパネル表示、ページ操作成功をそれぞれ確認する必要があります。1Passwordと同じDeveloper ID要件がClaudeにもある、という一次資料は今回確認できませんでした。

**5. 最小の第一歩：既存HeliumでClaude連携を1本通す**

**提案は1つです。既にある`~/Applications/Helium.app`を使い、Claude Code → Claude拡張 → 公開ページ読取の往復を確認する。** 自前ビルド前に、必要な連携経路を絞って検証できます。アプリの存在とバージョン**0.17.2.2**は読み取りで確認しました。[ローカルInfo.plist](/Users/yu01/Applications/Helium.app/Contents/Info.plist)

将来の検証を半日～1日に時間制限して、次を確認します。

1. 専用の検証プロファイルで正規Claude拡張を有効にする。
2. `claude --chrome`から`/chrome`でHeliumへの接続を確認する。
3. 公開ページのタブを作成し、ページ内容の読取を1回成功させる。
4. 再起動後も接続できるか確認する。[公式接続・診断手順](https://code.claude.com/docs/en/chrome)

**合格条件：Heliumを接続先として使い、実際のページ読取が成功すること。** 失敗時も、ホスト未検出・起動失敗・通信拒否・拡張APIの問題のどこまで進んだかを確定できれば、1日の検証成果になります。[ネイティブ通信の診断分類](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)

これは今後の実行提案です。今回はアプリ起動や拡張導入も行っていません。また、成功しても、将来の独自署名版Idatenにおける1Password連携まで証明するものではありません。
