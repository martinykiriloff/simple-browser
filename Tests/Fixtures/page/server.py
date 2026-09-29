#!/usr/bin/env python3
"""Fixture site for the page and feature self-tests (translation, context menu,
downloads, tabs, history, content blocking).

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


BLOCKING = """<!doctype html>
<html><head><meta charset="utf-8"><title>Blocking</title>
<script>window.loaded = [];</script></head><body>
<h1>A page with ads</h1>
<script src="/ads/banner.js"></script>
<script src="/ads/allowed.js"></script>
<script src="http://localhost:8767/tracker.js"></script>
<script src="/app.js"></script>
<img id="pixel" src="/pixel.gif?track=1" alt="">
<img id="photo" src="/pixel.png" alt="">
<div class="ad-banner" id="hidden-ad">Buy now!</div>
<div class="sponsored" id="sponsored">Sponsored</div>
<div class="promo" id="promo">A promotion on this site</div>
<div class="only-on-localhost" id="elsewhere">Hidden on localhost only</div>
<p id="content">The article itself.</p>
<iframe id="frame" src="http://localhost:8767/ads/frame.html" width="200" height="60"></iframe>
</body></html>"""

# What the filter lists contain, by version: /filters/bump moves to the next.
FILTERS = {
    "ads": [
        """[Adblock Plus 2.0]
! Title: Test ads
/ads/banner.
/ads/frame.
/ads/allowed.
@@/ads/allowed.js
##.ad-banner
##.sponsored:not-a-real-pseudo(1)
127.0.0.1##.promo
localhost##.only-on-localhost
! what WebKit cannot do is left out
||x.example^$redirect=noop.js
example.com##+js(nowif)
""",
        """[Adblock Plus 2.0]
! Title: Test ads, a day later
/ads/banner.
/ads/frame.
/ads/allowed.
@@/ads/allowed.js
/app.js
##.ad-banner
127.0.0.1##.promo
""",
    ],
    "privacy": [
        """! Title: Test privacy
||localhost^$third-party
/pixel.gif?track=
! padding so this is long enough to be a list
||tracker-one.example^
||tracker-two.example^
"""
    ],
}
download_requests = []


def slow_bytes(start, end):
    """The file every /slow.bin is a prefix of: byte i is (i * 31) % 251."""
    return bytes((i * 31) % 251 for i in range(start, end))


filter_version = {"ads": 0, "privacy": 0}
filter_requests = {"ads": [], "privacy": []}


NEWS_ARTICLE = '<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><title>The light nobody owned | The Harbour Gazette</title>\n<meta property="og:site_name" content="The Harbour Gazette">\n<meta name="author" content="Marta Oyelaran">\n<meta property="article:published_time" content="2026-03-12T09:30:00Z">\n<style>body{font:15px system-ui;margin:0} nav,aside,footer{background:#eee;padding:10px} .layout{display:flex} main{flex:1;padding:20px}</style></head>\n<body>\n<nav id="site-nav"><a href="/">Home</a> <a href="/news">News</a> <a href="/sport">Sport</a> <a href="/weather">Weather</a> <a href="/subscribe">Subscribe</a></nav>\n<div class="layout">\n<main>\n<article class="story-body">\n  <h1>The light nobody owned</h1>\n  <p class="byline">By Marta Oyelaran</p>\n  <div class="share-bar" id="share"><a href="/share/x">Share on X</a> <a href="/share/mail">Email</a> <button onclick="window.shared = true">Copy link</button></div>\n  <p id="first">The lighthouse at the end of the harbour wall has been dark for eleven years, and for most of that time nobody in the town thought to ask why. It was simply one of the things that had stopped, like the fish market and the Sunday ferry.</p>\n  <div class="ad-slot" id="ad-1"><a href="http://ads.example/click">Buy our sponsor\'s boat insurance today</a><script>window.adRan = true;</script></div>\n  <p>Then, in the spring, a retired electrician named Ilse Brandt began rowing out to it every morning. She had no permission, she says, and no plan beyond finding out whether the lamp could be made to turn again, which it could, after six weeks and a great deal of grease. <a id="relative" href="/harbour/history">The harbour\'s own history</a> says little about it.</p>\n  <figure><img id="lazy" src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" data-src="/pixel.png" width="600" height="400" alt="The lighthouse at dusk">\n    <figcaption>The lighthouse at dusk, before the lamp was mended.</figcaption></figure>\n  <h2>A question of ownership</h2>\n  <p onclick="window.clickedParagraph = true" style="color:red" id="handlers">What she had not expected was the paperwork. A working light is an aid to navigation, and an aid to navigation must be charted, inspected, insured and, above all, owned by somebody, which this one, it turned out, was not.</p>\n  <blockquote>There was no one to say that she could not mend it.</blockquote>\n  <p>The harbour authority had transferred it to the council in 1998. The council has no record of receiving it. For a quarter of a century the lighthouse belonged, in the most literal sense, to no one at all, and so there was no one to say that she could not mend it. <a id="script-link" href="javascript:window.ranLink = true">Read the transfer</a>.</p>\n  <img src="/pixel.gif?track=1" width="1" height="1" alt="">\n  <form id="newsletter" class="newsletter-signup"><input name="email" placeholder="Your email"><button>Sign up</button></form>\n  <p>By summer the town had formed a committee, as towns do. It meets in the back room of the chandlery, where the minutes are kept in a tide table, and its first resolution, passed unanimously, was that the light should be lit on the longest night of the year.</p>\n  <p style="display:none" id="hidden-text">Hidden text that only machines were meant to read, long enough to be taken for a paragraph of the article if nothing checked whether anyone could see it.</p>\n  <iframe src="/ads/frame.html" width="300" height="100"></iframe>\n</article>\n<section id="comments" class="comments"><h2>Comments</h2>\n  <p>First! This is a comment, which is long enough to look like prose but is not part of the article that the reporter wrote, and must be left out of Reader altogether.</p>\n  <p>Second comment, similarly long-winded, going on about the ferry timetable and the price of diesel as comments under local news stories always seem to do.</p></section>\n</main>\n<aside class="sidebar" id="sidebar"><h3>Most read</h3><ul><li><a href="/1">Ferry cancelled again</a></li><li><a href="/2">Council loses another building</a></li>\n  <li><a href="/3">Record catch landed at dawn</a></li></ul>\n  <p>A long sidebar paragraph promoting the newspaper\'s own subscription offer, with enough words in it to be mistaken for an article paragraph by a careless algorithm, which this one should not be.</p></aside>\n</div>\n<footer id="footer" style="margin-top:1600px"><p>© The Harbour Gazette. All rights reserved. Registered at the post office as a newspaper, with a long legal notice that goes on and on for the sake of the lawyers.</p></footer>\n</body></html>'

WEB_APP = '<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><title>Tasks</title></head><body style="font:14px system-ui;margin:20px">\n<header><h1>My tasks</h1><input id="new" placeholder="Add a task"><button>Add</button></header>\n<ul id="tasks"><li><label><input type="checkbox"> Task number 1: call the harbour office about berth 1</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 2: call the harbour office about berth 2</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 3: call the harbour office about berth 3</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 4: call the harbour office about berth 4</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 5: call the harbour office about berth 5</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 6: call the harbour office about berth 6</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 7: call the harbour office about berth 7</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 8: call the harbour office about berth 8</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 9: call the harbour office about berth 9</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 10: call the harbour office about berth 10</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 11: call the harbour office about berth 11</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 12: call the harbour office about berth 12</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 13: call the harbour office about berth 13</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 14: call the harbour office about berth 14</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 15: call the harbour office about berth 15</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 16: call the harbour office about berth 16</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 17: call the harbour office about berth 17</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 18: call the harbour office about berth 18</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 19: call the harbour office about berth 19</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 20: call the harbour office about berth 20</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 21: call the harbour office about berth 21</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 22: call the harbour office about berth 22</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 23: call the harbour office about berth 23</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 24: call the harbour office about berth 24</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 25: call the harbour office about berth 25</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 26: call the harbour office about berth 26</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 27: call the harbour office about berth 27</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 28: call the harbour office about berth 28</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 29: call the harbour office about berth 29</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 30: call the harbour office about berth 30</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 31: call the harbour office about berth 31</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 32: call the harbour office about berth 32</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 33: call the harbour office about berth 33</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 34: call the harbour office about berth 34</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 35: call the harbour office about berth 35</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 36: call the harbour office about berth 36</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 37: call the harbour office about berth 37</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 38: call the harbour office about berth 38</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 39: call the harbour office about berth 39</label> <button>Edit</button> <button>Delete</button></li><li><label><input type="checkbox"> Task number 40: call the harbour office about berth 40</label> <button>Edit</button> <button>Delete</button></li></ul>\n<table><tr><th>Project</th><th>Open</th><th>Done</th></tr><tr><td>Project 1</td><td>3</td><td>7</td></tr><tr><td>Project 2</td><td>6</td><td>14</td></tr><tr><td>Project 3</td><td>9</td><td>21</td></tr><tr><td>Project 4</td><td>12</td><td>28</td></tr><tr><td>Project 5</td><td>15</td><td>35</td></tr><tr><td>Project 6</td><td>18</td><td>42</td></tr><tr><td>Project 7</td><td>21</td><td>49</td></tr><tr><td>Project 8</td><td>24</td><td>56</td></tr><tr><td>Project 9</td><td>27</td><td>63</td></tr><tr><td>Project 10</td><td>30</td><td>70</td></tr><tr><td>Project 11</td><td>33</td><td>77</td></tr><tr><td>Project 12</td><td>36</td><td>84</td></tr><tr><td>Project 13</td><td>39</td><td>91</td></tr><tr><td>Project 14</td><td>42</td><td>98</td></tr><tr><td>Project 15</td><td>45</td><td>105</td></tr><tr><td>Project 16</td><td>48</td><td>112</td></tr><tr><td>Project 17</td><td>51</td><td>119</td></tr><tr><td>Project 18</td><td>54</td><td>126</td></tr><tr><td>Project 19</td><td>57</td><td>133</td></tr><tr><td>Project 20</td><td>60</td><td>140</td></tr></table>\n<p>Signed in as ada. <a href="/settings">Settings</a> · <a href="/signout">Sign out</a></p>\n</body></html>'


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def filters(self, name):
        version = min(filter_version[name], len(FILTERS[name]) - 1)
        etag = f'"{name}-{version}"'
        sent = self.headers.get("If-None-Match")
        filter_requests[name].append({"if-none-match": sent, "cookie": self.headers.get("Cookie")})
        if sent == etag:
            self.send_response(304)
            self.send_header("ETag", etag)
            self.end_headers()
            return
        self.send(200, FILTERS[name][version], "text/plain; charset=utf-8", {"ETag": etag})

    def send(self, status, body, content_type="text/html; charset=utf-8", headers=None):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def slow(self):
        """A file that arrives slowly and can be taken up where it stopped."""
        import time
        from urllib.parse import parse_qs, urlparse
        query = parse_qs(urlparse(self.path).query)
        size = int(query.get("size", ["3000000"])[0])
        rate = int(query.get("rate", ["600000"])[0])
        name = query.get("name", ["slow.bin"])[0]
        etag = f'"slow-{size}"'
        start = 0
        asked = self.headers.get("Range")
        if asked and asked.startswith("bytes=") and self.headers.get("If-Range", etag) == etag:
            start = int(asked[6:].split("-")[0] or 0)
        download_requests.append({"path": self.path, "range": asked, "start": start})
        self.send_response(206 if start else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", f'attachment; filename="{name}"')
        self.send_header("Content-Length", str(size - start))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", etag)
        if start:
            self.send_header("Content-Range", f"bytes {start}-{size - 1}/{size}")
        self.end_headers()
        step = max(1, rate // 10)
        try:
            for position in range(start, size, step):
                self.wfile.write(slow_bytes(position, min(size, position + step)))
                self.wfile.flush()
                time.sleep(0.1)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send_response(302)
        self.send_header("Location", "/second")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/":
            self.send(200, ARTICLE)
        elif path == "/long":
            rows = "".join(f"<p style='height:40px'>Paragraph {i}</p>" for i in range(200))
            self.send(200, f"<!doctype html><title>Long page</title><body>{rows}</body>")
        elif path == "/form":
            self.send(200, "<!doctype html><title>A form</title><input id=field><p>Half-filled forms must not sleep.</p>")
        elif path == "/tabs":
            self.send(200, TABS)
        elif path == "/popup":
            self.send(200, POPUP)
        elif path == "/second":
            self.send(200, "<!doctype html><title>Second</title><p id=second>The second page</p>")
        elif path == "/spa":
            self.send(200, """<!doctype html><title>Single page app</title>
<button id=route onclick="history.pushState({}, '', '/spa/settings'); document.title = 'App settings'">Settings</button>""")
        elif path == "/optout":
            self.send(200, OPTOUT)
        elif path == "/en":
            self.send(200, ENGLISH)
        elif path == "/recette":
            self.send(200, "<!doctype html><title>Recette</title><p id=recipe>La recette</p>")
        elif path == "/cookie/set":
            value = self.path.split("v=", 1)[1] if "v=" in self.path else "set"
            self.send(200, "<!doctype html><title>Cookie set</title><p>Signed in as " + value + "</p><script>localStorage.setItem('who', '" + value + "')</script>",
                      headers={"Set-Cookie": "session=" + value + "; Path=/; Max-Age=86400"})
        elif path == "/cookie/show":
            self.send(200, "<!doctype html><title>Who</title><p id=cookie>" + (self.headers.get("Cookie") or "") + "</p>"
                      "<p id=stored></p><script>document.getElementById('stored').textContent = localStorage.getItem('who') || ''</script>")
        elif path == "/signin":
            self.send(200, """<!doctype html><title>Sign in</title><form method=post action=/signin>
<label>Username <input name=username id=username></label><label>Password <input name=password id=password type=password></label>
<button id=submit>Sign in</button></form>""")
        elif path == "/media":
            self.send(200, """<!doctype html><title>Video call</title><button id=start onclick="start({video: true, audio: true})">Join with video</button>
<script>
window.media = 'idle';
async function start(constraints) {
  window.media = 'asking';
  try {
    window.stream = await navigator.mediaDevices.getUserMedia(constraints);
    window.media = 'granted:' + window.stream.getTracks().map(t => t.kind).sort().join('+');
  } catch (e) { window.media = 'refused:' + e.name; window.mediaError = e.message; }
}
function stop() { window.stream.getTracks().forEach(t => t.stop()); }
if (location.search.includes('auto')) start({ video: true });
</script>""")
        elif path == "/media-frame":
            self.send(200, """<!doctype html><title>A page with a call widget</title><p>The widget below is from another site.</p>
<iframe id=widget src="http://localhost:8767/media?auto=1" allow="camera; microphone" width=400 height=100></iframe>""")
        elif path == "/popups":
            self.send(200, """<!doctype html><title>Pop-ups</title>
<button id=open onclick="window.clicked = window.open('/second?clicked=1') ? 'opened' : 'blocked'">Open a window</button>
<script>
window.auto = window.open('/second?auto=1') ? 'opened' : 'blocked';
window.auto2 = window.open('/long?auto=2') ? 'opened' : 'blocked';
</script>""")
        elif path == "/downloads":
            self.send(200, """<!doctype html><title>Many files</title><p>This page hands over three files by itself.</p><script>
for (const n of [1, 2, 3]) {
  const frame = document.createElement('iframe');
  frame.style.display = 'none';
  frame.src = '/report.zip?n=' + n;
  document.body.appendChild(frame);
}
</script>""")
        elif path == "/geo":
            self.send(200, """<!doctype html><title>Where am I</title><script>
window.geo = 'idle';
function locate() {
  window.geo = 'asking';
  navigator.geolocation.getCurrentPosition(p => { window.geo = 'position'; }, e => { window.geo = 'error:' + e.code; }, { timeout: 4000 });
}
</script>""")
        elif path == "/notify":
            self.send(200, """<!doctype html><title>Notify</title><script>
window.notify = typeof Notification === 'undefined' ? 'no API' : 'permission:' + Notification.permission;
function ask() { window.asked = 'asking'; Notification.requestPermission().then(r => { window.asked = r; }, e => { window.asked = 'error:' + e; }); }
</script>""")
        elif path == "/slow.bin":
            self.slow()
        elif path == "/broken.bin":
            # Promises a megabyte, sends a tenth, and hangs up.
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="broken.bin"')
            self.send_header("Content-Length", "1000000")
            self.end_headers()
            self.wfile.write(slow_bytes(0, 100000))
            self.wfile.flush()
            self.connection.close()
        elif path == "/setup.command":
            self.send(200, "#!/bin/sh\necho this must never run\n", "application/octet-stream",
                      {"Content-Disposition": 'attachment; filename="setup.command"'})
        elif path == "/downloads/requests":
            import json
            self.send(200, json.dumps(download_requests), "application/json")
        elif path == "/downloads/reset":
            download_requests.clear()
            self.send(200, "{}", "application/json")
        elif path == "/article":
            self.send(200, NEWS_ARTICLE)
        elif path == "/webapp":
            self.send(200, WEB_APP)
        elif path == "/harbour/history":
            self.send(200, "<!doctype html><title>History</title><p id=history>The harbour's history</p>")
        elif path == "/find":
            self.send(200, """<!doctype html><title>Find</title><body style="font:16px system-ui;margin:40px">
<p>A needle in the first paragraph, and a second Needle, capitalised.</p>
<p style="margin-top:1500px" id=far>Far down the page: needle number three.</p>
<p>needleneedle: two more, back to back.</p>
<iframe id=frame src="/find-frame" width=400 height=120></iframe></body>""")
        elif path == "/find-frame":
            self.send(200, "<!doctype html><title>Frame</title><p>In a frame: a needle, and another needle.</p>")
        elif path == "/blocking":
            self.send(200, BLOCKING)
        elif path in ("/ads/banner.js", "/ads/allowed.js", "/tracker.js", "/app.js"):
            name = path.rsplit("/", 1)[1].split(".")[0]
            self.send(200, f"window.loaded && window.loaded.push('{name}');", "application/javascript")
        elif path == "/ads/frame.html":
            self.send(200, "<!doctype html><title>An ad</title><p>An ad in a frame</p>")
        elif path == "/pixel.gif":
            self.send(200, PIXEL, "image/png")
        elif path in ("/filters/ads.txt", "/filters/privacy.txt"):
            self.filters(path.split("/")[2].split(".")[0])
        elif path == "/filters/portal.txt":
            self.send(200, "<!DOCTYPE html><html><body><h1>Welcome to Hotel Wi-Fi</h1><p>Please sign in</p><p>to continue</p><p>browsing</p></body></html>",
                      "text/plain")
        elif path == "/filters/bump":
            filter_version["ads"] += 1
            self.send(200, "{}", "application/json")
        elif path == "/filters/reset":
            for name in filter_version:
                filter_version[name] = 0
                filter_requests[name] = []
            self.send(200, "{}", "application/json")
        elif path == "/filters/requests":
            import json
            self.send(200, json.dumps(filter_requests), "application/json")
        elif path == "/pixel.png":
            self.send(200, PIXEL, "image/png")
        elif path == "/checkout":
            # A shop that labels its fields (autocomplete), as Shopify's checkout does.
            countries = "".join(f"<option value={c}>{n}</option>" for c, n in [("", "Choose…"), ("US", "United States"), ("GB", "United Kingdom"), ("FR", "France")])
            months = "".join(f"<option value={m:02d}>{m:02d}</option>" for m in range(1, 13))
            years = "".join(f"<option value={y}>{y}</option>" for y in range(2026, 2036))
            self.send(200, f"""<!doctype html><title>Checkout</title><form id=checkout method=post action=/checkout>
<input id=given autocomplete="shipping given-name" placeholder="First name"><input id=family autocomplete="shipping family-name" placeholder="Last name">
<input id=line1 autocomplete="shipping address-line1"><input id=line2 autocomplete="shipping address-line2"><input id=city autocomplete="shipping address-level2">
<select id=country autocomplete="shipping country">{countries}</select><input id=zip autocomplete="shipping postal-code"><input id=email type=email autocomplete=email>
<input id=ccname autocomplete=cc-name><input id=ccnumber autocomplete=cc-number inputmode=numeric>
<select id=ccmonth autocomplete=cc-exp-month>{months}</select><select id=ccyear autocomplete=cc-exp-year>{years}</select>
<input id=csc autocomplete=cc-csc><button id=pay>Pay</button></form>""")
        elif path == "/checkout-legacy":
            self.send(200, """<!doctype html><title>Old shop</title><form method=post action=/checkout>
<label>First name <input name=fname id=fname></label><label>Last name <input name=lname id=lname></label>
<label>Street address <input name=address1 id=address1></label><label>City <input name=city id=city></label>
<label>ZIP code <input name=zip id=zip></label><label>Card number <input name=ccnum id=ccnum></label>
<label>Expiration (MM/YY) <input name=ccexp id=ccexp></label><label>CVV <input name=cvv id=cvv></label><button id=buy>Buy</button></form>""")
        elif path == "/otp":
            self.send(200, "<!doctype html><title>Verify</title><form><input id=code autocomplete=one-time-code inputmode=numeric><button>Verify</button></form>")
        elif path == "/webauthn":
            self.send(200, """<!doctype html><title>Passkey</title><button id=passkey onclick="navigator.credentials.get({publicKey: {challenge: new Uint8Array(32)}}).catch(e => document.title = 'Passkey: ' + e.name)">Sign in with a passkey</button>""")
        elif path == "/page":
            # Any title, for tests that need many tabs told apart; with an icon.
            from urllib.parse import parse_qs, urlparse
            from html import escape
            title = escape(parse_qs(urlparse(self.path).query).get("title", ["Page"])[0])
            self.send(200, f"<!doctype html><title>{title}</title><link rel=icon href=/pixel.png><h1>{title}</h1>")
        elif path == "/report.zip":
            self.send(200, b"PK\x05\x06" + b"\x00" * 18, "application/zip",
                      {"Content-Disposition": 'attachment; filename="rapport.zip"'})
        else:
            self.send(404, "")


def serve_https():
    """The same site over https on 8768, with a certificate it signed itself:
    a connection no browser should trust without being told to."""
    import os, ssl, subprocess, tempfile, threading
    folder = tempfile.mkdtemp(prefix="simplebrowser-fixture-")
    key, cert = os.path.join(folder, "key.pem"), os.path.join(folder, "cert.pem")
    made = subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "2",
                           "-subj", "/CN=Fixture Self-Signed/O=SimpleBrowser Tests",
                           "-addext", "subjectAltName=IP:127.0.0.1,DNS:localhost"], capture_output=True)
    if made.returncode != 0:
        return
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server = ThreadingHTTPServer(("127.0.0.1", PORT + 1), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()


if __name__ == "__main__":
    serve_https()
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
