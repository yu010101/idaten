#!/bin/bash
# 同じ試作版 Idaten(WebKit タブ入り)で「全部 Chromium タブ」と「全部 WebKit タブ」のメモリを交互に測る。
# 既存の起動器 run_chrome.mjs(EXTRA_FLAGS / WEBKIT_TABS / NEUTRAL_HIB)と footprint-cli・summarize.py を再利用する。
# 休眠拡張は止める(タブが眠ると比較にならない)。m4 で実行する想定(本人の Mac の画面を使わない)。
#
# 使い方: tools/bench/wk_vs_cr.sh <出力ディレクトリ> [組数]
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT=$1; PAIRS=${2:-3}; mkdir -p "$OUT"
BIN="${BIN:-$HOME/idaten-test/poc/Idaten.app/Contents/MacOS/Idaten}"
FP=tools/footprint/.build/release/footprint-cli
DURATION=${DURATION:-330}
NODE="${NODE:-/opt/homebrew/bin/node}"
URLS=$(grep -vE '^[[:space:]]*(#|$)' tools/bench/urls.txt | tr '\n' ' ')
printf 'name\tpoint\tmedian_mib\tpeak_mib\tprocs_median\tsamples\n' > "$OUT/summary.tsv"

run() {  # $1 名前 $2 WEBKIT_TABS(0/1)
  local prof="$OUT/$1-prof"; rm -rf "$prof"
  BROWSER_BIN="$BIN" EXTRA_FLAGS=--enable-idaten-webkit-tab WEBKIT_TABS=$2 NEUTRAL_HIB=1 \
    "$NODE" tools/bench/run_chrome.mjs "$prof" $((DURATION + 30)) - $URLS > "$OUT/$1-run.json" 2> "$OUT/$1-run.err" &
  local r=$!; sleep 45
  local pid
  pid=$(python3 -c "import json;print(json.loads(open('$OUT/$1-run.json').read().splitlines()[0])['pid'])") || {
    echo "no pid $1" >> "$OUT/errors.txt"; kill "$r"; return; }
  echo "$1 WebContent=$(pgrep -f com.apple.WebKit.WebContent | wc -l | tr -d ' ')" >> "$OUT/procs.txt"
  "$FP" --pid "$pid" --interval 1 --duration "$DURATION" --csv "$OUT/$1.csv" > "$OUT/$1.log" 2>&1
  python3 tools/bench/summarize.py "$OUT/$1.csv" "$1" >> "$OUT/summary.tsv"
  wait "$r"; sleep 8
}

for i in $(seq 1 "$PAIRS"); do
  # 順序効果を相殺する: 奇数組は Chromium→WebKit、偶数組は逆
  if [ $((i % 2)) -eq 1 ]; then run "chromium-$i" 0; run "webkit-$i" 1; else run "webkit-$i" 1; run "chromium-$i" 0; fi
  echo "組 $i 終了 $(date +%H:%M)" >> "$OUT/log.txt"
done
echo done > "$OUT/DONE"
