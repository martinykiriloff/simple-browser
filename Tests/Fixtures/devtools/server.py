"""Tiny local site that exercises every DevTools panel.

    python3 Tests/Fixtures/devtools/server.py          # serves http://127.0.0.1:8765/
"""
import base64
import hashlib
import json
import os
import struct
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da63f8cfc0f01f000401010097c7b5f10000000049454e44ae426082"
)
SCRIPT = b"window.__scriptLoaded = true;\nfunction greet(name){if(!name){return 'hello';}return 'hello '+name;}\n"


B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def vlq(value):
    """Base64 VLQ, as used by source map `mappings`."""
    value = (-value << 1) | 1 if value < 0 else value << 1
    out = ""
    while True:
        digit = value & 31
        value >>= 5
        out += B64[digit | (32 if value else 0)]
        if not value:
            return out


def build_bundle():
    """A "minified" bundle: a banner line, then every statement of src/cart.js
    on ONE line, with a source map back to the original lines. Exercises the
    column handling that real minified code needs."""
    with open(os.path.join(HERE, "src", "cart.js")) as f:
        original = f.read().splitlines()
    pieces, segments = [], []
    column = 0
    previous = [0, 0, 0, 0]            # generated column, source, line, column
    for number, line in enumerate(original):
        text = line.strip()
        if not text:
            continue
        indent = len(line) - len(line.lstrip())
        fields = [column, 0, number, indent]
        segments.append("".join(vlq(a - b) for a, b in zip(fields, previous)))
        previous = fields
        pieces.append(text)
        column += len(text) + 1
    bundle = "/* bundle.js: generated, do not edit */\n" + " ".join(pieces) + "\n//# sourceMappingURL=bundle.js.map\n"
    source_map = {
        "version": 3, "file": "bundle.js", "sourceRoot": "", "sources": ["src/cart.js"], "names": [],
        "sourcesContent": ["\n".join(original) + "\n"],
        "mappings": ";" + ",".join(segments),
    }
    return bundle.encode(), json.dumps(source_map).encode()


class Handler(BaseHTTPRequestHandler):
    # The app's HTTP cache outlives this process: start above anything a
    # previous run could have left in it, so every real fetch counts higher.
    cacheable_hits = int(time.time())

    def _send(self, code, body, ctype="text/plain", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Served-By", "devtools-fixture")
        for name, value in (extra or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def websocket_echo(self):
        """Minimal RFC 6455 server: handshake, then echo text frames back."""
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.close_connection = True
        try:
            while True:
                head = self.rfile.read(2)
                if len(head) < 2:
                    return
                opcode = head[0] & 0x0F
                length = head[1] & 0x7F
                if length == 126:
                    length = struct.unpack(">H", self.rfile.read(2))[0]
                elif length == 127:
                    length = struct.unpack(">Q", self.rfile.read(8))[0]
                mask = self.rfile.read(4) if head[1] & 0x80 else b"\0\0\0\0"
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(self.rfile.read(length)))
                if opcode == 8:            # close
                    self.wfile.write(b"\x88\x00")
                    return
                if opcode == 1:            # text: echo it back
                    reply = b"echo: " + payload
                    self.wfile.write(bytes([0x81, len(reply)]) + reply if len(reply) < 126
                                     else bytes([0x81, 126]) + struct.pack(">H", len(reply)) + reply)
                    self.wfile.flush()
        except OSError:
            return

    def do_GET(self):
        if self.path == "/ws" and "websocket" in self.headers.get("Upgrade", "").lower():
            self.websocket_echo()
        elif self.path in ("/", "/index.html"):
            with open(os.path.join(HERE, "index.html"), "rb") as f:
                self._send(200, f.read(), "text/html; charset=utf-8")
        elif self.path.startswith("/api/data.json"):
            body = json.dumps({"ok": True, "items": [1, 2, 3], "path": self.path}).encode()
            self._send(200, body, "application/json")
        elif self.path == "/manifest.json":
            manifest = {"name": "Fixture Shop", "short_name": "Shop", "start_url": "/?pwa=1", "display": "standalone",
                        "theme_color": "#1a73e8", "background_color": "#ffffff",
                        "icons": [{"src": "/pixel.png", "sizes": "192x192", "type": "image/png"}]}
            self._send(200, json.dumps(manifest).encode(), "application/manifest+json")
        elif self.path == "/pixel.png":
            self._send(200, PNG, "image/png")
        elif self.path == "/bundle.js":
            self._send(200, build_bundle()[0], "application/javascript")
        elif self.path == "/bundle.js.map":
            self._send(200, build_bundle()[1], "application/json")
        elif self.path == "/src/cart.js":
            with open(os.path.join(HERE, "src", "cart.js"), "rb") as f:
                self._send(200, f.read(), "application/javascript")
        elif self.path == "/cacheable":
            # Counts how often it is really fetched, to test "Disable cache".
            Handler.cacheable_hits += 1
            self._send(200, str(Handler.cacheable_hits).encode(), "text/plain", {"Cache-Control": "max-age=3600"})
        elif self.path == "/script.js":
            self._send(200, SCRIPT, "application/javascript")
        else:
            self._send(404, b"not found")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self._send(201, b"created:" + self.rfile.read(length))

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
