# End-to-end check of WebMCP (AR-9): a page registers tools through
# document.modelContext and an MCP client sees and calls them, namespaced by
# origin and marked untrusted. Run by scripts/test-webmcp.sh, which launches
# the app with --agent-webmcp --agent-approve all.
import json, sys, time, urllib.request, urllib.error, re, os
from urllib.parse import urlparse

PORT = int(os.environ.get("PORT", "9398"))
TOKEN = os.environ.get("TOKEN", "test-token-0123456789-abcdefghijklmnop")
SITE = os.environ.get("SITE", "http://127.0.0.1:8792")
URL = f"http://127.0.0.1:{PORT}/mcp"
SITE_PORT = urlparse(SITE).port
PREFIX = f"webmcp__127_0_0_1_{SITE_PORT}__"
session = None
failures = []
next_id = [0]

def post(message, token=TOKEN, headers=None):
    global session
    data = json.dumps(message).encode()
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if token: h["Authorization"] = "Bearer " + token
    if session: h["Mcp-Session-Id"] = session
    h.update(headers or {})
    req = urllib.request.Request(URL, data=data, headers=h, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            sid = r.headers.get("Mcp-Session-Id")
            if sid: session = sid
            body = r.read()
            return r.status, (json.loads(body) if body else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

def call_raw(_tool, **args):
    next_id[0] += 1
    status, reply = post({"jsonrpc": "2.0", "id": next_id[0], "method": "tools/call", "params": {"name": _tool, "arguments": args}})
    assert status == 200, (status, reply)
    result = reply["result"]
    text = "\n".join(c.get("text", "") for c in result["content"] if c["type"] == "text")
    return result.get("isError", False), text

def call(_tool, **args):
    err, text = call_raw(_tool, **args)
    text = re.sub(r'<untrusted-page-content[^>]*>\n', '', text).replace('\n</untrusted-page-content>', '')
    return err, text

def check(name, ok, detail=""):
    print(("✔ " if ok else "✘ ") + name + ("" if ok else f"\n    {str(detail)[:1500]}"))
    if not ok: failures.append(name)

def tool_names():
    next_id[0] += 1
    status, reply = post({"jsonrpc": "2.0", "id": next_id[0], "method": "tools/list"})
    return {t["name"]: t for t in reply["result"]["tools"]}

def wait_for(predicate, seconds=10):
    deadline = time.time() + seconds
    value = predicate()
    while not value and time.time() < deadline:
        time.sleep(0.25)
        value = predicate()
    return value

# --- handshake
status, reply = post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "webmcp-e2e", "version": "test"}}})
check("initialize", status == 200 and session, reply)
post({"jsonrpc": "2.0", "method": "notifications/initialized"})

# --- the page registers its tools
err, text = call("new_tab", url=SITE + "/webmcp.html")
check("new_tab opens the WebMCP fixture", not err and "WebMCP shop" in text, text)
listed = wait_for(lambda: (lambda r: r if "get_cart" in r[1] and "add_to_cart" in r[1] else None)(call("page_tools")))
err, text = listed or call("page_tools")
check("page_tools lists both tools, namespaced by origin", not err and PREFIX + "get_cart" in text and PREFIX + "add_to_cart" in text, text)
check("page_tools: get_cart is read-only, add_to_cart asks first",
      re.search(re.escape(PREFIX + "get_cart") + r".*read-only", text) and re.search(re.escape(PREFIX + "add_to_cart") + r".*asks first", text), text)
err, text = call("evaluate", expression="[window.webmcpAvailable, window.navigatorAlias, window.duplicateRefused]")
check("document.modelContext and navigator.modelContext are one object; a duplicate name is refused",
      "true" in text and text.count("true") >= 2 and "InvalidStateError" in text, text)
err, text = call("evaluate", expression="typeof window.__keelWebMCP + ' ' + typeof webkit?.messageHandlers?.keelWebMCP")
check("the relay and its message handler are out of the page's reach", "undefined undefined" in text, text)

# --- tools/list
tools = tool_names()
check("tools/list includes the page's tools", PREFIX + "get_cart" in tools and PREFIX + "add_to_cart" in tools, list(tools))
if PREFIX + "add_to_cart" in tools:
    t = tools[PREFIX + "add_to_cart"]
    check("the consequential tool is marked destructive and its description untrusted",
          t.get("annotations", {}).get("destructiveHint") is True and "untrusted" in t.get("description", ""), t)

# --- calling them
err, raw = call_raw("call_page_tool", name="get_cart")
check("call_page_tool get_cart returns untrusted page content",
      not err and "<untrusted-page-content" in raw and '"count":0' in raw.replace(" ", ""), raw)
err, raw = call_raw("call_page_tool", name=PREFIX + "add_to_cart", arguments={"sku": "kiwi", "quantity": 2})
check("call_page_tool add_to_cart runs (approved by --agent-approve all)", not err and "Added 2 × kiwi" in raw and "<untrusted-page-content" in raw, raw)
err, text = call("evaluate", expression="document.querySelector('#cart').textContent")
check("add_to_cart changed the page", "2× kiwi" in text, text)
err, raw = call_raw(PREFIX + "get_cart")
check("a webmcp__ tool is callable directly", not err and "kiwi" in raw and "<untrusted-page-content" in raw, raw)
err, text = call("call_page_tool", name="fails")
check("a tool that throws is a script error", err and "out of stock" in text, text)
err, text = call("call_page_tool", name="nope")
check("an unknown page tool is an error", err, text)

# --- navigating away takes the tools with it
err, text = call("navigate", url=SITE + "/page2.html")
check("navigate away", not err, text)
gone = wait_for(lambda: (lambda r: r if "No page" in r[1] else None)(call("page_tools")), 5)
err, text = gone or call("page_tools")
check("the tools are gone after navigating away", "No page in your tabs offers WebMCP tools" in text, text)
tools = tool_names()
check("tools/list no longer has them", not any(n.startswith("webmcp__") for n in tools), [n for n in tools if n.startswith("webmcp__")])
next_id[0] += 1
status, reply = post({"jsonrpc": "2.0", "id": next_id[0], "method": "tools/call", "params": {"name": PREFIX + "get_cart", "arguments": {}}})
check("calling a gone tool is an error", status == 200 and ("error" in reply or reply["result"].get("isError")), reply)

# --- back to the page registers them again; closing the tab drops them
err, text = call("navigate", url=SITE + "/webmcp.html")
listed = wait_for(lambda: (lambda r: r if "get_cart" in r[1] else None)(call("page_tools")))
check("a fresh load registers the tools again", listed is not None, listed)
err, text = call("list_tabs")
m = re.search(r"\* (\w+)", text)
if m:
    call("close_tab", tabId=m.group(1))
    tools = tool_names()
    check("closing the tab drops its tools", not any(n.startswith("webmcp__") for n in tools), [n for n in tools if n.startswith("webmcp__")])

print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
