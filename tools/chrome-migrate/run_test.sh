#!/bin/bash
# m4 で実行。本物のキーチェーンには触れない(--use-mock-keychain)。自分の起動物だけを止める
set -u
T=$HOME/chrome-migrate-test
APP=${APP:-$HOME/idaten-test/signed/Idaten.app}
PORT=18765
LOG=$T/server.log
cd $T
rm -rf $T/p-* $LOG

python3 $T/testserver.py $PORT $LOG > $T/server.out 2>&1 &
SRV=$!
sleep 1

launch() { # $1=profile dir, $2..=urls
  local d=$1; shift
  mkdir -p "$d"
  open -n -g -a "$APP" --args --user-data-dir="$d" --use-mock-keychain --no-first-run --no-default-browser-check \
     "--host-resolver-rules=MAP *.idaten.test 127.0.0.1" "$@"
}
mainpid() { pgrep -f "MacOS/Idaten --user-data-dir=$1 " | head -1; }
stop() { # 自分の起動物だけ TERM して終わるまで待つ
  local d=$1 pid=""
  for i in $(seq 1 20); do pid=$(mainpid "$d"); [ -n "$pid" ] && break; sleep 0.5; done
  [ -z "$pid" ] && { echo "  (no process for $d)"; return; }
  kill -TERM $pid
  for i in $(seq 1 40); do ps -p $pid > /dev/null || { echo "  stopped pid=$pid"; return; }; sleep 0.5; done
  echo "  pid=$pid still alive"
}
count_rows() { sqlite3 "$1/Default/Cookies" "select count(*) || ' | ' || ifnull(group_concat(host_key||':'||name||':'||substr(encrypted_value,1,3)||':persist='||is_persistent, ' '),'') from cookies" 2>&1; }

echo "== 1. 元プロファイル A に Cookie を配る"
launch $T/p-A "http://app.idaten.test:$PORT/set" "http://localhost:$PORT/secset"
sleep 6; stop $T/p-A
echo "  A rows: $(count_rows $T/p-A)"

for P in B C D E; do
  echo "== 2. 空の先プロファイル $P を一度起動して閉じる"
  launch $T/p-$P about:blank; sleep 5; stop $T/p-$P
  echo "  $P rows: $(count_rows $T/p-$P)"
done

echo "== 3. 移す"
echo "-- B: 正しい鍵(mock→mock)"
python3 $T/chrome_migrate.py --src $T/p-A/Default --dst $T/p-B/Default --src-key mock --dst-key mock 2>&1
echo "-- C: 負の対照 先の鍵を違うものにする"
printf 'wrong_password' > $T/wrong.key
python3 $T/chrome_migrate.py --src $T/p-A/Default --dst $T/p-C/Default --src-key mock --dst-key file:$T/wrong.key 2>&1
echo "-- D: 負の対照 ドメインハッシュを付けない"
python3 $T/chrome_migrate.py --src $T/p-A/Default --dst $T/p-D/Default --src-key mock --dst-key mock --skip-hash 2>&1
echo "-- E: 対照 何も移さない"
for P in B C D E; do echo "  $P rows: $(count_rows $T/p-$P)"; done

echo "== 4. 先で同じサイトを開く(サーバログで Cookie ヘッダを見る)"
for P in B C D E; do
  echo "marker: open $P" >> $LOG
  launch $T/p-$P "http://app.idaten.test:$PORT/check-$P-app" "http://www.idaten.test:$PORT/check-$P-www" "http://localhost:$PORT/check-$P-local"
  sleep 6; stop $T/p-$P
done

kill $SRV
echo "== server.log"
cat $LOG
