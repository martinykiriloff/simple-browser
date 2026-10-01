// Drives every DevTools panel from inside the DevTools UI and returns a
// report. There is no XCTest on a Command Line Tools-only Mac, so this is
// the DevTools test suite:
//
//   python3 Tests/Fixtures/devtools/server.py &
//   swift run SimpleBrowser --show-devtools \
//     --devtools-script Tests/Fixtures/devtools/drive-all.js \
//     --devtools-out /tmp/devtools-report.json --devtools-delay 4 http://127.0.0.1:8765/
//
// The body runs as an async function inside the DevTools web view.
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const out = { failures: [] };
const check = (name, ok, detail) => { if (!ok) out.failures.push(name + (detail !== undefined ? ": " + JSON.stringify(detail) : "")); };
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
    const labels = net.copyItems(dataReq).filter((i) => i !== "-").map((i) => i.label);
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
    check("Copy as Markdown has method, status, payload and response", out.markdown && out.markdown.startsWith("## POST 201 http://127.0.0.1:8765/api/post") && out.markdown.includes("### Request payload") && out.markdown.includes('"hello": "world"') && out.markdown.includes("created:"), out.markdown && out.markdown.slice(0, 300));
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
