#!/usr/bin/env python3
"""計測の生データから CPU 時間を集計する。

メモリだけ見て「軽い」と言うと、裏で CPU を食っていた場合に嘘になる。
footprint-cli の CSV には `cpu_nanos`(一族の CPU 時間の累計)が入っているので、
観測区間の増分から「その間に使った CPU 秒」を出す。

使い方: cpu_report.py <計測ディレクトリ>
"""
import collections, csv, pathlib, statistics, sys


def cpu_seconds(path: pathlib.Path, start: float, end: float) -> float | None:
    """[start, end] の区間で増えた CPU 時間(秒)。プロセスが途中で消えると累計が減るので、増分だけ足す。"""
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            rows.append((float(r["t_sec"]), int(r["cpu_nanos"])))
    window = [(t, c) for t, c in rows if start <= t <= end]
    if len(window) < 2:
        return None
    total = 0
    for (_, a), (_, b) in zip(window, window[1:]):
        if b >= a:                      # 減っていたら「プロセスが終わった」ので数えない
            total += b - a
    return total / 1e9


def main(out_dir: str) -> None:
    d = pathlib.Path(out_dir)
    per_browser = collections.defaultdict(list)
    for csv_path in sorted(d.glob("*.csv")):
        name = csv_path.stem                   # 例: chrome-3 / idaten-3 / chromeext-3
        browser = name.rsplit("-", 1)[0]
        # 採取は「起動して URL を渡し、読み込み待ちが終わった後」に始まる。
        # なので最初の行の累計値が「起動から読み込みまでに使った CPU」に相当する
        with open(csv_path) as f:
            first = next(csv.DictReader(f), None)
        startup = int(first["cpu_nanos"]) / 1e9 if first else None
        early = cpu_seconds(csv_path, 0, 60)     # 採取開始〜60秒
        idle = cpu_seconds(csv_path, 60, 300)    # 60〜300秒(放置)
        if early is None or idle is None or startup is None:
            continue
        per_browser[browser].append((startup, early, idle))

    print(f"# CPU 時間 ({out_dir})\n")
    print("| | 起動〜読み込み完了までの累計 | 採取開始〜60秒 | 60〜300秒(放置) | 回数 |")
    print("|---|---|---|---|---|")
    for browser, vals in sorted(per_browser.items()):
        s0 = [v[0] for v in vals]; s1 = [v[1] for v in vals]; s2 = [v[2] for v in vals]
        print(f"| {browser} | {statistics.median(s0):.1f} 秒 | {statistics.median(s1):.1f} 秒 "
              f"| {statistics.median(s2):.1f} 秒 | {len(vals)} |")
    print("\n放置中の CPU は「開いたまま置いておくと何を食うか」を表す。"
          "メモリが少なくても放置で CPU を回していれば、電池と発熱の面では軽くない。")


if __name__ == "__main__":
    main(sys.argv[1])
