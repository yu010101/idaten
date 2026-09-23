#!/bin/bash
# 比較用の動画を作る。YouTube を使わないのは、配信される広告・解像度・コーデックが毎回変わり、
# 「同じ負荷」にならないため(過去の計測で動画によって優劣が入れ替わった記録がある)。
# 手元で固定の mp4 を作り、127.0.0.1 から配信して両ブラウザに同じものを再生させる。
set -eu -o pipefail
cd "$(dirname "$0")/video"
if [ ! -f sample.mp4 ]; then
  # 60秒・1280x720・30fps・H.264。テスト映像と音を合成する(外部から落とさない)
  ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=60" \
    -f lavfi -i "sine=frequency=440:duration=60" \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -shortest sample.mp4
fi
cat > video.html <<'HTML'
<!doctype html><meta charset="utf-8"><title>bench video</title>
<style>html,body{margin:0;background:#000}video{width:100vw;height:100vh;object-fit:contain}</style>
<video src="sample.mp4" autoplay loop muted playsinline></video>
HTML
ls -la sample.mp4 video.html
