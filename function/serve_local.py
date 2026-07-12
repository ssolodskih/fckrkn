"""HTTP wrapper around handler.handler.

Serves the relay over plain HTTP so it can run outside a Cloud Function - both
for local testing and inside a Serverless Container.

    # local test
    ALLOW_ALL=1 PORT=8080 uv run function/serve_local.py
    # container (see function/Dockerfile)
    HOST=0.0.0.0 PORT=8080 python serve_local.py

Then point the client at http://HOST:PORT. Threaded so a held `exchange`
long-poll does not block concurrent calls (mirrors YC --concurrency>1).
"""

import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import handler as fn


class _H(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode()
        resp = fn.handler(
            {"body": body, "isBase64Encoded": False, "httpMethod": "POST"}, None
        )
        data = resp["body"].encode()
        self.send_response(resp["statusCode"])
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002 - matches stdlib signature
        pass


if __name__ == "__main__":
    host = os.environ.get("HOST", "127.0.0.1")
    port = int(os.environ.get("PORT", "8080"))
    print(
        f"yacfsocks relay serving on http://{host}:{port}  (ALLOW_ALL={fn.ALLOW_ALL})"
    )
    ThreadingHTTPServer((host, port), _H).serve_forever()
