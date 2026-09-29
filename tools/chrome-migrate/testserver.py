#!/usr/bin/env python3
"""試験用サーバ。/set で Cookie を配り、全リクエストの Cookie ヘッダをログに書く(値は試験用のダミー)"""
import http.server, sys, time, secrets
LOG = sys.argv[2]
SID = "S-" + secrets.token_hex(6)
DOM = "D-" + secrets.token_hex(6)


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        host = self.headers.get("Host", "")
        ck = self.headers.get("Cookie", "")
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} host={host} path={self.path} cookie=[{ck}]\n")
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        if self.path.startswith("/set"):
            self.send_header("Set-Cookie", f"sid={SID}; Max-Age=86400; Path=/; HttpOnly; SameSite=Lax")
            self.send_header("Set-Cookie", f"dom={DOM}; Domain=idaten.test; Max-Age=86400; Path=/")
            self.send_header("Set-Cookie", "sess=only-session; Path=/")
        if self.path.startswith("/secset"):
            self.send_header("Set-Cookie", f"secnone=N-{SID}; Max-Age=86400; Path=/; Secure; SameSite=None")
            self.send_header("Set-Cookie", f"__Host-h=H-{SID}; Max-Age=86400; Path=/; Secure")
        self.end_headers()
        self.wfile.write(b"<title>ok</title>ok")

    def log_message(self, *a):
        pass


with open(LOG, "a") as f:
    f.write(f"server start issued sid={SID} dom={DOM}\n")
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
