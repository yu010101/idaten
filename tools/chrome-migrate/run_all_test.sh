#!/bin/bash
# m4 で実行。mock キーチェーンだけを使う。本物のキーチェーン・本人のデータには触れない。
# 元 user-data-dir に複数プロファイル(Default, Profile 2, Profile 3)を作り、一括で移す。
set -u
T=$HOME/chrome-migrate-test
APP=${APP:-$HOME/idaten-test/signed/Idaten.app}
PORT=18777
SRC=$T/src-uddir      # 元(擬似 Chrome)
DST=$T/dst-uddir      # 先(Idaten)
LOG=$T/all.log
cd $T
rm -rf $SRC $DST $LOG $T/dst-uddir.* ; mkdir -p $SRC $DST

python3 $T/server_multi.py $PORT $LOG > $T/all.out 2>&1 &
SRV=$!; sleep 1

launch() { # $1=user-data-dir $2=profile-dir $3..=urls
  local ud=$1 pd=$2; shift 2
  open -n -g -a "$APP" --args --user-data-dir="$ud" --profile-directory="$pd" \
    --use-mock-keychain --no-first-run --no-default-browser-check \
    "--host-resolver-rules=MAP *.idaten.test 127.0.0.1" "$@"
}
mainpid() { pgrep -f "MacOS/Idaten --user-data-dir=$1 " | head -1; }
stop() { local ud=$1 pid=""
  for i in $(seq 1 20); do pid=$(mainpid "$ud"); [ -n "$pid" ] && break; sleep 0.5; done
  [ -z "$pid" ] && { echo "  (no proc $ud)"; return; }
  kill -TERM $pid
  for i in $(seq 1 40); do ps -p $pid > /dev/null || { echo "  stopped $pid"; return; }; sleep 0.5; done
  echo "  $pid still alive"; }

echo "== 1. 元に 3 プロファイルを作り、それぞれ別の Cookie を配る"
for pd in "Default" "Profile 2" "Profile 3"; do
  tag=$(echo "$pd" | tr -d ' ')
  launch "$SRC" "$pd" "http://app.idaten.test:$PORT/set?tag=$tag"
  sleep 5; stop "$SRC"
done
echo "-- 元 Local State info_cache:"
python3 -c 'import json;print(json.dumps(json.load(open("'"$SRC"'/Local State"))["profile"]["info_cache"],ensure_ascii=False))' 2>&1
for pd in "Default" "Profile 2" "Profile 3"; do
  echo "   $pd Cookies: $(sqlite3 "$SRC/$pd/Cookies" 'select group_concat(name) from cookies' 2>&1)"
done

echo "== 2. 先(Idaten)を一度起動して閉じる(Default と Local State を作る)"
launch "$DST" "Default" about:blank; sleep 5; stop "$DST"

echo "== 3. dry-run(件数だけ)"
python3 $T/migrate_all.py --chrome-root "$SRC" --idaten-root "$DST" \
  --src-key mock --dst-key mock --all --no-default-skip --dry-run 2>&1

echo "== 4. 本番: 全プロファイルを一括で移す"
python3 $T/migrate_all.py --chrome-root "$SRC" --idaten-root "$DST" \
  --src-key mock --dst-key mock --all --no-default-skip 2>&1

echo "== 5. 先 Local State info_cache(移した後):"
python3 -c 'import json;print(json.dumps(json.load(open("'"$DST"'/Local State"))["profile"]["info_cache"],ensure_ascii=False,indent=1))' 2>&1

echo "== 6. 移した各プロファイルの Cookies を mock 鍵で読み戻し(ground truth):"
for pd in "chrome-Default" "chrome-Profile 2" "chrome-Profile 3"; do
  echo "   $pd: $(sqlite3 "$DST/$pd/Cookies" 'select group_concat(name) from cookies' 2>&1)"
done

echo "== 7. 移した各プロファイルを起動して Cookie がサーバに届くか(空白入りの名前も安全に)"
echo "marker: verify" >> $LOG
# 元プロファイルに対応する先 dir だけを NUL 区切りで取り出す(空白で割れないように)
python3 -c '
import json
m=json.load(open("'"$T"'/dst-uddir/migrate_map.json"))
src=json.load(open("'"$SRC"'/Local State"))["profile"]["info_cache"]
for k,v in m.items():
    if k in src: print(v)
' | while IFS= read -r pd; do
  echo "  -- open profile-dir=$pd"
  launch "$DST" "$pd" "http://app.idaten.test:$PORT/check?who=$(echo "$pd" | tr ' ' '_')"
  sleep 5; stop "$DST"
done

kill $SRV
echo "== all.log"
cat $LOG
