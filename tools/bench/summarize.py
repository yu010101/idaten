#!/usr/bin/env python3
"""footprint-cli の CSV から、観測点ごとの「直前30秒の中央値」と全期間のピークを出す。

瞬間値1点だと、採取の瞬間に GC やタブの読み込みが重なっただけで数字が動く。
観測点(60秒・5分・15分)の直前30秒を中央値でまとめ、別に全期間のピークも残す。
使い方: summarize.py <csv> <名前>   → TSV 1行/観測点 を標準出力へ
"""
import csv, statistics, sys

POINTS = [("60s", 60), ("300s", 300), ("900s", 900)]
MIB = 1024 * 1024

def main(path: str, name: str) -> None:
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            rows.append((float(r["t_sec"]), int(r["nprocs"]), int(r["footprint_bytes"])))
    if not rows:
        print(f"{name}\t-\t-\t-\t-\t0")
        return
    peak = max(fp for _, _, fp in rows) / MIB
    for label, at in POINTS:
        window = [(n, fp) for t, n, fp in rows if at - 30 <= t <= at]
        if not window:
            continue
        median_mib = statistics.median(fp for _, fp in window) / MIB
        procs = statistics.median(n for n, _ in window)
        print(f"{name}\t{label}\t{median_mib:.1f}\t{peak:.1f}\t{procs:.0f}\t{len(window)}")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
