# Token-efficiency benchmark: an MCP client driving the real app over the
# fixture pages in this folder. Run by scripts/bench-agent.sh.
#
# For each page: snapshot (full and interactiveOnly), get_page_content and the
# full DOM (outerHTML), all as estimated tokens, plus snapshot latency. Then a
# simple, robust check that Keel's tools surface the page's planted problem.
# Exits non-zero when the median snapshot/full-DOM ratio is over 50% or a
# scenario check fails.
import json, os, re, statistics, sys, time, urllib.request, urllib.error

PORT = int(os.environ.get("PORT", "9398"))
TOKEN = os.environ["TOKEN"]
SITE = os.environ.get("SITE", "http://127.0.0.1:8792")
OUT = os.environ.get("BENCH_OUT")  # optional: write the Markdown table here
URL = f"http://127.0.0.1:{PORT}/mcp"
TARGET = 0.50
session = None
next_id = [0]
failures = []

def post(message):
    global session
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
               "Authorization": "Bearer " + TOKEN}
    if session: headers["Mcp-Session-Id"] = session
    request = urllib.request.Request(URL, data=json.dumps(message).encode(), headers=headers, method="POST")
    with urllib.request.urlopen(request, timeout=120) as reply:
        session = reply.headers.get("Mcp-Session-Id") or session
        body = reply.read()
        return json.loads(body) if body else None

def call(name, **args):
    next_id[0] += 1
    started = time.perf_counter()
    reply = post({"jsonrpc": "2.0", "id": next_id[0], "method": "tools/call", "params": {"name": name, "arguments": args}})
    elapsed = (time.perf_counter() - started) * 1000
    result = reply["result"]
    text = "\n".join(c.get("text", "") for c in result["content"] if c["type"] == "text")
    return result.get("isError", False), text, result.get("structuredContent") or {}, elapsed

def estimate(text):
    # The same estimate Keel uses (TokenEstimate): ASCII ~4 chars/token, other scripts ~1.5.
    ascii_count = sum(1 for ch in text if ord(ch) < 128)
    return int(-(-(ascii_count / 4 + (len(text) - ascii_count) / 1.5) // 1)) if text else 0

def tokens(text, structured):
    value = structured.get("tokens")
    return int(value) if isinstance(value, (int, float)) else estimate(text)

def check(name, ok, detail=""):
    print(("✔ " if ok else "✘ ") + name + ("" if ok else f"\n    {str(detail)[:1200]}"))
    if not ok: failures.append(name)

def evaluate(expression):
    err, text, _, _ = call("evaluate", expression=expression)
    text = re.sub(r"<untrusted-page-content[^>]*>\n?|\n?</untrusted-page-content>", "", text).strip()
    return err, text

# --- scenario checks: does Keel's toolset surface the planted problem?
def check_layout():
    err, text, _, _ = call("inspect_element", selector="#toolbar", properties=["display", "flex-wrap", "width", "overflow-x"])
    _, overflow = evaluate("(() => { const el = document.querySelector('#toolbar'); return el.scrollWidth - el.clientWidth; })()")
    _, culprit = evaluate("(() => { const r = document.querySelector('#toolbar').getBoundingClientRect(); "
                          "return [...document.querySelectorAll('#toolbar > *')].filter(c => c.getBoundingClientRect().right > r.right + 1).length; })()")
    ok = not err and "flex-wrap: nowrap" in text and int(overflow or 0) > 0 and int(culprit or 0) > 0
    check(f"layout: inspect_element shows flex-wrap: nowrap on #toolbar, overflowing by {overflow}px ({culprit} children past its edge)", ok, (text, overflow, culprit))

def check_request():
    err, text, _, _ = call("diagnose", includeAudits=False)
    ok = not err and re.search(r"GET 500 \S*/api/orders", text) is not None
    check("request: diagnose lists GET 500 /api/orders under failed requests", ok, text)

def check_slow():
    call("click", selector="#apply")
    time.sleep(0.5)
    err, text, _, _ = call("performance_metrics")
    inp = re.search(r"INP[^\n]*?(\d+(?:\.\d+)?)\s*ms", text)
    longest = re.search(r"Long tasks: \d+, \d+ ms total, longest (\d+) ms", text)
    value = max(float(inp.group(1)) if inp else 0, float(longest.group(1)) if longest else 0)
    check(f"slow: performance_metrics reports the ~300 ms interaction (INP / long task {value:.0f} ms)", not err and value >= 250, text)

def check_leak():
    call("heap_snapshot", filter="NotificationWidget")
    for _ in range(10): call("click", selector="#open"); call("click", selector="#close")
    err, text, _, _ = call("heap_snapshot", compare=True, filter="NotificationWidget")
    grew = re.search(r"NotificationWidget[^\n]*\+\s*(\d+)", text)
    check(f"leak: heap_snapshot compare shows NotificationWidget grew by {grew.group(1) if grew else '?'} after 10 open/close cycles",
          not err and grew is not None and int(grew.group(1)) >= 10, text)

def check_cookie():
    err, text, _, _ = call("storage", area="cookies", key="session")
    _, seen = evaluate("document.cookie.includes('session=')")
    _, badge = evaluate("document.querySelector('#session').textContent")
    ok = not err and "session=abc123" in text and "/admin" in text and seen == "false" and "not signed in" in badge
    check("cookie: storage shows session=abc123 scoped to Path=/admin while document.cookie on / lacks it", ok, (text, seen, badge))

PAGES = [
    ("layout.html", "Layout bug (overflowing flex row)", check_layout),
    ("request.html", "Failing request (500)", check_request),
    ("slow.html", "Slow interaction (300 ms handler)", check_slow),
    ("leak.html", "Leaking listener", check_leak),
    ("cookie.html", "Cookie scope (Path=/admin)", check_cookie),
    ("docs.html", "Large docs page", None),
]

post({"jsonrpc": "2.0", "id": 0, "method": "initialize",
      "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "keel-bench", "version": "1"}}})
post({"jsonrpc": "2.0", "method": "notifications/initialized"})

UNCUT = {"maxTokens": 1_000_000, "maxLength": 10_000_000}  # measure the whole tree, not the session's 8k budget
rows = []
for page, label, scenario in PAGES:
    err, text, _, _ = call("new_tab", url=f"{SITE}/{page}")
    if err:
        check(f"{page}: new_tab", False, text); continue
    time.sleep(0.5)  # let load-time fetches settle
    _, elements = evaluate("document.querySelectorAll('*').length")
    _, snap_text, snap_s, _ = call("snapshot", **UNCUT)            # warm-up (first call injects the agent)
    timings = []
    for _ in range(3):
        _, snap_text, snap_s, ms = call("snapshot", **UNCUT)
        timings.append(ms)
    _, small_text, small_s, _ = call("snapshot", interactiveOnly=True, **UNCUT)
    _, default_text, default_s, _ = call("snapshot")
    _, content_text, content_s, _ = call("get_page_content", maxLength=10_000_000)
    _, dom = evaluate("(() => { const h = document.documentElement.outerHTML; let o = 0; "
                      "for (let i = 0; i < h.length; i++) if (h.charCodeAt(i) > 127) o++; return [h.length, o]; })()")
    length, other = json.loads(dom)
    full = int(-(-((length - other) / 4 + other / 1.5) // 1))
    row = {"page": page, "label": label, "elements": int(elements), "snapshot": tokens(snap_text, snap_s),
           "interactive": tokens(small_text, small_s), "default": tokens(default_text, default_s),
           "cut": "cut to the session's budget" in default_text,
           "content": tokens(content_text, content_s), "full": full, "ms": statistics.median(timings)}
    row["ratio"] = row["snapshot"] / full
    rows.append(row)
    if scenario: scenario()
    call("close_tab")

lines = ["| Page | Elements | Snapshot | Interactive-only | Page content (md) | Full DOM | Snapshot / DOM | Interactive / DOM | Snapshot ms (median of 3) |",
         "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
for r in rows:
    lines.append(f"| {r['label']} (`{r['page']}`) | {r['elements']:,} | {r['snapshot']:,} | {r['interactive']:,} | {r['content']:,} | {r['full']:,} | "
                 f"{r['ratio']:.0%} | {r['interactive'] / r['full']:.0%} | {r['ms']:.0f} |")
median = statistics.median(r["ratio"] for r in rows) if rows else 1
verdict = f"median snapshot = {median:.0%} of full DOM (target ≤ {TARGET:.0%})"
table = "\n".join(lines)
print("\n" + table + "\n")
for r in rows:
    if r["cut"]: print(f"note: with the default 8k-token session budget, {r['page']}'s snapshot is cut to {r['default']:,} tokens")
print(verdict)
if OUT:
    with open(OUT, "w") as f: f.write(table + "\n\n" + verdict + "\n")

if len(rows) != len(PAGES): failures.append("not every page was measured")
if median > TARGET: failures.append(verdict)
if failures:
    print(f"\n{len(failures)} failure(s): " + "; ".join(failures)); sys.exit(1)
print("\nAll scenario checks passed.")
