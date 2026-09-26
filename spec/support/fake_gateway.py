#!/usr/bin/env python3
"""A stand-in for the AI gateway, for the integration specs.

Serves just enough to drive every branch of the plugin's HTTP layer over a
real socket:

    POST /define            a normal answer
    (every answer echoes X-Request-Id, or mints one when the client sent none)
    GET  /last              the last POST this server saw, to check the wire
    POST /slow/define       sleeps, to trip the client's timeout
    POST /boom/define       500 with an error body
    POST /locked/define     401
    POST /garbage/define    200 that is not JSON
    GET  /stable/version.json   an update manifest one version ahead

    POST /koreader-library/sync       two books, with URLs back into /store
    GET  /store/<name>                the bytes of one of them
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

LAST_REQUEST = {}

# `claimed` is the manifest's size; where it differs from the bytes served, the download arrives truncated.
BOOKS = {
    "Lem/Solaris.epub": {"body": b"SOLARIS" * 10, "claimed": 70},
    "Borges/Ficciones.epub": {"body": b"FICCIONES", "claimed": 9},
    "Broken/Half.epub": {"body": b"only ten!!", "claimed": 4096},
}

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # keep the test output clean
        pass

    def _send(self, status, payload, content_type="application/json"):
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        # Echoed back so the client can be shown reading it off the wire.
        sent = self.headers.get("X-Request-Id")
        self.send_header("X-Request-Id", sent or "gateway-minted")
        self.end_headers()
        self.wfile.write(body)

    def _library(self):
        host = self.headers.get("Host") or "127.0.0.1"
        return {
            "version": 1,
            "generated_at": "2026-09-21T11:00:00.000Z",
            "files": [
                {
                    "path": path,
                    "size": book["claimed"],
                    "etag": "etag-%d" % index,
                    "url": "http://%s/store/%s" % (host, path),
                }
                for index, (path, book) in enumerate(BOOKS.items())
            ],
        }

    def do_GET(self):
        if self.path.startswith("/store/"):
            book = BOOKS.get(self.path[len("/store/"):])
            if book is None:
                self._send(404, {"error": "no such book"})
                return
            self._send(200, book["body"], "application/epub+zip")
            return
        if self.path == "/last":
            self._send(200, LAST_REQUEST)
            return
        if self.path == "/stable/version.json":
            self._send(200, {
                "channel": "stable",
                "packages": {
                    "koreader-aidict": {
                        "version": [9, 9, 9],
                        "version_string": "9.9.9",
                        "url": "http://127.0.0.1/stable/packages/x.kpkg",
                        "sha256": "abc123",
                    }
                },
            })
        self._send(404, {"error": "no such path"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)

        global LAST_REQUEST
        LAST_REQUEST = {
            "method": self.command,
            "path": self.path,
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "body": json.loads(raw) if raw else None,
        }

        if self.path == "/koreader-library/sync":
            self._send(200, {"manifest": self._library(), "apply": [], "plugin": None})
            return
        if self.path == "/slow/define":
            time.sleep(3)
            self._send(200, {"definition": "too late"})
            return
        if self.path == "/boom/define":
            self._send(500, {"error": {"message": "upstream model is down"}})
            return
        if self.path == "/locked/define":
            self._send(401, {"error": "bad key"})
            return
        if self.path == "/garbage/define":
            self._send(200, b"<html>not json at all</html>", "text/html")
            return
        if self.path == "/define":
            request = json.loads(raw or b"{}")
            self._send(200, {
                "word": request.get("word"),
                "definition": "A wild animal of the dog family.",
                "translation": "лиса",
                "part_of_speech": "noun",
                "examples": ["The fox ran across the field."],
                "model": "fake-gateway",
            })
            return
        self._send(404, {"error": "no such path"})

if __name__ == "__main__":
    port = int(sys.argv[1])
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
