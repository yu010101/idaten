#!/bin/bash
# 鍵が違う2者の間でも運べるか: A(mock) → X(鍵K2) → F(mock)。X は中継用の DB(ブラウザでは開かない)
# run_test.sh の後に実行する(p-A を使う)
set -u
T=$HOME/chrome-migrate-test
APP=${APP:-$HOME/idaten-test/signed/Idaten.app}
PORT=18765
LOG=$T/server2.log
cd $T
rm -rf $T/p-X $T/p-F $LOG
python3 $T/testserver.py $PORT $LOG > $T/server2.out 2>&1 &
SRV=$!
sleep 1
launch() { local d=$1; shift; mkdir -p "$d"
  open -n -g -a "$APP" --args --user-data-dir="$d" --use-mock-keychain --no-first-run --no-default-browser-check \
     "--host-resolver-rules=MAP *.idaten.test 127.0.0.1" "$@"; }
mainpid() { pgrep -f "MacOS/Idaten --user-data-dir=$1 " | head -1; }
stop() { local d=$1 pid=""
  for i in $(seq 1 20); do pid=$(mainpid "$d"); [ -n "$pid" ] && break; sleep 0.5; done
  [ -z "$pid" ] && { echo "  (no process for $d)"; return; }
  kill -TERM $pid
  for i in $(seq 1 40); do ps -p $pid > /dev/null || { echo "  stopped pid=$pid"; return; }; sleep 0.5; done
  echo "  pid=$pid still alive"; }

launch $T/p-F about:blank; sleep 5; stop $T/p-F
# X は空の v24 DB の複製(ブラウザが作ったものを流用。自分でスキーマは作らない)
mkdir -p $T/p-X/Default; cp $T/p-F/Default/Cookies $T/p-X/Default/Cookies
python3 -c 'import secrets;open("'$T'/k2.key","w").write(secrets.token_urlsafe(16))'
echo "-- A(mock) -> X(K2)"
python3 $T/chrome_migrate.py --src $T/p-A/Default --dst $T/p-X/Default --src-key mock --dst-key file:$T/k2.key 2>&1
echo "-- X を mock 鍵で読むと失敗するはず(dry-run)"
python3 $T/chrome_migrate.py --src $T/p-X/Default --dst $T/p-F/Default --src-key mock --dst-key mock --dry-run 2>&1
echo "-- X(K2) -> F(mock)"
python3 $T/chrome_migrate.py --src $T/p-X/Default --dst $T/p-F/Default --src-key file:$T/k2.key --dst-key mock 2>&1
echo "marker: open F" >> $LOG
launch $T/p-F "http://app.idaten.test:$PORT/check-F-app" "http://www.idaten.test:$PORT/check-F-www"
sleep 6; stop $T/p-F
kill $SRV
cat $LOG
