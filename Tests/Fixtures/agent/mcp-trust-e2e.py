# End-to-end check of the trust layer: an MCP client in a sandbox session,
# approvals answered "deny" by the scripted run (--agent-approve deny).
# Run by scripts/test-trust.sh.
import json, os, re, sys, urllib.request, urllib.error, glob

PORT = int(os.environ["PORT"])
TOKEN = os.environ["TOKEN"]
SITE = os.environ["SITE"]
MODE = os.environ.get("MODE", "deny")
AGENT_DIR = os.environ.get("KEEL_AGENT_DIR", "")
BASE = f"http://127.0.0.1:{PORT}"
session = None
failures = []
next_id = [0]

def request(path, body=None, headers=None, method=None, token=TOKEN):
    global session
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if token: h["Authorization"] = "Bearer " + token
    if session and path == "/mcp": h["Mcp-Session-Id"] = session
    h.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, headers=h, method=method or ("POST" if data else "GET"))
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            sid = r.headers.get("Mcp-Session-Id")
            if sid and path == "/mcp": session = sid
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def call(name, **args):
    next_id[0] += 1
    status, reply = request("/mcp", {"jsonrpc": "2.0", "id": next_id[0], "method": "tools/call", "params": {"name": name, "arguments": args}})
    assert status == 200, (status, reply)
    result = reply["result"]
    text = "\n".join(c.get("text", "") for c in result["content"] if c["type"] == "text")
    return result.get("isError", False), text, result.get("structuredContent") or {}

def code(structured):
    return (structured.get("error") or {}).get("code")

def check(name, ok, detail=""):
    print(("✔ " if ok else "✘ ") + name + ("" if ok else f"\n    {str(detail)[:1200]}"))
    if not ok: failures.append(name)

def page_value(js):
    err, text, _ = call("evaluate", expression=js)
    return re.sub(r'<untrusted-page-content[^>]*>\n|\n</untrusted-page-content>', '', text).strip().strip('"')

# --- transport and pairing
status, reply = request("/schema", token=None)
check("the tool schema is published and versioned", status == 200 and reply.get("toolSchemaVersion") and len(reply.get("tools", [])) > 30, reply)
status, _ = request("/pair", {"name": "evil"}, headers={"Origin": "https://evil.example"}, token=None)
check("a web page cannot ask to pair", status == 403, status)
status, _ = request("/pair", token=None, method="GET")
check("pairing takes POST only", status == 405, status)
status, _ = request("/mcp", {"jsonrpc": "2.0", "id": 0, "method": "ping"}, token="keel_not-a-paired-token")
check("an unpaired token is refused", status == 401, status)

status, reply = request("/mcp", {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "trust-e2e", "version": "1"}}})
check("initialize reports the tool schema version", status == 200 and reply["result"].get("_meta", {}).get("keel/toolSchemaVersion"), reply)
request("/mcp", {"jsonrpc": "2.0", "method": "notifications/initialized"})
status, reply = request("/mcp", {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
names = [t["name"] for t in reply["result"]["tools"]]
check("session tools are listed; page tools only with WebMCP on", "session_info" in names and "request_human" in names and "page_tools" not in names, names)

if MODE == "budget":
    call("new_tab", url=SITE + "/checkout.html")
    results = [call("click", selector="#note") for _ in range(3)]
    err, text, structured = results[-1]
    check("the action budget runs out, not retryable", err and code(structured) == "budget_exhausted" and structured["error"]["retryable"] is False, (text, structured))
    err, text, structured = call("snapshot")
    check("reads go on after the budget is spent", not err, text)
    print(f"\n{len(failures)} failed" if failures else "\nall passed")
    sys.exit(1 if failures else 0)

# --- isolation
err, text, _ = call("list_tabs")
check("the person's tabs are not visible to the agent", "Second page" not in text and "person.html" not in text, text)
err, text, structured = call("snapshot")
check("with no tab of its own, the agent is told to open one", err and code(structured) in ("no_tab", "internal") and "new_tab" in text, (text, structured))
err, text, structured = call("session_info")
check("session_info: a sandbox", not err and structured.get("mode") == "sandbox" and "sandbox" in text, (text, structured))

err, text, structured = call("new_tab", url=SITE + "/checkout.html")
check("new_tab opens in the sandbox", not err and structured.get("ok") is True and structured.get("tabId"), (text, structured))
check("the sandbox has none of the person's cookies", "secret-cookie" not in page_value("document.cookie"), page_value("document.cookie"))
check("…nor their local storage, on the same origin", page_value("String(localStorage.getItem('person_token'))") == "null", page_value("String(localStorage.getItem('person_token'))"))

err, snap, structured = call("snapshot")
check("page content is marked untrusted", not err and "<untrusted-page-content origin=\"127.0.0.1:" in snap and snap.rstrip().endswith("</untrusted-page-content>"), snap[:300])
check("snapshots report their token count", structured.get("tokens", 0) > 0 and "tokens" in snap, structured)

# --- approvals (answered deny)
err, text, structured = call("fill", selector="input[name=email]", value="alex@example.com")
check("typing an email needs no approval", not err, (text, structured))
err, text, structured = call("fill", selector="input[name=card]", value="4242 4242 4242 4242")
check("typing a card number asks, and denied is refused", err and code(structured) == "approval_denied" and structured["error"]["retryable"] is False, (text, structured))
check("the card number never reached the page", page_value("document.querySelector('input[name=card]').value") == "", page_value("document.querySelector('input[name=card]').value"))
err, text, structured = call("fill", selector="input[name=pw]", value="hunter2")
check("typing a password asks", err and code(structured) == "approval_denied", (text, structured))
err, text, structured = call("click", text="Place order")
check("placing an order asks", err and code(structured) == "approval_denied", (text, structured))
check("the order was not placed", page_value("document.getElementById('status').textContent") == "waiting", page_value("document.getElementById('status').textContent"))
err, text, structured = call("click", selector="#note")
check("an ordinary click goes through", not err and page_value("document.getElementById('status').textContent") == "NOTE OPENED", (text, structured))
err, text, structured = call("upload_files", selector="input[name=email]", paths=["/etc/hosts"])
check("uploads ask", err and code(structured) == "approval_denied", (text, structured))

# --- origins
err, text, structured = call("navigate", url="file:///etc/hosts")
check("file: URLs are blocked", err and code(structured) == "origin_blocked", (text, structured))

# --- page instructions
call("navigate", url=SITE + "/injection.html")
err, snap, structured = call("snapshot")
check("text addressed to agents is flagged beside the content", not err and "addressed to AI agents" in snap, snap[:500])
err, text, structured = call("click", text="Contact support")
check("acting on a page with such text asks first", err and code(structured) == "approval_denied", (text, structured))

# --- handing over, errors, events
err, text, structured = call("request_human", reason="login", message="Sign in please", timeoutMs=600)
check("request_human waits for the person, then says so retryably", err and code(structured) == "needs_human" and structured["error"]["retryable"] is True, (text, structured))
err, text, structured = call("click", ref="e99999")
check("a missing element is a retryable structured error", err and structured.get("error", {}).get("retryable") is True, (text, structured))
next_id[0] += 1
status, reply = request("/mcp", {"jsonrpc": "2.0", "id": next_id[0], "method": "tools/call", "params": {"name": "navigate", "arguments": {"action": "sideways"}}})
check("invalid arguments carry their code", reply["result"]["isError"] and reply["result"]["structuredContent"]["error"]["code"] == "invalid_arguments", reply)
err, text, structured = call("session_events", afterId=0)
outcomes = [e["outcome"] for e in structured.get("events", [])]
check("session_events lists what happened, denials included", "denied" in outcomes and "ok" in outcomes and structured.get("lastEventId", 0) > 5, outcomes)
last = structured.get("lastEventId", 0)
err, text, structured = call("session_events", afterId=last)
check("session_events after the last id: only the newer ones", all(e["tool"] == "session_events" or e["id"] > last for e in structured.get("events", [])), structured)

if AGENT_DIR:
    logs = glob.glob(os.path.join(AGENT_DIR, "Logs", "*.jsonl"))
    lines = sum(len(open(f).read().splitlines()) for f in logs)
    text = "".join(open(f).read() for f in logs)
    check("every call is in the session's audit file", logs and lines >= 15, (logs, lines))
    check("the audit file keeps no card number", "4242 4242 4242 4242" not in text, "card number in log")

print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
