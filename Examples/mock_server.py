#!/usr/bin/env python3
"""A local stand-in for a Traceway server, for trying the iOS SDK 2.x.

It answers the endpoints the SDK talks to and prints what arrives:

- POST /api/otel/v1/opamp    OpAMP polls (protobuf). With --config it serves
                             that settings document as the remote config,
                             the way a Data Collection rule would.
- POST /api/otel/v1/logs     OTLP logs (gzip protobuf): exceptions, messages,
- POST /api/otel/v1/traces   OTLP spans    session events, breadcrumbs.
                             Decoded with `protoc --decode_raw` when protoc
                             is installed, otherwise only sized.
- POST /api/recordings       wireframe replay segments (gzip JSON, rrweb).
                             --save DIR writes each upload there.

Run:   python3 Examples/mock_server.py [--config settings.json] [--save out/]
Then:  Traceway.start(connectionString: "demo-token@http://localhost:8080")
"""

import argparse
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8080


def varint(value):
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def field(number, payload):
    """A length-delimited protobuf field."""
    return varint(number << 3 | 2) + varint(len(payload)) + payload


def server_to_agent(config_body):
    """A ServerToAgent with the settings document under config_map["traceway"]
    and a 60 s heartbeat; just the heartbeat without a document."""
    heartbeat = field(4, field(2, varint(4 << 3) + varint(60)))
    if config_body is None:
        return heartbeat
    config_file = field(1, config_body) + field(2, b"application/json")
    entry = field(1, b"traceway") + field(2, config_file)
    remote = field(1, field(1, entry)) + field(2, hashlib.sha256(config_body).digest())
    return field(3, remote) + heartbeat


class Handler(BaseHTTPRequestHandler):
    config_body = None
    save_dir = None

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        if self.headers.get("Content-Encoding", "").lower() == "gzip":
            try:
                raw = gzip.decompress(raw)
            except OSError as exc:
                print(f"!! failed to gunzip body: {exc}")

        auth = self.headers.get("Authorization")
        if self.path == "/api/otel/v1/opamp":
            uid = self.headers.get("OpAMP-Instance-UID")
            print(f"--- OpAMP poll from {uid} ({len(raw)} bytes, {auth})")
            self.reply(server_to_agent(self.config_body), "application/x-protobuf")
        elif self.path in ("/api/otel/v1/logs", "/api/otel/v1/traces"):
            print(f"=== {self.path} ({len(raw)} bytes, {auth})")
            self.print_protobuf(raw)
            self.reply(b"", "application/x-protobuf")
        elif self.path == "/api/recordings":
            body = json.loads(raw or b"{}")
            for segment in body.get("segments", []):
                events = segment.get("events", [])
                print(
                    f"=== recording: {len(events)} rrweb events, "
                    f"exceptionId={segment.get('exceptionId')} "
                    f"sessionId={segment.get('sessionId')} "
                    f"segmentIndex={segment.get('segmentIndex')}"
                )
            if self.save_dir:
                name = os.path.join(self.save_dir, f"recording-{int(time.time() * 1000)}.json")
                with open(name, "w") as out:
                    json.dump(body, out)
                print(f"    saved to {name}")
            self.reply(b"{}", "application/json")
        else:
            print(f"=== {self.path} ({len(raw)} bytes): not a 2.x endpoint")
            self.reply(b"{}", "application/json", status=404)

    def print_protobuf(self, raw):
        if not raw or not shutil.which("protoc"):
            return
        decoded = subprocess.run(
            ["protoc", "--decode_raw"], input=raw, capture_output=True
        ).stdout.decode("utf-8", "replace")
        print(decoded[:4000] + ("\n..." if len(decoded) > 4000 else ""))

    def reply(self, body, content_type, status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # we print our own


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", help="settings document to serve over OpAMP")
    parser.add_argument("--save", help="directory to write recording uploads to")
    parser.add_argument("--port", type=int, default=PORT)
    args = parser.parse_args()
    if args.config:
        with open(args.config, "rb") as source:
            Handler.config_body = source.read()
        json.loads(Handler.config_body)  # fail early on invalid JSON
    if args.save:
        os.makedirs(args.save, exist_ok=True)
        Handler.save_dir = args.save
    print(f"Traceway mock server on http://localhost:{args.port}")
    HTTPServer(("0.0.0.0", args.port), Handler).serve_forever()
