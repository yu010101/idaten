#!/bin/zsh
# Karu.app を作る。SwiftPM の実行ファイルを .app に包み、ad-hoc 署名する(型は ~/aiboard/make_app.sh と同じ)。
# 既定では build/Karu.app まで。--install を付けたときだけ ~/Applications へ置く。
set -eu
cd "$(dirname "$0")"
mkdir -p build
# ビルドが失敗したら、そこで止める(古い実行ファイルを包まない)
if ! swift build -c release > build/build.log 2>&1; then
  echo "ビルド失敗。.app は作り直していない: build/build.log" >&2
  grep -E "error:" build/build.log >&2 || true
  exit 1
fi
APP=build/Karu.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Karu "$APP/Contents/MacOS/Karu"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" > build/codesign.log 2>&1
echo "built: $APP ($(du -sh "$APP" | cut -f1))"
if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  DEST="$HOME/Applications/Karu.app"
  [ -d "$DEST" ] && rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "installed: $DEST"
fi
