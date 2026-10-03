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


# ---- Network panel v2 fixtures: one response of every kind the Preview knows.
FX_HTML = b"""<!doctype html><html><head><title>Preview page</title>
<style>h1 { color: rgb(10, 120, 30); }</style></head>
<body><h1 id="fx-title">Rendered preview</h1><img src="/pixel.png" alt="relative pixel">
<a href="/api/data.json">a link</a><p>caf\xc3\xa9 &amp; cr\xc3\xa8me</p>
<script>document.title = "scripts ran"; document.body.setAttribute("data-script", "ran");</script>
</body></html>"""
FX_XML = b"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>Fixture feed</title><link>http://127.0.0.1:8765/</link>
<item><title>First post</title><guid isPermaLink="false">a1</guid></item>
<item><title>Second post</title><description><![CDATA[<b>bold</b> text]]></description></item>
<!-- a comment --></channel></rss>"""
FX_SVG = b"""<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20" viewBox="0 0 40 20"><rect width="40" height="20" fill="#1a73e8"/><circle cx="10" cy="10" r="6" fill="#fff"/></svg>"""
FX_EVENTS = b"""retry: 2000

: a comment line
id: 1
event: greeting
data: {"hello": "world"}

id: 2
data: line one
data: line two

event: done
data: bye

"""
FX_NDJSON = b'{"n": 1, "ok": true}\n{"n": 2, "ok": false}\n{"n": 3, "tags": ["a", "b"]}\n'
FX_BINARY = bytes(range(256)) + b"Keel hex view" + bytes(range(255, -1, -1))
FX_FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/NotoSansGothic-Regular.ttf",
    "/System/Library/Fonts/Supplemental/NotoSansCoptic-Regular.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/Library/Fonts/Arial Unicode.ttf",
]


def fx_font():
    for path in FX_FONT_CANDIDATES:
        if os.path.exists(path):
            with open(path, "rb") as f:
                return f.read()
    return None


def fx_wav(seconds=0.25, rate=8000):
    """A short sine tone as 8-bit mono PCM WAV."""
    import math
    samples = bytes(int(128 + 60 * math.sin(2 * math.pi * 440 * i / rate)) for i in range(int(seconds * rate)))
    header = b"RIFF" + struct.pack("<I", 36 + len(samples)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate, 1, 8)
    return header + b"data" + struct.pack("<I", len(samples)) + samples


def fx_big_js(target=2_600_000):
    """A large minified-looking script, to keep the Response viewer honest."""
    chunk = "function f{0}(a,b){{var c=a*{0}+b;if(c>{0}){{return c-{0};}}return [a,b,c,'item-{0}'];}}"
    parts, size, i = [], 0, 0
    while size < target:
        piece = chunk.format(i)
        parts.append(piece)
        size += len(piece)
        i += 1
    return ";".join(parts).encode()


class Handler(BaseHTTPRequestHandler):
    # The app's HTTP cache outlives this process: start above anything a
    # previous run could have left in it, so every real fetch counts higher.
    cacheable_hits = int(time.time())

    def _send(self, code, body, ctype="text/plain", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Served-By", "devtools-fixture")
        for name, value in (extra.items() if isinstance(extra, dict) else (extra or [])):
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
        elif self.path.startswith("/fx/"):
            self.fixture_get()
        elif self.path == "/ext/clockwork-api":
            # A response a Laravel app with Clockwork would send: its profile is at /__clockwork/<id>.
            self._send(200, b'{"ok":true}', "application/json", {"X-Clockwork-Id": "1700000000-0001-123", "X-Clockwork-Path": "/__clockwork/", "X-Clockwork-Version": "5.2"})
        elif self.path.startswith("/__clockwork/1700000000-0001-123"):
            profile = {
                "id": "1700000000-0001-123", "method": "GET", "uri": "/ext/clockwork-api", "controller": "App\\Http\\Controllers\\OrderController@index",
                "responseStatus": 200, "responseDuration": 182.4, "memoryUsage": 18874368, "time": 1700000000.5, "databaseDuration": 31.5,
                "databaseQueries": [
                    {"query": "select * from `orders` where `user_id` = 7", "duration": 4.1, "connection": "mysql", "file": "app/Http/Controllers/OrderController.php", "line": 21},
                    {"query": "select * from `items` where `order_id` = 1", "duration": 9.0, "connection": "mysql", "file": "app/Models/Order.php", "line": 40},
                    {"query": "select * from `items` where `order_id` = 2", "duration": 9.2, "connection": "mysql", "file": "app/Models/Order.php", "line": 40},
                    {"query": "select * from `items` where `order_id` = 3", "duration": 9.2, "connection": "mysql", "file": "app/Models/Order.php", "line": 40},
                ],
                "log": [{"level": "error", "message": "Payment gateway timed out", "file": "app/Services/Pay.php", "line": 88}],
                "timelineData": {"total": {"description": "Total execution time", "start": 1700000000.5, "end": 1700000000.68, "duration": 182.4}},
                "viewsData": [{"description": "orders.index", "data": {"name": "orders.index"}}],
            }
            self._send(200, json.dumps(profile).encode(), "application/json")
        elif self.path == "/ext/data.json":
            self._send(200, json.dumps({"user": {"id": 7, "name": "Ada"}, "orders": [{"id": 1, "total": 9.5}, {"id": 2, "total": 12}]}).encode(), "application/json")
        else:
            self._send(404, b"not found")

    def fixture_get(self):
        path = self.path.split("?")[0]
        if path == "/fx/page.html":
            self._send(200, FX_HTML, "text/html; charset=utf-8", {"Cache-Control": "no-cache"})
        elif path == "/fx/feed.xml":
            self._send(200, FX_XML, "application/rss+xml")
        elif path == "/fx/logo.svg":
            self._send(200, FX_SVG, "image/svg+xml", {"Cache-Control": "max-age=60"})
        elif path == "/fx/font.ttf":
            font = fx_font()
            if font is None:
                self._send(404, b"no font on this system")
            else:
                self._send(200, font, "font/ttf", {"Access-Control-Allow-Origin": "*"})
        elif path == "/fx/blob.bin":
            self._send(200, FX_BINARY, "application/octet-stream")
        elif path == "/fx/tone.wav":
            self._send(200, fx_wav(), "audio/wav")
        elif path == "/fx/events":
            self._send(200, FX_EVENTS, "text/event-stream", {"Cache-Control": "no-store"})
        elif path == "/fx/ndjson":
            self._send(200, FX_NDJSON, "application/x-ndjson")
        elif path == "/fx/jsonp":
            self._send(200, b'cb_123({"jsonp": true, "list": [1, 2]});', "application/javascript")
        elif path == "/fx/form":
            self._send(200, b"name=Ada+Lovelace&lang=en&note=caf%C3%A9", "application/x-www-form-urlencoded")
        elif path == "/fx/style.css":
            self._send(200, b"body{margin:0;color:#222}.a,.b{padding:2px 4px}@media (max-width:600px){.a{display:none}}", "text/css")
        elif path == "/fx/big.js":
            self._send(200, fx_big_js(), "application/javascript")
        elif path == "/fx/cookies":
            self._send(200, b'{"cookies": "set"}', "application/json", [
                ("Set-Cookie", "fx_session=s3cr3t; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=3600"),
                ("Set-Cookie", "fx_pref=dark; Path=/fx; Expires=Wed, 21 Oct 2037 07:28:00 GMT"),
                ("Set-Cookie", "fx_track=1; SameSite=None"),
                ("Cache-Control", "no-store"),
            ])
        elif path == "/fx/timing":
            time.sleep(1.1)
            self._send(200, b'{"slow": true}', "application/json", [
                ("Server-Timing", 'db;dur=53.2;desc="Database", app;dur=47.2, cache;desc="Cache read";dur=23'),
                ("Access-Control-Allow-Origin", "*"),
                ("Content-Security-Policy", "default-src 'self'"),
                ("Link", "</fx/style.css>; rel=preload; as=style"),
                ("Referrer-Policy", "no-referrer"),
            ])
        elif path == "/fx/redirect":
            self.send_response(302)
            self.send_header("Location", "/api/data.json?redirected=1")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif path == "/fx/error":
            self._send(500, b'{"error": "boom", "code": 500}', "application/json")
        else:
            self._send(404, b"not found")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        if self.path.startswith("/fx/upload"):
            self._send(200, json.dumps({"received": len(body)}).encode(), "application/json")
            return
        self._send(201, b"created:" + body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
