#!/usr/bin/env python3
"""Tiny local stand-in for the Traceway `/api/report` endpoint.

It accepts the SDK's gzip-compressed JSON, pretty-prints the decoded body and
the Authorization header, and returns HTTP 200 with `{}` (the success shape the
SDK expects). Use it to verify the iOS SDK end-to-end without a real backend.

Run:    python3 Examples/mock_server.py
Then point the SDK at:  demo-token@http://localhost:8080/api/report
"""

import gzip
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8080


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)

        if self.headers.get("Content-Encoding", "").lower() == "gzip":
            try:
                raw = gzip.decompress(raw)
            except OSError as exc:
                print(f"!! failed to gunzip body: {exc}")

        print("\n=== POST", self.path, "===")
        print("Authorization:", self.headers.get("Authorization"))
        print("Content-Type:", self.headers.get("Content-Type"))
        print("Content-Encoding:", self.headers.get("Content-Encoding"))
        try:
            print(json.dumps(json.loads(raw), indent=2))
        except json.JSONDecodeError:
            print(raw.decode("utf-8", "replace"))

        body = b"{}"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # silence the default access log; we print our own


if __name__ == "__main__":
    print(f"Traceway mock server listening on http://localhost:{PORT}/api/report")
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
