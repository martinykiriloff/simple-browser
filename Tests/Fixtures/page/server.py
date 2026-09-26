#!/usr/bin/env python3
"""Fixture site for the page self-test (translation, context menu, downloads).

    python3 Tests/Fixtures/page/server.py      # http://127.0.0.1:8767/
"""
import struct
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8767

def png(width, height, rgb):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    rows = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


PIXEL = png(8, 8, (200, 30, 30))

STYLE = "<style>body{font:16px -apple-system,system-ui;margin:40px;max-width:40em} img{width:80px;height:80px}</style>"

ARTICLE = """<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><title>Un article</title>""" + STYLE + """</head>
<body>
<h1 id="title">Bonjour tout le monde</h1>
<p id="intro">Ceci est un <b id="bold">article important</b> sur la cuisine française, avec un
  <a id="link" href="/recette">lien vers la recette</a> et du code <code id="code">let x = 1</code>.</p>
<p id="keep">Le nom <span id="brand" class="notranslate">Maison Dupont</span> ne se traduit pas.</p>
<pre id="pre">if (a) { b(); }</pre>
<ul id="list"><li>Premier élément de la liste</li><li>Deuxième élément de la liste</li></ul>
<form onsubmit="return false"><input id="search" placeholder="Rechercher une recette">
  <input id="send" type="submit" value="Envoyer maintenant"></form>
<p><img id="image" src="/pixel.png" alt="Une photo du plat"></p>
<p id="select-me">Fromage</p>
<div id="blank" style="height:60px"></div>
<p><button id="more" onclick="var p=document.createElement('p');p.id='added';p.textContent='Un nouveau paragraphe arrive plus tard';document.body.appendChild(p)">Charger plus</button></p>
<p><a id="file" href="/report.zip">Télécharger le rapport</a></p>
<script>
  window.clicked = false;
  window.linkRef = document.getElementById('link');
  document.getElementById('link').addEventListener('click', function (e) { e.preventDefault(); window.clicked = true; });
</script>
</body></html>"""

TABS = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Tabs</title></head><body>
<p><a id="blank" href="/second" target="_blank">A link that opens a new tab</a></p>
<p><button id="signin" onclick="window.open('/popup', 'signin', 'width=420,height=520')">Sign in (opens a pop-up)</button></p>
<p><a id="plain" href="/second">Second page</a></p>
<p><a id="background" href="/second">Open me with Command</a></p>
<script>window.addEventListener('message', function (e) { document.title = 'Signed in: ' + e.data; });</script>
</body></html>"""

POPUP = """<!doctype html>
<html><head><meta charset="utf-8"><title>Sign in</title></head><body>
<p>Signing in…</p>
<script>
  setTimeout(function () {
    if (window.opener) { window.opener.postMessage('ada', '*'); }
    setTimeout(function () { window.close(); }, 300);
  }, 300);
</script></body></html>"""

OPTOUT = """<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="google" content="notranslate"><title>Non</title></head>
<body><p>Cette page demande de ne pas être traduite, merci beaucoup de respecter ce choix.</p></body></html>"""

ENGLISH = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>English</title></head>
<body><p>This page is already written in English, so there is nothing to translate here at all.</p></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, status, body, content_type="text/html; charset=utf-8", headers=None):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/":
            self.send(200, ARTICLE)
        elif path == "/tabs":
            self.send(200, TABS)
        elif path == "/popup":
            self.send(200, POPUP)
        elif path == "/second":
            self.send(200, "<!doctype html><title>Second</title><p id=second>The second page</p>")
        elif path == "/optout":
            self.send(200, OPTOUT)
        elif path == "/en":
            self.send(200, ENGLISH)
        elif path == "/recette":
            self.send(200, "<!doctype html><title>Recette</title><p id=recipe>La recette</p>")
        elif path == "/pixel.png":
            self.send(200, PIXEL, "image/png")
        elif path == "/report.zip":
            self.send(200, b"PK\x05\x06" + b"\x00" * 18, "application/zip",
                      {"Content-Disposition": 'attachment; filename="rapport.zip"'})
        else:
            self.send(404, "")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
