#!/usr/bin/env python3
"""試験用サーバ。/set?tag=XX でタグ入りの Cookie を配る。全リクエストの Cookie ヘッダをログに書く。"""
import http.server, sys, time
from urllib.parse import urlparse, parse_qs
LOG = sys.argv[2]


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        tag = (q.get("tag") or ["x"])[0]
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} host={self.headers.get('Host','')} "
                    f"path={self.path} cookie=[{self.headers.get('Cookie','')}]\n")
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        if u.path == "/set":
            self.send_header("Set-Cookie", f"sid_{tag}=V-{tag}-{int(time.time())}; Max-Age=86400; Path=/; HttpOnly")
            self.send_header("Set-Cookie", f"dom_{tag}=D-{tag}; Domain=idaten.test; Max-Age=86400; Path=/")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
