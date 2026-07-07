"""Local HTTP wrapper around handler.handler for testing without deploying.

    ALLOW_ALL=1 PORT=8080 python serve_local.py

Then point the client at http://127.0.0.1:8080. Threaded so a held `down`
long-poll does not block concurrent `up` calls (mirrors YC --concurrency>1).
"""

import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import handler as fn


class _H(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode()
        resp = fn.handler({"body": body, "isBase64Encoded": False, "httpMethod": "POST"}, None)
        data = resp["body"].encode()
        self.send_response(resp["statusCode"])
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    print(f"yacfsocks function serving on http://127.0.0.1:{port}  (ALLOW_ALL={fn.ALLOW_ALL})")
    ThreadingHTTPServer(("127.0.0.1", port), _H).serve_forever()
