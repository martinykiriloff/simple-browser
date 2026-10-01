// SimpleBrowser DevTools — the command menu (⌘⇧P) and Open file (⌘P), as in
// Chrome: one box, fuzzy matching; a leading ">" means commands, otherwise
// it is a file from the Sources navigator.
"use strict";

(function () {
  const PANEL_TITLES = { elements: "Elements", console: "Console", sources: "Sources", network: "Network", performance: "Performance",
                         memory: "Memory", audits: "Audits", application: "Application" };

  // Subsequence match, scored like Chrome's: consecutive runs and word
  // starts count most, earlier matches beat later ones. Null if no match.
  function fuzzy(query, text) {
    if (!query) return { score: 0, positions: [] };
    const q = query.toLowerCase(), t = text.toLowerCase();
    const positions = [];
    let score = 0, from = 0, previous = -2;
    for (const ch of q) {
      if (ch === " ") continue;
      const i = t.indexOf(ch, from);
      if (i < 0) return null;
      score += 1;
      if (i === previous + 1) score += 5;
      if (i === 0 || /[\s\-_.:/>(]/.test(t[i - 1])) score += 8;
      score -= Math.min(i - from, 10) * 0.1;
      positions.push(i);
      previous = i; from = i + 1;
    }
    if (t.startsWith(q)) score += 20;
    return { score, positions };
  }

  const CommandMenu = window.CommandMenu = {
    extra: [],                  // commands registered by other modules
    items: [],
    index: 0,
    files: [],

    register(command) { this.extra.push(command); },

    // Built fresh each time, so toggles say what they will do.
    commands() {
      const R = window.SBRendering ? SBRendering.state : {};
      const set = (feature, value) => () => SBRendering.set(feature, value).catch((e) => Toast.show(e.message));
      const list = [];
      const add = (category, title, action) => list.push({ category, title, action });
      for (const name of Object.keys(DevTools.panels)) add("Panel", "Show " + (PANEL_TITLES[name] || name), () => DevTools.showPanel(name));
      for (const [name, pane] of Drawer.panes) add("Drawer", "Show " + pane.title, () => Drawer.show(name));
      add("Elements", "Inspect element in the page", () => { DevTools.showPanel("elements"); DevTools.panels.elements.setInspectMode(true); });
      add("Sources", "Open file", () => setTimeout(() => this.open(""), 0));
      add("Rendering", (R.paintFlashing ? "Hide" : "Show") + " paint flashing rectangles", set("paintFlashing", !R.paintFlashing));
      add("Rendering", (R.layerBorders ? "Hide" : "Show") + " layer borders", set("layerBorders", !R.layerBorders));
      add("Rendering", (R.fpsMeter ? "Hide" : "Show") + " frames per second (FPS) meter", set("fpsMeter", !R.fpsMeter));
      add("Rendering", (R.rulers ? "Hide" : "Show") + " rulers", set("rulers", !R.rulers));
      add("Rendering", "Emulate CSS prefers-color-scheme: dark", set("colorScheme", "dark"));
      add("Rendering", "Emulate CSS prefers-color-scheme: light", set("colorScheme", "light"));
      add("Rendering", "Emulate CSS prefers-reduced-motion: reduce", set("reducedMotion", "reduce"));
      add("Rendering", "Emulate CSS print media type", set("media", "print"));
      add("Rendering", "Do not emulate CSS media type or features", async () => {
        for (const feature of ["media", "colorScheme", "reducedMotion", "contrast"]) await SBRendering.set(feature, "").catch(() => {});
      });
      add("Debugger", R.disableJavaScript ? "Enable JavaScript" : "Disable JavaScript", set("disableJavaScript", !R.disableJavaScript));
      add("Screenshot", "Capture screenshot", () => SBScreenshots.capture("viewport"));
      add("Screenshot", "Capture full size screenshot", () => SBScreenshots.capture("full"));
      add("Screenshot", "Capture node screenshot", () => SBScreenshots.capture("node"));
      add("Application", "Clear site data", async () => {
        try { const r = await DevTools.rpc("Storage.clearSiteData"); Toast.show("Cleared site data" + (r.records.length ? " for " + r.records.join(", ") : "")); }
        catch (e) { Toast.show(e.message); }
      });
      if (window.SBCacheControl) add("Network", (SBCacheControl.disabled ? "Enable" : "Disable") + " cache (while DevTools is open)", () => $("#network-disable-cache").click());
      add("Network", "Search network requests", () => Drawer.show("search"));
      add("Network", "Copy network log as Markdown", () => DevTools.rpc("Clipboard.write", { text: DevTools.panels.network.summaryMarkdown() }));
      add("Network", "Copy network log as HAR", async () => DevTools.rpc("Clipboard.write", { text: await DevTools.rpc("Network.getHAR") }));
      add("Network", "Export HAR…", () => DevTools.rpc("Network.exportHAR"));
      add("Console", "Clear console", () => DevTools.panels.console.clear());
      add("Console", "Copy all console errors as Markdown", () => DevTools.rpc("Clipboard.write", { text: DevTools.panels.console.errorsMarkdown() }));
      add("Global", "Reload page", () => DevTools.rpc("Page.reload"));
      add("Global", "Dock to bottom", () => DevTools.setDockSide("bottom"));
      add("Global", "Dock to right", () => DevTools.setDockSide("right"));
      add("Global", "Undock into separate window", () => DevTools.setDockSide("undocked"));
      for (const theme of ["dark", "light", "system"]) {
        add("Appearance", `Switch to ${theme} theme`, () => { Theme.apply(theme); DevTools.rpc("Settings.set", { key: "theme", value: theme }); });
      }
      add("Global", "Close DevTools", () => DevTools.rpc("DevTools.close"));
      return list.concat(this.extra);
    },

    async loadFiles() {
      const sources = DevTools.panels.sources;
      const urls = new Set(sources.initialized ? sources.files.keys() : []);
      if (!urls.size) { try { for (const f of await DevTools.rpc("Sources.list")) urls.add(f.url); } catch (_) {} }
      for (const r of DevTools.panels.network.requests.values()) if (/^(script|stylesheet|document)$/.test(r.resourceType)) urls.add(r.url);
      this.files = Array.from(urls).filter((u) => !u.startsWith("debugger://"));
    },

    // `prefix` ">" for commands, "" for files.
    async open(prefix) {
      const menu = $("#command-menu"), input = $("#command-input");
      menu.hidden = false;
      input.value = prefix;
      input.focus();
      if (!prefix) await this.loadFiles();
      this.update();
    },

    close() { $("#command-menu").hidden = true; },

    // The matches for the current input, best first.
    matches(text) {
      if (text.startsWith(">")) {
        const query = text.slice(1).trim();
        return this.commands().map((c) => {
          const m = fuzzy(query, c.title);
          return m && Object.assign({}, c, m);
        }).filter(Boolean).sort((a, b) => b.score - a.score || a.category.localeCompare(b.category));
      }
      const query = text.trim();
      return this.files.map((url) => {
        const name = fileName(url);
        const m = fuzzy(query, name) || (query && fuzzy(query, url) && { score: fuzzy(query, url).score - 10, positions: [] });
        return m && { title: name, subtitle: url, category: "File", score: m.score, positions: m.positions,
                      action: () => DevTools.openSource(url, 1, 0) };
      }).filter(Boolean).sort((a, b) => b.score - a.score || a.title.localeCompare(b.title));
    },

    update() {
      const text = $("#command-input").value;
      this.items = this.matches(text).slice(0, 100);
      this.index = 0;
      this.render(text.startsWith(">"));
    },

    render(commands) {
      const list = $("#command-list");
      list.textContent = "";
      if (!this.items.length) list.appendChild(h("div", { class: "command-empty" }, commands ? "No matching commands" : "No matching files. Type > to run a command."));
      this.items.forEach((item, i) => {
        const title = h("span", { class: "command-title" });
        let last = 0;
        for (const p of item.positions || []) {
          title.append(item.title.slice(last, p), h("b", {}, item.title[p]));
          last = p + 1;
        }
        title.append(item.title.slice(last));
        const row = h("div", { class: "command-item" + (i === this.index ? " active" : "") },
          h("span", { class: "command-category" }, item.category), title,
          item.subtitle ? h("span", { class: "command-subtitle" }, item.subtitle) : null);
        row.addEventListener("mousedown", (e) => { e.preventDefault(); this.index = i; this.accept(); });
        list.appendChild(row);
      });
    },

    move(delta) {
      if (!this.items.length) return;
      this.index = (this.index + delta + this.items.length) % this.items.length;
      $$("#command-list .command-item").forEach((el, i) => el.classList.toggle("active", i === this.index));
      $$("#command-list .command-item")[this.index]?.scrollIntoView({ block: "nearest" });
    },

    accept() {
      const item = this.items[this.index];
      this.close();
      if (item) Promise.resolve(item.action()).catch((e) => Toast.show(e.message));
      return item;
    },

    // For drivers and tests: run the best match for a query, as if typed and Enter pressed.
    async run(text) {
      if (!text.startsWith(">")) await this.loadFiles();
      $("#command-input").value = text;
      this.update();
      return this.accept();
    },

    init() {
      const input = $("#command-input");
      input.addEventListener("input", async () => {
        if (!input.value.startsWith(">") && !this.files.length) await this.loadFiles();
        this.update();
      });
      input.addEventListener("keydown", (e) => {
        if (e.key === "ArrowDown") { e.preventDefault(); this.move(1); }
        else if (e.key === "ArrowUp") { e.preventDefault(); this.move(-1); }
        else if (e.key === "Enter") { e.preventDefault(); this.accept(); }
        else if (e.key === "Escape") { e.preventDefault(); this.close(); }
        e.stopPropagation();
      });
      input.addEventListener("blur", () => setTimeout(() => this.close(), 100));
      document.addEventListener("keydown", (e) => {
        const meta = e.metaKey || e.ctrlKey;
        if (meta && !e.altKey && e.key.toLowerCase() === "p") {
          e.preventDefault();
          this.open(e.shiftKey ? ">" : "");
        }
      }, true);
    },
  };
})();
