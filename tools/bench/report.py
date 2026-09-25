#!/usr/bin/env python3
"""bench2 の summary.tsv から報告用の表を作る。

中央値どうしを引き算しただけの「○倍」は、ばらつきが分からないので誤解を生む。
組ごとの差(同じ組の Chrome と Idaten)を並べ、その中央値と範囲も出す。
"""
import collections, random, statistics, sys, pathlib

def bootstrap_median_ci(diffs, n_resamples=20000, level=0.95, seed=20260923):
    """ペア差の中央値の区間。**組ごと**に再標本化する(Chrome と Idaten を別々に混ぜない)。

    小さい組数では区間が広く、被覆率も理屈どおりにならない。4組なら [最小, 最大] でも 87.5% しかない。
    """
    if len(diffs) < 2:
        return (float("nan"), float("nan"))
    rng = random.Random(seed)
    medians = []
    for _ in range(n_resamples):
        sample = [diffs[rng.randrange(len(diffs))] for _ in diffs]
        medians.append(statistics.median(sample))
    medians.sort()
    lo = medians[int((1 - level) / 2 * n_resamples)]
    hi = medians[int((1 + level) / 2 * n_resamples) - 1]
    return (lo, hi)


def main(out_dir: str) -> None:
    path = pathlib.Path(out_dir) / "summary.tsv"
    rows = [l.rstrip("\n").split("\t") for l in path.read_text().splitlines()[1:] if l.strip()]
    data = collections.defaultdict(dict)   # (browser, pair) -> {point: (median, peak, procs)}
    for name, point, median, peak, procs, n in rows:
        browser, pair = name.rsplit("-", 1)
        data[(browser, pair)][point] = (float(median), float(peak), float(procs))

    print(f"# 比較結果 ({out_dir})\n")
    print((pathlib.Path(out_dir) / "conditions.txt").read_text())
    for point in ("60s", "300s", "900s"):
        pairs = sorted({p for (_, p) in data})
        diffs, chrome_vals, idaten_vals = [], [], []
        for p in pairs:
            c = data.get(("chrome", p), {}).get(point)
            i = data.get(("idaten", p), {}).get(point)
            if not c or not i:
                continue
            chrome_vals.append(c[0]); idaten_vals.append(i[0]); diffs.append(c[0] - i[0])
        ext_vals = [data[("chromeext", p)][point][0] for p in pairs
                    if ("chromeext", p) in data and point in data[("chromeext", p)]]
        if not diffs:
            continue
        print(f"\n## 観測点 {point}(直前30秒の中央値) — {len(diffs)} 組")
        print("| | 中央値 MiB | 最小 | 最大 |")
        print("|---|---|---|---|")
        rows = [("Chrome", chrome_vals), ("Idaten", idaten_vals), ("差(Chrome − Idaten)", diffs)]
        fork_vals = [data[("forkext", p)][point][0] for p in pairs
                     if ("forkext", p) in data and point in data[("forkext", p)]]
        if ext_vals:
            rows.insert(2, ("Chrome + 同じ休眠拡張", ext_vals))
        if fork_vals:
            rows.insert(2, ("フォーク版 Idaten + 同じ休眠拡張", fork_vals))
        for label, vals in rows:
            print(f"| {label} | {statistics.median(vals):.0f} | {min(vals):.0f} | {max(vals):.0f} |")
        ratios = [c / i for c, i in zip(chrome_vals, idaten_vals) if i > 0]
        print(f"\n比(Chrome ÷ Idaten): 中央値 {statistics.median(ratios):.2f}"
              f"(最小 {min(ratios):.2f}・最大 {max(ratios):.2f})")
        lo, hi = bootstrap_median_ci(diffs)
        print(f"ペア差の中央値の95%区間(組を再標本化): {lo:.0f} 〜 {hi:.0f} MiB")
        if len(diffs) < 6:
            print(f"※ {len(diffs)}組では区間の信頼性は低い。公開の主張には使わない(Codex 2026-09-23)")

if __name__ == "__main__":
    main(sys.argv[1])
