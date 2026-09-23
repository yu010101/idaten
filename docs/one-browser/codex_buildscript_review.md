codex
**現状のまま「無人で1回通す」「失敗しても再実行で復旧する」は成立しません。** 特に1・2は実行前に直す必要があります。読み取りのみでレビューし、ファイル変更・実ビルドはしていません。上流との比較は取得できた `main` に基づきます。

1. **[重大／a] `source dev.sh` がリポジトリの場所を誤認する。**  
   [build_helium.sh:77](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:77)、85行。上流は `_root_dir=$(dirname $(greadlink -f $0))` を使っています。`source` しても `$0` は呼び出し元の `build_helium.sh` のままです。絶対パス起動ならラッパーの配置先、記載どおりの相対パス起動なら `cd` 後の誤ったパスを基準にし、`devutils/shared.sh` 等を読み込めません。**公式の対話シェルでの手順を、そのまま別スクリプト内に移せていません。**  
   根拠：[上流 dev.sh の初期化](https://github.com/imputnet/helium-macos/blob/main/dev.sh#L3-L6)、[Bash の `$0`・関数の仕様](https://www.gnu.org/s/bash/manual/bash.html)。

2. **[重大／a・c] 段の途中の失敗を見逃し、成功スタンプを付ける。**  
   [build_helium.sh:24](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:24)、43–50・67–69行。関数を `if "$@"` の条件として実行しているため、末尾コマンドが成功すると、それ以前の失敗が隠れます。例えば `pip install` 失敗後に Metal ダウンロードが成功すると `deps` 済み、指定タグの checkout 失敗後に `git log` が成功すると `clone` 済みになります。上流 `he` 内の `set -e` もこの条件付き呼び出しでは救済になりません。**単に先頭へ `set -e` を足すだけでは不十分です。** この挙動は書き込みなしの Bash 最小例で再現しました。  
   根拠：[Bash の errexit 例外](https://www.gnu.org/s/bash/manual/bash.html#The-Set-Builtin)、[Bash メンテナーの説明](https://lists.gnu.org/archive/html/bug-bash/2024-07/msg00149.html)。

3. **[高／a・b] Xcode のライセンス処理が Metal ダウンロードより後。初期設定も確認していない。**  
   [build_helium.sh:50](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:50)、53–59・97–98行。ライセンス未同意の個体では `deps` が先に失敗し、同意する段まで到達できません。Xcode がインストール済みでも、選択中の開発者ディレクトリが CLT を指していたり、初回コンポーネント導入が未完了だったりする場合を扱っていません。依存導入前に、選択先・初期設定・ライセンスを確認する必要があります。  
   根拠：[Apple の Xcode 選択・初期コンポーネント導入手順](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components?changes=_1)、[Chromium のライセンス説明](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md#xcode-license-agreement)。

4. **[高／b] `nohup` 起動と、パスワードを要求し得る `sudo` が両立していない。**  
   [build_helium.sh:4](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:4)、36・59行。`sudo xcodebuild -license accept` は非対話実行を強制していません。TTY ありならパスワード待ち、記載の SSH 起動なら通常は TTY 不在で失敗します。`accept` が省くのはライセンス対話で、sudo 認証ではありません。Homebrew の `NONINTERACTIVE=1` も権限を与えるものではなく、認証できなければ停止します。借用個体の sudo 設定を事前確認せず無人投入できません。  
   根拠：[Homebrew installer の sudo 判定](https://github.com/Homebrew/install/blob/HEAD/install.sh)、[Chromium の全ユーザー向けライセンス同意](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md#xcode-license-agreement)。

5. **[高／a・c] Homebrew installer の取得失敗を成功扱いできる。**  
   [build_helium.sh:36](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:36)。`curl` が失敗して空文字を返すと `/bin/bash -c ""` は成功し、`brew` スタンプが付きます。その後の再実行でも導入を飛ばします。取得の終了コードと、導入後の実体確認が必要です。空コマンドが終了コード0になることも最小例で確認しました。  
   根拠：[Bash の単純コマンドと終了ステータス](https://www.gnu.org/s/bash/manual/bash.html#Simple-Command-Expansion)。

6. **[高／b・c] setup の再実行は、安全な途中再開ではない。巨大処理の時間上限もない。**  
   [build_helium.sh:78](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:78)。上流は `src/out` がなければ `src` を削除して準備し直し、あれば前準備を飛ばします。しかし `out` の存在だけでは、その後の toolchain・resources・設定生成まで完了した証明になりません。また、アーカイブ取得経路の失敗後は Git clone 経路へフォールバックします。失敗理由によっては大量取得を別方式でやり直します。本スクリプトには試行数・停滞時間・総経過時間の上限も、キャッシュ破損時の復旧方針もありません。**再実行だけで残り時間内に復旧する保証はありません。**  
   根拠：[上流 setup とフォールバック](https://github.com/imputnet/helium-macos/blob/main/dev.sh#L8-L53)、[取得・展開処理](https://github.com/imputnet/helium-macos/blob/main/retrieve_and_unpack_resource.sh)。

7. **[高／c] スタンプが入力・環境・成果物に結び付いていない。**  
   [build_helium.sh:21](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:21)、27・67行。同じ `WORK` で `HELIUM_REF` を変更しても clone/setup/build はすべてスキップします。venv や `.app` を削除しても同様です。Xcode 更新でも再検証されません。並行起動を防ぐロックもなく、同じソース・スタンプを競合更新できます。少なくとも入力SHA・設定・必要成果物とスタンプを照合する必要があります。  
   根拠：該当ローカルコード、[公式のリリース選択・失敗後の復旧手順](https://github.com/imputnet/helium-macos/blob/main/docs/building.md#official-non-development-build)。

8. **[高／a] `package` が何も見つけなくても「完了」になる。**  
   [build_helium.sh:92](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:92)、102–104行。これは生成処理ではなく一覧表示です。検索結果が空でも成功し得ます。さらに `stage package` の失敗をチェックせず「完了」へ進みます。期待する `.app` 内の実行ファイルの存在・アーキテクチャ・起動確認がありません。なお、採用している開発手順では **DMG がないこと自体は異常ではありません**。DMG を得る公式経路は `build.sh` です。  
   根拠：[公式ビルドと開発ビルドの区別](https://github.com/imputnet/helium-macos/blob/main/docs/building.md)。

9. **[中／b] 24時間枠に対する実行制御がない。**  
   [build_helium.sh:4](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:4)、86・95–105行。`nohup` はスリープを防ぎません。また空き容量の事前判定、残り時間判定、成果物回収の時間確保がありません。上流 `he build` は `-k 0` を渡すため、コンパイル失敗後も実行可能な仕事を継続し得ます。初回の成立確認では失敗発見後にも時間を消費します。スリープ無効設定済みなら前者は顕在化しませんが、その確認もありません。  
   根拠：[Chromium の caffeinate・取得時間・Spotlight の注意](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md)、[上流の build 呼び出し](https://github.com/imputnet/helium-macos/blob/main/dev.sh#L114-L120)。

**(d) `timings.txt` は、成功した段の終点差分しか残さず、今回の実測目的には不足しています。** 以下は公式必須要件ではなく、測定の再現性・時間予算評価に必要な項目です。

| 対象行 | 不足と影響 |
|---|---|
| [22–30行](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:22) | **失敗・中断した試行の開始／終了日時、経過時間、終了コード、失敗位置**。数時間使って落ちた試行が測定値から消える。 |
| [21・26行](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:21) | **run ID、試行番号、skip、全試行の累積時間**。追記された複数実行と、初回／再開ビルドを区別できない。 |
| [95–105行](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:95) | **借用開始時刻、24時間の期限、回収完了時刻**。段の合計は課金開始からの所要時間にならない。 |
| [55–58・69行](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:55) | **macOS build、CPU/RAM、Xcode 選択先と版、SDK、Python、submodule SHA、Chromium 版、実際の `args.gn` とビルド並列度**。一部は別ログにあるが、測定との対応が固定されない。 |
| [22・25–26行](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:22) | **空き容量の最小値、ソース／キャッシュ／出力別容量、swap・メモリのピーク**。`df` の差分はボリューム全体の純増減であり、ビルドの占有量やピークではない。表記の `MB` も計算上は MiB。 |
| [78行](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:78) | **ダウンロード／展開／toolchain／patch／GN の個別時間、転送量、再試行数、キャッシュ利用、フォールバック有無**。`setup` 一括では24時間超過の原因を判断できない。 |
| [92行](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:92) | **成果物の絶対パス・ハッシュ・検証結果・回収結果**。サイズ一覧だけでは今回生成した正常な成果物と確認できない。 |

測定条件が効く根拠は、[Chromium のビルド設定と高速化の説明](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md#faster-builds)、[Helium の取得・展開経路](https://github.com/imputnet/helium-macos/blob/main/retrieve_and_unpack_resource.sh)です。M4・32GB・1TBという仕様だけから、24時間以内の完了可否は判定できません。
tokens used
57,661
**現状のまま「無人で1回通す」「失敗しても再実行で復旧する」は成立しません。** 特に1・2は実行前に直す必要があります。読み取りのみでレビューし、ファイル変更・実ビルドはしていません。上流との比較は取得できた `main` に基づきます。

1. **[重大／a] `source dev.sh` がリポジトリの場所を誤認する。**  
   [build_helium.sh:77](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:77)、85行。上流は `_root_dir=$(dirname $(greadlink -f $0))` を使っています。`source` しても `$0` は呼び出し元の `build_helium.sh` のままです。絶対パス起動ならラッパーの配置先、記載どおりの相対パス起動なら `cd` 後の誤ったパスを基準にし、`devutils/shared.sh` 等を読み込めません。**公式の対話シェルでの手順を、そのまま別スクリプト内に移せていません。**  
   根拠：[上流 dev.sh の初期化](https://github.com/imputnet/helium-macos/blob/main/dev.sh#L3-L6)、[Bash の `$0`・関数の仕様](https://www.gnu.org/s/bash/manual/bash.html)。

2. **[重大／a・c] 段の途中の失敗を見逃し、成功スタンプを付ける。**  
   [build_helium.sh:24](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:24)、43–50・67–69行。関数を `if "$@"` の条件として実行しているため、末尾コマンドが成功すると、それ以前の失敗が隠れます。例えば `pip install` 失敗後に Metal ダウンロードが成功すると `deps` 済み、指定タグの checkout 失敗後に `git log` が成功すると `clone` 済みになります。上流 `he` 内の `set -e` もこの条件付き呼び出しでは救済になりません。**単に先頭へ `set -e` を足すだけでは不十分です。** この挙動は書き込みなしの Bash 最小例で再現しました。  
   根拠：[Bash の errexit 例外](https://www.gnu.org/s/bash/manual/bash.html#The-Set-Builtin)、[Bash メンテナーの説明](https://lists.gnu.org/archive/html/bug-bash/2024-07/msg00149.html)。

3. **[高／a・b] Xcode のライセンス処理が Metal ダウンロードより後。初期設定も確認していない。**  
   [build_helium.sh:50](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:50)、53–59・97–98行。ライセンス未同意の個体では `deps` が先に失敗し、同意する段まで到達できません。Xcode がインストール済みでも、選択中の開発者ディレクトリが CLT を指していたり、初回コンポーネント導入が未完了だったりする場合を扱っていません。依存導入前に、選択先・初期設定・ライセンスを確認する必要があります。  
   根拠：[Apple の Xcode 選択・初期コンポーネント導入手順](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components?changes=_1)、[Chromium のライセンス説明](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md#xcode-license-agreement)。

4. **[高／b] `nohup` 起動と、パスワードを要求し得る `sudo` が両立していない。**  
   [build_helium.sh:4](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:4)、36・59行。`sudo xcodebuild -license accept` は非対話実行を強制していません。TTY ありならパスワード待ち、記載の SSH 起動なら通常は TTY 不在で失敗します。`accept` が省くのはライセンス対話で、sudo 認証ではありません。Homebrew の `NONINTERACTIVE=1` も権限を与えるものではなく、認証できなければ停止します。借用個体の sudo 設定を事前確認せず無人投入できません。  
   根拠：[Homebrew installer の sudo 判定](https://github.com/Homebrew/install/blob/HEAD/install.sh)、[Chromium の全ユーザー向けライセンス同意](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md#xcode-license-agreement)。

5. **[高／a・c] Homebrew installer の取得失敗を成功扱いできる。**  
   [build_helium.sh:36](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:36)。`curl` が失敗して空文字を返すと `/bin/bash -c ""` は成功し、`brew` スタンプが付きます。その後の再実行でも導入を飛ばします。取得の終了コードと、導入後の実体確認が必要です。空コマンドが終了コード0になることも最小例で確認しました。  
   根拠：[Bash の単純コマンドと終了ステータス](https://www.gnu.org/s/bash/manual/bash.html#Simple-Command-Expansion)。

6. **[高／b・c] setup の再実行は、安全な途中再開ではない。巨大処理の時間上限もない。**  
   [build_helium.sh:78](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:78)。上流は `src/out` がなければ `src` を削除して準備し直し、あれば前準備を飛ばします。しかし `out` の存在だけでは、その後の toolchain・resources・設定生成まで完了した証明になりません。また、アーカイブ取得経路の失敗後は Git clone 経路へフォールバックします。失敗理由によっては大量取得を別方式でやり直します。本スクリプトには試行数・停滞時間・総経過時間の上限も、キャッシュ破損時の復旧方針もありません。**再実行だけで残り時間内に復旧する保証はありません。**  
   根拠：[上流 setup とフォールバック](https://github.com/imputnet/helium-macos/blob/main/dev.sh#L8-L53)、[取得・展開処理](https://github.com/imputnet/helium-macos/blob/main/retrieve_and_unpack_resource.sh)。

7. **[高／c] スタンプが入力・環境・成果物に結び付いていない。**  
   [build_helium.sh:21](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:21)、27・67行。同じ `WORK` で `HELIUM_REF` を変更しても clone/setup/build はすべてスキップします。venv や `.app` を削除しても同様です。Xcode 更新でも再検証されません。並行起動を防ぐロックもなく、同じソース・スタンプを競合更新できます。少なくとも入力SHA・設定・必要成果物とスタンプを照合する必要があります。  
   根拠：該当ローカルコード、[公式のリリース選択・失敗後の復旧手順](https://github.com/imputnet/helium-macos/blob/main/docs/building.md#official-non-development-build)。

8. **[高／a] `package` が何も見つけなくても「完了」になる。**  
   [build_helium.sh:92](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:92)、102–104行。これは生成処理ではなく一覧表示です。検索結果が空でも成功し得ます。さらに `stage package` の失敗をチェックせず「完了」へ進みます。期待する `.app` 内の実行ファイルの存在・アーキテクチャ・起動確認がありません。なお、採用している開発手順では **DMG がないこと自体は異常ではありません**。DMG を得る公式経路は `build.sh` です。  
   根拠：[公式ビルドと開発ビルドの区別](https://github.com/imputnet/helium-macos/blob/main/docs/building.md)。

9. **[中／b] 24時間枠に対する実行制御がない。**  
   [build_helium.sh:4](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:4)、86・95–105行。`nohup` はスリープを防ぎません。また空き容量の事前判定、残り時間判定、成果物回収の時間確保がありません。上流 `he build` は `-k 0` を渡すため、コンパイル失敗後も実行可能な仕事を継続し得ます。初回の成立確認では失敗発見後にも時間を消費します。スリープ無効設定済みなら前者は顕在化しませんが、その確認もありません。  
   根拠：[Chromium の caffeinate・取得時間・Spotlight の注意](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md)、[上流の build 呼び出し](https://github.com/imputnet/helium-macos/blob/main/dev.sh#L114-L120)。

**(d) `timings.txt` は、成功した段の終点差分しか残さず、今回の実測目的には不足しています。** 以下は公式必須要件ではなく、測定の再現性・時間予算評価に必要な項目です。

| 対象行 | 不足と影響 |
|---|---|
| [22–30行](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:22) | **失敗・中断した試行の開始／終了日時、経過時間、終了コード、失敗位置**。数時間使って落ちた試行が測定値から消える。 |
| [21・26行](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:21) | **run ID、試行番号、skip、全試行の累積時間**。追記された複数実行と、初回／再開ビルドを区別できない。 |
| [95–105行](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:95) | **借用開始時刻、24時間の期限、回収完了時刻**。段の合計は課金開始からの所要時間にならない。 |
| [55–58・69行](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:55) | **macOS build、CPU/RAM、Xcode 選択先と版、SDK、Python、submodule SHA、Chromium 版、実際の `args.gn` とビルド並列度**。一部は別ログにあるが、測定との対応が固定されない。 |
| [22・25–26行](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:22) | **空き容量の最小値、ソース／キャッシュ／出力別容量、swap・メモリのピーク**。`df` の差分はボリューム全体の純増減であり、ビルドの占有量やピークではない。表記の `MB` も計算上は MiB。 |
| [78行](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:78) | **ダウンロード／展開／toolchain／patch／GN の個別時間、転送量、再試行数、キャッシュ利用、フォールバック有無**。`setup` 一括では24時間超過の原因を判断できない。 |
| [92行](/Users/yu01/idaten-browser/tools/cloudbuild/build_helium.sh:92) | **成果物の絶対パス・ハッシュ・検証結果・回収結果**。サイズ一覧だけでは今回生成した正常な成果物と確認できない。 |

測定条件が効く根拠は、[Chromium のビルド設定と高速化の説明](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md#faster-builds)、[Helium の取得・展開経路](https://github.com/imputnet/helium-macos/blob/main/retrieve_and_unpack_resource.sh)です。M4・32GB・1TBという仕様だけから、24時間以内の完了可否は判定できません。
