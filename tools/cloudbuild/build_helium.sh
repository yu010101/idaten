#!/bin/bash
# クラウドMac(Scaleway Apple silicon 等)で helium-macos を1回通すための手順。
# 借りている間は最低24時間の課金なので、無人で走らせ、落ちても再実行で続きから進められるようにしてある。
#
# 使い方:
#   scp build_helium.sh <mac>: && ssh <mac> 'nohup bash build_helium.sh > run.out 2>&1 &'
#   進み具合:  ssh <mac> 'tail -f helium-build/run.jsonl'
# 環境変数: WORK(作業場所) / HELIUM_REF(タグやコミット。既定 main) / BUDGET_HOURS(既定 22。過ぎたら次の段に入らない)
#
# 設計(Codexレビュー 2026-09-22 の指摘を反映):
#  - 段は必ず `set -e` の子シェルで実行する。途中のコマンドが失敗したら、その段は失敗として扱う
#  - 済み印は「入力(ref・Xcodeの版)」と結び付け、入力が変わったら作り直す
#  - 失敗した試行も run.jsonl に残す(何時間使って落ちたかが分からないと、時間の見積もりに使えない)
#  - 対話待ちで止まる箇所(sudo のパスワード・Xcodeのライセンス)は、着手前に検査して早く落とす
set -u -o pipefail

WORK="${WORK:-$HOME/helium-build}"
HELIUM_REF="${HELIUM_REF:-main}"
BUDGET_HOURS="${BUDGET_HOURS:-22}"
mkdir -p "$WORK"
LOG="$WORK/build.log"
JSONL="$WORK/run.jsonl"
STAMP="$WORK/.stamps"
LOCK="$WORK/.lock"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
STARTED=$(date +%s)
DEADLINE=$((STARTED + BUDGET_HOURS * 3600))
mkdir -p "$STAMP"

# 二重起動の防止(同じソースを2つの実行が同時に書き換えると、原因の分からない壊れ方をする)
if ! mkdir "$LOCK" 2> "$WORK/.lock.err"; then
  echo "既に実行中のようです: $LOCK を消してから再実行してください" | tee -a "$LOG"
  exit 3
fi
trap 'rmdir "$LOCK"' EXIT

say() { printf '\n=== [%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }

# 1行1件の記録。成功も失敗もスキップも残す
note() {
  python3 - "$JSONL" "$RUN_ID" "$@" <<'PY'
import json, sys, time
path, run_id, stage, event = sys.argv[1:5]
rec = {"run": run_id, "stage": stage, "event": event, "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
for kv in sys.argv[5:]:
    k, _, v = kv.partition("=")
    rec[k] = v
with open(path, "a") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
PY
}

free_mb() { df -m "$WORK" | awk 'NR==2{print $4}'; }

# 入力が変われば作り直すため、済み印は「段名＋入力の指紋」で持つ
fingerprint() {
  printf '%s|%s|%s' "$HELIUM_REF" "$(xcodebuild -version 2>> "$LOG" | tr '\n' ' ')" "$(sw_vers -buildVersion)" |
    shasum -a 256 | cut -c1-12
}

stage() {
  local name="$1"; shift
  local fp; fp="$(fingerprint)"
  local mark="$STAMP/$name.$fp"
  if [ -f "$mark" ]; then say "skip $name (済)"; note "$name" skip; return 0; fi
  local now; now=$(date +%s)
  if [ "$now" -ge "$DEADLINE" ]; then
    say "時間切れ(BUDGET_HOURS=$BUDGET_HOURS)のため $name に入らない"
    note "$name" skipped_no_time remaining_s=0
    return 9
  fi
  local t0 f0 rc t1 f1
  t0=$now; f0=$(free_mb)
  say "start $name (残り $(((DEADLINE - now) / 60)) 分)"
  note "$name" start free_mb="$f0"
  # 段は必ず set -e の子シェルで動かす。末尾だけ成功して途中の失敗が隠れるのを防ぐ
  ( set -eo pipefail; "$name"_fn ) >> "$LOG" 2>&1
  rc=$?
  t1=$(date +%s); f1=$(free_mb)
  note "$name" $([ $rc -eq 0 ] && echo done || echo failed) rc="$rc" elapsed_s="$((t1 - t0))" \
    used_mb="$((f0 - f1))" free_mb="$f1"
  if [ $rc -ne 0 ]; then
    say "FAILED $name rc=$rc — ログ末尾: $(tail -5 "$LOG" | tr '\n' ' ')"
    return $rc
  fi
  touch "$mark"
  return 0
}

brew_env() { eval "$(/opt/homebrew/bin/brew shellenv)"; }

# --- 段の中身 ------------------------------------------------------------

# 着手前の検査。ここで落ちれば数時間を無駄にしない
preflight_fn() {
  sw_vers
  uname -m
  sysctl -n hw.memsize hw.ncpu
  df -h "$WORK"
  # sudo がパスワードを要求する個体では、無人実行が途中で止まる。先に確かめる
  sudo -n true
  # Xcode 本体が選ばれているか(CLT のままだと Chromium はビルドできない)
  xcode-select -p | grep -q "Xcode"
  xcodebuild -version
  xcrun --show-sdk-version
  xcrun --show-sdk-build-version
  # ライセンス同意と初回コンポーネント導入。未同意だと後続が全部止まる
  sudo -n xcodebuild -license accept
  sudo -n xcodebuild -runFirstLaunch
  # 眠ると無人実行が止まるので、この実行の間は眠らせない
  caffeinate -dimsu -w $$ &
  echo "preflight ok"
}

brew_fn() {
  if command -v /opt/homebrew/bin/brew >> "$LOG" 2>&1; then echo "brew あり"; return 0; fi
  # 取得の失敗を「空のスクリプトを実行して成功」と誤認しないよう、必ずファイルへ落として中身を確かめる
  curl -fsSL -o "$WORK/brew_install.sh" https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
  test -s "$WORK/brew_install.sh"
  NONINTERACTIVE=1 /bin/bash "$WORK/brew_install.sh"
  test -x /opt/homebrew/bin/brew
}

deps_fn() {
  brew_env
  brew install python@3.13 wget coreutils readline quilt git
  command -v greadlink       # dev.sh が使う(coreutils が入った証拠)
  python3.13 -m venv "$WORK/venv"
  "$WORK/venv/bin/python" -m pip install --upgrade pip
  "$WORK/venv/bin/python" -m pip install 'httplib2==0.22.0' requests pillow
  "$WORK/venv/bin/python" -c "import httplib2, requests, PIL; print('python deps ok')"
  # Homebrew の binutils が入っていると Chromium のビルドが壊れる(公式手順の注意)
  if brew list binutils >> "$LOG" 2>&1; then brew unlink binutils; fi
  # Helium の構築資料が要求する Metal Toolchain
  xcodebuild -downloadComponent MetalToolchain
}

clone_fn() {
  brew_env
  cd "$WORK"
  if [ ! -d helium-macos/.git ]; then
    git clone --recurse-submodules https://github.com/imputnet/helium-macos.git
  fi
  cd helium-macos
  git fetch --tags --force
  git checkout "$HELIUM_REF"
  git submodule update --init --recursive
  git rev-parse HEAD
  git submodule status
}

# dev.sh は `$0` を見て自分の場所を決める。別スクリプトから source すると呼び出し元の場所を
# 掴んでしまうので(Codexレビュー #1)、リポジトリを cwd にした `bash -c` の中で読み込む。
# こうすると $0 は "bash" になり、greadlink -f が cwd 基準で解決して正しい位置になる
he() {
  cd "$WORK/helium-macos"
  bash -c "set -eo pipefail; source ./dev.sh; he $1"
}

setup_fn() {
  brew_env
  export PATH="$WORK/venv/bin:$PATH"
  he setup
  test -d "$WORK/helium-macos/build/src/out"
}

build_fn() {
  brew_env
  export PATH="$WORK/venv/bin:$PATH"
  he build
}

# 成果物が本当にできているかを確かめる(一覧に何も出なくても成功にしない)
package_fn() {
  cd "$WORK/helium-macos"
  local app
  app=$(find build -maxdepth 4 -name 'Helium*.app' -print -quit)
  test -n "$app"
  local exe
  exe="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
  test -x "$exe"
  file "$exe"
  lipo -archs "$exe"
  du -sh "$app"
  shasum -a 256 "$exe" | cut -c1-24
  echo "APP=$PWD/$app"
  echo "$PWD/$app" > "$WORK/artifact_path.txt"
}

# --- 実行 ----------------------------------------------------------------

say "開始 run=$RUN_ID work=$WORK ref=$HELIUM_REF 期限=$(date -r "$DEADLINE" '+%H:%M')"
note run start ref="$HELIUM_REF" budget_h="$BUDGET_HOURS" free_mb="$(free_mb)"
rc=0
# `if ! stage ...` の形で呼ぶと、段の中の set -e が無効化される(条件の文脈では errexit が効かず、
# 子シェルにもその抑止が伝わる)。実際に「途中で落ちた段が rc=0・済み印つき」になるのを手元で再現した
# ので、必ず単独のコマンドとして呼び、返り値を別に見る
for s in preflight brew deps clone setup build package; do
  stage "$s"
  rc=$?
  [ $rc -eq 0 ] || break
done
note run finish rc="$rc" total_s="$(($(date +%s) - STARTED))" free_mb="$(free_mb)"
say "終了 rc=$rc 合計 $((($(date +%s) - STARTED) / 60)) 分"
cat "$JSONL"
exit $rc
