# End-to-end check of the agent server: an MCP client driving the real app
# against the fixture site in this folder. Run by scripts/test-agent.sh.
import json, sys, time, urllib.request, urllib.error, base64, re, os, tempfile

PORT = int(os.environ.get("PORT", "9399"))
TOKEN = os.environ.get("TOKEN", "test-token-0123456789-abcdefghijklmnop")
SITE = os.environ.get("SITE", "http://127.0.0.1:8791")
URL = f"http://127.0.0.1:{PORT}/mcp"
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

def call(name, **args):
    next_id[0] += 1
    status, reply = post({"jsonrpc": "2.0", "id": next_id[0], "method": "tools/call", "params": {"name": name, "arguments": args}})
    assert status == 200, (status, reply)
    result = reply["result"]
    text = "\n".join(c.get("text", "") for c in result["content"] if c["type"] == "text")
    images = [c for c in result["content"] if c["type"] == "image"]
    return result.get("isError", False), text, images

def check(name, ok, detail=""):
    print(("✔ " if ok else "✘ ") + name + ("" if ok else f"\n    {str(detail)[:1500]}"))
    if not ok: failures.append(name)

def ref_for(snapshot, pattern):
    for line in snapshot.splitlines():
        if re.search(pattern, line):
            m = re.search(r"\[ref=(e\d+)\]", line)
            if m: return m.group(1)
    raise AssertionError(f"no ref for {pattern} in snapshot")

# --- access
status, _ = post({"jsonrpc": "2.0", "id": 0, "method": "ping"}, token=None)
check("no token is 401", status == 401, status)
status, _ = post({"jsonrpc": "2.0", "id": 0, "method": "ping"}, token="wrong")
check("wrong token is 401", status == 401, status)
status, _ = post({"jsonrpc": "2.0", "id": 0, "method": "ping"}, headers={"Origin": "https://evil.example"})
check("foreign origin is 403", status == 403, status)

# --- handshake
status, reply = post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "claude-code", "version": "test"}}})
check("initialize", status == 200 and reply["result"]["serverInfo"]["name"] == "simplebrowser" and session, reply)
status, _ = post({"jsonrpc": "2.0", "method": "notifications/initialized"})
check("initialized notification is 202", status == 202, status)
status, reply = post({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
names = [t["name"] for t in reply["result"]["tools"]]
check("tools/list", len(names) >= 25 and "snapshot" in names, names)

# --- tabs and navigation
err, text, _ = call("new_tab", url=SITE + "/")
check("new_tab loads the page", not err and "Agent fixture" in text, text)
tab = re.search(r"Opened tab (\w+)", text).group(1)
err, text, _ = call("list_tabs")
check("list_tabs marks the new tab", not err and f"* {tab}" in text, text)

err, snap, _ = call("snapshot")
check("snapshot has heading, link with url, form fields", not err and 'heading "Agent fixture" [level=1]' in snap and 'link "Second page"' in snap and "url=/page2.html" in snap and 'textbox "Email"' in snap and 'combobox' in snap, snap)
check("snapshot reaches shadow DOM and iframes", 'button "Shadow button"' in snap and 'button "Frame button"' in snap, snap)
check("snapshot leaves out hidden elements", "Invisible" not in snap, snap)
check("snapshot finds the clickable div", 'generic' in snap and "Fake button div" in snap, snap)
err, small, _ = call("snapshot", interactiveOnly=True)
check("interactiveOnly is smaller", not err and len(small) < len(snap) and "paragraph" not in small, small)

# --- acting
email = ref_for(snap, r'textbox "Email"')
err, text, _ = call("fill", ref=email, value="agent@example.com")
check("fill", not err and "agent@example.com" in text, text)
err, text, _ = call("fill_form", fields=[{"selector": "#name", "value": "Ada"}, {"selector": "#plan", "value": "Pro"}, {"selector": "#terms", "value": "true"}])
check("fill_form fills text, select and checkbox", not err and text.count("✓") == 3, text)
err, text, _ = call("evaluate", expression="[document.querySelector('#plan').value, document.querySelector('#terms').checked, document.querySelector('#name').value]")
check("fill_form took effect", '"pro"' in text and "true" in text and '"Ada"' in text, text)
signup = ref_for(snap, r'button "Sign up"')
err, text, _ = call("click", ref=signup)
check("click submits", not err, text)
err, text, _ = call("wait_for", text="Submitted agent@example.com / pro / true")
check("wait_for text after submit", not err, text)

cta = ref_for(snap, r'button "Call to action"')
err, text, _ = call("click", ref=cta)
check("click reports new console errors and failed requests", not err and "cta failure" in text, text)
err, text, _ = call("evaluate", expression="window.lastClickTrusted")
check("clicks are trusted", text.strip() == "true", text)

err, text, _ = call("click", selector="#covered")
check("click refuses a covered element and names the cover", err and "covered by" in text, text)

err, text, _ = call("click", selector="my-widget >>> nothing")
check("bad selector is an error", err, text)
shadow = ref_for(snap, r'button "Shadow button"')
err, text, _ = call("click", ref=shadow)
check("click inside shadow DOM", not err, text)
frame_button = ref_for(snap, r'button "Frame button"')
err, text, _ = call("click", ref=frame_button)
err2, text2, _ = call("evaluate", expression="document.querySelector('iframe').contentDocument.querySelector('button').textContent")
check("click inside a same-origin iframe", not err and "frame clicked" in text2, (text, text2))

err, text, _ = call("type_text", selector="#notes", text="Hello World\nline two")
err2, text2, _ = call("evaluate", expression="document.querySelector('#notes').value")
check("type_text types real keys", not err and "Hello World\\nline two" in text2, (text, text2))
err, text, _ = call("click", selector="#keys")
err, text, _ = call("press_key", key="ArrowDown")
err, text, _ = call("press_key", key="Shift+A")
err2, text2, _ = call("evaluate", expression="document.querySelector('#keys').textContent")
check("press_key sends trusted keys", "ArrowDown" in text2 and "A" in text2 and "untrusted" not in text2, text2)
err, text, _ = call("evaluate", expression="document.querySelector('#name').focus()")
err, text, _ = call("press_key", key="Meta+A")
err, text, _ = call("press_key", key="Backspace")
err2, text2, _ = call("evaluate", expression="document.querySelector('#name').value")
check("Meta+A selects all", text2.strip() == '""', text2)
err, text, _ = call("type_text", selector="#name", text="Ada", clear=True)
err, text, _ = call("type_text", selector="#name", text="Lovelace", clear=True)
err2, text2, _ = call("evaluate", expression="document.querySelector('#name').value")
check("type_text clear replaces", text2.strip() == '"Lovelace"', text2)

err, text, _ = call("upload_files", selector="#upload", paths=[os.path.join(os.path.dirname(os.path.abspath(__file__)), "upload.txt")])
err2, text2, _ = call("evaluate", expression="(async () => { const f = document.querySelector('#upload').files[0]; return [f.name, await f.text()]; })()")
check("upload_files", not err and "upload.txt" in text2 and "hello upload" in text2, (text, text2))

err, text, _ = call("hover", selector="#cta")
check("hover", not err, text)
err, text, _ = call("scroll", direction="bottom")
check("scroll to bottom", not err and "Scrolled" in text, text)
err, text, _ = call("scroll", selector="h1")
check("scroll to element", not err, text)

# --- dialogs
err, text, _ = call("click", selector="#ask")
check("a confirm() is reported", "confirm() dialog" in text, text)
err, text, _ = call("evaluate", expression="1+1")
check("tools say a dialog is blocking", err and "handle_dialog" in text, text)
err, text, _ = call("handle_dialog", accept=False)
check("handle_dialog answers", not err, text)
time.sleep(0.3)
err, text, _ = call("evaluate", expression="document.querySelector('#answer').textContent")
check("the page got Cancel", '"no"' in text, text)

# --- debugging
err, text, _ = call("evaluate", expression="(el) => el.getBoundingClientRect().width > 0", selector="#cta")
check("evaluate with an element", text.strip() == "true", text)
err, text, _ = call("evaluate", expression="const a = 2; return a * 21")
check("evaluate statements", text.strip() == "42", text)
err, text, _ = call("evaluate", expression="await new Promise(r => setTimeout(() => r({ok: true, when: new Map([['a', 1]])}), 50))")
check("evaluate awaits and serializes maps", '"ok": true' in text and '"a": 1' in text, text)
err, text, _ = call("evaluate", expression="throw new Error('boom')")
check("evaluate reports exceptions", err and "boom" in text, text)
err, text, _ = call("evaluate", expression="typeof window.__sbAutomation", world="isolated")
check("isolated world sees the agent", '"object"' in text, text)
err, text, _ = call("evaluate", expression="typeof window.__sbAutomation")
check("page world cannot see the agent", '"undefined"' in text, text)

err, text, _ = call("console_messages")
check("console_messages", not err and "fixture loaded" in text and "[error]" in text and "cta failure" in text, text)
last = int(re.findall(r"#(\d+) ", text)[-1])
err, text, _ = call("console_messages", level="error")
check("console level filter", "fixture loaded" not in text and "cta failure" in text, text)
err, text, _ = call("console_messages", afterId=last)
check("console afterId", "fixture loaded" not in text, text)

err, text, _ = call("network_requests")
check("network_requests", not err and "data.json" in text and "missing.json" in text, text)
data_id = [l.split()[0] for l in text.splitlines() if "data.json" in l][0]
err, text, _ = call("network_requests", failedOnly=True)
check("failedOnly", "missing.json" in text and "data.json" not in text, text)
err, text, _ = call("network_request", id=data_id)
check("network_request has the body", not err and '"items"' in text, text)

err, text, _ = call("inspect_element", selector="#cta")
check("inspect_element: computed and matched rules", not err and "background-color: rgb(10, 100, 200)" in text and "#cta" in text and "font-size: 18px" in text, text)
err, text, _ = call("performance_metrics")
check("performance_metrics", not err and "Navigation:" in text and "Resources:" in text, text)
err, text, _ = call("storage", area="local")
check("storage local", "fixture = yes" in text, text)
err, text, _ = call("storage", area="cookies", action="set", key="sb_test", value="1")
err, text, _ = call("storage", area="cookies")
check("cookies set and read", "sb_test=1" in text, text)

err, text, _ = call("get_page_content")
check("markdown content", not err and "# Agent fixture" in text and "[link](http" in text and "| Name | Qty |" in text and "- Two" in text and "  - Two point one" in text, text)

err, text, images = call("screenshot")
check("screenshot viewport", not err and images and base64.b64decode(images[0]["data"])[:4] == b"\x89PNG", text)
err, text, images = call("screenshot", selector="#cta", format="jpeg")
check("screenshot element jpeg", not err and images and images[0]["mimeType"] == "image/jpeg", text)
err, text, images = call("screenshot", fullPage=True, format="jpeg", savePath=os.path.join(tempfile.gettempdir(), "sb-agent-full.jpg"))
check("screenshot full page", not err and images and os.path.exists(os.path.join(tempfile.gettempdir(), "sb-agent-full.jpg")), text)

err, text, _ = call("emulate", device="iPhone SE")
check("emulate", not err and "375" in text, text)
err, text, _ = call("evaluate", expression="[innerWidth, navigator.userAgent.includes('iPhone')]")
check("emulated viewport and UA", "375" in text and "true" in text, text)
err, text, _ = call("emulate", reset=True)

err, text, _ = call("devtools", selector="#cta")
check("devtools opens on the element", not err and "selected" in text, text)
err, text, _ = call("devtools", action="close")

# --- targeting by text, and snapshot diffs
err, text, _ = call("click", text="Call to action")
check("click by visible text", not err and "Call to action" in text, text)
err, text, _ = call("click", text="Sign up", role="button")
check("click by text and role", not err and 'button "Sign up"' in text, text)
err, text, _ = call("click", text="No such words anywhere")
check("missing text is explained", err and "snapshot" in text.lower(), text)
err, base, _ = call("snapshot", diff=True)
call("evaluate", expression="document.querySelector('#result').textContent = 'Changed by the test'")
err, text, _ = call("snapshot", diff=True)
check("snapshot diff shows only what changed", not err and "+ " in text and "Changed by the test" in text and "Agent fixture" not in text.split("```diff")[-1], text)
err, text, _ = call("snapshot", diff=True)
check("snapshot diff with no change says so", "No changes" in text, text)

# --- DevTools-backed tools
err, text, _ = call("diagnose")
check("diagnose summarises errors, failures and audits", not err and "**Summary:**" in text and "console error" in text and "missing.json" in text and "audit scores" in text, text)
err, text, _ = call("run_audit", categories=["accessibility"])
check("run_audit lists failures with selectors", not err and "Accessibility —" in text and "#noalt" in text, text)
err, text, _ = call("run_audit", categories=["seo", "performance"])
check("run_audit seo and performance", not err and "SEO" in text and "## Performance" in text, text)

err, text, _ = call("application_data", kind="manifest")
check("application_data manifest", not err and "Agent Fixture" in text, text)
err, text, _ = call("application_data", kind="indexeddb")
check("application_data indexeddb databases", not err and "fixture-db" in text, text)
err, text, _ = call("application_data", kind="indexeddb", database="fixture-db", store="todos")
check("application_data indexeddb records", not err and "Write tests" in text, text)

err, text, _ = call("heap_snapshot")
check("heap_snapshot by class", not err and "objects" in text and "Class" in text, text)
call("click", selector="#cta")
err, text, _ = call("heap_snapshot", compare=True, filter="Leaky")
check("heap_snapshot compare shows growth", not err and "LeakyThing" in text and "+5000" in text, text)

err, text, _ = call("mock_network", action="block", pattern="*data.json", reload=True)
err2, text2, _ = call("network_requests", filter="data.json")
check("mock_network block", not err and "data.json" in text and ("failed" in text2 or "blocked" in text2.lower()), (text, text2))
call("mock_network", action="clear")
err, text, _ = call("mock_network", action="override", pattern=SITE + "/data.json", body='{"items":[1,2,3,4,5,6,7]}', reload=True)
if "inspector protocol" in text:
    print("– mock_network override: inspector protocol unavailable in this build, skipped")
else:
    time.sleep(0.5)
    err2, text2, _ = call("console_messages", search="data")
    check("mock_network override serves the mock", not err and "data 7" in text2, (text, text2))
err, text, _ = call("mock_network", action="clear", reload=True)
check("mock_network clear", not err and "Blocked: nothing" in text and "Overrides: none" in text, text)

err, text, _ = call("emulate", colorScheme="dark")
err2, text2, _ = call("evaluate", expression="[matchMedia('(prefers-color-scheme: dark)').matches, getComputedStyle(document.body).backgroundColor]")
check("emulate dark mode", not err and "true" in text2 and "rgb(1, 2, 3)" in text2, (text, text2))
err, text, _ = call("emulate", reset=True)
err2, text2, _ = call("evaluate", expression="getComputedStyle(document.body).backgroundColor")
check("emulate reset", not err and "rgb(1, 2, 3)" not in text2, (text, text2))

err, text, _ = call("devtools", selector="#cta")
time.sleep(0.5)
err, text, _ = call("devtools_selection")
check("devtools_selection returns the selected element", not err and "#cta" in text and "Computed styles" in text, text)
call("devtools", action="close")
err, text, _ = call("devtools_selection")
check("devtools_selection when closed explains", "not open" in text, text)

# --- navigation
err, snap, _ = call("snapshot")
link = ref_for(snap, r'link "Second page"')
err, text, _ = call("click", ref=link)
check("click a link navigates and reports it", "Navigated" in text and "Second page" in text and "HTTP 200" in text, text)
err, text, _ = call("click", ref=link)
check("stale refs after navigation are explained", err and "snapshot" in text.lower(), text)
err, text, _ = call("navigate", action="back")
check("navigate back", not err and "Agent fixture" in text, text)
err, text, _ = call("navigate", url=SITE + "/nope.html")
check("navigate reports 404", "HTTP 404" in text, text)
err, text, _ = call("navigate", action="sideways")
check("bad enum is an error", err, text)

err, text, _ = call("close_tab", tabId=tab)
check("close_tab", not err, text)

# --- the first tab, whose DevTools' Agent panel scripts/test-agent.sh watches
err, text, _ = call("list_tabs")
first = [l for l in text.splitlines() if "Second page" in l]
if first:
    first_id = first[0].split()[1] if first[0].startswith("*") else first[0].split()[0]
    call("select_tab", tabId=first_id)
    call("snapshot")
    call("click", text="This text is not on the page")
    err, text, _ = call("get_page_content")
    check("acting in the first tab", not err and "You made it" in text, text)

print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
