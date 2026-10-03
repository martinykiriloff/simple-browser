// Drives every DevTools panel from inside the DevTools UI and returns a
// report. There is no XCTest on a Command Line Tools-only Mac, so this is
// the DevTools test suite:
//
//   python3 Tests/Fixtures/devtools/server.py &
//   swift run Keel --show-devtools \
//     --devtools-script Tests/Fixtures/devtools/drive-all.js \
//     --devtools-out /tmp/devtools-report.json --devtools-delay 4 http://127.0.0.1:8765/
//
// The body runs as an async function inside the DevTools web view.
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const out = { failures: [] };
const check = (name, ok, detail) => { out.checks = (out.checks || 0) + 1; if (!ok) out.failures.push(name + (detail !== undefined ? ": " + JSON.stringify(detail) : "")); };
try {
  // ---- Elements ---------------------------------------------------------------
  DevTools.showPanel("elements"); await wait(600);
  const el = DevTools.panels.elements;
  out.elements = { lines: document.querySelectorAll("#dom-tree .node-line").length, breadcrumbs: document.querySelector("#breadcrumbs").textContent };
  check("tree shows body children", out.elements.lines >= 12, out.elements.lines);
  check("body selected by default", out.elements.breadcrumbs === "htmlbody", out.elements.breadcrumbs);
  const h1Id = Array.from(el.nodes.values()).find((n) => n.nodeName === "h1")?.nodeId;
  check("h1 is in the tree", !!h1Id);
  if (h1Id) {
    el.select(h1Id); await wait(500);
    const sections = Array.from(document.querySelectorAll("#styles-list .styles-section")).map((s) => s.querySelector(".styles-selector").textContent.trim());
    const overridden = Array.from(document.querySelectorAll("#styles-list .styles-prop.overridden")).map((p) => p.textContent.trim());
    out.h1 = { sections, overridden };
    check("cascade order", sections.slice(0, 2).join() === "element.style {,.hero.big {", sections);
    check("overridden declarations struck", overridden.includes("font-size: 15px;"), overridden);
    check("inherited section", !!document.querySelector("#styles-list .inherited-header"));
    await DevTools.rpc("CSS.updateStyle", { nodeId: h1Id, edits: [{ name: "color", value: "red" }] });
    await wait(300);
    const computed = await DevTools.rpc("CSS.getComputedStyle", { nodeId: h1Id });
    check("live style edit applies", computed.find((c) => c[0] === "color")?.[1] === "rgb(255, 0, 0)");
    check("tree survives a style edit", document.querySelectorAll("#dom-tree .node-line").length >= 12);
    const box = await DevTools.rpc("DOM.getBoxModel", { nodeId: h1Id });
    check("box model", box.padding.left === 20 && box.border.left === 2, box);
    await DevTools.rpc("Overlay.highlightNode", { nodeId: h1Id });
    const search = await DevTools.rpc("DOM.performSearch", { query: "generated" });
    check("search finds generated nodes", search.nodeIds.length >= 5, search.nodeIds.length);
    await DevTools.rpc("Overlay.hideHighlight");
  }

  // ---- Console -----------------------------------------------------------------
  DevTools.showPanel("console"); await wait(400);
  out.console = { messages: document.querySelectorAll("#console-messages .console-message").length, badges: document.getElementById("badges").textContent };
  check("console has the page's messages", out.console.messages >= 10, out.console.messages);
  check("repeat counter", document.querySelector("#console-messages .repeat")?.textContent === "3");
  const errorLocation = Array.from(document.querySelectorAll("#console-messages .console-message.level-error")).find((m) => m.textContent.includes("boom from console.error"))?.querySelector(".location")?.textContent;
  check("console locations point at page code, not at our hooks", /^127\.0\.0\.1:8765:\d+$/.test(errorLocation || ""), errorLocation);
  check("group nesting", !!document.querySelector("#console-messages .console-group .console-message"));
  const table = document.querySelector("#console-messages .console-table");
  check("console.table renders", !!table && table.querySelectorAll("tbody tr").length === 2 && table.querySelectorAll("th").length === 4);
  check("uncaught rejection message", Array.from(document.querySelectorAll(".console-message.level-error .body")).some((b) => b.textContent.includes("Uncaught (in promise) Error: unhandled rejection sample")));
  const ev = await DevTools.rpc("Console.evaluate", { expression: "({a:1, b:[1,2,3], el: document.body, f(){}, s:'str'})" });
  check("evaluate returns an object", ev?.result?.description === "Object", ev);
  const props = await DevTools.rpc("Runtime.getProperties", { objectId: ev.result.objectId });
  check("lazy properties", props.map((p) => p.name).join() === "a,b,el,f,s,[[Prototype]]", props.map((p) => p.name));
  const awaited = await DevTools.rpc("Console.evaluate", { expression: "await new Promise(r => setTimeout(() => r('async ok'), 50))" });
  check("top-level await", awaited?.result?.description === "async ok", awaited);
  const dollar = await DevTools.rpc("Console.evaluate", { expression: "$0 && $0.tagName" });
  check("$0 is the selected element", dollar?.result?.description === "H1", dollar);
  const err = await DevTools.rpc("Console.evaluate", { expression: "nope.x" });
  check("evaluation errors surface", /ReferenceError/.test(err?.exceptionDetails?.text || ""), err);
  const comp = await DevTools.rpc("Runtime.getCompletions", { expression: "document.que" });
  check("completions", comp.names.includes("querySelector"), comp.names.slice(0, 5));

  // ---- Network ------------------------------------------------------------------
  DevTools.showPanel("network"); await wait(500);
  const requests = Array.from(DevTools.panels.network.requests.values());
  out.network = { status: document.querySelector("#network-status").textContent,
                  rows: Array.from(document.querySelectorAll("#network-table tbody tr")).map((r) => Array.from(r.children).slice(0, 4).map((c) => c.textContent).join(" | ")) };
  // The WebSocket is only visible to the inspector protocol, which may or may not have attached before it opened.
  // WebKit's hidden frontend may fetch the source map too, once attached.
  check("eight HTTP requests, merged", requests.filter((r) => r.resourceType !== "websocket" && !r.url.endsWith(".map")).length === 8, out.network.rows);
  const doc = requests.find((r) => r.resourceType === "document");
  check("document has status and headers from the navigation response", doc && doc.statusCode === 200 && doc.sources.includes("navigationDelegate") && doc.sources.includes("agent") && !!doc.responseHeaders["x-served-by"], doc && { s: doc.statusCode, src: doc.sources });
  const fetched = requests.find((r) => r.url.endsWith("/api/data.json"));
  check("fetch merged from both agents with a body", fetched && fetched.sources.length === 2 && /"ok": true/.test(fetched.responseBody || ""), fetched && fetched.sources);
  check("POST payload captured", requests.some((r) => r.method === "POST" && r.statusCode === 201 && r.requestBody === '{"hello":"world"}'));
  check("404 is a failure row", !!document.querySelector("#network-table tbody tr.failed"));
  const row = Array.from(document.querySelectorAll("#network-table tbody tr")).find((r) => r.textContent.includes("data.json") && r.textContent.includes("200"));
  if (row) {
    row.click(); await wait(300);
    check("headers pane", document.querySelector("#network-detail-body").textContent.includes("Response Headers"));
    document.querySelector('#network-detail-tabs [data-subpanel="preview"]').click(); await wait(200);
    check("JSON preview tree", document.querySelector("#network-detail-body").textContent.includes("items"));
    document.querySelector('#network-detail-tabs [data-subpanel="timing"]').click(); await wait(200);
    check("timing pane", document.querySelector("#network-detail-body").textContent.includes("Waiting for server response"));
  }
  const png = Array.from(document.querySelectorAll("#network-table tbody tr")).find((r) => r.textContent.includes("pixel.png"));
  if (png) {
    png.click(); await wait(200);
    document.querySelector('#network-detail-tabs [data-subpanel="response"]').click(); await wait(200);
    document.querySelector("#network-detail-body button")?.click(); await wait(1500);
    check("image body re-fetch", !!document.querySelector("#network-detail-body img"));
  }

  // ---- Sources ---------------------------------------------------------------------
  DevTools.showPanel("sources"); await wait(600);
  const s = DevTools.panels.sources;
  check("navigator lists files", document.querySelectorAll("#sources-tree .nav-item.file").length >= 5);
  await s.open(new URL("/script.js", DevTools.info.url).href); await wait(700);
  const before = document.querySelectorAll("#sources-code .code-line").length;
  check("script is highlighted", document.querySelectorAll("#sources-code .tok-keyword").length >= 3);
  document.querySelector("#sources-pretty").click(); await wait(300);
  const after = document.querySelectorAll("#sources-code .code-line").length;
  check("pretty print expands minified code", after > before, { before, after });
  await s.open(DevTools.info.url); await wait(800);
  check("document source is the original bytes, not the live DOM", !document.querySelector("#sources-code").textContent.includes("generated 0") || !SBDebugger.available);
  check("HTML with embedded CSS and JS is highlighted",
        document.querySelectorAll("#sources-code .tok-tag").length > 10 && document.querySelectorAll("#sources-code .tok-prop").length > 3 && document.querySelectorAll("#sources-code .tok-keyword").length > 5);

  // ---- Debugger ----------------------------------------------------------------------
  const dbg = SBDebugger;
  for (let i = 0; i < 80 && !dbg.available; i++) await wait(100);
  check("debugger attached", dbg.available, document.querySelector("#debugger-note").textContent);
  if (dbg.available) {
    const scriptURL = new URL("/script.js", DevTools.info.url).href;
    for (const bp of dbg.breakpoints.slice()) await dbg.toggle(bp.url, bp.line);      // start clean
    await s.open(scriptURL); await wait(500);
    if (s.files.get(scriptURL).pretty) { document.querySelector("#sources-pretty").click(); await wait(300); }
    await dbg.toggle(scriptURL, 2);
    check("breakpoint installed", dbg.breakpoints.length === 1 && !!dbg.breakpoints[0].id, dbg.breakpoints);
    check("gutter marker", !!document.querySelector('#sources-code .code-line.breakpoint[data-line="2"]'));
    check("breakpoint listed", document.querySelector("#dbg-breakpoints").textContent.includes("script.js:2"));
    // Trigger through the protocol from a timer, so nothing awaits the frozen page.
    await dbg.send("Runtime.evaluate", { expression: "setTimeout(function caller() { var local = 41; greet('Ada'); }, 0); 1" });
    for (let i = 0; i < 50 && !dbg.paused; i++) await wait(100);
    await wait(700);
    check("paused on breakpoint", dbg.paused && /breakpoint/i.test(document.querySelector("#dbg-banner").textContent), document.querySelector("#dbg-banner").textContent);
    check("call stack", dbg.frames.length >= 2 && dbg.frames[0].functionName === "greet" && dbg.frames[1].functionName === "caller", dbg.frames.map((f) => f.functionName + ":" + f.line));
    check("execution line marked", !!document.querySelector('#sources-code .code-line.exec[data-line="2"]'));
    check("stepping enabled", !document.querySelector("#dbg-step-over").disabled);
    out.scope = document.querySelector("#dbg-scope").textContent.slice(0, 200);
    check("scope shows the argument", /name: "Ada"/.test(out.scope), out.scope);
    const state = await DevTools.rpc("Protocol.state");
    check("WebKit's own inspector window stayed hidden", state.paused === true && state.webkitInspectorVisible === false, state);
    await DevTools.rpc("Console.evaluate", { expression: "name + '!'", callFrameId: dbg.currentCallFrameId() }); await wait(400);
    const results = Array.from(document.querySelectorAll("#console-messages .console-message.type-result .body"));
    check("console evaluates in the paused frame", results.length && results[results.length - 1].textContent.includes("Ada!"), results.length && results[results.length - 1].textContent);
    let failedFast = false;
    try { await DevTools.rpc("DOM.getDocument", { depth: 1 }); } catch (e) { failedFast = /paused/i.test(e.message); }
    check("page calls fail fast while paused instead of hanging", failedFast);
    await dbg.selectFrame(1); await wait(700);
    const callerScope = document.querySelector("#dbg-scope").textContent;
    check("caller frame scope", /local: 41/.test(callerScope), callerScope.slice(0, 160));
    dbg.step("stepOut");
    for (let i = 0; i < 40 && !(dbg.paused && dbg.frames[0] && dbg.frames[0].functionName === "caller"); i++) await wait(100);
    check("step out lands in the caller", dbg.paused && dbg.frames[0] && dbg.frames[0].functionName === "caller", dbg.frames.map((f) => f.functionName + ":" + f.line));
    await dbg.send("Debugger.resume");
    for (let i = 0; i < 40 && dbg.paused; i++) await wait(100);
    check("resumed", !dbg.paused && document.querySelector("#dbg-banner").hidden);
    const alive = await DevTools.rpc("DOM.getDocument", { depth: 1 }).then(() => true, () => false);
    check("page is live again after resume", alive);
    await dbg.toggle(scriptURL, 2);
    check("breakpoint removed", dbg.breakpoints.length === 0 && !document.querySelector("#sources-code .code-line.breakpoint"));
    // Conditional breakpoint: pauses for Bob only.
    await s.open(scriptURL); await wait(400);
    await dbg.setBreakpoint(scriptURL, 2, { condition: "name === 'Bob'" });
    check("conditional marker", !!document.querySelector('#sources-code .code-line.breakpoint.conditional[data-line="2"]'));
    await dbg.send("Runtime.evaluate", { expression: "setTimeout(function () { greet('Ada'); }, 0); 1" });
    await wait(900);
    check("a false condition does not pause", !dbg.paused);
    await dbg.send("Runtime.evaluate", { expression: "setTimeout(function () { greet('Bob'); }, 0); 1" });
    for (let i = 0; i < 50 && !dbg.paused; i++) await wait(100);
    check("a true condition pauses", dbg.paused && dbg.frames[0] && dbg.frames[0].functionName === "greet", dbg.frames.map((f) => f.functionName));
    await dbg.send("Debugger.resume");
    for (let i = 0; i < 40 && dbg.paused; i++) await wait(100);
    // Logpoint: never pauses, logs through the normal console pipeline.
    await dbg.setBreakpoint(scriptURL, 2, { condition: "", logMessage: "'greeting', name" });
    check("logpoint marker", !!document.querySelector('#sources-code .code-line.breakpoint.logpoint[data-line="2"]'));
    await dbg.send("Runtime.evaluate", { expression: "setTimeout(function () { greet('Zed'); }, 0); 1" });
    await wait(1200);
    check("a logpoint does not pause", !dbg.paused);
    check("a logpoint logs to the console", Array.from(document.querySelectorAll("#console-messages .console-message .body")).some((b) => b.textContent.includes("greeting Zed")));
    await dbg.toggle(scriptURL, 2);
    check("logpoint removed", dbg.breakpoints.length === 0);

    // Source maps: bundle.js is one minified line mapped back to src/cart.js.
    const bundleURL = new URL("/bundle.js", DevTools.info.url).href;
    const cartURL = new URL("/src/cart.js", DevTools.info.url).href;
    for (let i = 0; i < 50 && !SBSourceMaps.maps.has(bundleURL); i++) await wait(100);
    check("source map loaded for the bundle", SBSourceMaps.maps.has(bundleURL), Array.from(SBSourceMaps.maps.keys()));
    check("original file is in the navigator", s.files.has(cartURL) && document.querySelector("#sources-tree").textContent.includes("cart.js"));
    await s.open(cartURL); await wait(500);
    check("original source is shown", document.querySelector("#sources-code").textContent.includes("function cartTotal(items)") && document.querySelectorAll("#sources-code .code-line").length >= 13);
    await dbg.toggle(cartURL, 4);          // `total += ...` inside the loop
    const mappedBp = dbg.breakpoints.find((b) => b.url === cartURL);
    check("breakpoint in the original is placed in the bundle", mappedBp && mappedBp.id && mappedBp.target && mappedBp.target.url === bundleURL && mappedBp.target.lineNumber === 1 && mappedBp.target.columnNumber > 50, mappedBp && mappedBp.target);
    await dbg.send("Runtime.evaluate", { expression: "setTimeout(function () { checkout([{ price: 2, qty: 3 }]); }, 0); 1" });
    for (let i = 0; i < 50 && !dbg.paused; i++) await wait(100);
    await wait(600);
    check("pause is reported at the original location", dbg.paused && dbg.frames[0] && dbg.frames[0].functionName === "cartTotal" && dbg.frames[0].url === cartURL && dbg.frames[0].line === 4, dbg.frames.map((f) => f.functionName + " " + fileName(f.url) + ":" + f.line));
    check("caller frame is mapped too", dbg.frames[1] && dbg.frames[1].url === cartURL && dbg.frames[1].line === 9, dbg.frames.slice(0, 3).map((f) => fileName(f.url) + ":" + f.line));
    check("execution line is marked in the original file", !!document.querySelector('#sources-code .code-line.exec[data-line="4"]') && s.current === cartURL);
    check("call stack shows original file names", document.querySelector("#dbg-stack").textContent.includes("cart.js:4"));
    await dbg.toggle(cartURL, 4);
    await dbg.send("Debugger.resume");
    for (let i = 0; i < 40 && dbg.paused; i++) await wait(100);
    await wait(500);
    const traced = Array.from(document.querySelectorAll("#console-messages .console-message")).find((m) => m.textContent.includes("checkout total"));
    check("console locations are mapped to the original", traced && traced.querySelector(".location") && traced.querySelector(".location").textContent === "cart.js:10", traced && traced.querySelector(".location")?.textContent);

    // A debugger statement pauses too, in a script with no URL.
    await dbg.send("Runtime.evaluate", { expression: "setTimeout(function viaStatement() { var reason = 'statement'; debugger; }, 0); 1" });
    for (let i = 0; i < 50 && !dbg.paused; i++) await wait(100);
    await wait(600);
    check("debugger statement pauses", dbg.paused && /debugger statement/i.test(document.querySelector("#dbg-banner").textContent), document.querySelector("#dbg-banner").textContent);
    check("anonymous script source is shown", document.querySelector("#sources-code").textContent.includes("viaStatement"));
    await dbg.send("Debugger.resume");
    for (let i = 0; i < 40 && dbg.paused; i++) await wait(100);
    check("resumed again", !dbg.paused);
  }

  // ---- Event listeners, forced state, DOM / XHR / event breakpoints ---------------------------
  if (SBDebugger.available) {
    const dbg = SBDebugger;
    const banner = () => document.querySelector("#dbg-banner").textContent;
    // Triggers run from a timer: a synchronous pause would hold the evaluate itself.
    const pauseBy = async (expression) => {
      await dbg.send("Runtime.evaluate", { expression: "setTimeout(() => { " + expression + " }, 0); 1" });
      for (let i = 0; i < 40 && !dbg.paused; i++) await wait(100);
      await wait(500);
      return dbg.paused;
    };
    const resume = async () => {
      for (let n = 0; n < 4 && dbg.paused; n++) { await dbg.send("Debugger.resume").catch(() => {}); for (let i = 0; i < 20 && dbg.paused; i++) await wait(100); await wait(200); }
      return !dbg.paused;
    };
    const pageValue = async (expression) => (await DevTools.rpc("Console.evaluate", { expression }))?.result?.description;

    DevTools.showPanel("elements"); await wait(400);
    const button = Array.from(el.nodes.values()).find((n) => n.nodeName === "button")?.nodeId;
    check("the button is in the tree", !!button);
    el.select(button); await wait(300);

    // Event Listeners tab
    document.querySelector('#styles-tabs [data-subpanel="listeners"]').click(); await wait(1500);
    const listenerRows = () => Array.from(document.querySelectorAll("#listeners-list .listener-group")).map((g) => ({
      type: g.dataset.type,
      rows: Array.from(g.querySelectorAll(".listener-row")).map((r) => r.querySelector(".target").textContent + " " + r.querySelector(".handler").textContent + (r.querySelector(".flags")?.textContent || "") + " @" + (r.querySelector(".location")?.textContent || "")),
    }));
    out.listeners = listenerRows();
    const types = out.listeners.map((g) => g.type);
    check("listeners are grouped by event type", types.join() === "click,mouseenter,resize", types);
    check("our own agents' listeners are not shown", !types.some((t) => /^__sb|^error$/.test(t)), types);
    const clickRows = out.listeners.find((g) => g.type === "click")?.rows || [];
    check("both click listeners, with target, handler and flags", clickRows.length === 2 && clickRows.some((r) => /^button#action onActionClick\(\)/.test(r)) && clickRows.some((r) => /attribute/.test(r)), clickRows);
    check("listener links to its source line", clickRows.some((r) => /onActionClick.*@127\.0\.0\.1:8765:\d+$/.test(r)), clickRows);
    check("passive flag", /passive/.test((out.listeners.find((g) => g.type === "mouseenter")?.rows || [])[0] || ""));
    check("window listeners are attributed to the window", /^window onResize\(\)/.test((out.listeners.find((g) => g.type === "resize")?.rows || [])[0] || ""));
    document.querySelector("#listeners-ancestors").click(); await wait(1200);
    check("without Ancestors only the node's own listeners remain", listenerRows().map((g) => g.type).join() === "click,mouseenter", listenerRows().map((g) => g.type));
    document.querySelector("#listeners-ancestors").click(); await wait(1200);

    // Disabling a listener really stops it.
    const clicksBefore = +(await pageValue("document.getElementById('action').click(); window.__clicks"));
    // The click changes an attribute, which re-renders the list: find the box afresh each time.
    const handlerBox = () => Array.from(document.querySelectorAll("#listeners-list .listener-row")).find((r) => r.textContent.includes("onActionClick"))?.querySelector("input");
    await wait(1500);
    handlerBox().click(); await wait(500);
    const clicksDisabled = +(await pageValue("document.getElementById('action').click(); window.__clicks"));
    check("a disabled listener is shown struck through", !!handlerBox()?.closest(".listener-row.off"));
    handlerBox().click(); await wait(500);
    const clicksEnabled = +(await pageValue("document.getElementById('action').click(); window.__clicks"));
    check("a disabled listener does not run, and runs again when re-enabled", clicksDisabled === clicksBefore && clicksEnabled === clicksBefore + 1, [clicksBefore, clicksDisabled, clicksEnabled]);

    // :hov
    document.querySelector('#styles-tabs [data-subpanel="styles"]').click(); await wait(400);
    const selectors = () => Array.from(document.querySelectorAll("#styles-list .styles-selector")).map((s) => s.textContent.trim());
    check("no :hover rule before forcing", !selectors().some((s) => s.includes(":hover")), selectors());
    document.querySelector("#styles-hov").click();
    const hoverBox = document.querySelector('#styles-hov-grid input[data-pseudo="hover"]');
    hoverBox.click(); await wait(900);
    const forcedColor = (await DevTools.rpc("CSS.getComputedStyle", { nodeId: button })).find((c) => c[0] === "color")?.[1];
    check("forcing :hover applies the :hover rule", forcedColor === "rgb(200, 0, 0)" && selectors().some((s) => s.includes(".act:hover")), { forcedColor, selectors: selectors() });
    hoverBox.click(); await wait(900);
    const unforcedColor = (await DevTools.rpc("CSS.getComputedStyle", { nodeId: button })).find((c) => c[0] === "color")?.[1];
    check("un-forcing removes it", unforcedColor !== "rgb(200, 0, 0)" && !selectors().some((s) => s.includes(":hover")), unforcedColor);
    document.querySelector("#styles-hov").click();

    // DOM breakpoint, from the node's context menu
    await el.breakOnItems(button).find((i) => /attribute/.test(i.label)).action(); await wait(600);
    check("DOM breakpoint is listed", document.querySelector("#dbg-dom .dbg-bp")?.textContent.includes("button#action.act"), document.querySelector("#dbg-dom").textContent);
    check("the context menu shows it as set", el.breakOnItems(button).find((i) => /attribute/.test(i.label)).label.startsWith("✓"));
    check("attribute change pauses", await pauseBy("document.getElementById('action').click()"));
    check("banner names the DOM breakpoint and the node", /attribute modification/.test(banner()) && banner().includes("button#action.act"), banner());
    check("the stack starts in the code that changed the attribute", dbg.frames[0]?.functionName === "onActionClick", dbg.frames.map((f) => f.functionName + " " + f.url + ":" + f.line));
    check("and that line is showing", document.querySelector("#sources-code .code-line.exec")?.textContent.includes("setAttribute"), document.querySelector("#sources-code .code-line.exec")?.textContent.slice(0, 120));
    check("the breakpoint that hit is highlighted", !!document.querySelector("#dbg-dom .dbg-bp.hit"));
    check("resumes after DOM breakpoint", await resume());
    await el.breakOnItems(button).find((i) => /attribute/.test(i.label)).action(); await wait(500);
    check("removed DOM breakpoint no longer pauses", !(await pauseBy("document.getElementById('action').click()")) && !document.querySelector("#dbg-dom .dbg-bp"));
    await resume();

    // XHR/fetch breakpoint
    await dbg.setURLBreakpoint("later=1", true); await wait(300);
    check("fetch to a matching URL pauses", await pauseBy("window.__fetchLater()"));
    check("banner names the request", /XHR or fetch/.test(banner()) && banner().includes("/api/data.json?later=1"), banner());
    check("the stack starts at the page's fetch call, not inside our hook", dbg.frames.length > 0 && dbg.frames[0].url === "http://127.0.0.1:8765/" && !dbg.frames.some((f) => (f.url || "").startsWith("user-script:")), dbg.frames.map((f) => f.functionName + " " + f.url + ":" + f.line));
    check("the fetch call's line is showing", document.querySelector("#sources-code .code-line.exec")?.textContent.includes("__fetchLater"), document.querySelector("#sources-code .code-line.exec")?.textContent.slice(0, 120));
    check("resumes after XHR breakpoint", await resume());
    await dbg.setURLBreakpoint("later=1", false); await wait(300);
    check("a disabled XHR breakpoint does not pause", !(await pauseBy("window.__fetchLater()")));
    await resume();
    await dbg.removeURLBreakpoint("later=1");

    // Event listener breakpoint
    await dbg.setEventBreakpoint("listener:click", true); await wait(300);
    check("a click listener pauses", await pauseBy("document.getElementById('action').click()"));
    check("banner names the event", /event listener/.test(banner()) && banner().includes("click"), banner());
    await dbg.setEventBreakpoint("listener:click", false);
    check("resumes after event breakpoint", await resume());
    check("removed event breakpoint does not pause", !(await pauseBy("document.getElementById('action').click()")));
    await resume();

    // Timer breakpoint
    await dbg.setEventBreakpoint("timeout", true); await wait(200);
    const timerPaused = await pauseBy("(function tick() { window.__ticked = true; })()");
    out.timerBanner = banner();
    await dbg.setEventBreakpoint("timeout", false);
    check("setTimeout breakpoint pauses when a timer fires", timerPaused && /setTimeout/.test(out.timerBanner), out.timerBanner);
    check("resumes after timer breakpoint", await resume());

    // Nothing may be left behind for the next session.
    const left = [await DevTools.rpc("Settings.get", { key: "urlBreakpoints" }), await DevTools.rpc("Settings.get", { key: "eventBreakpoints" })];
    check("no breakpoints left in settings", left.join("|") === "[]|[]", left);

    // Network: copy as cURL / fetch
    const net = DevTools.panels.network;
    const post = Array.from(net.requests.values()).find((r) => r.method === "POST");
    if (post) {
      out.curl = net.asCurl(post);
      check("copy as cURL carries method, headers and body", out.curl.startsWith("curl 'http://127.0.0.1:8765/api/post'") && /-H 'content-type: application\/json'/i.test(out.curl) && out.curl.includes(`--data-raw '{"hello":"world"}'`), out.curl);
      const asFetch = net.asFetch(post);
      check("copy as fetch is runnable code", /^fetch\("http:\/\/127\.0\.0\.1:8765\/api\/post", \{/.test(asFetch) && asFetch.includes('"method": "POST"') && asFetch.includes('"body": "{\\"hello\\":\\"world\\"}"'), asFetch);
      check("copy menu offers URL, cURL and fetch", net.copyItems(post).filter((i) => i !== "-").map((i) => i.label).slice(0, 3).join() === "Copy URL,Copy as cURL,Copy as fetch");
    } else check("a POST request was recorded", false);

    // Disable cache: a max-age resource is normally served from cache, and refetched when disabled.
    const hit = async () => +(await pageValue("await fetch('/cacheable').then((r) => r.text())"));
    const first = await hit(), second = await hit();
    document.querySelector("#network-disable-cache").click(); await wait(500);
    const third = await hit(), fourth = await hit();
    document.querySelector("#network-disable-cache").click(); await wait(500);
    const fifth = await hit();
    out.cache = [first, second, third, fourth, fifth];
    check("cached by default", second === first, out.cache);
    check("Disable cache refetches every time", third > second && fourth > third, out.cache);
    check("turning it off brings the cache back", fifth === fourth, out.cache);
    check("Disable cache is not left on", (await DevTools.rpc("Settings.get", { key: "disableCache" })) === "false");
  }

  // ---- Network with the protocol attached ----------------------------------------------
  // A reload with DevTools open is seen by the inspector protocol too: real
  // status, headers and bodies for every resource, not just fetch and XHR.
  if (SBDebugger.available) {
    DevTools.showPanel("network"); await wait(200);
    await DevTools.rpc("Page.reload");
    await wait(2500);
    const after = Array.from(DevTools.panels.network.requests.values());
    out.networkAfterReload = after.map((r) => fileName(r.url) + " " + r.statusCode + " " + r.resourceType + " [" + r.sources.join(",") + "]");
    check("reload clears and refills the log, now with the WebSocket", after.filter((r) => !r.url.endsWith(".map")).length === 9, out.networkAfterReload);
    const ws = after.find((r) => r.resourceType === "websocket");
    check("WebSocket handshake row", ws && ws.statusCode === 101 && ws.url.startsWith("ws://"), ws && { s: ws.statusCode, u: ws.url });
    const wsRow = Array.from(document.querySelectorAll("#network-table tbody tr")).find((r) => r.textContent.includes("websocket"));
    if (wsRow) {
      wsRow.click(); await wait(700);
      const frames = Array.from(document.querySelectorAll("#ws-frames tr")).map((tr) => tr.className + " " + tr.children[1].textContent);
      check("WebSocket messages tab shows both directions", frames.includes("ws-sent hello ws") && frames.includes("ws-received echo: hello ws"), frames);
      await SBDebugger.send("Runtime.evaluate", { expression: "window.__socket && window.__socket.send('live frame'); 1" });
      await wait(700);
      const live = Array.from(document.querySelectorAll("#ws-frames tr")).map((tr) => tr.children[1].textContent);
      check("new frames appear live", live.includes("live frame") && live.includes("echo: live frame"), live);
    }
    const image = after.find((r) => r.url.endsWith("/pixel.png"));
    check("image has a real status and headers", image && image.statusCode === 200 && image.responseHeaders["x-served-by"] === "devtools-fixture" && image.sources.includes("inspector"), image && { s: image.statusCode, src: image.sources });
    const script = after.find((r) => r.url.endsWith("/script.js"));
    check("script has request headers", script && Object.keys(script.requestHeaders).length > 0 && script.statusCode === 200, script && script.requestHeaders);
    check("no duplicate rows after merging three sources", new Set(after.map((r) => r.url + r.method)).size === after.length, out.networkAfterReload);
    const scriptRow = Array.from(document.querySelectorAll("#network-table tbody tr")).find((r) => r.textContent.includes("script.js"));
    if (scriptRow) {
      scriptRow.click(); await wait(200);
      document.querySelector('#network-detail-tabs [data-subpanel="response"]').click(); await wait(1200);
      const text = document.querySelector("#network-detail-body").textContent;
      check("script body comes from the engine, not a re-fetch", text.includes("function greet") && !text.includes("fetched again"), text.slice(0, 160));
    }
    const pngRow = Array.from(document.querySelectorAll("#network-table tbody tr")).find((r) => r.textContent.includes("pixel.png"));
    if (pngRow) {
      pngRow.click(); await wait(200);
      document.querySelector('#network-detail-tabs [data-subpanel="preview"]').click(); await wait(1200);
      check("image preview from the engine", !!document.querySelector("#network-detail-body img"));
    }
  }

  // ---- Network power tools: blocking, overrides, search, Copy for AI -------------------
  {
    const net = DevTools.panels.network;
    DevTools.showPanel("network"); await wait(200);
    const pageFetch = async (path) => (await DevTools.rpc("Console.evaluate", { expression: `await fetch('${path}').then(async (r) => r.status + ' ' + (r.headers.get('x-override') || '-') + ' ' + await r.text(), (e) => 'failed ' + e.message)` }))?.result?.description || "";
    SBBlocking.patterns = [];
    check("an unblocked request goes through", /^200 /.test(await pageFetch("/api/data.json?blockme=1")));
    await SBBlocking.add("*/api/data.json?blockme*"); await wait(400);
    out.blocked = await pageFetch("/api/data.json?blockme=2");
    check("a blocking pattern blocks the request", /^failed/.test(out.blocked), out.blocked);
    Drawer.show("blocking"); await wait(200);
    check("the blocking pane lists the pattern", document.querySelector("#blocking-list").textContent.includes("*/api/data.json?blockme*"));
    await SBBlocking.setEnabled(false); await wait(400);
    check("unticking Enable lets requests through", /^200 /.test(await pageFetch("/api/data.json?blockme=3")));
    await SBBlocking.setEnabled(true);
    await SBBlocking.remove("*/api/data.json?blockme*"); await wait(400);
    check("removing the pattern unblocks", /^200 /.test(await pageFetch("/api/data.json?blockme=4")));
    check("no blocking patterns left in settings", (await DevTools.rpc("Settings.get", { key: "blockedPatterns" })) === "[]");
    const dataReq = Array.from(net.requests.values()).find((r) => r.url.endsWith("/api/data.json"));
    const labels = net.contextItems(dataReq).flatMap((i) => i === "-" ? [] : i.submenu ? i.submenu.filter((x) => x !== "-") : [i]).map((i) => i.label);
    check("request menu offers blocking, overrides and Copy for AI", ["Block request URL", "Block request domain", "Override content…", "Override headers…", "Copy as Markdown (for AI)", "Copy all as HAR"].every((l) => labels.includes(l)), labels);
    check("Block request domain blocks the host", net.blockDomainPattern(dataReq.url) === "127.0.0.1:8765");

    if (SBDebugger.available) {
      SBOverrides.list = [];                // start clean, whatever an earlier session saved
      await SBOverrides.add({ url: "http://127.0.0.1:8765/api/override.json", status: 202, mimeType: "application/json", headersText: "X-Override: yes", body: '{"overridden":true}' });
      out.override = await pageFetch("/api/override.json");
      check("a local override answers the request", out.override === '202 yes {"overridden":true}', out.override);
      await SBOverrides.add({ url: "http://127.0.0.1:8765/api/data.json?headers=*", status: 200, headersText: "X-Override: headers-only", keepBody: true });
      out.override2 = await pageFetch("/api/data.json?headers=1");
      check("a headers-only override keeps the real body", /^200 headers-only \{"ok": true/.test(out.override2), out.override2);
      Drawer.show("overrides"); await wait(200);
      check("the overrides pane lists both", document.querySelectorAll("#overrides-list .override-item").length === 2);
      SBOverrides.list = []; await SBOverrides.apply();
      check("without overrides the server answers again", /^404 /.test(await pageFetch("/api/override.json")));
    }

    const bodyHits = await SBNetSearch.run("items");
    check("search finds response bodies", bodyHits.some((r) => r.url.includes("/api/data.json") && r.hits.some((x) => x.where === "Response")), bodyHits.map((r) => r.url));
    const headerHits = await SBNetSearch.run("devtools-fixture");
    check("search finds headers", headerHits.some((r) => r.hits.some((x) => x.where === "Response header")), headerHits.length);
    Drawer.show("search"); await wait(200);
    check("search results are listed", document.querySelectorAll("#netsearch-results .search-hit").length > 0);

    const post = Array.from(net.requests.values()).find((r) => r.method === "POST");
    out.markdown = post && net.asMarkdown(post);
    check("Copy as Markdown has method, status, payload and response", out.markdown && out.markdown.startsWith("## POST http://127.0.0.1:8765/api/post → 201 Created") && out.markdown.includes("### Request payload") && out.markdown.includes('"hello": "world"') && out.markdown.includes("created:"), out.markdown && out.markdown.slice(0, 300));
    const summary = net.summaryMarkdown();
    check("Copy all as Markdown is a table with failures", /\| # \| Method \| Status/.test(summary) && summary.includes("## Failed requests"), summary.slice(0, 200));
    const har = JSON.parse(await DevTools.rpc("Network.getHAR"));
    check("Copy all as HAR", har.log && har.log.entries.length >= 8, har.log && har.log.entries.length);

    const cons = DevTools.panels.console;
    const errItem = cons.entries.find((i) => i.entry.level === "error" && cons.plainText(i).includes("boom from console.error"));
    out.consoleMarkdown = errItem && cons.entryMarkdown(errItem);
    check("console Copy for AI has the message, location and stack", !!out.consoleMarkdown && out.consoleMarkdown.startsWith("**Console error**") && out.consoleMarkdown.includes("boom from console.error") && out.consoleMarkdown.includes("Stack:") && out.consoleMarkdown.includes("127.0.0.1:8765"), out.consoleMarkdown);
    const errorsMd = cons.errorsMarkdown();
    check("Copy all errors as Markdown", errorsMd.startsWith("# Console errors") && errorsMd.includes("unhandled rejection sample"), errorsMd.slice(0, 200));
    check("console context menu", cons.contextItems(errItem).filter((i) => i !== "-").map((i) => i.label).slice(0, 2).join() === "Copy message,Copy for AI (Markdown)");
    Drawer.hide();
  }

  // ---- Command menu, Rendering, screenshots -----------------------------------------------
  {
    const pageEval = async (expression) => (await DevTools.rpc("Console.evaluate", { expression }))?.result?.description;
    const input = document.querySelector("#command-input");
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "P", metaKey: true, shiftKey: true, bubbles: true })); await wait(200);
    check("⇧⌘P opens the command menu in command mode", !document.querySelector("#command-menu").hidden && input.value === ">");
    input.value = ">rendering"; input.dispatchEvent(new Event("input")); await wait(150);
    check("Show Rendering is the best match", CommandMenu.items[0]?.title === "Show Rendering", CommandMenu.items.slice(0, 3).map((i) => i.title));
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })); await wait(300);
    check("Enter runs it", Drawer.current === "rendering" && document.querySelector("#command-menu").hidden && document.querySelectorAll("#rendering-body .rendering-option").length >= 10);
    const fuzzyHits = CommandMenu.matches(">cfss").map((i) => i.title);
    check("fuzzy matching skips letters", fuzzyHits[0] === "Capture full size screenshot", fuzzyHits.slice(0, 3));
    check("the menu has the Chrome actions", ["Disable JavaScript", "Capture screenshot", "Capture node screenshot", "Clear site data", "Dock to right", "Show Network request blocking"].every((t) => CommandMenu.commands().some((c) => c.title === t)));
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "p", metaKey: true, bubbles: true })); await wait(500);
    check("⌘P opens it on files", !document.querySelector("#command-menu").hidden && input.value === "" && CommandMenu.items.some((i) => i.title === "script.js"), CommandMenu.items.map((i) => i.title));
    CommandMenu.close();
    await CommandMenu.run("script.js"); await wait(800);
    check("Open file shows it in Sources", DevTools.activePanel === "sources" && (DevTools.panels.sources.current || "").endsWith("/script.js"), DevTools.panels.sources.current);

    if (SBDebugger.available) {
      await SBRendering.set("media", "print");
      check("emulate CSS print media", (await pageEval("matchMedia('print').matches")) === "true");
      await SBRendering.set("media", "");
      check("media emulation off again", (await pageEval("matchMedia('print').matches")) === "false");
      await SBRendering.set("colorScheme", "dark");
      check("emulate prefers-color-scheme: dark", (await pageEval("matchMedia('(prefers-color-scheme: dark)').matches")) === "true");
      await SBRendering.set("colorScheme", "light");
      check("emulate prefers-color-scheme: light", (await pageEval("matchMedia('(prefers-color-scheme: light)').matches")) === "true");
      await SBRendering.set("colorScheme", "");
      await SBRendering.set("reducedMotion", "reduce");
      check("emulate prefers-reduced-motion: reduce", (await pageEval("matchMedia('(prefers-reduced-motion: reduce)').matches")) === "true");
      await SBRendering.set("reducedMotion", "");
      for (const feature of ["paintFlashing", "layerBorders", "repaintCounter", "rulers"]) {
        let ok = true;
        try { await SBRendering.set(feature, true); await SBRendering.set(feature, false); } catch (e) { ok = e.message; }
        check(feature + " switches through the protocol", ok === true, ok);
      }
      check("nothing left emulated", Object.keys(SBRendering.state).length === 0, SBRendering.state);
    }
    await SBRendering.set("fpsMeter", true); await wait(1500);
    const meter = await DevTools.rpc("Rendering.getFPS");
    // An occluded window gets no animation frames at all; then only the overlay can be checked.
    const visibility = await pageEval("document.visibilityState");
    if (visibility !== "visible") out.fpsNote = "page is " + visibility + ": no animation frames to count";
    check("the FPS meter runs in the page", meter.shown && (meter.fps > 0 || visibility !== "visible"), meter);
    check("the FPS overlay is not part of the page's DOM tree", (await DevTools.rpc("DOM.performSearch", { query: "dropped/s" })).nodeIds.length === 0 && (await DevTools.rpc("DOM.performSearch", { query: " fps" })).nodeIds.length === 0);
    await SBRendering.set("fpsMeter", false);
    check("and goes away", !(await DevTools.rpc("Rendering.getFPS")).shown);

    const info = await DevTools.rpc("Page.getInfo");
    const shot = await SBScreenshots.capture("viewport", null, "none");
    out.screenshots = { viewport: shot, info: { w: info.width, h: info.height, sw: info.scrollWidth, sh: info.scrollHeight, dpr: info.devicePixelRatio } };
    check("viewport screenshot", shot.width >= info.width && shot.height >= info.height * 0.9, out.screenshots);
    if (SBDebugger.available) {
      const full = await SBScreenshots.capture("full", null, "none");
      out.screenshots.full = full;
      check("full size screenshot is the whole document", Math.abs(full.width / full.height - info.scrollWidth / info.scrollHeight) < 0.05, out.screenshots);
      const h1 = Array.from(DevTools.panels.elements.nodes.values()).find((n) => n.nodeName === "h1")?.nodeId;
      const box = await DevTools.rpc("DOM.getBoxModel", { nodeId: h1 });
      const node = await SBScreenshots.capture("node", h1, "none");
      out.screenshots.node = node;
      check("node screenshot is the node's box", Math.abs(node.width / node.height - box.rect.width / box.rect.height) < 0.1, { node, box: box.rect });
    }
    Drawer.hide();
  }

  // ---- Memory: heap snapshots, comparison, heap size over time -------------------------
  if (SBDebugger.available) {
    const mem = DevTools.panels.memory;
    DevTools.showPanel("memory"); await wait(300);
    await DevTools.rpc("Console.evaluate", { expression: "class CartItem { constructor(i) { this.i = i; this.label = 'item ' + i; } }; window.CartItem = CartItem; window.__cart = Array.from({ length: 50 }, (_, i) => new CartItem(i)); 1" });
    const first = await mem.takeSnapshot();
    const cart = first.summary.get("CartItem");
    out.heap = { objects: first.nodeCount, total: first.total, parseMs: Math.round(first.parseMs), cart };
    check("heap snapshot summarises objects by constructor", cart && cart.count >= 50 && cart.shallow > 0, out.heap);
    check("retained sizes come from the dominator tree", cart && cart.retained >= cart.shallow && Array.from(first.summary.values()).some((r) => r.retained > r.shallow * 2), cart);
    check("the summary table lists the class", !!document.querySelector('#memory-body tr[data-class="CartItem"]'));
    await DevTools.rpc("Console.evaluate", { expression: "window.__cart2 = Array.from({ length: 30 }, (_, i) => new CartItem(100 + i)); 1" });
    const second = await mem.takeSnapshot();
    const diff = SBHeapSnapshot.compare(first, second).find((r) => r.name === "CartItem");
    check("comparison finds the new objects", diff && diff.added >= 30 && diff.delta >= 30, diff);
    const view = document.querySelector("#memory-view");
    view.value = "comparison"; view.dispatchEvent(new Event("change")); await wait(200);
    check("comparison view", !!document.querySelector('#memory-body tr[data-class="CartItem"]') && document.querySelector("#memory-body thead").textContent.includes("# New"));
    view.value = "summary"; view.dispatchEvent(new Event("change"));
    for (let i = 0; i < 40 && !mem.samples.length; i++) await wait(100);
    check("JS heap size over time", mem.samples.length > 0 && mem.samples[mem.samples.length - 1].js > 0, { samples: mem.samples.length, error: mem.trackingError });
    check("readout", /JS heap \d/.test(document.querySelector("#memory-readout").textContent), document.querySelector("#memory-readout").textContent);
    await DevTools.rpc("Console.evaluate", { expression: "delete window.__cart; delete window.__cart2; 1" });
  }

  // ---- Audits ------------------------------------------------------------------------------
  {
    const audits = DevTools.panels.audits;
    DevTools.showPanel("audits"); await wait(200);
    const report = await audits.run();
    out.auditScores = report.categories.map((c) => c.id + ":" + c.score);
    check("four categories, scored 0–100", report.categories.length === 4 && report.categories.every((c) => c.score >= 0 && c.score <= 100), out.auditScores);
    const label = audits.audit("label");
    check("an unlabelled input is reported, with its node", label && !label.passed && label.items.some((i) => i.selector === "#q" && i.nodeId != null), label);
    check("missing lang", !audits.audit("html-has-lang").passed);
    check("missing main landmark", !audits.audit("landmark-one-main").passed);
    const contrast = audits.audit("color-contrast");
    check("low-contrast text", !contrast.passed && contrast.items.some((i) => i.selector === "#faint"), contrast.items.map((i) => i.selector + " " + i.detail));
    check("the button has a name", audits.audit("button-name").passed);
    check("SEO: no meta description", !audits.audit("meta-description").passed);
    const linkText = audits.audit("link-text");
    check("SEO: generic link text", !linkText.passed && linkText.items.some((i) => /click here/.test(i.detail)), linkText.items);
    check("SEO: no viewport meta", !audits.audit("viewport", "seo").passed);
    check("SEO: successful status", audits.audit("http-status-code").passed);
    check("best practices: doctype and charset", audits.audit("doctype").passed && audits.audit("charset").passed);
    const errorsAudit = audits.audit("errors-in-console");
    check("best practices: console errors", !errorsAudit.passed && errorsAudit.total >= 2, errorsAudit.total);
    check("performance: metrics measured", audits.audit("first-contentful-paint").numericValue > 0 && audits.audit("server-response-time").numericValue > 0, [audits.audit("first-contentful-paint").displayValue, audits.audit("server-response-time").displayValue]);
    check("performance: payload is small", audits.audit("total-byte-weight").passed);
    check("score gauges", document.querySelectorAll("#audits-body .audit-gauges .audit-gauge").length === 4);
    document.querySelector('#audits-body .audit[data-audit="label"] .audit-node').click(); await wait(900);
    const selected = DevTools.panels.elements.nodes.get(DevTools.panels.elements.selectedId);
    check("a finding reveals its node in Elements", DevTools.activePanel === "elements" && (selected?.attributes || []).includes("q"), selected && selected.attributes);
    const md = audits.markdown();
    check("Markdown export", md.startsWith("# Audit report") && md.includes("## Accessibility:") && md.includes("`#q`"), md.slice(0, 300));
    const json = JSON.parse(audits.json());
    check("JSON export", json.categories.length === 4 && json.url.startsWith("http://127.0.0.1:8765/"));
  }

  // ---- Performance -------------------------------------------------------------------
  DevTools.showPanel("performance"); await wait(400);
  out.perf = document.querySelector("#vitals").textContent;
  check("vitals", /First Contentful Paint\d+ ms/.test(out.perf) && /Time to First Byte\d+ ms/.test(out.perf), out.perf);
  if (SBDebugger.available) {
    document.querySelector("#perf-record").click(); await wait(500);
    check("recording started", SBProfiler.recording);
    await SBDebugger.send("Runtime.evaluate", { expression: "setTimeout(function busyWork() { function inner(n) { var s = 0; for (var i = 0; i < n; i++) s += Math.sqrt(i); return s; } var t = performance.now(); while (performance.now() - t < 150) inner(20000); document.body.style.padding = '2px'; document.body.offsetHeight; }, 0); 1" });
    await wait(900);
    await SBProfiler.stop(); await wait(300);
    const prof = SBProfiler.profile;
    out.profile = prof && { samples: prof.sampleCount, nodes: prof.nodes.length, depth: prof.maxDepth, top: prof.functions.slice(0, 3).map((f) => f.name + " " + Math.round(f.self * 1000) + "ms"), events: Array.from(new Set(prof.events.map((e) => e.type))) };
    // WebKit's sampler yields anything from 1 to 100+ stacks for the same
    // 150 ms loop depending on JIT tier, so assert on what we reconstruct.
    const hot = prof && prof.functions[0];
    check("the script task's full duration is attributed", hot && hot.self > 0.12 && hot.self < 0.25, out.profile);
    if (prof && prof.sampleCount > 0 && prof.nodes.some((n) => n.name === "inner")) {
      check("hot function tops the bottom-up table", hot.name === "inner", out.profile);
      check("flame chart nests inner under busyWork", prof.nodes.some((n) => n.name === "busyWork" && n.depth === 0) && prof.nodes.some((n) => n.name === "inner" && n.depth === 1), out.profile);
    } else {
      check("an unsampled task still gets an estimated frame", prof && prof.nodes.some((n) => n.estimated && n.end - n.start > 0.12), out.profile);
    }
    check("timeline recorded layout and script events", prof && prof.events.some((e) => e.type === "Layout") && prof.events.some((e) => e.category === "scripting"), out.profile);
    const canvas = document.querySelector("#perf-chart");
    check("flame chart is drawn", !document.querySelector("#perf-recording").hidden && canvas.width > 100 && SBProfiler.hitRegions.length > 0);
    check("bottom-up table rendered", document.querySelector("#perf-profile-table tbody tr td .mono")?.textContent === (hot && hot.name));
    check("our own agents are not in the profile", prof && !prof.nodes.some((n) => n.url.startsWith("user-script:")));
    // Recording switches the debugger off; it must come back, breakpoints and all.
    await SBDebugger.send("Runtime.evaluate", { expression: "setTimeout(function afterRecording() { debugger; }, 0); 1" });
    for (let i = 0; i < 50 && !SBDebugger.paused; i++) await wait(100);
    check("debugger works again after a recording", SBDebugger.paused && SBDebugger.frames[0] && SBDebugger.frames[0].functionName === "afterRecording", SBDebugger.frames.map((f) => f.functionName));
    await SBDebugger.send("Debugger.resume");
    for (let i = 0; i < 40 && SBDebugger.paused; i++) await wait(100);
    DevTools.showPanel("performance"); await wait(200);
  }

  // ---- Application --------------------------------------------------------------------
  DevTools.showPanel("application"); await wait(800);
  check("local storage", document.querySelector("#application-body").textContent.includes("greetinghello"));
  DevTools.panels.application.section = "cookies"; await DevTools.panels.application.load(); await wait(300);
  check("cookies", document.querySelector("#application-body").textContent.includes("sessionabc123"));

  // ---- Device mode ---------------------------------------------------------------------
  const desktop = await DevTools.rpc("Page.getInfo");
  await DeviceMode.set(DeviceMode.devices().find((d) => d.name === "iPhone SE"));
  await wait(2000);
  const phone = await DevTools.rpc("Page.getInfo");
  out.device = { desktop: desktop.width, phone: phone.width + "x" + phone.height, ua: phone.userAgent.slice(0, 40) };
  check("device mode sets the viewport", phone.width === 375 && phone.height <= 667, out.device);
  check("device mode sets the user agent", /iPhone/.test(phone.userAgent), phone.userAgent);
  check("device button shows the active device", document.getElementById("btn-device").classList.contains("active"));
  await DeviceMode.clear();
  await wait(2000);
  const restored = await DevTools.rpc("Page.getInfo");
  check("leaving device mode restores viewport and user agent", restored.width === desktop.width && !/iPhone/.test(restored.userAgent), { w: restored.width, ua: restored.userAgent.slice(0, 40) });

  // ---- Application: IndexedDB, Cache Storage, manifest, service workers ------------------
  const pageEval = async (expression) => {
    const r = await DevTools.rpc("Console.evaluate", { expression });
    return r?.result?.description ?? ("error: " + (r?.exceptionDetails?.text || JSON.stringify(r)));
  };
  {
    const app = DevTools.panels.application;
    out.appSetup = [
      await pageEval("await new Promise((resolve, reject) => { const req = indexedDB.open('shop', 2); req.onupgradeneeded = () => { const db = req.result; if (!db.objectStoreNames.contains('products')) { const s = db.createObjectStore('products', { keyPath: 'id' }); s.createIndex('byName', 'name'); } }; req.onsuccess = () => { const db = req.result; const tx = db.transaction('products', 'readwrite'); const s = tx.objectStore('products'); s.put({ id: 1, name: 'Apple', price: 1.5, added: new Date(0), tags: ['fruit'] }); s.put({ id: 2, name: 'Bread', price: 3 }); s.put({ id: 3, name: 'Cheese', price: 7 }); tx.oncomplete = () => { db.close(); resolve('idb ok'); }; tx.onerror = () => reject(tx.error); }; req.onerror = () => reject(req.error); })"),
      await pageEval("await caches.open('v1').then((c) => c.addAll(['/api/data.json?cached=1', '/pixel.png'])).then(() => 'cache ok')"),
      await pageEval("(() => { const l = document.createElement('link'); l.rel = 'manifest'; l.href = '/manifest.json'; document.head.appendChild(l); return 'manifest ok'; })()"),
    ];
    DevTools.showPanel("application"); await wait(300);
    await app.loadTree();
    const treeText = document.querySelector("#application-tree").textContent;
    check("IndexedDB databases and stores are in the tree", treeText.includes("shop") && treeText.includes("products"), { setup: out.appSetup, treeText });
    check("caches are in the tree", treeText.includes("v1"), treeText);
    await app.open("idb:shop/products");
    check("IndexedDB records", app.rows.length === 3 && document.querySelector("#application-body").textContent.includes("Apple"), app.rows.length);
    document.querySelector('#application-body tr[data-index="0"]').click(); await wait(200);
    const record = document.querySelector("#app-detail").textContent;
    check("a record's value as a tree, dates included", record.includes("Apple") && record.includes("1970-01-01T00:00:00.000Z") && record.includes("fruit"), record.slice(0, 200));
    app.selectedIndex = 1; await app.deleteSelected();
    check("delete a record", app.rows.length === 2 && !app.rows.some((r) => r.value && r.value.name === "Bread"), app.rows.map((r) => r.value && r.value.name));
    await app.clearAll();
    check("clear an object store", app.rows.length === 0);
    await app.open("cache:v1");
    check("cache entries", app.rows.length === 2 && app.rows.some((r) => r.url.endsWith("/api/data.json?cached=1") && r.status === 200), app.rows);
    document.querySelector(`#application-body tr[data-index="${app.rows.findIndex((r) => r.url.includes("data.json"))}"]`).click(); await wait(500);
    check("a cached response's headers and body", /"ok": true/.test(document.querySelector("#app-detail").textContent) && /content-type/i.test(document.querySelector("#app-detail").textContent));
    await app.open("manifest");
    const manifestText = document.querySelector("#application-body").textContent;
    check("the Web App Manifest is parsed", manifestText.includes("Fixture Shop") && manifestText.includes("standalone") && document.querySelectorAll("#application-body .manifest-icon img").length === 1, manifestText.slice(0, 200));
    check("manifest warnings", manifestText.includes("No 512×512 icon"));
    await app.open("serviceworkers");
    out.serviceWorkers = app.extra;
    check("the service workers pane says what it can", document.querySelector("#application-body").textContent.length > 30 && app.extra && typeof app.extra.supported === "boolean");
    await DevTools.rpc("IndexedDB.deleteDatabase", { name: "shop" });
    await DevTools.rpc("CacheStorage.deleteCache", { cache: "v1" });
    await app.open("local");
  }

  // ---- Elements: Accessibility pane -----------------------------------------------------------
  {
    DevTools.showPanel("elements"); await wait(300);
    const button = Array.from(el.nodes.values()).find((n) => n.nodeName === "button")?.nodeId;
    const input = Array.from(el.nodes.values()).find((n) => n.nodeName === "input")?.nodeId;
    el.select(button); await wait(200);
    document.querySelector('#styles-tabs [data-subpanel="accessibility"]').click();
    for (let i = 0; i < 30 && !(el.a11y && el.a11y.computed.nodeId === button); i++) await wait(100);
    const a11y = el.a11y || {};
    out.a11y = { computed: a11y.computed, engine: a11y.engine };
    check("computed role and name", a11y.computed && a11y.computed.role === "button" && a11y.computed.name === "Action" && a11y.computed.nameSource === "contents", out.a11y);
    if (SBDebugger.available) check("WebKit's own accessibility object", a11y.engine && a11y.engine.exists && a11y.engine.role === "button" && a11y.engine.label === "Action", a11y.engine);
    check("the tree runs down to the node", /button\s*"Action"/.test(document.querySelector("#a11y-view .a11y-node.current")?.textContent || ""), document.querySelector("#a11y-view")?.textContent.slice(0, 200));
    check("computed properties", /Name\s*Action/.test(document.querySelector("#a11y-view .a11y-props")?.textContent || ""));
    el.select(input); await wait(200);
    for (let i = 0; i < 30 && !(el.a11y && el.a11y.computed.nodeId === input); i++) await wait(100);
    check("a placeholder is the only name of the unlabelled input", el.a11y.computed.nameSource === "placeholder" && el.a11y.computed.role === "textbox", el.a11y.computed);
    document.querySelector('#styles-tabs [data-subpanel="styles"]').click();
  }

  // ---- Animations ----------------------------------------------------------------------------------
  {
    out.animSetup = await pageEval("(() => { const s = document.createElement('style'); s.id = 'spin-style'; s.textContent = '@keyframes spin { from { transform: rotate(0deg) } to { transform: rotate(360deg) } } #spinner { animation: spin 2s linear infinite; display: inline-block }'; document.head.appendChild(s); const d = document.createElement('div'); d.id = 'spinner'; d.textContent = '*'; document.body.appendChild(d); d.animate([{ opacity: 1 }, { opacity: 0.2 }], { duration: 1000, iterations: Infinity, id: 'fade' }); return 'ok'; })()");
    Drawer.show("animations"); await wait(400);
    const list = await SBAnimations.refresh();
    out.animations = list.map((a) => `${a.name} ${a.type} ${a.playState} ${a.target && a.target.label}`);
    const spin = list.find((a) => a.name === "spin");
    check("CSS animations and Web Animations are listed", spin && spin.type === "CSS animation" && list.some((a) => a.name === "fade" && a.type === "Web animation"), out.animations);
    check("with their target node", spin && spin.target && spin.target.label === "div#spinner" && spin.duration === 2000 && spin.iterations === "infinite", spin);
    await SBAnimations.pauseAll();
    check("pause all", SBAnimations.list.length >= 2 && SBAnimations.list.every((a) => a.playState === "paused"), SBAnimations.list.map((a) => a.playState));
    await SBAnimations.setRate(0.25);
    check("playback rate", SBAnimations.list.every((a) => a.playbackRate === 0.25));
    await SBAnimations.resumeAll();
    check("resume all", SBAnimations.list.every((a) => a.playState === "running"), SBAnimations.list.map((a) => a.playState));
    await SBAnimations.setRate(1);
    check("rows with a timeline", document.querySelectorAll("#animations-list .anim-row .anim-track").length >= 2);
    await pageEval("document.getAnimations().forEach((a) => a.cancel()); document.getElementById('spinner').remove(); document.getElementById('spin-style').remove(); 1");
    Drawer.hide();
  }

  // ---- Console: live expressions ----------------------------------------------------------------
  {
    DevTools.showPanel("console"); await wait(200);
    const cons = DevTools.panels.console;
    for (const l of cons.live.slice()) cons.removeLive(l);
    await pageEval("window.__liveCounter = 1; 1");
    cons.addLive("window.__liveCounter * 2");
    await wait(700);
    const liveValue = () => document.querySelector("#console-live .live-value")?.textContent;
    check("a live expression shows its value", document.querySelector("#console-live .live-expression")?.textContent === "window.__liveCounter * 2" && liveValue() === "2", document.querySelector("#console-live").textContent);
    const before = cons.entries.length;
    await DevTools.rpc("Runtime.evaluate", { expression: "window.__liveCounter = 21" });
    await wait(700);
    check("it updates by itself", liveValue() === "42", liveValue());
    check("without logging anything", cons.entries.length === before, [before, cons.entries.length]);
    check("and is remembered", JSON.parse(localStorage.getItem("devtools.console.live")).includes("window.__liveCounter * 2"));
    cons.removeLive(cons.live[0]);
    check("removing it", document.querySelector("#console-live").hidden && !cons.live.length);
  }

  // ---- Console v2 ---------------------------------------------------------------
  {
    DevTools.showPanel("console"); await wait(500);
    const cons = DevTools.panels.console;
    const results = () => Array.from(document.querySelectorAll("#console-messages .console-message.type-result"));
    const evalShown = async (expression) => {
      const before = results().length;
      cons.evaluate(expression);
      for (let i = 0; i < 30 && results().length === before; i++) await wait(50);
      await wait(100);
      return results()[results().length - 1];
    };
    const text = (el) => el ? el.querySelector(".body").textContent : null;
    check("console: arrays render as Array(3) [1, 2, 3]", text(await evalShown("[1, 2, 3]")) === "Array(3) [1, 2, 3]", text(results().at(-1)));
    check("console: objects preview nested values as {…}", text(await evalShown("({a: 1, b: {c: 2}, s: 'x'})")) === "{a: 1, b: {…}, s: 'x'}", text(results().at(-1)));
    check("console: maps preview their entries", text(await evalShown("new Map([['a', 1]])")) === "Map(1) {'a' => 1}", text(results().at(-1)));
    check("console: promises show their state", text(await evalShown("Promise.resolve(3)")) === "Promise {<fulfilled>: 3}", text(results().at(-1)));
    check("console: class instances are named", /^CartThing \{n: 1\}$/.test(text(await evalShown("new (class CartThing { constructor() { this.n = 1; } })()"))), text(results().at(-1)));
    const nodeResult = await evalShown("document.getElementById('title')");
    const node = nodeResult && nodeResult.querySelector(".v-node");
    check("console: DOM nodes render as inline elements", !!node && node.textContent.startsWith("<h1 id=\"title\"") && !!node.querySelector(".tag") && !!node.querySelector(".attr-value"), node && node.textContent);
    if (node) {
      node.click(); await wait(900);
      check("console: clicking a node reveals it in Elements", DevTools.activePanel === "elements" && /h1#title/.test(document.querySelector("#breadcrumbs").textContent), document.querySelector("#breadcrumbs").textContent);
      DevTools.showPanel("console"); await wait(200);
    }
    const fnResult = await evalShown("(function add(a, b) { return a + b; })");
    fnResult?.querySelector(".obj-toggle")?.click(); await wait(500);
    check("console: functions show their source when expanded", /return a \+ b/.test(fnResult?.querySelector(".obj-source")?.textContent || ""), fnResult && fnResult.textContent.slice(0, 120));
    const errResult = await evalShown("new Error('v2 boom')");
    check("console: errors show their stack as links", !!errResult?.querySelector(".v-error .link") || /v2 boom/.test(text(errResult) || ""), text(errResult));

    // prompt: highlighting, multi-line, eager evaluation, autocomplete
    const prompt = document.querySelector("#console-prompt");
    const type = async (value) => { prompt.focus(); prompt.value = value; prompt.setSelectionRange(value.length, value.length); prompt.dispatchEvent(new Event("input")); await wait(450); };
    await type("const greeting = 'hi' + 1");
    const mirror = document.querySelector("#console-prompt-row .code-input-mirror");
    check("prompt: syntax highlighting while typing", !!mirror && !!mirror.querySelector(".tok-keyword") && !!mirror.querySelector(".tok-string") && !!mirror.querySelector(".tok-number"));
    await type("function twice(x) {");
    prompt.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })); await wait(100);
    check("prompt: Enter with an open bracket continues on a new line", prompt.value.startsWith("function twice(x) {\n"), prompt.value);
    await type("[1, 2, 3].map((n) => n * 2).join('-')");
    for (let i = 0; i < 20 && document.querySelector("#console-eager")?.textContent !== "\"2-4-6\""; i++) await wait(100);
    check("prompt: eager evaluation previews a pure expression", document.querySelector("#console-eager")?.textContent === "\"2-4-6\"", [cons.eagerResult, cons.lastEager]);
    await DevTools.rpc("Console.evaluate", { expression: "window.__eagerHits = 0; 1" });
    await type("window.__eagerHits = 5");
    const hits = await DevTools.rpc("Runtime.evaluateLive", { expression: "window.__eagerHits" });
    check("prompt: eager evaluation never runs side effects", hits?.result?.description === "0" && document.querySelector("#console-eager").hidden, hits);
    check("prompt: the side-effect check", EagerEval.isSafe("document.title.toUpperCase()") && EagerEval.isSafe("$0") && !EagerEval.isSafe("alert(1)") && !EagerEval.isSafe("a = 1") && !EagerEval.isSafe("list.push(1)") && !EagerEval.isSafe("i++") && !EagerEval.isSafe("arr.map(sideEffect)") && !EagerEval.isSafe("fetch('/x')"));
    await type("document.getElementById('title').getAttr");
    const items = Array.from(document.querySelectorAll("#console-completions .item")).map((i) => i.querySelector(".completion-name").textContent + ":" + i.querySelector(".completion-type").textContent);
    check("prompt: autocomplete completes the expression before the dot, with types", !document.querySelector("#console-completions").hidden && items.some((i) => i === "getAttribute:method"), items.slice(0, 5));
    prompt.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", bubbles: true, cancelable: true })); await wait(100);
    check("prompt: Tab accepts the completion", prompt.value === "document.getElementById('title').getAttribute", prompt.value);
    await type("");
    const saved = JSON.parse(await DevTools.rpc("Settings.get", { key: "consoleHistory" }) || "[]");
    check("prompt: history is kept by the app across sessions", saved.includes("[1, 2, 3]"), saved.slice(-3));

    // sidebar, group similar, hide network, log XHR
    cons.setSetting("sidebar", true); await wait(150);
    const errorsRow = document.querySelector("#console-side-error");
    check("sidebar: shows counts by kind", !document.querySelector("#console-sidebar").hidden && /^\d+ errors?$/.test(errorsRow?.textContent.trim() || "") && /\d+ user messages?/.test(document.querySelector("#console-side-user")?.textContent || ""), errorsRow?.textContent);
    errorsRow.click(); await wait(150);
    const visible = Array.from(document.querySelectorAll("#console-messages .console-message")).filter((m) => !m.hidden && m.offsetParent && !m.classList.contains("type-command") && !m.classList.contains("type-result"));
    check("sidebar: selecting errors shows only errors", visible.length > 0 && visible.every((m) => m.classList.contains("level-error")), visible.map((m) => m.dataset.level));
    document.querySelector("#console-side-all").click(); await wait(100);
    cons.setSetting("sidebar", false);
    await DevTools.rpc("Console.evaluate", { expression: "for (var i = 0; i < 4; i++) console.log('similar item', i); 1" }); await wait(500);
    const badge = Array.from(document.querySelectorAll("#console-messages .console-similar-badge")).find((b) => b.closest(".console-message").textContent.includes("similar item"));
    check("group similar: consecutive similar messages collapse with a count", badge?.textContent === "4", badge?.textContent);
    cons.setSetting("hideNetwork", true); await wait(100);
    const failing = Array.from(document.querySelectorAll("#console-messages .console-message")).filter((m) => m.textContent.includes("Failed to load resource"));
    check("hide network: network messages are hidden", failing.length > 0 && failing.every((m) => m.hidden), failing.length);
    cons.setSetting("hideNetwork", false);
    cons.setSetting("logXHR", true);
    await DevTools.rpc("Console.evaluate", { expression: "await fetch('/api/data.json?xhrlog=1').then((r) => r.status)" }); await wait(1200);
    check("log XMLHttpRequests: finished fetches are logged", Array.from(document.querySelectorAll("#console-messages .console-message")).some((m) => /Fetch finished loading: GET ".*xhrlog=1"/.test(m.textContent)));
    cons.setSetting("logXHR", false);

    // message actions
    const errItem = cons.entries.find((i) => i.entry.level === "error" && cons.plainText(i).includes("boom from console.error"));
    const labels = errItem ? cons.contextItems(errItem, errItem.el).filter((i) => i !== "-").map((i) => i.label) : [];
    check("message menu: Copy message, Copy for AI, Copy stack, Store as global, Reveal in Sources, Save as…",
      ["Copy message", "Copy for AI (Markdown)", "Copy stack", "Store as global variable", "Reveal in Sources panel", "Save as…"].every((l) => labels.includes(l)), labels);
    const md = errItem ? await cons.entryMarkdownForAI(errItem) : "";
    check("Copy for AI includes the source lines around the location", /Source around `/.test(md) && /→ +\d+ \|.*boom from console\.error/.test(md), md.slice(-400));
    check("Copy stack", errItem && /@ http:\/\/127\.0\.0\.1:8765\//.test(cons.stackText(errItem)), errItem && cons.stackText(errItem));
    const objItem = cons.entries.find((i) => i.entry.type === "result" && i.entry.args[0]?.description === "Object");
    const name = objItem ? await cons.storeAsGlobal(objItem.entry.args[0]) : null;
    await wait(300);
    const stored = name ? await DevTools.rpc("Runtime.evaluateLive", { expression: name + ".a" }) : null;
    check("Store as global variable makes temp1", /^temp\d+$/.test(name || "") && stored?.result?.description === "1", { name, stored });
    check("Save as… writes the whole console as text", /boom from console\.error/.test(cons.consoleText()) && /^.*> \[1, 2, 3\]$/m.test(cons.consoleText()));
  }

  // ---- Elements v2 ----------------------------------------------------------------
  {
    const el = DevTools.panels.elements;
    DevTools.showPanel("elements"); await wait(600);
    const pageEvalV2 = async (expression) => (await DevTools.rpc("Console.evaluate", { expression }))?.result?.description;
    await pageEvalV2(`(() => {
      const wrap = document.createElement('section'); wrap.id = 'v2';
      wrap.innerHTML = '<div id="v2-grid" style="display:grid;grid-template-columns:50px 80px;gap:4px"><span>a</span><span>b</span></div>' +
        '<div id="v2-flex" style="display:flex"><i>1</i><i>2</i></div>' +
        '<div id="v2-scroll" style="height:30px;overflow:auto"><div style="height:200px">tall</div></div>' +
        '<p id="v2-move">move me</p><p id="v2-target" class="one two" style="color: #ff0000; margin-top: 3px">target</p><button id="v2-listener">L</button>' +
        '<div id="v2-host"><b slot="s" id="v2-slotted">slotted</b></div>';
      document.body.appendChild(wrap);
      wrap.querySelector('#v2-listener').addEventListener('click', () => {});
      const root = wrap.querySelector('#v2-host').attachShadow({ mode: 'open' });
      root.innerHTML = '<span id="in-shadow">inside</span><slot name="s"></slot>';
      window.__v2move = wrap.querySelector('#v2-move');
      return 'ok';
    })()`);
    await wait(800);
    const idOf = async (selector) => { const r = await DevTools.rpc("DOM.performSearch", { query: selector }); return r.nodeIds[0]; };
    const show = async (selector) => { const id = await idOf(selector); if (id != null) { await el.revealNode(id); await wait(250); } return id; };
    const gridId = await show("#v2-grid");
    const line = (id) => el.elements.get(id)?.querySelector(":scope > .node-line");
    check("elements: grid badge", !!line(gridId)?.querySelector(".dom-badge.grid"), line(gridId)?.textContent);
    line(gridId)?.querySelector(".dom-badge.grid")?.click(); await wait(400);
    let overlays = await DevTools.rpc("Overlay.getLayoutOverlays");
    check("elements: the grid badge turns on the grid overlay", overlays.some((o) => o.nodeId === gridId && o.kind === "grid") && line(gridId).querySelector(".dom-badge.grid.on"), overlays);
    const flexId = await show("#v2-flex");
    line(flexId)?.querySelector(".dom-badge.flex")?.click(); await wait(300);
    overlays = await DevTools.rpc("Overlay.getLayoutOverlays");
    check("elements: flex badge and overlay", overlays.some((o) => o.nodeId === flexId && o.kind === "flex"), overlays);
    const overlayDrawn = await pageEvalV2("document.getElementById('__sb-devtools-layout-overlay') ? 'none' : 'hidden from the page world? ' + !!document.querySelector('[id^=__sb-devtools-layout]')");
    line(gridId).querySelector(".dom-badge.grid").click(); line(flexId).querySelector(".dom-badge.flex").click(); await wait(300);
    check("elements: overlays switch off again", (await DevTools.rpc("Overlay.getLayoutOverlays")).length === 0);
    const scrollId = await show("#v2-scroll");
    check("elements: scroll badge", !!line(scrollId)?.querySelector(".dom-badge.scroll"));
    const listenerId = await show("#v2-listener");
    check("elements: event badge for a node with listeners", !!line(listenerId)?.querySelector(".dom-badge.event") && !line(scrollId)?.querySelector(".dom-badge.event"));
    const hostId = await show("#v2-host");
    await el.expand(hostId); await wait(300);
    const hostLi = el.elements.get(hostId);
    const shadowLine = hostLi?.querySelector(":scope > ol.children > li.node > .node-line");
    check("elements: #shadow-root (open)", /#shadow-root \(open\)/.test(shadowLine?.textContent || ""), shadowLine?.textContent);
    const slottedId = Array.from(el.nodes.values()).find((n) => (n.attributes || []).join(" ").includes("v2-slotted"))?.nodeId;
    if (slottedId == null) await el.expand(hostId);
    const slotted = Array.from(el.nodes.values()).find((n) => (n.attributes || []).join(" ").includes("v2-slotted"));
    check("elements: slot badge on a slotted node", !!(slotted && line(slotted.nodeId)?.querySelector(".dom-badge.slot")), slotted && line(slotted.nodeId)?.textContent);
    if (slotted) {
      line(slotted.nodeId).querySelector(".dom-badge.slot")?.click(); await wait(500);
      check("elements: the slot badge reveals the slot", el.nodes.get(el.selectedId)?.nodeName === "slot" && /#shadow-root/.test(document.querySelector("#breadcrumbs").textContent), document.querySelector("#breadcrumbs").textContent);
    }
    const shadowRootId = +shadowLine?.parentElement.dataset.nodeId;
    await el.expand(shadowRootId); await wait(300);
    const inShadow = Array.from(el.nodes.values()).find((n) => (n.attributes || []).includes("in-shadow"));
    if (inShadow) {
      const jsPath = await DevTools.rpc("DOM.copyPath", { nodeId: inShadow.nodeId, kind: "jsPath" });
      check("copy JS path steps into shadow roots", jsPath === 'document.querySelector("#v2-host").shadowRoot.querySelector("#in-shadow")', jsPath);
    } else check("node inside the shadow root is in the tree", false);

    // copy
    const targetId = await show("#v2-target");
    check("copy selector", await DevTools.rpc("DOM.copyPath", { nodeId: targetId, kind: "selector" }) === "#v2-target");
    check("copy JS path", await DevTools.rpc("DOM.copyPath", { nodeId: targetId, kind: "jsPath" }) === 'document.querySelector("#v2-target")');
    check("copy XPath", await DevTools.rpc("DOM.copyPath", { nodeId: targetId, kind: "xpath" }) === '//*[@id="v2-target"]');
    const full = await DevTools.rpc("DOM.copyPath", { nodeId: targetId, kind: "fullXPath" });
    check("copy full XPath", /^\/html\/body\/section(\[\d+\])?\/p\[2\]$/.test(full), full);
    const md = await el.elementMarkdown(targetId);
    check("copy element for AI", md.startsWith("## Element `<p>`") && /\*\*Accessibility\*\*: role/.test(md) && /### Matched rules/.test(md) && /element\.style/.test(md) && /\| color \| rgb\(255, 0, 0\) \|/.test(md), md.slice(0, 600));
    check("copy styles", /color: #ff0000;|color: rgb\(255, 0, 0\);/.test(await el.stylesText(targetId)), await el.stylesText(targetId));
    const items = el.copyItems(targetId).map((i) => i.label);
    check("the Copy items", ["Copy selector", "Copy JS path", "Copy XPath", "Copy full XPath", "Copy styles", "Copy outerHTML", "Copy element for AI (Markdown)"].every((l) => items.includes(l)), items);
    const global = await el.storeAsGlobal(targetId); await wait(300);
    check("store a node as a global variable", /^temp\d+$/.test(global || "") && await pageEvalV2(global + ".id") === "v2-target", global);
    DevTools.showPanel("elements"); await wait(200);

    // undo / redo
    await el.mutate("DOM.setAttributeValue", { nodeId: targetId, name: "title", value: "undo me" });
    await el.undo();
    check("⌘Z undoes an attribute edit", await pageEvalV2("document.getElementById('v2-target').hasAttribute('title')") === "false");
    await el.redo();
    check("⇧⌘Z redoes it", await pageEvalV2("document.getElementById('v2-target').title") === "undo me");
    const moveId = await idOf("#v2-move");
    await el.mutate("DOM.removeNode", { nodeId: moveId }); await wait(200);
    check("delete removes the node", await pageEvalV2("document.getElementById('v2-move') === null") === "true");
    document.querySelector("#dom-tree").focus();
    document.querySelector("#dom-tree").dispatchEvent(new KeyboardEvent("keydown", { key: "z", metaKey: true, bubbles: true, cancelable: true })); await wait(500);
    check("⌘Z brings the same node back, in place", await pageEvalV2("document.getElementById('v2-move') === window.__v2move && window.__v2move.nextElementSibling.id === 'v2-target'") === "true");
    await el.mutate("CSS.updateStyle", { nodeId: targetId, edits: [{ name: "color", value: "blue" }] });
    await el.undo();
    check("⌘Z undoes a style edit", await pageEvalV2("getComputedStyle(document.getElementById('v2-target')).color") === "rgb(255, 0, 0)");

    // drag and drop
    check("element lines are draggable", line(targetId)?.draggable === true && line(Array.from(el.nodes.values()).find((n) => n.nodeName === "body").nodeId)?.draggable === false);
    const moved = await el.moveNode(moveId, targetId, "after"); await wait(300);
    check("drop after a node moves it there", moved && await pageEvalV2("document.getElementById('v2-target').nextElementSibling === window.__v2move") === "true");
    check("the tree shows the new order", (() => { const li = el.elements.get(targetId); return li && li.nextElementSibling && +li.nextElementSibling.dataset.nodeId === moveId; })());
    await el.undo(); await wait(300);
    check("⌘Z undoes the move", await pageEvalV2("window.__v2move.nextElementSibling.id") === "v2-target");

    // search highlighting
    el.openSearch(); document.querySelector("#elements-search").value = "move me"; await el.runSearch(); await wait(400);
    check("search highlights the match in the tree", Array.from(document.querySelectorAll("#dom-tree mark.dom-search-mark")).some((m) => m.textContent.toLowerCase() === "move me"));
    el.closeSearch();
    check("closing the search removes the highlight", !document.querySelector("#dom-tree mark.dom-search-mark"));

    // styles: colour picker, .cls, copy menu
    el.select(targetId); document.querySelector('#styles-tabs [data-subpanel="styles"]').click(); await wait(500);
    const swatch = document.querySelector("#styles-list .styles-section .color-swatch[role=button]");
    swatch?.click(); await wait(200);
    check("a colour swatch opens the colour picker", !!document.querySelector(".color-picker") && ["HEX", "RGB"].includes(ColorPicker.parts.kind.textContent), ColorPicker.parts && ColorPicker.parts.kind.textContent);
    ColorPicker.setText("rgb(0, 128, 0)"); await wait(500);
    check("the picker applies the colour live", await pageEvalV2("getComputedStyle(document.getElementById('v2-target')).color") === "rgb(0, 128, 0)");
    ColorPicker.parts.kind.click();
    check("the format switches between hex, rgb and hsl", ColorPicker.parts.kind.textContent === "HSL" && /^hsl\(120, 100%, 25%\)$/.test(ColorPicker.parts.value.value), ColorPicker.parts.value.value);
    check("colour conversions", ColorPicker.format({ r: 255, g: 0, b: 0, a: 0.5 }, "rgb") === "rgba(255, 0, 0, 0.5)" && ColorPicker.format({ r: 255, g: 0, b: 0, a: 1 }, "hex") === "#ff0000" && ColorPicker.parse("hsl(240, 100%, 50%)").b === 255);
    ColorPicker.close(true); await wait(400);
    document.querySelector("#styles-cls").click(); await wait(100);
    const clsBoxes = Array.from(document.querySelectorAll("#styles-cls-list input")).map((b) => b.dataset.class);
    check(".cls lists the element's classes", clsBoxes.join() === "one,two", clsBoxes);
    const one = document.querySelector('#styles-cls-list input[data-class="one"]');
    one.checked = false; one.dispatchEvent(new Event("change")); await wait(500);
    check(".cls toggles a class off and keeps it listed", await pageEvalV2("document.getElementById('v2-target').className") === "two" && !!document.querySelector('#styles-cls-list input[data-class="one"]'));
    const input = document.querySelector("#styles-cls-input");
    input.value = "three"; input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })); await wait(500);
    check(".cls adds a class", await pageEvalV2("document.getElementById('v2-target').className") === "two three");
    document.querySelector("#styles-cls").click();
    const prop = Array.from(document.querySelectorAll("#styles-list .styles-prop")).find((p) => p.textContent.startsWith("color"));
    prop?.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 20, clientY: 20 })); await wait(100);
    const labels = (el.lastStylesMenu?.items || []).filter((i) => i !== "-").map((i) => i.label);
    ContextMenu.hide();
    check("styles menu: Copy declaration, rule, all declarations, as JS", ["Copy declaration", "Copy rule", "Copy all declarations", "Copy declaration as JS", "Copy all declarations as JS"].every((l) => labels.includes(l)), labels);
    check("Copy as JS uses camelCase", el.jsDeclaration({ name: "font-size", value: "22px" }) === "fontSize: '22px'" && el.jsDeclaration({ name: "-webkit-line-clamp", value: "2" }) === "WebkitLineClamp: '2'");

    // computed
    document.querySelector('#styles-tabs [data-subpanel="computed"]').click(); await wait(600);
    const names = () => Array.from(document.querySelectorAll("#computed-list .computed-row .name")).map((n) => n.textContent);
    const setOnly = names();
    check("computed: only properties a rule sets, by default", setOnly.includes("color") && setOnly.includes("margin-top") && !setOnly.includes("accent-color"), setOnly.slice(0, 12));
    const colorRow = document.querySelector('#computed-list .computed-row[data-name="color"]');
    colorRow?.click(); await wait(100);
    const traceText = colorRow?.nextElementSibling?.textContent || "";
    check("computed: the trace names the rules that set a value", /element\.style/.test(traceText) && /inherited from body/.test(traceText), traceText.slice(0, 200));
    document.querySelector("#computed-show-all").click(); await wait(200);
    check("computed: Show all", names().length > setOnly.length + 50 && names().includes("accent-color"));
    document.querySelector("#computed-group").click(); await wait(200);
    const groups = Array.from(document.querySelectorAll("#computed-list .computed-group-title")).map((g) => g.textContent);
    check("computed: Group by category", ["Layout", "Text", "Appearance"].every((g) => groups.includes(g)), groups);
    document.querySelector("#computed-show-all").click(); document.querySelector("#computed-group").click();

    // layout: editable box model
    document.querySelector('#styles-tabs [data-subpanel="layout"]').click(); await wait(500);
    const marginTop = document.querySelector('#layout-view .box-num[data-prop="margin-top"]');
    check("layout: box-model numbers are editable", marginTop?.textContent === "3");
    await el.editBox(targetId, "margin-top", "7"); await wait(300);
    check("layout: editing a number sets it on the element", await pageEvalV2("getComputedStyle(document.getElementById('v2-target')).marginTop") === "7px" && document.querySelector('#layout-view .box-num[data-prop="margin-top"]').textContent === "7");
    document.querySelector('#styles-tabs [data-subpanel="styles"]').click();
    await pageEvalV2("document.getElementById('v2').remove(); delete window.__v2move; 1");
  }

  // ---- Sources v2 ------------------------------------------------------------------
  {
    const s = DevTools.panels.sources;
    const dbg = SBDebugger;
    DevTools.showPanel("sources"); await wait(500);
    const scriptURL = new URL("/script.js", DevTools.info.url).href;
    const cartURL = new URL("/src/cart.js", DevTools.info.url).href;
    for (let i = 0; i < 50 && !SBSourceMaps.maps.has(new URL("/bundle.js", DevTools.info.url).href); i++) await wait(100);

    // search across all sources
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "f", code: "KeyF", metaKey: true, altKey: true, bubbles: true })); await wait(300);
    check("⌥⌘F opens Search in the drawer", Drawer.current === "source-search" && !document.querySelector("#drawer").hidden);
    document.querySelector("#srcsearch-input").value = "function greet";
    const found = await s.runSearchAll();
    const files = Array.from(document.querySelectorAll("#srcsearch-results .srcsearch-file")).map((f) => f.querySelector(".srcsearch-name").textContent);
    check("search finds matches across sources", found && found.total >= 1 && files.includes("script.js") && !!document.querySelector("#srcsearch-results .srcsearch-hit mark"), files);
    document.querySelector("#srcsearch-input").value = "cartTotal";
    await s.runSearchAll();
    const cartHits = Array.from(document.querySelectorAll("#srcsearch-results .srcsearch-file")).find((f) => f.querySelector(".srcsearch-name").textContent === "cart.js");
    check("search covers original (source-mapped) files", !!cartHits && cartHits.querySelectorAll(".srcsearch-hit").length === 2, cartHits && cartHits.textContent.slice(0, 200));
    cartHits?.querySelectorAll(".srcsearch-hit")[1].click(); await wait(700);
    check("a result opens the file at the line", s.current === cartURL && document.querySelector('#sources-code .code-line.highlight')?.dataset.line === "9", [s.current, document.querySelector('#sources-code .code-line.highlight')?.dataset.line]);
    document.querySelector("#srcsearch-regex").checked = true; document.querySelector("#srcsearch-input").value = "total\\s\\+=";
    const rx = await s.runSearchAll();
    check("search with a regular expression", rx && rx.total >= 1);
    document.querySelector("#srcsearch-regex").checked = false;
    Drawer.hide();

    // go to line / symbol
    s.openGoto("line"); await wait(50);
    const gotoInput = document.querySelector("#sources-goto-input");
    gotoInput.value = ":6"; gotoInput.dispatchEvent(new Event("input"));
    gotoInput.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })); await wait(100);
    check("go to line", document.querySelector("#sources-goto").hidden && document.querySelector('#sources-code .code-line.current-line')?.dataset.line === "6");
    s.openGoto("symbol"); await wait(50);
    const symbols = s.gotoList.map((i) => i.name + ":" + i.line);
    check("go to symbol lists functions", symbols.includes("cartTotal:1") && symbols.includes("checkout:8"), symbols);
    gotoInput.value = "@check"; gotoInput.dispatchEvent(new Event("input"));
    gotoInput.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })); await wait(100);
    check("go to symbol jumps", document.querySelector('#sources-code .code-line.current-line')?.dataset.line === "8");
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "l", metaKey: true, bubbles: true })); await wait(50);
    check("⌘L opens go to line", !document.querySelector("#sources-goto").hidden && gotoInput.value === ":");
    s.closeGoto();

    // brackets, word highlight, folding
    const partner = s.matchBracket(1, s.lines[0].indexOf("{"));
    check("bracket matching", partner && partner.line === 7 && document.querySelectorAll("#sources-code .code-mark.bracket-match").length === 2, partner);
    const words = s.highlightWord("total");
    check("highlights every occurrence of the selected word", words === 4 && document.querySelectorAll("#sources-code .code-mark.word-hit").length === 4, words);
    check("folding ranges for {} blocks", s.foldRanges && s.foldRanges.get(1) === 7 && s.foldRanges.get(8) === 12, s.foldRanges && Array.from(s.foldRanges));
    check("fold toggles in the gutter", !!document.querySelector('#sources-code .code-line[data-line="1"] .fold-toggle'));
    s.toggleFold(1);
    check("folding hides the block", document.querySelector('#sources-code .code-line[data-line="3"]').classList.contains("folded") && !document.querySelector('#sources-code .code-line[data-line="8"]').classList.contains("folded"));
    s.toggleFold(1);
    check("unfolding shows it again", !document.querySelector("#sources-code .code-line.folded"));

    // snippets
    const snippet = s.newSnippet("const v2 = 41;\nv2 + 1"); await wait(400);
    check("a new snippet opens in an editor", s.current === s.snippetURL(snippet.name) && !!document.querySelector("#sources-code .snippet-editor textarea") && !document.querySelector("#sources-nav-snippets").hidden);
    check("the snippet editor highlights", !!document.querySelector("#sources-code .snippet-editor .code-input-mirror .tok-keyword"));
    const ran = await s.runSnippet(snippet);
    check("running a snippet", ran?.result?.description === "42" && document.querySelector("#snippet-result").textContent === "< 42", ran);
    const stored = JSON.parse(await DevTools.rpc("Settings.get", { key: "snippets" }) || "[]");
    check("snippets are kept by the app", stored.some((x) => x.name === snippet.name && x.content.includes("v2 + 1")));
    check("renaming a snippet", s.renameSnippet(snippet, "v2 snippet") && JSON.parse(await DevTools.rpc("Settings.get", { key: "snippets" })).some((x) => x.name === "v2 snippet"));
    s.deleteSnippet(snippet); await wait(200);
    check("deleting a snippet", !JSON.parse(await DevTools.rpc("Settings.get", { key: "snippets" }) || "[]").some((x) => x.name === "v2 snippet") && !s.files.has(s.snippetURL("v2 snippet")));
    s.showNav("page");

    // debugger
    if (dbg.available) {
      for (const bp of dbg.breakpoints.slice()) await dbg.toggle(bp.url, bp.line);
      await s.open(cartURL); await wait(300);
      await dbg.toggle(cartURL, 4);
      await dbg.send("Runtime.evaluate", { expression: "setTimeout(function () { checkout([{ price: 2, qty: 3 }, { price: 1, qty: 1 }]); }, 0); 1" });
      for (let i = 0; i < 50 && !dbg.paused; i++) await wait(100);
      await wait(900);
      check("debugger: paused in cartTotal", dbg.paused && dbg.frames[0]?.functionName === "cartTotal");
      const inlineText = Array.from(document.querySelectorAll("#sources-code .inline-values")).map((e) => e.closest(".code-line").dataset.line + ": " + e.textContent);
      check("debugger: inline values at the end of the lines", inlineText.some((t) => /^4: .*total = 0/.test(t) && /i = 0/.test(t)) && inlineText.some((t) => /^1: items = Array\(2\)/.test(t)), inlineText);
      const hit = dbg.expressionInLine("    total += items[i].price * items[i].qty;", 5, 4);
      check("debugger: the expression under the pointer", hit?.expression === "total", hit);
      const member = dbg.expressionInLine("    total += items[i].price * items[i].qty;", 24, 4);
      check("debugger: a property chain under the pointer", member === null || member.expression === "price" || /price/.test(member.expression), member);
      const value = await dbg.evaluateHover("items.length");
      check("debugger: hover evaluates on the paused frame", value?.description === "2", value);
      const lineEl = document.querySelector('#sources-code .code-line[data-line="4"] .code-text');
      dbg.showPopover({ expression: "items", line: 4 }, await dbg.evaluateHover("items"), 100, 100); await wait(400);
      check("debugger: the value popover", /items/.test(document.querySelector(".dbg-popover")?.textContent || "") && /Array\(2\)/.test(document.querySelector(".dbg-popover")?.textContent || ""), document.querySelector(".dbg-popover")?.textContent);
      dbg.hidePopover();
      check("debugger: Copy call stack", /^cartTotal \(.*cart\.js:4:\d+\) \[generated: .*bundle\.js:\d+:\d+\]\ncheckout \(/.test(dbg.callStackText()), dbg.callStackText().slice(0, 200));
      const md = await dbg.pauseMarkdown();
      check("debugger: Copy for AI", md.startsWith("## Paused in the debugger") && /Paused on breakpoint/.test(md) && /→ +4 \| +total \+=/.test(md) && /### Call stack/.test(md) && /`total` = 0/.test(md) && /`items` = Array\(2\)/.test(md), md.slice(0, 900));
      const menu = dbg.onGutterMenu(6, 10, 10); ContextMenu.hide();
      check("debugger: Continue to here and Never pause here in the gutter menu", menu.some((i) => i.label === "Continue to here") && menu.some((i) => i.label === "Never pause here"), menu.filter((i) => i !== "-").map((i) => i.label));
      await dbg.toggle(cartURL, 4);
      const continued = await dbg.continueToHere(cartURL, 6);
      for (let i = 0; i < 30 && !(dbg.paused && dbg.frames[0] && dbg.frames[0].line === 6); i++) await wait(100);
      check("debugger: Continue to here runs to the line", continued && dbg.paused && dbg.frames[0]?.line === 6, dbg.frames.map((f) => f.functionName + ":" + f.line));
      await dbg.setIgnored(cartURL, true);
      check("debugger: Add script to ignore list", dbg.ignoreList.includes(new URL("/bundle.js", DevTools.info.url).href) && dbg.isIgnoredURL(cartURL) && /bundle\.js/.test(document.querySelector("#dbg-ignore").textContent));
      check("debugger: ignore-listed frames fold away in the call stack", dbg.frames.length >= 2 && document.querySelectorAll("#dbg-stack .dbg-frame").length < dbg.frames.length && /ignore-listed frame/.test(document.querySelector("#dbg-stack").textContent), document.querySelector("#dbg-stack").textContent);
      const persisted = JSON.parse(await DevTools.rpc("Settings.get", { key: "ignoreList" }) || "[]");
      await dbg.setIgnored(cartURL, false);
      check("debugger: the ignore list is kept and can be emptied", persisted.length === 1 && dbg.ignoreList.length === 0);
      await dbg.send("Debugger.resume");
      for (let i = 0; i < 40 && dbg.paused; i++) await wait(100);
      check("debugger: inline values go away on resume", !document.querySelector("#sources-code .inline-values") && !dbg.paused);
      await dbg.neverPauseHere(cartURL, 4);
      check("debugger: Never pause here is a breakpoint that never pauses", dbg.breakpoints.some((b) => b.url === cartURL && b.line === 4 && b.condition === "false") && !!document.querySelector('#sources-code .code-line.breakpoint.never[data-line="4"]') && /Never pause here/.test(document.querySelector("#dbg-breakpoints").textContent));
      await dbg.send("Runtime.evaluate", { expression: "setTimeout(function () { checkout([{ price: 2, qty: 3 }]); }, 0); 1" });
      await wait(1000);
      check("debugger: …and it does not pause", !dbg.paused);
      if (dbg.paused) { await dbg.send("Debugger.resume"); await wait(500); }
      await dbg.toggle(cartURL, 4);
    }
  }

  {
    const snap = await DevTools.rpc("DevTools.snapshot");
    check("DevTools.snapshot pictures DevTools itself", /^data:image\/png;base64,/.test(snap?.dataURL || "") && snap.width > 100, snap && snap.width);
  }

  // ---- Network v2: previews by type, response viewer, headers, cookies, initiator, timing,
  //      filter syntax, columns, copy formats, Copy for AI, Explain failures, HAR import ----------
  {
    const net = DevTools.panels.network;
    DevTools.showPanel("network"); await wait(300);
    net.setFilter(""); net.setExplain(false);
    out.fxSetup = await pageEval(`await new Promise((resolve) => (async () => {
      const paths = ['/fx/page.html', '/fx/feed.xml', '/fx/logo.svg', '/fx/font.ttf', '/fx/blob.bin', '/fx/tone.wav', '/fx/events', '/fx/ndjson',
        '/fx/jsonp?callback=cb_123', '/fx/form', '/fx/style.css', '/fx/big.js', '/fx/cookies', '/fx/timing', '/fx/error', '/fx/redirect'];
      const statuses = [];
      for (const p of paths) { const r = await fetch(p); await r.arrayBuffer(); statuses.push(r.status); }
      const fd = new FormData(); fd.append('title', 'Hello'); fd.append('file', new Blob(['file body'], { type: 'text/plain' }), 'a.txt');
      statuses.push((await fetch('/fx/upload', { method: 'POST', body: fd })).status);
      return statuses.join(',');
    })().then(resolve))`);
    await wait(1500);
    const reqs = () => Array.from(net.requests.values());
    // The request the page made (a Link: preload header can add another row for the same URL).
    const find = (suffix) => { const all = reqs().filter((r) => r.url.endsWith(suffix)); return all.filter((r) => r.sources.length > 1 || r.responseBody != null).pop() || all.pop(); };
    const detail = () => document.querySelector("#network-detail-body");
    const openTab = async (r, tab) => {
      net.select(r.id); net.setDetailTab(tab); net.renderDetail();
      for (let i = 0; i < 50 && /Loading (the full )?response body/.test(detail().textContent); i++) await wait(100);
      await wait(200);
      // A streamed body the page could not read and the engine did not keep: fetch it again, as a user would.
      const again = Array.from(detail().querySelectorAll("button")).find((b) => b.textContent === "Fetch body again");
      if (again && (tab === "preview" || tab === "response")) { again.click(); for (let i = 0; i < 30 && net.get(r.id).responseBody == null; i++) await wait(100); await wait(200); }
      return detail();
    };
    const fontServed = out.fxSetup.split(",")[3] === "200";
    out.fxRequests = reqs().filter((r) => r.url.includes("/fx/")).map((r) => [fileName(r.url), r.sources.join("+"), r.protocolRequestID ? "P" : "-", r.responseBody != null ? r.responseBody.length : "-"].join(" "));
    check("fixture requests ran", /^200,200,200,(200|404),200,200,200,200,200,200,200,200,200,200,500,200,200$/.test(out.fxSetup), out.fxSetup);

    // Preview: HTML rendered without scripts, relative assets resolved, and its formatted source.
    const page = find("/fx/page.html");
    if (page) {
      const body = await openTab(page, "preview");
      const frame = body.querySelector("iframe.nv-frame");
      for (let i = 0; i < 30 && frame && !frame.dataset.loaded; i++) await wait(100);
      const doc = frame && frame.contentDocument;
      check("HTML preview renders the page in a sandboxed frame", body.dataset.previewKind === "html" && frame && frame.getAttribute("sandbox") === "allow-same-origin" && doc && !!doc.querySelector("#fx-title"), body.dataset.previewKind);
      check("HTML preview runs no scripts", doc && doc.body.getAttribute("data-script") !== "ran" && doc.title === "Preview page", doc && doc.title);
      check("HTML preview resolves relative URLs against the response", doc && doc.querySelector("img").src === "http://127.0.0.1:8765/pixel.png", doc && doc.querySelector("img").src);
      body.querySelector('.nv-seg-item[data-value="source"]').click(); await wait(200);
      check("HTML source toggle: formatted and highlighted", body.querySelectorAll(".code-line").length >= 10 && body.querySelectorAll(".tok-tag").length > 5, body.querySelectorAll(".code-line").length);
    } else check("page.html was recorded", false);

    // JSON: tree with expand/collapse all, search and property paths.
    const json = reqs().find((r) => /\/api\/data\.json$/.test(r.url) && r.responseBody);
    if (json) {
      const body = await openTab(json, "preview");
      const view = net.activeView && net.activeView.view;
      check("JSON preview is a tree with a toolbar", body.dataset.previewKind === "json" && view instanceof SBNetPreview.JSONView && /Expand all/.test(body.textContent));
      view.collapseAll();
      view.expandAll();
      check("expand all", body.querySelectorAll(".nv-jnode.expanded").length >= 2);
      check("search finds keys and values", view.search("items") === 1 && view.search("2") >= 1 && !!body.querySelector(".nv-jrow.nv-hit-row.current"), view.hits.length);
      const node = view.reveal(["items", 1]);
      check("property path of a nested value", node && SBNetPreview.pathString(node.path) === "items[1]" && SBNetPreview.pathString(["data", "items", 3, "id"]) === "data.items[3].id" && SBNetPreview.pathString(["a b", 0]) === '["a b"][0]');
      check("JSON context menu: Copy value and Copy property path", node && view.menuItems(node).map((i) => i.label).slice(0, 2).join() === "Copy value,Copy property path" && view.copyValue(view.reveal(["path"])) === json.responseBody.match(/"path": "([^"]*)"/)[1]);
    } else check("a JSON body was recorded", false);

    const kindChecks = [
      ["/fx/jsonp?callback=cb_123", "jsonp", (b) => b.textContent.includes("cb_123") && b.textContent.includes("jsonp")],
      ["/fx/ndjson", "ndjson", (b) => b.querySelectorAll(".nv-record").length === 3 && /3 records/.test(b.textContent)],
      ["/fx/events", "sse", (b) => Array.from(b.querySelectorAll(".nv-sse-row td:nth-child(2)")).map((td) => td.textContent).join() === "greeting,message,done" && /retry 2000 ms/.test(b.textContent)],
      ["/fx/feed.xml", "xml", (b) => /RSS feed “Fixture feed” · 2 items/.test(b.textContent) && !!b.querySelector(".nv-xml .nv-xnode") && b.textContent.includes("First post") && b.textContent.includes("CDATA")],
      ["/fx/form", "form", (b) => b.textContent.includes("Ada Lovelace") && b.textContent.includes("café")],
      ["/fx/style.css", "css", (b) => b.querySelectorAll(".code-line").length >= 8 && !!b.querySelector(".tok-prop")],
    ];
    for (const [path, kind, test] of kindChecks) {
      const r = find(path);
      const b = r ? await openTab(r, "preview") : null;
      check(`preview of ${path} as ${kind}`, b && b.dataset.previewKind === kind && test(b), b && { kind: b.dataset.previewKind, text: b.textContent.slice(0, 160) });
    }

    // Images, SVG, fonts, media and binary need the bytes: the protocol keeps them.
    if (SBDebugger.available) {
      const svg = find("/fx/logo.svg");
      let b = svg ? await openTab(svg, "preview") : detail();
      await wait(300);
      check("SVG preview renders the image with its dimensions", b && b.dataset.previewKind === "svg" && b.querySelector(".nv-image-box")?.dataset.width === "40", b && b.textContent.slice(0, 120));
      b.querySelector('.nv-seg-item[data-value="tree"]')?.click(); await wait(150);
      check("SVG as an XML tree", !!b.querySelector(".nv-xml") && b.textContent.includes("circle"));
      const pixel = reqs().filter((r) => r.url.endsWith("/pixel.png")).pop();
      b = await openTab(pixel, "preview"); await wait(300);
      check("image preview: natural size, bytes, MIME, checkerboard", b.dataset.previewKind === "image" && b.querySelector(".nv-image-box")?.dataset.width === "1" && /image\/png/.test(b.textContent) && !!b.querySelector(".nv-checker"), b.textContent.slice(0, 120));
      if (fontServed) {
        const font = find("/fx/font.ttf");
        b = await openTab(font, "preview");
        for (let i = 0; i < 30 && b.querySelector(".nv-font")?.dataset.fontStatus === "loading"; i++) await wait(100);
        check("font preview loads the font and shows samples", b.dataset.previewKind === "font" && b.querySelector(".nv-font")?.dataset.fontStatus === "loaded" && b.querySelectorAll(".nv-font-sample").length === 6, b.textContent.slice(0, 160));
      }
      const wav = find("/fx/tone.wav");
      b = await openTab(wav, "preview");
      check("audio preview is a player", b.dataset.previewKind === "media" && /^data:audio\/wav/.test(b.querySelector("audio")?.getAttribute("src") || ""), b.textContent.slice(0, 120));
      const bin = find("/fx/blob.bin");
      b = await openTab(bin, "preview");
      const hexRows = Array.from(b.querySelectorAll(".nv-hex-row:not(.nv-hex-head)"));
      check("binary preview is a hex dump", b.dataset.previewKind === "binary" && hexRows.length === Math.ceil(534 / 16) && hexRows[0].textContent.startsWith("0000000000 01 02 03") && hexRows[16].querySelector(".nv-hex-ascii").textContent.startsWith("Keel he"), hexRows.slice(0, 1).map((r) => r.textContent).concat(hexRows[16]?.textContent));
      b = await openTab(bin, "response");
      check("binary response: hex and Save", !!b.querySelector(".nv-hex") && Array.from(b.querySelectorAll("button")).some((x) => x.textContent === "Save…"));
    }

    // Response tab: line numbers, highlighting, pretty-print, wrap, find (⌘F in the pane), copy and save.
    const script = reqs().filter((r) => r.url.endsWith("/fx/style.css")).pop();
    if (script) {
      const b = await openTab(script, "response");
      const view = net.activeView.view;
      check("response viewer: line numbers and highlighting", !!b.querySelector(".code-line .ln") && !!b.querySelector(".tok-prop") && /Copy/.test(b.textContent) && /Save…/.test(b.textContent));
      const before = b.querySelectorAll(".code-line").length;
      b.querySelector(".nv-pretty").click(); await wait(100);
      check("{ } pretty-prints the response", b.querySelectorAll(".code-line").length > before && b.querySelector(".nv-pretty").classList.contains("active"), [before, b.querySelectorAll(".code-line").length]);
      const wrap = b.querySelector(".nv-code-view input[type=checkbox]");
      const wrapped = !b.querySelector(".nv-scroll").classList.contains("nv-nowrap");
      wrap.click();
      check("word wrap toggle", b.querySelector(".nv-scroll").classList.contains("nv-nowrap") === wrapped);
      wrap.click();
      net.pointerInDetail = true;
      document.dispatchEvent(new KeyboardEvent("keydown", { key: "f", metaKey: true, bubbles: true })); await wait(100);
      check("⌘F in the response pane opens its find bar, not the drawer", !b.querySelector(".nv-find").hidden && Drawer.current !== "search", Drawer.current);
      const input = b.querySelector(".nv-find-input");
      input.value = "padding"; input.dispatchEvent(new Event("input")); await wait(300);
      check("find highlights matches with a count", b.querySelectorAll("mark.nv-hit").length >= 1 && !!b.querySelector("mark.nv-hit.current") && /^1 of \d+/.test(b.querySelector(".nv-find-count").textContent), b.querySelector(".nv-find-count").textContent);
      view.step(1);
      check("next/previous match", view.matches.length < 2 || view.current === 1);
      net.pointerInDetail = false;
    }

    // A 2.6 MB minified script stays fast: only the visible lines are drawn.
    const big = find("/fx/big.js");
    if (big && SBDebugger.available) {
      let t0 = performance.now();
      let b = await openTab(big, "response");
      const view = net.activeView && net.activeView.view;
      out.bigResponseMs = Math.round(performance.now() - t0 - 200);
      check("large response renders quickly and virtualized", view && view.virtual && b.querySelectorAll(".code-line").length < 400 && !!b.querySelector(".nv-notice") && out.bigResponseMs < 3000, { ms: out.bigResponseMs, lines: b.querySelectorAll(".code-line").length });
      t0 = performance.now();
      view.setPretty(true);
      out.bigPrettyMs = Math.round(performance.now() - t0);
      check("pretty-printing 2.6 MB is fast", view.lines.length > 10000 && b.querySelectorAll(".code-line").length < 400 && out.bigPrettyMs < 4000, { ms: out.bigPrettyMs, lines: view.lines.length });
      check("find works across the whole large text", view.find("item-4242") >= 1 && !!b.querySelector("mark.nv-hit.current"), view.matches.length);
      t0 = performance.now();
      b = await openTab(big, "preview");
      out.bigPreviewMs = Math.round(performance.now() - t0 - 200);
      check("large script preview is formatted and virtualized", b.dataset.previewKind === "js" && b.querySelectorAll(".code-line").length < 400 && out.bigPreviewMs < 4000, out.bigPreviewMs);
    }

    // Headers: raw toggle, filter, notable headers, links, per-header copy, referrer policy, remote address.
    const timing = find("/fx/timing");
    if (timing) {
      let b = await openTab(timing, "headers");
      check("notable headers are highlighted", !!b.querySelector('.nv-header.nv-notable[data-header="content-security-policy"]') && !!b.querySelector('.nv-header.nv-notable[data-header="access-control-allow-origin"] .nv-tag'));
      check("URL-valued headers are links", !!b.querySelector('.nv-header[data-header="link"] a.link'));
      check("each header has Copy", b.querySelectorAll(".nv-header .nv-copy").length === b.querySelectorAll(".nv-header").length && b.querySelectorAll(".nv-header").length > 4);
      check("Referrer Policy in General", /Referrer Policyno-referrer/.test(b.textContent));
      check("slow request flagged in General", /Slow: 1\.\d+ s/.test(b.textContent), b.textContent.slice(0, 300));
      if (SBDebugger.available) check("Remote Address from the engine", /Remote Address127\.0\.0\.1:8765/.test(b.textContent) || !net.ext(timing).remoteAddress, net.ext(timing));
      net.rawSections.add("response"); net.renderDetail();
      b = detail();
      check("raw response headers as HTTP/1.1 text", /HTTP\/1\.1 200 OK\nAccess-Control-Allow-Origin: \*/i.test(b.querySelector(".nv-raw-text")?.textContent || ""), b.querySelector(".nv-raw-text")?.textContent.slice(0, 80));
      net.rawSections.clear();
      net.headerFilter = "server-timing"; net.renderDetail();
      check("header filter", detail().querySelectorAll(".nv-header").length === 1, detail().querySelectorAll(".nv-header").length);
      net.headerFilter = ""; net.renderDetail();
      b = await openTab(timing, "timing");
      check("timing: Server-Timing entries, queued and started times", b.querySelectorAll(".nv-server-timing").length === 3 && b.textContent.includes("Database") && /Queued at/.test(b.textContent) && /Started at/.test(b.textContent), b.textContent.slice(0, 200));
    }

    // Cookies: parsed request and response cookies with attributes and issues.
    const parsed = SBNet.parseSetCookies("a=1; Path=/; SameSite=None\nsess_id=2; Secure; SameSite=Lax; Expires=Wed, 21 Oct 2037 07:28:00 GMT, c=3; HttpOnly; Secure; SameSite=Strict");
    check("Set-Cookie parsing, folded or not", parsed.map((c) => c.name).join() === "a,sess_id,c" && parsed[1].expires.includes("2037") && parsed[2].httpOnly && parsed[2].sameSite === "Strict", parsed);
    check("cookie issues", SBNet.cookieIssues(parsed[0], "https://x.test/").some((i) => /SameSite=None without Secure/.test(i)) && SBNet.cookieIssues(parsed[1], "https://x.test/").some((i) => /HttpOnly/.test(i)) && SBNet.cookieIssues(parsed[2], "https://x.test/").length === 0);
    const cookieReq = find("/fx/cookies");
    out.setCookieHeader = cookieReq && SBNet.header(cookieReq.responseHeaders, "set-cookie");
    if (cookieReq && out.setCookieHeader) {
      net.select(cookieReq.id);
      check("Cookies tab appears for a request with cookies", !document.querySelector('#network-detail-tabs [data-subpanel="cookies"]').hidden);
      const b = await openTab(cookieReq, "cookies"); await wait(300);
      const rows = Array.from(b.querySelectorAll(".nv-cookies tbody tr")).map((tr) => tr.textContent);
      check("response cookies table with attributes and flagged issues", rows.some((t) => t.includes("fx_session") && t.includes("Strict") && t.includes("Max-Age=3600")) && b.querySelectorAll(".nv-cookie-issue").length >= 1 && /fx_track: SameSite=None without Secure/.test(b.textContent), rows);
    } else check("Set-Cookie headers reach the Network panel", !SBDebugger.available, cookieReq && cookieReq.responseHeaders);
    if (SBDebugger.available) {
      const withCookie = reqs().find((r) => SBNet.header(r.requestHeaders, "cookie"));
      if (withCookie) {
        const b = await openTab(withCookie, "cookies"); await wait(300);
        check("request cookies table", /Request Cookies/.test(b.textContent) && b.textContent.includes("session"), b.textContent.slice(0, 200));
      }
    }

    // Initiator: the stack of the script that made the request, and the chain from the document.
    if (SBDebugger.available) {
      const scripted = reqs().find((r) => net.initiatorFrames(net.ext(r).initiator).length && r.url.includes("/api/data.json"));
      if (scripted) {
        const b = await openTab(scripted, "initiator");
        check("initiator call stack links into Sources", b.querySelectorAll(".nv-frame-row .link").length >= 1 && /Request initiator chain/.test(b.textContent), b.textContent.slice(0, 200));
      } else check("an initiator stack was captured for a fetch", false, reqs().map((r) => fileName(r.url) + ":" + JSON.stringify(net.ext(r).initiator || null).slice(0, 60)).slice(0, 8));
    }
    const docReq = reqs().find((r) => r.resourceType === "document");
    if (docReq) check("initiator tab degrades gracefully", (await openTab(docReq, "initiator")).textContent.includes("Initiator type"));

    // Payload: multipart form data as a table.
    const upload = find("/fx/upload");
    out.uploadBody = upload && String(upload.requestBody).slice(0, 120);
    if (upload && upload.requestBody && /form-data/.test(upload.requestBody)) {
      const b = await openTab(upload, "payload");
      check("multipart payload as a table", /Form Data \(multipart, 2 parts\)/.test(b.textContent) && b.textContent.includes("a.txt") && b.textContent.includes("Hello"), b.textContent.slice(0, 200));
    }
    const mp = SBNetPreview.parseMultipart('--B\r\nContent-Disposition: form-data; name="t"\r\n\r\nHi\r\n--B\r\nContent-Disposition: form-data; name="f"; filename="a.txt"\r\nContent-Type: text/plain\r\n\r\nbody\r\n--B--\r\n', "multipart/form-data; boundary=B");
    check("multipart parsing", mp && mp.length === 2 && mp[1].filename === "a.txt" && mp[0].value === "Hi", mp);
    const post = reqs().find((r) => r.method === "POST" && r.url.endsWith("/api/post"));
    if (post) {
      const b = await openTab(post, "payload");
      check("JSON payload as a tree with view source", b.querySelector(".nv-json") && /view source/.test(b.textContent));
    }

    // Filter syntax and invert.
    const names = () => net.visibleRequests().map((r) => r.url);
    net.setFilter("status-code:500");
    check("filter status-code:", names().length >= 1 && names().every((u) => u.endsWith("/fx/error")), names());
    net.setFilter("-status-code:200");
    check("negated filter", net.visibleRequests().every((r) => r.statusCode !== 200) && names().length >= 2, names().length);
    net.setFilter("method:POST");
    check("filter method:", net.visibleRequests().length >= 2 && net.visibleRequests().every((r) => r.method === "POST"));
    net.setFilter("larger-than:1M");
    check("filter larger-than:", SBDebugger.available ? names().length === 1 && names()[0].endsWith("/fx/big.js") : true, names());
    net.setFilter("/fx\\/(feed|ndjson)/");
    check("regex filter", names().length === 2, names());
    net.setFilter("has-response-header:server-timing domain:127.0.0.1*");
    check("has-response-header: and domain: combined", names().length === 1 && names()[0].endsWith("/fx/timing"), names());
    net.setFilter("mime-type:application/x-ndjson");
    check("filter mime-type:", names().length === 1);
    net.setFilter("is:running");
    check("is:running", names().length === 0, names());
    net.setFilter("method:POST"); document.querySelector("#network-invert").click();
    check("invert", net.visibleRequests().length > 3 && net.visibleRequests().every((r) => r.method !== "POST"));
    document.querySelector("#network-invert").click();
    net.setFilter("");

    // Columns, summary bar, keyboard.
    check("default columns", Array.from(document.querySelectorAll("#network-table thead th")).map((th) => th.textContent).join() === "Name,Status,Type,Initiator,Size,Time,Waterfall");
    check("column menu lists every optional column", net.columnItems().filter((i) => i !== "-").length === 14);
    net.setColumnVisible("method", true); net.setColumnVisible("domain", true); net.setColumnVisible("remote", true);
    const methodCells = Array.from(document.querySelectorAll("#network-table tbody td.col-method")).map((td) => td.textContent);
    check("show Method, Domain and Remote Address columns", !!document.querySelector('#network-table th[data-col="method"]') && methodCells.includes("POST") && document.querySelector("#network-table tbody td.col-domain")?.textContent === "127.0.0.1:8765");
    net.setColumnVisible("method", false); net.setColumnVisible("domain", false); net.setColumnVisible("remote", false);
    check("hide them again", !document.querySelector('#network-table th[data-col="method"]') && JSON.parse(localStorage.getItem("devtools.network.columns")).includes("method"));
    check("status text is shown and coloured", !!document.querySelector("#network-table tbody .nv-status-bad") && Array.from(document.querySelectorAll("#network-table tbody td.col-status")).some((td) => td.textContent === "500 Internal Server Error"));
    await net.loadPageTiming();
    out.networkSummary = document.querySelector("#network-status").textContent;
    check("summary bar", /\d+ requests/.test(out.networkSummary) && /transferred/.test(out.networkSummary) && /resources/.test(out.networkSummary) && /Finish:/.test(out.networkSummary) && /DOMContentLoaded: /.test(out.networkSummary) && /Load: /.test(out.networkSummary), out.networkSummary);
    const rows = Array.from(document.querySelectorAll("#network-table tbody tr[data-id]"));
    net.select(rows[1].dataset.id);
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
    check("↓ selects the next request", net.selectedId === rows[2].dataset.id);
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true }));
    check("↑ selects the previous one", net.selectedId === rows[1].dataset.id);

    // Copy submenu and formats.
    const copyLabels = net.contextItems(post)[0].submenu.filter((i) => i !== "-").map((i) => i.label);
    check("Copy submenu has every format", ["Copy URL", "Copy as cURL", "Copy as fetch", "Copy as fetch (Node.js)", "Copy as PowerShell", "Copy response", "Copy as HAR entry", "Copy as Markdown (for AI)", "Copy all URLs", "Copy all as cURL", "Copy all as HAR"].every((l) => copyLabels.includes(l)), copyLabels);
    net.showMenu(10, 10, net.contextItems(post));
    check("the context menu shows Copy as a submenu", !!document.querySelector("#context-menu .nv-has-submenu .nv-submenu .item"));
    ContextMenu.hide();
    out.powershell = net.asPowerShell(post);
    check("Copy as PowerShell", out.powershell.includes('Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:8765/api/post"') && out.powershell.includes('-Method "POST"') && out.powershell.includes('-Body "{`"hello`":`"world`"}"'), out.powershell);
    const nodeFetch = net.asNodeFetch(post);
    check("Copy as fetch (Node.js)", nodeFetch.startsWith('fetch("http://127.0.0.1:8765/api/post"') && nodeFetch.includes('"method": "POST"'), nodeFetch);
    const entry = net.harEntry(post);
    check("Copy as HAR entry", entry.request.method === "POST" && entry.request.postData.text === '{"hello":"world"}' && entry.response.status === 201, entry.request);
    check("Copy all as cURL", net.allAsCurl().split(" ;\n").length === net.visibleRequests().length);

    // Copy for AI.
    const errorReq = find("/fx/error");
    const md = net.asMarkdown(errorReq);
    out.aiMarkdown = md;
    check("Copy for AI: status line, issues, key headers only, body", md.startsWith("## GET http://127.0.0.1:8765/fx/error → 500 Internal Server Error") && /- Issues: Server error 500/.test(md) && md.includes('"error": "boom"') && !/^date:/im.test(md) && /more omitted/.test(md), md.slice(0, 400));
    const slowMd = net.asMarkdown(timing);
    check("Copy for AI notes slow requests and Server-Timing", /Issues: .*Slow: 1\.\d+ s/.test(slowMd) && /Server-Timing: Database 53\.2 ms/.test(slowMd), slowMd.slice(0, 400));
    if (big && SBDebugger.available) {
      const bigMd = net.asMarkdown(await net.withBody(big));
      check("Copy for AI truncates a large body, keeping head and tail", bigMd.length < 9000 && /middle omitted/.test(bigMd) && /Large: \d\.\d+ MB/.test(bigMd) && /Uncompressed text/.test(bigMd), bigMd.slice(0, 300));
    }
    const binMd = find("/fx/blob.bin") && net.asMarkdown(await net.withBody(find("/fx/blob.bin")));
    check("Copy for AI leaves binary bodies out", !binMd || /binary application\/octet-stream/.test(binMd) || /not captured/.test(binMd), binMd && binMd.slice(-200));
    check("CORS failures are recognised", SBNet.issues({ url: "http://api.other.test/x", resourceType: "fetch", requestHeaders: { Origin: "http://127.0.0.1:8765" }, responseHeaders: { "content-type": "application/json" }, statusCode: 200 }).some((i) => i.kind === "cors"));

    // Explain failures.
    net.setExplain(true);
    const explained = net.visibleRequests();
    check("Explain failures shows only failed, blocked and slow requests", explained.some((r) => r.url.endsWith("/fx/error")) && explained.some((r) => r.url.endsWith("/missing")) && explained.some((r) => r.url.endsWith("/fx/timing")) && !explained.some((r) => r.url.endsWith("/fx/page.html")), explained.map((r) => fileName(r.url)));
    check("with the reason under each name and a summary", !document.querySelector("#network-explain-bar").hidden && /\d 5xx/.test(document.querySelector("#network-explain-bar").textContent) && !!document.querySelector("#network-table .nv-reason"));
    const failuresMd = await net.failuresMarkdown();
    check("failures as Markdown for AI", failuresMd.startsWith("# Failed, blocked and slow requests") && failuresMd.includes("/fx/error"), failuresMd.slice(0, 200));
    net.setExplain(false);

    // Import HAR: a read-only session, then back to the live log.
    const liveCount = net.all().length;
    const har = net.harFromRequests(net.all().filter((r) => /\/api\/data\.json$|\/fx\/error$/.test(r.url)));
    har.log.entries.push({ startedDateTime: new Date().toISOString(), time: 12, request: { method: "GET", url: "https://example.test/img.png", headers: [] },
      response: { status: 200, statusText: "OK", headers: [{ name: "content-type", value: "image/png" }], content: { size: 68, mimeType: "image/png", encoding: "base64",
        text: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==" } }, timings: { blocked: 1, dns: -1, connect: -1, send: 0, wait: 8, receive: 3 } });
    net.importHAR(JSON.stringify(har), "fixture.har");
    check("an imported HAR is shown as a read-only session", net.session && net.all().length === har.log.entries.length && !document.querySelector("#network-session-bar").hidden && /fixture\.har/.test(document.querySelector("#network-session-bar").textContent));
    const imported = net.all().find((r) => r.url.endsWith("/api/data.json"));
    let b = await openTab(imported, "preview");
    check("imported bodies preview", b.dataset.previewKind === "json");
    const importedImage = net.all().find((r) => r.url.endsWith("img.png"));
    b = await openTab(importedImage, "preview"); await wait(300);
    check("imported base64 bodies preview as images", b.dataset.previewKind === "image" && b.querySelector(".nv-image-box")?.dataset.width === "1");
    check("imported requests have no blocking or override actions", !net.contextItems(importedImage).some((i) => i.label === "Block request URL"));
    net.closeSession();
    check("back to the live log", !net.session && net.all().length === liveCount && document.querySelector("#network-session-bar").hidden);
    net.closeDetail();
  }

  // ---- Developer extensions: Components, dataLayer, PHP, Node, Claude, JSON responses ----------------
  {
    const evalPage = (expression) => DevTools.rpc("Console.evaluate", { expression });
    await SBExt.load();
    check("extensions report which are on", SBExt.loaded && typeof SBExt.states.react === "boolean", SBExt.states);
    check("the toolbar has the screen colour picker", !document.querySelector("#btn-colorpick").hidden);
    check("PHP, Node and Claude tabs are there", ["php", "node", "claude"].every((p) => !document.querySelector(`#tabs .tab[data-panel="${p}"]`).hidden));

    // Components: a renderer registered through the global hook, as react-dom does.
    await evalPage(`(() => {
      const hook = window.__REACT_DEVTOOLS_GLOBAL_HOOK__;
      if (!hook) return "no hook";
      const id = hook.inject({ version: "18.3.1", rendererPackageName: "react-dom", bundleType: 1 });
      const host = document.createElement("div"); host.id = "react-fixture"; host.textContent = "React fixture"; document.body.appendChild(host);
      const counterHook = { memoizedState: 3, next: null };
      counterHook.queue = { dispatch(v) { counterHook.memoizedState = v; }, lastRenderedReducer: function basicStateReducer() {} };
      const counter = { tag: 0, type: function Counter() {}, key: "c1", memoizedProps: { step: 1, label: "Clicks" }, memoizedState: counterHook, child: null, sibling: null };
      const div = { tag: 5, type: "div", stateNode: host, key: null, memoizedProps: {}, child: counter, sibling: null };
      const app = { tag: 0, type: function App() {}, key: null, memoizedProps: { title: "Fixture" }, memoizedState: null, child: div, sibling: null };
      const rootFiber = { tag: 3, child: app };
      counter.return = div; div.return = app; app.return = rootFiber; counter._debugOwner = app;
      host["__reactFiber$fixture"] = div;
      hook.onCommitFiberRoot(id, { current: rootFiber });
      return "ok";
    })()`);
    await wait(200);
    await SBReact.detect();
    check("Components appears once React is seen", !document.querySelector('#tabs .tab[data-panel="components"]').hidden);
    DevTools.showPanel("components"); await wait(500);
    const names = SBReact.nodes.map((n) => n.name);
    check("the tree lists components, not host elements", names.join(",") === "App,Counter", names);
    const counterNode = SBReact.nodes.find((n) => n.name === "Counter");
    const appNode = SBReact.nodes.find((n) => n.name === "App");
    if (counterNode) {
      await SBReact.inspect(counterNode.id); await wait(150);
      check("props are shown", JSON.stringify(SBReact.info.props).includes("Clicks"), SBReact.info.props);
      check("useState is listed and editable", SBReact.info.hooks.length === 1 && SBReact.info.hooks[0].kind === "useState" && SBReact.info.hooks[0].editable, SBReact.info.hooks);
      check("its owner is App", SBReact.info.owners.length === 1 && SBReact.info.owners[0].name === "App", SBReact.info.owners);
      check("its key is shown", document.querySelector("#react-detail").textContent.includes('key="c1"'));
      await DevTools.rpc("React.call", { method: "React.setState", params: { id: counterNode.id, hookIndex: 0, value: 7 } });
      const after = await DevTools.rpc("React.call", { method: "React.inspect", params: { id: counterNode.id } });
      check("editing a hook dispatches the new state", after.hooks[0].value === 7, after.hooks);
      check("hover highlights the component's DOM", (await DevTools.rpc("React.call", { method: "React.highlight", params: { id: appNode.id } })) === true);
      await DevTools.rpc("React.call", { method: "React.unhighlight", params: {} });
      check("a component copies as Markdown for AI", SBReact.markdown(SBReact.info).includes("<Counter>"));
    }
    const fromDOM = await DevTools.rpc("React.call", { method: "React.fromSelector", params: { selector: "#react-fixture" } });
    check("Elements → Components finds the component that rendered an element", appNode && fromDOM === appNode.id, fromDOM);
    $("#react-host").checked = true; SBReact.showHost = true; await SBReact.refresh(true);
    check("host elements on request", SBReact.nodes.map((n) => n.name).join(",") === "App,div,Counter", SBReact.nodes.map((n) => n.name));
    $("#react-host").checked = false; SBReact.showHost = false;

    // dataLayer: pushes before and after Tag Manager replaces push, and gtag's arguments.
    await evalPage(`window.dataLayer = window.dataLayer || []; dataLayer.push({ event: "page_view", page: "fixture" }); dataLayer.push({ event: "add_to_cart", value: 9.5 }); "ok"`);
    await evalPage(`(() => { function gtag(){ dataLayer.push(arguments); } gtag("event", "sign_up", { method: "email" });
      const own = dataLayer.push; dataLayer.push = function () { window.__gtmSaw = (window.__gtmSaw || 0) + 1; return Array.prototype.push.apply(this, arguments); };
      dataLayer.push({ event: "after_gtm" }); return window.__gtmSaw; })()`);
    await SBDataLayer.detect();
    check("dataLayer appears once a page uses it", !document.querySelector('#tabs .tab[data-panel="datalayer"]').hidden);
    DevTools.showPanel("datalayer"); await wait(300); await SBDataLayer.refresh();
    const events = SBDataLayer.events.map((e) => e.event);
    check("every push is recorded in order", ["page_view", "add_to_cart", "sign_up", "after_gtm"].every((e, i, all) => events.indexOf(e) >= 0 && (i === 0 || events.indexOf(e) > events.indexOf(all[i - 1]))), events);
    check("gtag calls are read as events", SBDataLayer.events.some((e) => e.event === "sign_up" && e.gtag));
    check("pushes after Tag Manager takes over push are still seen, and still reach it", events.includes("after_gtm") && (await evalPage("window.__gtmSaw")) !== null);
    check("the list renders", $$("#dl-list .dl-row").length >= 4, $$("#dl-list .dl-row").length);
    const model = await DevTools.rpc("DataLayer.call", { method: "DataLayer.state", params: {} });
    check("the merged model folds the pushes together", model.value === 9.5 && model.page === "fixture", model);
    DevTools.rpc("DataLayer.call", { method: "DataLayer.clear", params: {} });

    // PHP: a Clockwork-instrumented response, its profile, N+1 detection, Xdebug cookies.
    await evalPage(`fetch("/ext/clockwork-api").then((r) => r.text())`);
    await wait(900);
    DevTools.showPanel("php"); await wait(200); await SBPHP.refresh(); await wait(800);
    check("PHP lists requests that carry a Clockwork profile", SBPHP.requests.length === 1, SBPHP.requests.map((r) => r.url));
    const profile = SBPHP.requests[0] && SBPHP.profiles.get(SBPHP.requests[0].id);
    check("the profile is fetched and read", profile && profile.queries.length === 4 && profile.controller.includes("OrderController"), profile && profile.controller);
    if (profile) {
      check("N+1 query shapes are found", SBPHP.duplicates(profile.queries).some((d) => d.count === 3));
      SBPHP.tab = "database"; SBPHP.renderDetail(profile);
      check("the database tab marks repeated queries", $$("#php-detail .php-dup").length === 3);
      check("errors in the log are called out", SBPHP.markdown(profile, SBPHP.duplicates(profile.queries)).includes("Payment gateway timed out"));
      SBPHP.tab = "overview";
    }
    const xdebugOn = await DevTools.rpc("PHP.setXdebug", { mode: "debug", on: true, ideKey: "VSCODE" });
    check("Xdebug debug sets XDEBUG_SESSION for the site", xdebugOn.debug === "VSCODE", xdebugOn);
    const xdebugOff = await DevTools.rpc("PHP.setXdebug", { mode: "debug", on: false });
    check("…and clears it", !xdebugOff.debug, xdebugOff);

    // Node: a process started with --inspect by the test script, when Node is installed.
    const targets = await DevTools.rpc("Node.targets", { ports: [9339] });
    if (targets.length) {
      DevTools.showPanel("node"); await wait(100);
      $("#node-ports").value = "9339"; await SBNode.discover();
      check("Node targets are found on the inspector port", SBNode.targets.length === 1 && /node/i.test(SBNode.targets[0].version || "node"), SBNode.targets);
      await SBNode.connect(SBNode.targets[0]); await wait(1600);
      check("the console shows the process's output", $("#node-console").textContent.includes("node fixture tick"));
      await SBNode.evaluate("fixtureValue * 2"); await wait(400);
      check("the REPL evaluates in the process", $("#node-console").textContent.includes("42"), $("#node-console").textContent.slice(-200));
      await SBNode.cdp.send("Debugger.pause"); await wait(900);
      check("pause stops the process and shows the stack", !!SBNode.paused && $$("#node-stack .node-frame").length > 0);
      if (SBNode.paused) { await SBNode.cdp.send("Debugger.resume"); await wait(300); }
      check("resume runs it again", !SBNode.paused);
      SBNode.disconnect();
    } else {
      out.notes = (out.notes || []).concat("Node panel: no node binary, live checks skipped");
    }

    // Claude: no network call in the tests; the panel and its state only.
    const claude = await DevTools.rpc("Claude.state");
    check("Claude reports its model", claude.model === "claude-opus-5-5", claude);
    DevTools.showPanel("claude"); await wait(300);
    check("Claude shows the key form or the chat", claude.hasKey ? !$("#claude-chat").hidden : !$("#claude-key-form").hidden);
    check("context can be attached", $$("#claude-contexts input").length === 6);
    const context = await SBClaude.gather();
    check("attached context is wrapped as data", context.startsWith("<context>") && context.includes("<page>"), context.slice(0, 200));

    // The JSON Viewer inside Network's Response tab.
    await evalPage(`fetch("/ext/data.json").then((r) => r.json())`);
    await wait(700);
    DevTools.showPanel("network"); await wait(200);
    const netPanel = DevTools.panels.network;
    const jsonRequest = Array.from(netPanel.requests.values()).reverse().find((r) => r.url.includes("/ext/data.json"));
    check("the JSON request is listed", !!jsonRequest);
    if (jsonRequest) {
      // The page hooks deliver the body a moment after the request finishes.
      for (let i = 0; i < 20 && !(netPanel.requests.get(jsonRequest.id) || {}).responseBody; i++) {
        try { const updated = await DevTools.rpc("Network.getResponseBody", { id: jsonRequest.id }); if (updated.responseBody) netPanel.requests.set(updated.id, updated); } catch (_) {}
        await wait(150);
      }
      netPanel.select(jsonRequest.id); await wait(200);
      netPanel.setDetailTab("response"); netPanel.renderDetail(); await wait(700);
      const body = $("#network-detail-body");
      check("Response shows JSON as a tree", !!body.querySelector(".nv-json-view") && body.textContent.includes("orders"), body.textContent.slice(0, 200));
      const codeButton = Array.from(body.querySelectorAll(".nv-seg-item")).find((b) => b.textContent === "Code");
      if (codeButton) { codeButton.click(); await wait(200); }
      check("…or as code, at a click", !body.querySelector(".nv-json-view"));
      const treeButton = Array.from(body.querySelectorAll(".nv-seg-item")).find((b) => b.textContent === "JSON tree");
      if (treeButton) treeButton.click();
      netPanel.closeDetail();
    }
    DevTools.showPanel("elements"); await wait(100);
  }

  // ---- Disable JavaScript, Clear site data (last: they reload and wipe the fixture's state) ----
  if (SBDebugger.available) {
    const statusText = async () => {
      const found = await DevTools.rpc("DOM.performSearch", { query: "#status" });
      return found.nodeIds.length ? (await DevTools.rpc("DOM.getOuterHTML", { nodeId: found.nodeIds[0] })) : "";
    };
    await SBRendering.set("disableJavaScript", true);
    await DevTools.rpc("Page.reload"); await wait(2500);
    out.noScript = await statusText().catch((e) => "agent failed: " + e.message);
    check("Disable JavaScript stops the page's scripts, and DevTools still works", /running…/.test(out.noScript), out.noScript);
    await SBRendering.set("disableJavaScript", false);
    await DevTools.rpc("Page.reload"); await wait(2500);
    check("Enable JavaScript brings them back", /done/.test(await statusText().catch(() => "")));
  }
  const cleared = await DevTools.rpc("Storage.clearSiteData");
  check("Clear site data removes the site's records", cleared.records.length > 0, cleared);
  check("its cookies are gone", (await DevTools.rpc("Cookies.list")).length === 0);
  check("its local storage is empty", (await DevTools.rpc("Storage.getEntries", { area: "local" })).length === 0);

  DevTools.showPanel("elements"); await wait(200);
} catch (e) {
  out.failures.push("driver threw: " + String(e && e.stack || e));
}
out.passed = out.failures.length === 0;
return out;
