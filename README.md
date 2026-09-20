# Idaten(韋駄天)

<img src="docs/images/idaten-statue.jpg" alt="韋駄天像(明代・1527年・Linden-Museum Stuttgart蔵)" width="200" align="right">

名前は仏教由来の俊足の神「韋駄天」から。「拡張が要らない大半のサイトは韋駄天のごとく軽く速く、
要る時だけ本気を出す」という設計を表しています。

<sub>写真: 韋駄天像(中国・河南省、明代1527年、陶製)。Linden-Museum Stuttgart蔵。
撮影 [Daderot](https://commons.wikimedia.org/wiki/User:Daderot)、[CC0(パブリックドメイン)](https://creativecommons.org/publicdomain/zero/1.0/deed.ja)、
[Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Weituo_(Veda),_China,_Henan_province,_Ming_dynasty,_dated_1527_AD,_stoneware_-_Linden-Museum_-_Stuttgart,_Germany_-_DSC03608.jpg)より。</sub>

macOS用の軽量ブラウザ。既定タブは WebKit(Safari と同じエンジン)で動くので起動時から軽く、広告も内蔵の
`WKContentRuleList` で遮断します。Chrome拡張機能が要るサイトだけ、そのタブを実物の Chromium 系ブラウザ
(既定は [Helium](https://github.com/imputnet/helium)) に渡します — WebKit 上で拡張を再現しようとはしません。

## なぜこの形か

「Chrome拡張が全部動く」「広告を遮断する」「とにかく軽い」の3つを1つのエンジンで同時に満たす製品は
存在しません(調査結果: [`docs/prior-art-research-2026-09-19.txt`](docs/prior-art-research-2026-09-19.txt))。

- 拡張を自前実装で再現する路線([Kagi Orion](https://orionbrowser.com/))は、6人・6年かけても公式値で
  Chrome拡張API対応率は約70%どまり。
- Chromium系(Brave/Helium等)は広告遮断も拡張対応もできるが、素性がChromiumである以上、軽さの下限は
  Chromium基準から逃れられない。

Idatenは「1つのエンジンで全部」を諦め、**タブ単位でエンジンを使い分けます**。普段のブラウジングは
WebKitの軽さのまま、拡張が要る1〜2サイトだけ実物のChromiumへ切り替えます。

## 実測(2026-09-20時点)

同一4タブ(広告の多いニュースサイト2件+Wikipedia)を専用プロファイルで開いて比較:

| | プロセス数 | 合計メモリ(圧縮込み) |
|---|---|---|
| Chrome | 25 | 1,513.8 MB |
| Helium(Idatenが渡す先) | 11 | 461.2 MB |

差の主因は広告・計測用の第三者iframeが1つずつ独立レンダラープロセスになること(Chromiumのsite isolation)。
広告遮断はメモリ消費だけでなく、そもそものプロセス数を減らします。

計測は `tools/footprint/` の `footprint-cli`(`ri_phys_footprint` ベース)を使用。Apple標準の
`/usr/bin/footprint` と29プロセスで照合し、合計差0.016%で一致を確認済みです。n=1回の測定のため、
確定的な結論としては扱っていません(詳細: `tasks/todo.md` / `tasks/lessons.md`)。

## 機能

- **タブごとのエンジン切替**(⌘⇧E): 現在のタブをChromium系エンジンで開き直す。ドメイン単位で記憶可能
- **広告遮断**: `WKContentRuleList` による種リスト(38ドメイン)+ `rules/*.json` への拡張の口
- **タブ休眠**: 非アクティブなタブは `WKWebView.interactionState` を退避して破棄。復帰時は戻る/進むの履歴・
  スクロール位置ごと復元。メモリ逼迫時は選択中以外を自動休眠
- **複数プロファイル**: `WKWebsiteDataStore(forIdentifier:)` でCookie・ログイン状態をプロファイルごとに完全分離
  (Chromeの複数アカウント運用と同じ形)。Chromium側の身元もプロファイルごとに別
- **AIによるエンジン提案**(macOS 26+、Apple Intelligence対応機のみ): ページ内容から「拡張機能が要りそう」を
  Appleの端末内モデルで判定し、Chromiumへの切替を提案。通信は発生せず、追加の常駐メモリもほぼ増えない
  (OSが共有する既存モデルを使うため)

## ビルド

```sh
swift build -c release
./make_app.sh --install   # ~/Applications/Idaten.app へ導入
```

Xcodeプロジェクト不要(SwiftPM単体)。Swift 5.9 / macOS 14+。AIエンジン提案機能のみ macOS 26+ が必要
(それ未満では自動的に無効化されます)。

## Chromium系エンジンについて

Idaten自体はGPLコードを含みません。Chromium系エンジン(Helium/Brave/Chrome)は**同梱せず、利用者が別途
インストールした実行ファイルを検出して起動するだけ**です。優先順位や起動フラグは
`~/Library/Application Support/Idaten/engine.json` / `chromium_flags.txt` で変更できます。

## 状態

開発中。運用実績はまだありません。詳細な進捗は [`tasks/todo.md`](tasks/todo.md) を参照してください。

## ライセンス

[MIT](LICENSE)
