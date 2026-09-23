#!/bin/bash
# Chrome と Idaten のメモリ比較(第2版)。第1版の穴を埋める:
#   - 観測点を 60秒 / 5分 / 15分 にし、瞬間値でなく**区間の中央値とピーク**を取る(1秒間隔で全期間採取)
#   - 動画タブを含める(ローカル配信の固定mp4。YouTube は配信内容が毎回変わるので対照にしない)
#   - タブ数の水準を変えられる(既定12。SCENARIO=heavy で60)
#   - AB/BA を交互にする(順序効果を相殺。奇数回は Chrome→Idaten、偶数回は Idaten→Chrome)
#   - どちらも新品プロファイル。Idaten も専用のデータストア・セッション・履歴を使う(--bench-isolated)
#   - 実行のたびに条件と生データを残す。集計は生データから作り直せる
#
# 使い方: tools/bench/bench2.sh [組数] [読み込み待ち秒]
#   例: tools/bench/bench2.sh 10 45     # 10組(= Chrome 10回 + Idaten 10回)
set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FP="$ROOT/tools/footprint/.build/release/footprint-cli"
OUT_DIR="${BENCH_OUT:-$ROOT/measurements/bench2-$(date +%Y%m%d-%H%M%S)}"
PAIRS="${1:-10}"
LOAD_WAIT="${2:-45}"
DURATION="${DURATION:-330}"          # 1回あたりの採取時間(秒)。観測点は60s/300s。900s を見たいときは長くする
CONDITIONS="${CONDITIONS:-chrome idaten chrome_ext}"   # chrome_ext = Chrome に同じ休眠拡張を入れた条件
SCENARIO="${SCENARIO:-normal}"
VIDEO_PORT="${VIDEO_PORT:-8899}"
mkdir -p "$OUT_DIR"

URLS_FILE="$ROOT/tools/bench/urls.txt"
[ "$SCENARIO" = "heavy" ] && URLS_FILE="$ROOT/tools/bench/urls_heavy.txt"
URLS=()
while IFS= read -r line; do URLS+=("$line"); done < <(grep -vE '^[[:space:]]*(#|$)' "$URLS_FILE")

# 動画は手元で配信する。同じファイル・同じ自動再生・同じループで、両ブラウザに同じ負荷をかける
VIDEO_DIR="$ROOT/tools/bench/video"
VIDEO_URL="http://127.0.0.1:$VIDEO_PORT/video.html"
start_video_server() {
  [ -f "$VIDEO_DIR/sample.mp4" ] || { echo "動画が無い: $VIDEO_DIR/sample.mp4 (tools/bench/make_video.sh で作る)"; return 1; }
  (cd "$VIDEO_DIR" && nohup python3 -m http.server "$VIDEO_PORT" --bind 127.0.0.1 > "$OUT_DIR/video-server.log" 2>&1 &)
  sleep 1
  curl -fsS "$VIDEO_URL" -o /dev/null || { echo "動画サーバが立たない"; return 1; }
}
stop_video_server() { pkill -f "http.server $VIDEO_PORT" || true; }

{
  echo "日時: $(date '+%F %T')"
  echo "シナリオ: $SCENARIO / URL ${#URLS[@]} 件 + 動画1 / 組数 $PAIRS / 読み込み待ち ${LOAD_WAIT}s"
  echo "観測点: 60s(直前30秒の中央値) / 300s / 900s、全期間1秒間隔"
  echo "機械: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '不明') / $(( $(sysctl -n hw.memsize) / 1073741824 ))GB / macOS $(sw_vers -productVersion)"
  echo "Chrome: $(defaults read '/Applications/Google Chrome.app/Contents/Info.plist' CFBundleShortVersionString 2>/dev/null || echo '不明')"
  for app in "Google Chrome" Helium Idaten; do
    pgrep -x "$app" > /dev/null && echo "注意: $app が既に動いている(機械全体の負荷を共有する)"
  done
} | tee "$OUT_DIR/conditions.txt"

# 1秒間隔で 16 分採取し、観測点ごとに「直前30秒の中央値」と「全期間のピーク」を出す
sample_and_summarize() {   # $1 root pid, $2 出力名
  "$FP" --pid "$1" --interval 1 --duration "$DURATION" --csv "$OUT_DIR/$2.csv" > "$OUT_DIR/$2.log" 2>&1
  python3 "$ROOT/tools/bench/summarize.py" "$OUT_DIR/$2.csv" "$2" >> "$OUT_DIR/summary.tsv"
}

# Chrome の省メモリ機能(Memory Saver)のタイマーは 2〜6時間なので、15分以内の計測では発動しない
# (Codex 調査 docs/one-browser/codex_chrome_conditions.md)。結果は変わらない見込みだが、条件として明示しておく。
# state 2=ON / 0=OFF、aggressiveness 2=Maximum
write_memory_saver_prefs() {   # $1 profile, $2 state
  mkdir -p "$1/Default"
  python3 "$ROOT/tools/bench/write_chrome_prefs.py" "$1" "$2"
}

run_chrome() {   # $1 組番号
  local prof="$OUT_DIR/chrome-profile-$1"
  rm -rf "$prof"; mkdir -p "$prof"
  write_memory_saver_prefs "$prof" 2
  # 起動方法を chrome_ext 条件と揃える(片方だけ open、片方だけ CDP だと条件が違う)。
  # 起動器はページの状態(読み込み完了数・動画の再生)も記録する
  node "$ROOT/tools/bench/run_chrome.mjs" "$prof" "$((DURATION + 30))" - \
    "${URLS[@]}" "$VIDEO_URL" > "$OUT_DIR/chrome-run-$1.json" 2>&1 &
  local runner=$!
  sleep "$LOAD_WAIT"
  local pid
  pid=$(python3 -c "import json; print(json.loads(open('$OUT_DIR/chrome-run-$1.json').read().splitlines()[0])['pid'])") || {
    echo "chrome pid なし(組 $1)" | tee -a "$OUT_DIR/errors.txt"; kill "$runner" || true; return 1; }
  sample_and_summarize "$pid" "chrome-$1"
  wait "$runner" || true
  sleep 8
}

# Chrome に Idaten と同じ休眠規則(拡張)を入れた条件。これが「同じ方針どうし」の比較になる。
# Chrome 137 以降 --load-extension は使えないので、CDP の Extensions.loadUnpacked で入れる
run_chrome_ext() {   # $1 組番号
  local prof="$OUT_DIR/chromeext-profile-$1"
  rm -rf "$prof"; mkdir -p "$prof"
  write_memory_saver_prefs "$prof" 2
  # Extensions.loadUnpacked で入れた拡張は**その起動の間しか残らない**(実測 2026-09-23:
  # 準備してから開き直すと拡張のターゲットが消えていた)。同じプロセスの中で「入れる→開く→測り終わるまで生かす」
  node "$ROOT/tools/bench/run_chrome.mjs" "$prof" "$((DURATION + 30))" "$ROOT/extension" \
    "${URLS[@]}" "$VIDEO_URL" > "$OUT_DIR/chromeext-run-$1.json" 2>&1 &
  local runner=$!
  sleep "$LOAD_WAIT"
  if ! grep -q '"workerAlive":true' "$OUT_DIR/chromeext-run-$1.json"; then
    echo "拡張が動いていない(組 $1) — この条件は中止" | tee -a "$OUT_DIR/errors.txt"
    kill "$runner" || true
    return 1
  fi
  local pid
  pid=$(python3 -c "import json; print(json.loads(open('$OUT_DIR/chromeext-run-$1.json').read().splitlines()[0])['pid'])") || {
    echo "chrome_ext pid なし(組 $1)" | tee -a "$OUT_DIR/errors.txt"; kill "$runner" || true; return 1; }
  sample_and_summarize "$pid" "chromeext-$1"
  wait "$runner" || true      # 起動器が自分で閉じる(最後に残ったページ数を記録する)
  sleep 8
}

run_idaten() {   # $1 組番号
  local dir="$OUT_DIR/idaten-$1"
  mkdir -p "$dir"
  # --bench-isolated: セッション・履歴・ブックマーク・Cookie を専用の空ディレクトリに置く(Chrome の新品プロファイルと揃える)
  open -g -n -a "$ROOT/build/Idaten.app" --args --bench-isolated "$dir" "${URLS[@]}" "$VIDEO_URL"
  sleep "$LOAD_WAIT"
  local pid; pid=$(pgrep -f "Idaten.app/Contents/MacOS/Idaten --bench-isolated" | head -1)
  [ -n "$pid" ] || { echo "idaten pid なし(組 $1)" | tee -a "$OUT_DIR/errors.txt"; return 1; }
  sample_and_summarize "$pid" "idaten-$1"
  kill "$pid" || true
  sleep 8
}

start_video_server || exit 1
trap stop_video_server EXIT

printf 'name\tpoint\tmedian_mib\tpeak_mib\tprocs_median\tsamples\n' > "$OUT_DIR/summary.tsv"
for i in $(seq 1 "$PAIRS"); do
  echo "=== 組 $i/$PAIRS ($(date +%H:%M))" | tee -a "$OUT_DIR/log.txt"
  # 順序効果を相殺する: 奇数組は指定順、偶数組は逆順
  order="$CONDITIONS"
  if [ $((i % 2)) -eq 0 ]; then order=$(echo "$CONDITIONS" | tr ' ' '\n' | tail -r | tr '\n' ' '); fi
  for cond in $order; do
    case "$cond" in
      chrome) run_chrome "$i" || true ;;
      idaten) run_idaten "$i" || true ;;
      chrome_ext) run_chrome_ext "$i" || true ;;
    esac
  done
done

python3 "$ROOT/tools/bench/report.py" "$OUT_DIR" | tee "$OUT_DIR/report.md"
echo "出力: $OUT_DIR"
