#!/usr/bin/env python3
"""計測用の動画配信。Range(バイト範囲指定)に 206 で答える。

python3 -m http.server は Range に対応せず常に 200 で全体を返す。WebKit(AVFoundation)は
HTTP の mp4 再生に範囲指定を使うので、それが無いと再生しない可能性がある(09-26 の調査。未検証)。
Chrome/フォーク版にも同じサーバを使うので、条件は揃ったまま。

使い方: python3 range_server.py <port>   (カレントディレクトリを配信する)
"""
import http.server
import os
import re
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        self.range_left = None
        self._partial = False
        rng = self.headers.get("Range")
        path = self.translate_path(self.path)
        if not rng or not os.path.isfile(path):
            return super().send_head()
        m = re.fullmatch(r"bytes=(\d*)-(\d*)", rng.strip())
        size = os.path.getsize(path)
        if not m or (m.group(1) == "" and m.group(2) == ""):
            self.send_error(416)
            return None
        if m.group(1) == "":  # bytes=-N(末尾 N バイト)
            start, end = max(0, size - int(m.group(2))), size - 1
        else:
            start = int(m.group(1))
            end = int(m.group(2)) if m.group(2) else size - 1
        end = min(end, size - 1)
        if start > end:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.end_headers()
            return None
        f = open(path, "rb")
        f.seek(start)
        self._partial = True
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        self.range_left = end - start + 1
        return f

    def end_headers(self):
        # 全体を返すとき(200)も範囲指定に対応していると伝える。206 は send_head で付け済み
        if not getattr(self, "_partial", False):
            self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def copyfile(self, source, outputfile):
        left = getattr(self, "range_left", None)
        if left is None:
            return super().copyfile(source, outputfile)
        while left > 0:
            chunk = source.read(min(65536, left))
            if not chunk:
                break
            outputfile.write(chunk)
            left -= len(chunk)


if __name__ == "__main__":
    port = int(sys.argv[1])
    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
