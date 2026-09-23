#!/bin/bash
# Chrome と Idaten を同じ条件で比べる。数字を製品の売りに使う以上、測り方の穴を潰しておく:
#   - 同じURL集合・同じ順序・同じ待ち時間
#   - どちらも新品のプロファイル(拡張なし・ログインなし・キャッシュ空)
#   - 起動は `open -n -a` (端末から直接起動すると responsible pid が端末になり、WebKit の子プロセスを取りこぼす)
#   - 反復(既定3回)。1回の値は報告に使わない
#   - 測るのは ri_phys_footprint(圧縮・スワップ込み。Activity Monitor の「メモリ」と同じ量)
#
# 使い方: tools/bench/bench.sh [反復回数] [読み込み待ち秒] [放置秒]
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FP="$ROOT/tools/footprint/.build/release/footprint-cli"
URLS_FILE="$ROOT/tools/bench/urls.txt"
OUT_DIR="${BENCH_OUT:-$ROOT/measurements/bench-$(date +%Y%m%d-%H%M%S)}"
REPEATS="${1:-3}"
LOAD_WAIT="${2:-45}"     # 全タブの読み込みが落ち着くまで
IDLE_WAIT="${3:-60}"     # 放置してから測る(休眠や省メモリ機能が働く時間を両者に等しく与える)
mkdir -p "$OUT_DIR"

command -v "$FP" > /dev/null || { echo "footprint-cli が無い: cd tools/footprint && swift build -c release"; exit 1; }
[ -f "$URLS_FILE" ] || { echo "URL一覧が無い: $URLS_FILE"; exit 1; }
# macOS の bash 3.2 には mapfile が無い
URLS=()
while IFS= read -r line; do URLS+=("$line"); done < <(grep -vE '^[[:space:]]*(#|$)' "$URLS_FILE")
echo "URL ${#URLS[@]} 件 / 反復 $REPEATS 回 / 読み込み待ち ${LOAD_WAIT}s / 放置 ${IDLE_WAIT}s" | tee "$OUT_DIR/conditions.txt"

# 測る対象以外のブラウザが動いていると結果がぶれる。動いていたら止めずに知らせるだけにする(本人のものを勝手に閉じない)
for app in "Google Chrome" Helium Idaten; do
  if pgrep -x "$app" > /dev/null; then echo "注意: $app が既に動いている。結果がぶれる可能性がある" | tee -a "$OUT_DIR/conditions.txt"; fi
done

measure() {   # $1 ラベル, $2 root pid, $3 出力名
  "$FP" --pid "$2" --once > "$OUT_DIR/$3.txt" 2>&1
  # footprint-cli の最終行: TOTAL <MB> MB procs=<n>
  local line procs mb
  line=$(grep '^TOTAL' "$OUT_DIR/$3.txt" | tail -1)
  mb=$(echo "$line" | awk '{print $2}')
  procs=$(echo "$line" | sed -n 's/.*procs=\([0-9]*\).*/\1/p')
  echo "$1 procs=$procs mb=$mb"
}

run_chrome() {   # $1 回数
  local prof="$OUT_DIR/chrome-profile-$1"
  rm -rf "$prof"; mkdir -p "$prof"
  open -g -n -a "Google Chrome" --args --user-data-dir="$prof" --no-first-run --no-default-browser-check "${URLS[@]}"
  sleep "$LOAD_WAIT"
  local pid; pid=$(pgrep -f "user-data-dir=$prof" | head -1)
  [ -n "$pid" ] || { echo "Chrome の pid が取れない"; return 1; }
  measure "chrome-load-$1" "$pid" "chrome-load-$1"
  sleep "$IDLE_WAIT"
  measure "chrome-idle-$1" "$pid" "chrome-idle-$1"
  kill "$pid" 2> /dev/null
  sleep 5
}

run_idaten() {   # $1 回数
  local dir="$OUT_DIR/idaten-$1"
  mkdir -p "$dir"
  # --bench: 利用者のセッション・履歴・ブックマークを読み書きしないモード(自己検査と同じ扱い)
  open -g -n -a "$ROOT/build/Idaten.app" --args --bench "$dir" "${URLS[@]}"
  sleep "$LOAD_WAIT"
  local pid; pid=$(pgrep -f "Idaten.app/Contents/MacOS/Idaten --bench" | head -1)
  [ -n "$pid" ] || { echo "Idaten の pid が取れない"; return 1; }
  measure "idaten-load-$1" "$pid" "idaten-load-$1"
  sleep "$IDLE_WAIT"
  measure "idaten-idle-$1" "$pid" "idaten-idle-$1"
  kill "$pid" 2> /dev/null
  sleep 5
}

for i in $(seq 1 "$REPEATS"); do
  echo "--- 回 $i" | tee -a "$OUT_DIR/log.txt"
  run_chrome "$i" | tee -a "$OUT_DIR/log.txt"
  run_idaten "$i" | tee -a "$OUT_DIR/log.txt"
done

echo "出力: $OUT_DIR"
