# 同梱フィルタの帰属表記

Idatenに同梱している `easylist.json` は、[EasyList](https://easylist.to/) を
[adblock-rust](https://github.com/brave/adblock-rust)(MPL-2.0)の `content-blocking` 機能で
Apple の WKContentRuleList 形式(JSON)へ変換したものです。

- **原典**: EasyList — https://easylist.to/
- **ライセンス**: EasyList は GPLv3以降 / CC BY-SA 3.0以降 のデュアルライセンス。
  Idatenでは **CC BY-SA 3.0以降** を選択しています(帰属表記の保持のみで足りるため)。
  ライセンス全文: https://creativecommons.org/licenses/by-sa/3.0/legalcode
- **著作者**: The EasyList authors (https://easylist.to/)
- **変更内容**: ABP形式(.txt)からApple content-blocking形式(JSON)へ機械変換。
  adblock-rust が変換できないルール種別(scriptlet・procedural cosmetic等)は削除されている
  (adblock-rust content_blocking.rs の仕様、Idaten側の追加改変は無し)。
  変換に使ったツールは `tools/adblock-convert/`(このリポジトリに同梱、adblock-rustをビルド時にのみ呼ぶ。
  Idaten本体の実行ファイルには静的リンクしていない)。
- **変換元の取得日/バージョン**: `rules/easylist.source.txt` 内のヘッダコメント(Version/Last modified)を参照。

再配布・改変時は、この帰属表記(著作者・原典URL・ライセンス・変更内容)を保持してください。
