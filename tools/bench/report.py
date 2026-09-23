#!/usr/bin/env python3
"""bench2 の summary.tsv から報告用の表を作る。

中央値どうしを引き算しただけの「○倍」は、ばらつきが分からないので誤解を生む。
組ごとの差(同じ組の Chrome と Idaten)を並べ、その中央値と範囲も出す。
"""
import collections, statistics, sys, pathlib

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
        if ext_vals:
            rows.insert(2, ("Chrome + 同じ休眠拡張", ext_vals))
        for label, vals in rows:
            print(f"| {label} | {statistics.median(vals):.0f} | {min(vals):.0f} | {max(vals):.0f} |")
        ratios = [c / i for c, i in zip(chrome_vals, idaten_vals) if i > 0]
        print(f"\n比: 中央値 {statistics.median(ratios):.2f} 倍(最小 {min(ratios):.2f}・最大 {max(ratios):.2f})")

if __name__ == "__main__":
    main(sys.argv[1])
