codex
**現状は有効な完全ペアが4組です。10組は妥当な次の目標ですが、統計上の必須数ではありません。** 現在のばらつきなら1 GiB程度の平均差を検出するには余裕があり、512 MiBの差まで検出したいなら不足する見積もりです。ただし、反復を増やしても測定条件の偏りは解消しません。

対象ファイルと保存結果を読み取りました。ベンチ・集計スクリプト・以下の提案コードは実行していません。数値は保存済みTSVからの概算です。

**1. 必要な組数**

第2版の完全ペアは1〜4。5はChromeのみで除外します。無効だった `chromeext`、動画なし・瞬間測定だった第1版も混ぜません。根拠：[summary.tsv:2](/Users/yu01/idaten-browser/measurements/bench2-20260923-124156/summary.tsv:2)、[第1版の条件:4](/Users/yu01/idaten-browser/measurements/2026-09-23-chrome-vs-idaten.md:4)。

\(d_j=C_j-I_j\) とすると：

| 観測点 | ペア差 MiB：組1／2／3／4 | 差の平均 | 差の中央値 | 差の標本SD |
|---|---|---:|---:|---:|
| 60s | 5351.5／5373.9／5794.2／5533.9 | 5513.4 | 5453.9 | 約204 |
| 300s | 5729.3／4986.0／5566.8／6486.4 | 5692.1 | 5648.1 | 約618 |

実験単位は**組**です。30秒内の約30サンプルや、同一組の60s／300sを独立反復として数えてはいけません。

計画案は、**300sを主要評価点、両側α＝0.05、検出力80%または90%、最小検出差δ＝1024 MiB**。60sは副次評価点とします。δは「今回見えた約5.6 GiB」ではなく、「これだけ違えば実用上意味がある」という基準で置きます。これは提案であり、事前に決められていた条件ではありません。

対応のある平均差に対する計画式は：

\[
s_d=\sqrt{\frac{\sum(d_j-\bar d)^2}{n-1}},\qquad
n\approx (z_{1-\alpha/2}+z_{1-\beta})^2(s_d/\delta)^2
\]

小標本では過小評価しやすいため、下表は \(z_{1-\alpha/2}\) を \(t_{1-\alpha/2,n-1}\) に置き換え、式を満たす組数を探した**近似値**です。非心t分布による厳密な検出力計算ではありません。[NIST：対応比較](https://www.itl.nist.gov/div898/handbook/prc/section3/prc311.htm)、[NIST：必要標本数](https://www.itl.nist.gov/div898/handbook/prc/section2/prc222.htm)。

| 検出したい平均差δ | 検出力80% | 検出力90% |
|---|---:|---:|
| 1024 MiB | 約5組 | 約6組 |
| 512 MiB | 約14組 | 約17組 |

- **10組**：1 GiB差の検出目的なら妥当。AB／BAを5組ずつにできる。
- **6組**：同じばらつきが続く前提なら、1 GiB差の検出には足りる見積もり。ただしSDの推定元が4組なので不確か。
- **512 MiB差まで狙う場合**：順序を均等にするなら約14組／18組が目安。
- SDが現在の2倍なら、1 GiB差に必要な組数も表の512 MiB行相当になります。

片側なら \(z_{1-\alpha/2}\) を \(z_{1-\alpha}\) に替え、方向は \(C-I>0\)。ただし、**今回の結果を見てから片側へ変更して有意とするのは避け、次の確認実験で事前指定**してください。60sと300sの「どちらか有意」を採用するなら、多重性への対応も必要です。

また、これは**平均差の検出力**です。中央値の推論は別です。4組すべて同方向でも、正確な符号検定のp値は両側0.125、片側0.0625。全組同方向の場合、両側5%を下回る最小数は6組ですが、これは「検出力が十分」という意味ではありません。

**2. 比の中央値と、ペア差の信頼区間**

`report.py` は正しくペアを対応させ、

\[
\operatorname{median}_j(C_j/I_j)
\]

を出しています。「各ブラウザの中央値どうしの比」ではありません。差も既に \(\operatorname{median}_j(C_j-I_j)\) を出しています。ただし、**最小〜最大は信頼区間ではありません**。[report.py:23](/Users/yu01/idaten-browser/tools/bench/report.py:23)、[report.py:35](/Users/yu01/idaten-browser/tools/bench/report.py:35)。

比の中央値は、**今回の条件に限定した記述統計として使用可**。300sでは約12.40です。「Chrome／Idatenのメモリフットプリント比」と方向・指標を明記し、「12.4倍軽い」は避けます。

主指標をペア差の中央値にするなら、次のように**組を再標本化**します。以下は提案コードで、未実行です。

```python
import numpy as np
from scipy.stats import bootstrap

# 同一観測点について、完全ペアを同じ順序で並べる
c = np.array([6209.8, 5487.6, 6078.4, 6997.4])
i = np.array([480.5, 501.6, 511.6, 511.0])
d = c - i

result = bootstrap(
    (d,), np.median,
    confidence_level=0.95,
    n_resamples=100_000,
    method="percentile",
    rng=np.random.default_rng(20260923),
)
print(np.median(d), result.confidence_interval)
```

ChromeとIdatenを別々に再標本化してはいけません。比のCIも同じ組から作った `c / i` を再標本化します。[SciPy公式：bootstrap](https://docs.scipy.org/doc/scipy/reference/generated/scipy.stats.bootstrap.html)。

**ただし4組のbootstrap CIは、公開主張を強く裏付ける95%区間として扱いません。** 小標本で裾の情報が乏しく、再標本化回数を増やしても解決しません。独立・連続分布を仮定した分布によらない中央値区間でも、4組の `[最小差, 最大差]` の被覆率は

\[
1-2(1/2)^4=87.5\%
\]

にすぎません。

符号順位法のCIを使う場合も注意が必要です。通常のWilcoxonに対応する推定値は、差の単純中央値ではなく、

\[
\widehat\theta_{\rm HL}
=\operatorname{median}_{j\le k}\frac{d_j+d_k}{2}
\]

というHodges–Lehmann推定値です。差の分布の対称性などの前提を明示し、「中央値のCI」と無条件に呼ばないでください。[R公式：wilcox.test](https://www.stat.ethz.ch/R-manual/R-devel/library/stats/html/wilcox.test.html)。

**3. 直前30秒の中央値とピーク**

直前30秒の中央値は、GCや短いスパイクに左右されにくい**その時間帯の典型値**として適切です。ただし定常状態の証明ではなく、時間方向の増減や短時間の負荷を隠します。

実装上、次を明記・改善すべきです。

- 60sは**採取開始から60秒**。起動後45秒待って採取するので、起動からはおよそ105秒です。300sもおよそ345秒。[bench2.sh:70](/Users/yu01/idaten-browser/tools/bench/bench2.sh:70)
- 窓は `at - 30 <= t <= at`。現状は窓内に1点でもあれば出力するため、途中終了でも不完全な窓を採用できます。到達時刻・窓の時間的な充足・有効サンプル数の判定が必要です。[summarize.py:23](/Users/yu01/idaten-browser/tools/bench/summarize.py:23)
- 採取処理後に1秒sleepするので、厳密な1 Hzではありません。現在の有効ペアでは窓内28〜30点です。[採取実装:147](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift:147)

ピークは**測定区間内で観測した最大値**。瞬間的な容量要求、読み込みバースト、異常な増加を調べる補助指標に使えます。比較する場合は採取時間・間隔を揃え、各組のピーク差を別に集計します。

使ってはいけないのは、「普段の使用量」「起動を含む真の最大値」「必要RAM容量の上限」の代用です。最初の45秒と採取間隔内の山は見逃します。また現在の `peak_mib` は**全採取期間の同じ最大値を各観測点へ転載**しています。「60秒までのピーク」ではありません。[summarize.py:21](/Users/yu01/idaten-browser/tools/bench/summarize.py:21)。

**4. 主張文の可否**

以下はすべて、保存済み第2版の完全4ペアに基づきます。

言ってよい文：

1. 「このM1 Pro・16GB環境で、12ページと動画ページ1件を開く手順では、60秒・300秒の両観測点で、4組すべてIdatenのメモリフットプリントが小さかった。」
2. 「採取開始300秒の直前30秒中央値をペアで比較すると、Chrome−Idatenの差の中央値は約5,648 MiB、約5.52 GiBだった。」
3. 「同じ観測点で、各組のChrome／Idatenのメモリフットプリント比の中央値は約12.40だった。別の機械・ページ構成での比率は未検証。」

条件：[conditions.txt:2](/Users/yu01/idaten-browser/measurements/bench2-20260923-124156/conditions.txt:2)。数値：[summary.tsv:2](/Users/yu01/idaten-browser/measurements/bench2-20260923-124156/summary.tsv:2)。

言ってはいけない文：

1. 「IdatenはChromeより12倍軽い。」  
   指標・条件・比の方向が曖昧で、速度やCPUまで含む一般的優位に読める。
2. 「同じ作業で常に約6GB少なく、機能も性能も同じ。」  
   同じURLを渡したことと、同じページ状態・再生・操作性能を実現したことは別。約5,648 MiBは約5.92 GBですが、**“同じ作業”の同等性は未確認**です。
3. 「同じ休眠方式でもIdatenが12倍省メモリで、エンジンの優位性が証明された。」  
   有効な拡張条件の結果がなく、休眠・広告遮断などの寄与も分離できていません。[拡張条件の修正理由:86](/Users/yu01/idaten-browser/tools/bench/bench2.sh:86)

**5. 結果をひっくり返しうる穴の優先順**

**現データだけでは、どの要因が逆転を起こすかは断定できません。** 以下の順位は、影響経路と現状の対策からの推測です。

| 優先 | 穴 | 評価と必要な確認 |
|---|---|---|
| 1 | 機械全体の負荷・メモリ圧力 | 非対称なタブ破棄、読み込み遅延、プロセス終了を起こせば比較を大きく変え得る。各runのメモリ圧力、swap、CPU負荷、タブ状態を記録する。 |
| 2 | 本人のChromeの同時稼働 | 上記の具体的な負荷源で、実際に稼働が記録されている。本人の操作が時刻と偏ればペア化だけでは除去できない。専用セッションで再確認する。 |
| 3 | キャッシュ・動的コンテンツ | 新品プロファイル化でブラウザ内キャッシュの非対称性は軽減。ただしOS／ネットワーク側のキャッシュ、広告や配信内容、ページ読み込み成否は未統制。読み込み失敗などで実際の仕事量が違えば逆転も否定できない。 |
| 4 | 順序 | AB／BA交互で単純な順序効果は軽減。現4組も各2組。ただし無作為化ではなく、経時変化や持ち越しを完全には除去しない。今後は順序を均衡化して無作為割付する。 |

根拠：本人のChrome稼働は[conditions.txt:6](/Users/yu01/idaten-browser/measurements/bench2-20260923-124156/conditions.txt:6)、新品プロファイルと順序は[bench2.sh:67](/Users/yu01/idaten-browser/tools/bench/bench2.sh:67)・[bench2.sh:105](/Users/yu01/idaten-browser/tools/bench/bench2.sh:105)・[bench2.sh:124](/Users/yu01/idaten-browser/tools/bench/bench2.sh:124)。負荷共有と誤合算は別問題で、採取対象はPIDの親子・responsible関係で決まります。[採取対象の実装:74](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift:74)。

さらに、**「同じ作業」という主張には、この4項目より先に実際のページ状態を確認する必要があります。** 動画HTMLは自動再生を指定するだけで、再生成功の記録がありません。またIdatenの測定起動は本人の広告遮断設定を継承します。[video.html:3](/Users/yu01/idaten-browser/tools/bench/video/video.html:3)、[main.swift:83](/Users/yu01/idaten-browser/Sources/Idaten/main.swift:83)。Chrome公式も動画再生などをMemory Saverの非休眠条件として挙げており、状態の違いは比較条件に影響します。[Google公式](https://support.google.com/chrome/answer/12929150?hl=en)。

現在の差が大きいことは明確ですが、**10組への追加より先に「両者が何を表示・再生・休眠していたか」を確認する方が、主張の信頼性を大きく改善します。**
tokens used
50,118
**現状は有効な完全ペアが4組です。10組は妥当な次の目標ですが、統計上の必須数ではありません。** 現在のばらつきなら1 GiB程度の平均差を検出するには余裕があり、512 MiBの差まで検出したいなら不足する見積もりです。ただし、反復を増やしても測定条件の偏りは解消しません。

対象ファイルと保存結果を読み取りました。ベンチ・集計スクリプト・以下の提案コードは実行していません。数値は保存済みTSVからの概算です。

**1. 必要な組数**

第2版の完全ペアは1〜4。5はChromeのみで除外します。無効だった `chromeext`、動画なし・瞬間測定だった第1版も混ぜません。根拠：[summary.tsv:2](/Users/yu01/idaten-browser/measurements/bench2-20260923-124156/summary.tsv:2)、[第1版の条件:4](/Users/yu01/idaten-browser/measurements/2026-09-23-chrome-vs-idaten.md:4)。

\(d_j=C_j-I_j\) とすると：

| 観測点 | ペア差 MiB：組1／2／3／4 | 差の平均 | 差の中央値 | 差の標本SD |
|---|---|---:|---:|---:|
| 60s | 5351.5／5373.9／5794.2／5533.9 | 5513.4 | 5453.9 | 約204 |
| 300s | 5729.3／4986.0／5566.8／6486.4 | 5692.1 | 5648.1 | 約618 |

実験単位は**組**です。30秒内の約30サンプルや、同一組の60s／300sを独立反復として数えてはいけません。

計画案は、**300sを主要評価点、両側α＝0.05、検出力80%または90%、最小検出差δ＝1024 MiB**。60sは副次評価点とします。δは「今回見えた約5.6 GiB」ではなく、「これだけ違えば実用上意味がある」という基準で置きます。これは提案であり、事前に決められていた条件ではありません。

対応のある平均差に対する計画式は：

\[
s_d=\sqrt{\frac{\sum(d_j-\bar d)^2}{n-1}},\qquad
n\approx (z_{1-\alpha/2}+z_{1-\beta})^2(s_d/\delta)^2
\]

小標本では過小評価しやすいため、下表は \(z_{1-\alpha/2}\) を \(t_{1-\alpha/2,n-1}\) に置き換え、式を満たす組数を探した**近似値**です。非心t分布による厳密な検出力計算ではありません。[NIST：対応比較](https://www.itl.nist.gov/div898/handbook/prc/section3/prc311.htm)、[NIST：必要標本数](https://www.itl.nist.gov/div898/handbook/prc/section2/prc222.htm)。

| 検出したい平均差δ | 検出力80% | 検出力90% |
|---|---:|---:|
| 1024 MiB | 約5組 | 約6組 |
| 512 MiB | 約14組 | 約17組 |

- **10組**：1 GiB差の検出目的なら妥当。AB／BAを5組ずつにできる。
- **6組**：同じばらつきが続く前提なら、1 GiB差の検出には足りる見積もり。ただしSDの推定元が4組なので不確か。
- **512 MiB差まで狙う場合**：順序を均等にするなら約14組／18組が目安。
- SDが現在の2倍なら、1 GiB差に必要な組数も表の512 MiB行相当になります。

片側なら \(z_{1-\alpha/2}\) を \(z_{1-\alpha}\) に替え、方向は \(C-I>0\)。ただし、**今回の結果を見てから片側へ変更して有意とするのは避け、次の確認実験で事前指定**してください。60sと300sの「どちらか有意」を採用するなら、多重性への対応も必要です。

また、これは**平均差の検出力**です。中央値の推論は別です。4組すべて同方向でも、正確な符号検定のp値は両側0.125、片側0.0625。全組同方向の場合、両側5%を下回る最小数は6組ですが、これは「検出力が十分」という意味ではありません。

**2. 比の中央値と、ペア差の信頼区間**

`report.py` は正しくペアを対応させ、

\[
\operatorname{median}_j(C_j/I_j)
\]

を出しています。「各ブラウザの中央値どうしの比」ではありません。差も既に \(\operatorname{median}_j(C_j-I_j)\) を出しています。ただし、**最小〜最大は信頼区間ではありません**。[report.py:23](/Users/yu01/idaten-browser/tools/bench/report.py:23)、[report.py:35](/Users/yu01/idaten-browser/tools/bench/report.py:35)。

比の中央値は、**今回の条件に限定した記述統計として使用可**。300sでは約12.40です。「Chrome／Idatenのメモリフットプリント比」と方向・指標を明記し、「12.4倍軽い」は避けます。

主指標をペア差の中央値にするなら、次のように**組を再標本化**します。以下は提案コードで、未実行です。

```python
import numpy as np
from scipy.stats import bootstrap

# 同一観測点について、完全ペアを同じ順序で並べる
c = np.array([6209.8, 5487.6, 6078.4, 6997.4])
i = np.array([480.5, 501.6, 511.6, 511.0])
d = c - i

result = bootstrap(
    (d,), np.median,
    confidence_level=0.95,
    n_resamples=100_000,
    method="percentile",
    rng=np.random.default_rng(20260923),
)
print(np.median(d), result.confidence_interval)
```

ChromeとIdatenを別々に再標本化してはいけません。比のCIも同じ組から作った `c / i` を再標本化します。[SciPy公式：bootstrap](https://docs.scipy.org/doc/scipy/reference/generated/scipy.stats.bootstrap.html)。

**ただし4組のbootstrap CIは、公開主張を強く裏付ける95%区間として扱いません。** 小標本で裾の情報が乏しく、再標本化回数を増やしても解決しません。独立・連続分布を仮定した分布によらない中央値区間でも、4組の `[最小差, 最大差]` の被覆率は

\[
1-2(1/2)^4=87.5\%
\]

にすぎません。

符号順位法のCIを使う場合も注意が必要です。通常のWilcoxonに対応する推定値は、差の単純中央値ではなく、

\[
\widehat\theta_{\rm HL}
=\operatorname{median}_{j\le k}\frac{d_j+d_k}{2}
\]

というHodges–Lehmann推定値です。差の分布の対称性などの前提を明示し、「中央値のCI」と無条件に呼ばないでください。[R公式：wilcox.test](https://www.stat.ethz.ch/R-manual/R-devel/library/stats/html/wilcox.test.html)。

**3. 直前30秒の中央値とピーク**

直前30秒の中央値は、GCや短いスパイクに左右されにくい**その時間帯の典型値**として適切です。ただし定常状態の証明ではなく、時間方向の増減や短時間の負荷を隠します。

実装上、次を明記・改善すべきです。

- 60sは**採取開始から60秒**。起動後45秒待って採取するので、起動からはおよそ105秒です。300sもおよそ345秒。[bench2.sh:70](/Users/yu01/idaten-browser/tools/bench/bench2.sh:70)
- 窓は `at - 30 <= t <= at`。現状は窓内に1点でもあれば出力するため、途中終了でも不完全な窓を採用できます。到達時刻・窓の時間的な充足・有効サンプル数の判定が必要です。[summarize.py:23](/Users/yu01/idaten-browser/tools/bench/summarize.py:23)
- 採取処理後に1秒sleepするので、厳密な1 Hzではありません。現在の有効ペアでは窓内28〜30点です。[採取実装:147](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift:147)

ピークは**測定区間内で観測した最大値**。瞬間的な容量要求、読み込みバースト、異常な増加を調べる補助指標に使えます。比較する場合は採取時間・間隔を揃え、各組のピーク差を別に集計します。

使ってはいけないのは、「普段の使用量」「起動を含む真の最大値」「必要RAM容量の上限」の代用です。最初の45秒と採取間隔内の山は見逃します。また現在の `peak_mib` は**全採取期間の同じ最大値を各観測点へ転載**しています。「60秒までのピーク」ではありません。[summarize.py:21](/Users/yu01/idaten-browser/tools/bench/summarize.py:21)。

**4. 主張文の可否**

以下はすべて、保存済み第2版の完全4ペアに基づきます。

言ってよい文：

1. 「このM1 Pro・16GB環境で、12ページと動画ページ1件を開く手順では、60秒・300秒の両観測点で、4組すべてIdatenのメモリフットプリントが小さかった。」
2. 「採取開始300秒の直前30秒中央値をペアで比較すると、Chrome−Idatenの差の中央値は約5,648 MiB、約5.52 GiBだった。」
3. 「同じ観測点で、各組のChrome／Idatenのメモリフットプリント比の中央値は約12.40だった。別の機械・ページ構成での比率は未検証。」

条件：[conditions.txt:2](/Users/yu01/idaten-browser/measurements/bench2-20260923-124156/conditions.txt:2)。数値：[summary.tsv:2](/Users/yu01/idaten-browser/measurements/bench2-20260923-124156/summary.tsv:2)。

言ってはいけない文：

1. 「IdatenはChromeより12倍軽い。」  
   指標・条件・比の方向が曖昧で、速度やCPUまで含む一般的優位に読める。
2. 「同じ作業で常に約6GB少なく、機能も性能も同じ。」  
   同じURLを渡したことと、同じページ状態・再生・操作性能を実現したことは別。約5,648 MiBは約5.92 GBですが、**“同じ作業”の同等性は未確認**です。
3. 「同じ休眠方式でもIdatenが12倍省メモリで、エンジンの優位性が証明された。」  
   有効な拡張条件の結果がなく、休眠・広告遮断などの寄与も分離できていません。[拡張条件の修正理由:86](/Users/yu01/idaten-browser/tools/bench/bench2.sh:86)

**5. 結果をひっくり返しうる穴の優先順**

**現データだけでは、どの要因が逆転を起こすかは断定できません。** 以下の順位は、影響経路と現状の対策からの推測です。

| 優先 | 穴 | 評価と必要な確認 |
|---|---|---|
| 1 | 機械全体の負荷・メモリ圧力 | 非対称なタブ破棄、読み込み遅延、プロセス終了を起こせば比較を大きく変え得る。各runのメモリ圧力、swap、CPU負荷、タブ状態を記録する。 |
| 2 | 本人のChromeの同時稼働 | 上記の具体的な負荷源で、実際に稼働が記録されている。本人の操作が時刻と偏ればペア化だけでは除去できない。専用セッションで再確認する。 |
| 3 | キャッシュ・動的コンテンツ | 新品プロファイル化でブラウザ内キャッシュの非対称性は軽減。ただしOS／ネットワーク側のキャッシュ、広告や配信内容、ページ読み込み成否は未統制。読み込み失敗などで実際の仕事量が違えば逆転も否定できない。 |
| 4 | 順序 | AB／BA交互で単純な順序効果は軽減。現4組も各2組。ただし無作為化ではなく、経時変化や持ち越しを完全には除去しない。今後は順序を均衡化して無作為割付する。 |

根拠：本人のChrome稼働は[conditions.txt:6](/Users/yu01/idaten-browser/measurements/bench2-20260923-124156/conditions.txt:6)、新品プロファイルと順序は[bench2.sh:67](/Users/yu01/idaten-browser/tools/bench/bench2.sh:67)・[bench2.sh:105](/Users/yu01/idaten-browser/tools/bench/bench2.sh:105)・[bench2.sh:124](/Users/yu01/idaten-browser/tools/bench/bench2.sh:124)。負荷共有と誤合算は別問題で、採取対象はPIDの親子・responsible関係で決まります。[採取対象の実装:74](/Users/yu01/idaten-browser/tools/footprint/Sources/footprint-cli/main.swift:74)。

さらに、**「同じ作業」という主張には、この4項目より先に実際のページ状態を確認する必要があります。** 動画HTMLは自動再生を指定するだけで、再生成功の記録がありません。またIdatenの測定起動は本人の広告遮断設定を継承します。[video.html:3](/Users/yu01/idaten-browser/tools/bench/video/video.html:3)、[main.swift:83](/Users/yu01/idaten-browser/Sources/Idaten/main.swift:83)。Chrome公式も動画再生などをMemory Saverの非休眠条件として挙げており、状態の違いは比較条件に影響します。[Google公式](https://support.google.com/chrome/answer/12929150?hl=en)。

現在の差が大きいことは明確ですが、**10組への追加より先に「両者が何を表示・再生・休眠していたか」を確認する方が、主張の信頼性を大きく改善します。**
