// Keel DevTools — Application panel: storage (local, session,
// cookies, IndexedDB, Cache Storage), the Web App Manifest, service workers
// and page info.
"use strict";

(function () {
  // Tagged values from the tools agent ({ $type: "Date", value }) as display text.
  function displayValue(v) {
    if (Array.isArray(v)) return v.map(displayValue);
    if (v && typeof v === "object") {
      if (v.$type) {
        if (v.$type === "Date" || v.$type === "RegExp" || v.$type === "bigint" || v.$type === "number") return `${v.$type === "Date" ? "Date " : ""}${v.value}`;
        if (v.$type === "Map") return Object.fromEntries((v.entries || []).map(([k, x]) => [typeof k === "string" ? k : JSON.stringify(k), displayValue(x)]));
        if (v.$type === "Set") return (v.values || []).map(displayValue);
        if (v.$type === "Blob" || v.$type === "File") return `${v.$type}(${v.size} bytes${v.type ? ", " + v.type : ""})`;
        return v.$type + (v.length != null ? `(${v.length})` : v.byteLength != null ? `(${v.byteLength})` : "");
      }
      const out = {};
      for (const [k, x] of Object.entries(v)) out[k] = displayValue(x);
      return out;
    }
    return v;
  }
  const keyText = (k) => { const d = displayValue(k); return typeof d === "string" ? JSON.stringify(d) : typeof d === "object" ? JSON.stringify(d) : String(d); };

  const panel = {
    initialized: false,
    section: null,
    origin: "",
    host: "",
    rows: [],
    selectedIndex: -1,
    databases: [],        // [{ name, version, objectStores }]
    cacheNames: [],
    expanded: new Set(["indexeddb", "caches"]),
    idbPage: 0,
    PAGE: 50,

    init() {
      $("#application-filter").addEventListener("input", debounce(() => this.renderRows(), 100));
      $("#application-refresh").addEventListener("click", () => { this.loadTree(); this.load(); });
      $("#application-delete").addEventListener("click", () => this.deleteSelected());
      $("#application-clear").addEventListener("click", () => this.clearAll());
      $("#application-body").addEventListener("click", (e) => {
        const tr = e.target.closest("tr[data-index]");
        if (!tr || +tr.dataset.index < 0) return;
        this.selectedIndex = +tr.dataset.index;
        for (const row of $$("#application-body tr")) row.classList.toggle("selected", row === tr);
        if (this.section.startsWith("cache:")) this.showCachedResponse();
        if (this.section.startsWith("idb:")) this.showRecord();
      });
      $("#application-body").addEventListener("dblclick", (e) => {
        const td = e.target.closest("td[data-field]");
        if (td) this.editCell(td);
      });
      document.addEventListener("keydown", (e) => {
        if (DevTools.activePanel === "application" && (e.key === "Delete" || e.key === "Backspace") && !e.target.closest("input, textarea, [contenteditable]")) { e.preventDefault(); this.deleteSelected(); }
      });
      DevTools.on("DOM.documentUpdated", () => this.loadTree());
      this.loadTree();
    },

    show() { if (this.section) this.load(); },

    // ---- navigation tree ------------------------------------------------------------------------
    async loadTree() {
      let info = {};
      try { info = await DevTools.rpc("Page.getInfo"); } catch (_) {}
      this.origin = info.origin || "";
      try { this.host = new URL(info.url || "").host; } catch (_) { this.host = ""; }
      try {
        const names = await DevTools.rpc("IndexedDB.databases");
        this.databases = [];
        for (const d of names) {
          try { this.databases.push(await DevTools.rpc("IndexedDB.database", { name: d.name })); }
          catch (_) { this.databases.push({ name: d.name, version: d.version, objectStores: [] }); }
        }
      } catch (_) { this.databases = []; }
      try { this.cacheNames = await DevTools.rpc("CacheStorage.caches"); } catch (_) { this.cacheNames = []; }
      this.renderTree();
      if (!this.section) { this.section = "local"; this.renderTree(); this.load(); }
    },

    renderTree() {
      const tree = $("#application-tree");
      tree.textContent = "";
      const item = (label, section, sub, depth = 0) => {
        const el = h("div", { class: "app-item" + (this.section === section ? " selected" : ""), title: sub || label, style: `padding-left:${20 + depth * 14}px`, dataset: { section } },
          label, sub ? h("span", { class: "muted" }, "  " + sub) : null);
        el.addEventListener("click", () => this.open(section));
        return el;
      };
      const group = (label, key, sub, children) => {
        const open = this.expanded.has(key);
        const el = h("div", { class: "app-item app-group" + (this.section === key ? " selected" : ""), dataset: { section: key } },
          h("span", { class: "tree-arrow", onclick: (e) => { e.stopPropagation(); if (open) this.expanded.delete(key); else this.expanded.add(key); this.renderTree(); } }, children.length ? (open ? "▼" : "▶") : ""), label,
          sub ? h("span", { class: "muted" }, "  " + sub) : null);
        el.addEventListener("click", () => this.open(key));
        tree.appendChild(el);
        if (open) for (const child of children) tree.appendChild(child);
      };
      tree.appendChild(h("div", { class: "app-section" }, "Application"));
      tree.appendChild(item("Manifest", "manifest"));
      tree.appendChild(item("Service workers", "serviceworkers"));
      tree.appendChild(item("Storage", "storage", this.origin));
      tree.appendChild(h("div", { class: "app-section" }, "Storage"));
      tree.appendChild(item("Local storage", "local", this.origin));
      tree.appendChild(item("Session storage", "session", this.origin));
      const idbChildren = [];
      for (const db of this.databases) {
        idbChildren.push(item(db.name, "idb:" + db.name, "v" + db.version, 1));
        for (const store of db.objectStores) idbChildren.push(item(store.name, "idb:" + db.name + "/" + store.name, String(store.count), 2));
      }
      group("IndexedDB", "indexeddb", this.origin, idbChildren);
      tree.appendChild(item("Cookies", "cookies", this.host));
      group("Cache storage", "caches", "", this.cacheNames.map((name) => item(name, "cache:" + name, "", 1)));
      tree.appendChild(h("div", { class: "app-section" }, "Frames"));
      tree.appendChild(item("Page", "page", ""));
    },

    open(section) {
      this.section = section;
      this.idbPage = 0;
      this.renderTree();
      return this.load();
    },

    title() {
      const s = this.section || "";
      if (s.startsWith("idb:")) return "IndexedDB — " + s.slice(4);
      if (s.startsWith("cache:")) return "Cache storage — " + s.slice(6);
      return { local: "Local storage — " + this.origin, session: "Session storage — " + this.origin, cookies: "Cookies — " + this.host,
               indexeddb: "IndexedDB — " + this.origin, caches: "Cache storage — " + this.origin, page: "Page", manifest: "Manifest",
               serviceworkers: "Service workers", storage: "Storage — " + this.origin }[s] || "";
    },

    // ---- loading -------------------------------------------------------------------------------------
    async load() {
      const body = $("#application-body");
      $("#application-title").textContent = this.title();
      this.rows = [];
      this.selectedIndex = -1;
      this.extra = null;
      const s = this.section;
      try {
        if (s === "local" || s === "session") {
          const entries = await DevTools.rpc("Storage.getEntries", { area: s });
          this.rows = entries.map(([key, value]) => ({ key, value }));
        } else if (s === "cookies") {
          this.rows = await DevTools.rpc("Cookies.list");
        } else if (s === "indexeddb") {
          this.rows = this.databases.map((d) => ({ name: d.name, version: d.version, stores: d.objectStores.map((o) => o.name).join(", ") }));
        } else if (s.startsWith("idb:")) {
          const [database, store] = s.slice(4).split("/");
          if (!store) {
            const db = this.databases.find((d) => d.name === database);
            this.rows = (db ? db.objectStores : []).map((o) => ({ name: o.name, keyPath: JSON.stringify(o.keyPath), autoIncrement: o.autoIncrement, count: o.count, indexes: o.indexes.map((i) => i.name).join(", ") }));
          } else {
            const page = await DevTools.rpc("IndexedDB.records", { database, store, skip: this.idbPage * this.PAGE, limit: this.PAGE });
            this.extra = page;
            this.rows = page.records.map((r, i) => ({ n: this.idbPage * this.PAGE + i, key: r.key, primaryKey: r.primaryKey, value: r.value }));
          }
        } else if (s === "caches") {
          this.rows = this.cacheNames.map((name) => ({ name }));
        } else if (s.startsWith("cache:")) {
          this.rows = (await DevTools.rpc("CacheStorage.entries", { cache: s.slice(6) })).map((r, i) => Object.assign({ n: i }, r));
        } else if (s === "manifest") {
          this.extra = await DevTools.rpc("Manifest.get");
        } else if (s === "serviceworkers") {
          this.extra = await DevTools.rpc("ServiceWorker.list");
        } else if (s === "storage") {
          this.extra = { databases: this.databases.length, caches: this.cacheNames.length, local: (await DevTools.rpc("Storage.getEntries", { area: "local" })).length, cookies: (await DevTools.rpc("Cookies.list")).length };
        } else if (s === "page") {
          const info = await DevTools.rpc("Page.getInfo");
          this.rows = Object.entries(info).map(([key, value]) => ({ key, value: String(value) }));
        }
      } catch (err) {
        body.textContent = "";
        body.appendChild(h("div", { class: "empty-state" }, err.message));
        return;
      }
      this.renderRows();
    },

    columns() {
      const s = this.section;
      if (s === "cookies") return ["name", "value", "domain", "path", "expires", "size", "httpOnly", "secure", "sameSite"];
      if (s === "indexeddb") return ["name", "version", "stores"];
      if (s.startsWith("idb:")) return s.includes("/") ? ["n", "key", "value"] : ["name", "keyPath", "autoIncrement", "count", "indexes"];
      if (s === "caches") return ["name"];
      if (s.startsWith("cache:")) return ["n", "url", "status", "type", "contentType", "contentLength", "date"];
      return ["key", "value"];
    },

    renderRows() {
      const body = $("#application-body");
      body.textContent = "";
      const s = this.section;
      if (s === "manifest") return this.renderManifest(body);
      if (s === "serviceworkers") return this.renderServiceWorkers(body);
      if (s === "storage") return this.renderStorage(body);
      const filter = $("#application-filter").value.trim().toLowerCase();
      const table = h("table", { class: "data-table kv-table" });
      const editable = s === "local" || s === "session";
      const columns = this.columns();
      const headings = { n: "#", contentType: "Content-Type", contentLength: "Content-Length", keyPath: "Key path", autoIncrement: "Auto increment", httpOnly: "HttpOnly", sameSite: "SameSite", url: "Name" };
      table.appendChild(h("thead", {}, h("tr", {}, columns.map((c) => h("th", { class: "col-" + c }, headings[c] || c[0].toUpperCase() + c.slice(1))))));
      const tbody = h("tbody");
      const format = (c, v) => {
        if (v == null) return "";
        if (c === "expires") return v ? new Date(v).toISOString() : "Session";
        if (typeof v === "boolean") return v ? "✓" : "";
        if (c === "key" && s.startsWith("idb:")) return keyText(v);
        if (c === "value" && s.startsWith("idb:")) { const d = displayValue(v); return typeof d === "string" ? JSON.stringify(d) : JSON.stringify(d); }
        if (c === "contentLength") return formatBytes(v);
        return String(v);
      };
      this.rows.forEach((row, index) => {
        const text = columns.map((c) => format(c, row[c])).join(" ").toLowerCase();
        if (filter && !text.includes(filter)) return;
        const tr = h("tr", { dataset: { index: String(index) }, class: index === this.selectedIndex ? "selected" : "" });
        for (const c of columns) tr.appendChild(h("td", { dataset: editable ? { field: c } : null, title: format(c, row[c]).slice(0, 500) }, format(c, row[c]).slice(0, 300)));
        if (s === "indexeddb" || s === "caches" || (s.startsWith("idb:") && !s.includes("/"))) {
          tr.addEventListener("dblclick", () => this.open(s === "caches" ? "cache:" + row.name : s === "indexeddb" ? "idb:" + row.name : s + "/" + row.name));
        }
        tbody.appendChild(tr);
      });
      if (editable) {
        const tr = h("tr", { class: "new-row", dataset: { index: "-1" } });
        tr.appendChild(h("td", { dataset: { field: "key" } }, "Add new entry (double-click)"));
        tr.appendChild(h("td", { dataset: { field: "value" } }, ""));
        tbody.appendChild(tr);
      }
      table.appendChild(tbody);
      body.appendChild(table);
      if (s.startsWith("idb:") && s.includes("/") && this.extra) {
        const page = this.extra;
        const bar = h("div", { class: "statusbar app-pager" }, `${page.total} record(s)`);
        if (this.idbPage > 0) bar.appendChild(h("button", { class: "text-button", onclick: () => { this.idbPage--; this.load(); } }, "‹ Previous"));
        if (page.hasMore) bar.appendChild(h("button", { class: "text-button", onclick: () => { this.idbPage++; this.load(); } }, "Next ›"));
        body.appendChild(bar);
        body.appendChild(h("div", { class: "app-detail", id: "app-detail" }, h("div", { class: "detail-note" }, "Select a record to see its value.")));
      }
      if (s.startsWith("cache:")) body.appendChild(h("div", { class: "app-detail", id: "app-detail" }, h("div", { class: "detail-note" }, "Select an entry to see the cached response.")));
      if (!this.rows.length && !editable) body.appendChild(h("div", { class: "empty-state" }, s === "indexeddb" ? "No IndexedDB databases for this origin." : s === "caches" ? "No caches for this origin." : "Nothing stored."));
    },

    // ---- details -------------------------------------------------------------------------------------
    showRecord() {
      const row = this.rows[this.selectedIndex];
      const detail = $("#app-detail");
      if (!row || !detail) return;
      detail.textContent = "";
      detail.appendChild(h("div", { class: "detail-head-line" }, "Key: ", h("span", { class: "mono" }, keyText(row.key))));
      detail.appendChild(JSONTree.render(displayValue(row.value)));
    },

    async showCachedResponse() {
      const row = this.rows[this.selectedIndex];
      const detail = $("#app-detail");
      if (!row || !detail) return;
      detail.textContent = "";
      try {
        const res = await DevTools.rpc("CacheStorage.response", { cache: this.section.slice(6), url: row.url });
        detail.appendChild(h("div", { class: "detail-head-line" }, `${res.status} ${res.statusText} · ${res.type}`));
        detail.appendChild(h("div", { class: "detail-body" }, res.headers.map(([k, v]) => h("div", { class: "kv" }, h("span", { class: "k" }, k), h("span", { class: "v" }, v)))));
        if (res.body.startsWith("data:image/")) detail.appendChild(h("img", { class: "preview-img", src: res.body }));
        else detail.appendChild(h("pre", { class: "code" }, tryPrettyJSON(res.body) || res.body));
      } catch (e) { detail.appendChild(h("div", { class: "detail-note v-error" }, e.message)); }
    },

    renderManifest(body) {
      const m = this.extra || {};
      if (!m.present) { body.appendChild(h("div", { class: "empty-state" }, "No manifest detected: the page has no <link rel=\"manifest\">.")); return; }
      const section = (title, rows) => DevTools.panels.network.section(title, rows);
      const kv = (k, v) => DevTools.panels.network.kv(k, v);
      body.appendChild(section("Manifest", [kv("URL", m.url), kv("Status", String(m.status ?? ""))]));
      if (m.errors.length) body.appendChild(section(`Errors (${m.errors.length})`, m.errors.map((e) => h("div", { class: "v-error" }, e))));
      if (m.warnings.length) body.appendChild(section(`Installability warnings (${m.warnings.length})`, m.warnings.map((w) => h("div", { class: "manifest-warning" }, "⚠ " + w))));
      const mf = m.manifest;
      if (mf) {
        const color = (c) => c ? h("span", {}, h("span", { class: "color-swatch", style: "background:" + c }), c) : "";
        body.appendChild(section("Identity", [kv("Name", mf.name || ""), kv("Short name", mf.short_name || ""), kv("Description", mf.description || ""), kv("ID", mf.id || "")]));
        body.appendChild(section("Presentation", [kv("Start URL", m.startURL || ""), kv("Scope", mf.scope || ""), kv("Display", mf.display || ""), kv("Orientation", mf.orientation || ""),
          h("div", { class: "kv" }, h("span", { class: "k" }, "Theme color"), h("span", { class: "v" }, color(mf.theme_color))),
          h("div", { class: "kv" }, h("span", { class: "k" }, "Background color"), h("span", { class: "v" }, color(mf.background_color)))]));
        const icons = h("div", { class: "manifest-icons" });
        for (const icon of m.icons) icons.appendChild(h("div", { class: "manifest-icon" }, h("img", { src: icon.src, alt: "" }), h("div", { class: "muted" }, [icon.sizes, icon.type, icon.purpose].filter(Boolean).join(" · "))));
        body.appendChild(section(`Icons (${m.icons.length})`, [icons]));
        body.appendChild(section("Raw", [h("pre", { class: "code" }, tryPrettyJSON(m.raw) || m.raw)], false));
      }
    },

    renderServiceWorkers(body) {
      const sw = this.extra || {};
      if (!sw.supported) {
        body.appendChild(h("div", { class: "detail-note" }, "Service workers are not available: " + (sw.reason || "unknown reason") + " WebKit's inspector protocol has no ServiceWorker domain for page targets either, so there is no start/stop, push or sync here."));
        return;
      }
      if (!sw.registrations.length) { body.appendChild(h("div", { class: "empty-state" }, "No service workers registered for this origin.")); return; }
      for (const r of sw.registrations) {
        const worker = (label, w) => w ? DevTools.panels.network.kv(label, `${w.scriptURL} (${w.state})`) : null;
        const actions = h("div", { class: "kv" }, h("span", { class: "k" }, ""), h("span", { class: "v" },
          h("button", { class: "text-button", onclick: async () => { await DevTools.rpc("ServiceWorker.update", { scope: r.scope }); this.load(); } }, "Update"), " ",
          h("button", { class: "text-button", onclick: async () => { await DevTools.rpc("ServiceWorker.unregister", { scope: r.scope }); this.load(); } }, "Unregister")));
        body.appendChild(DevTools.panels.network.section(r.scope, [worker("Active", r.active), worker("Waiting", r.waiting), worker("Installing", r.installing), DevTools.panels.network.kv("Update via cache", r.updateViaCache), actions].filter(Boolean)));
      }
      body.appendChild(h("div", { class: "detail-note" }, "Listed with navigator.serviceWorker from the isolated world; WebKit's protocol has no ServiceWorker domain for pages, so push, sync and offline emulation are not available."));
    },

    renderStorage(body) {
      const x = this.extra || {};
      const kv = (k, v) => DevTools.panels.network.kv(k, v);
      body.appendChild(DevTools.panels.network.section("Usage", [kv("Origin", this.origin), kv("Local storage", x.local + " item(s)"), kv("Cookies", x.cookies + " cookie(s)"),
        kv("IndexedDB", x.databases + " database(s)"), kv("Cache storage", x.caches + " cache(s)")]));
      const button = h("button", { class: "text-button" }, "Clear site data");
      button.addEventListener("click", async () => {
        try { const r = await DevTools.rpc("Storage.clearSiteData"); Toast.show("Cleared site data" + (r.records.length ? " for " + r.records.join(", ") : "")); }
        catch (e) { Toast.show(e.message); }
        this.loadTree(); this.load();
      });
      body.appendChild(h("div", { class: "detail-note" }, button, " Removes cookies, local and session storage, IndexedDB, caches and service workers for this site in this profile."));
    },

    // ---- editing -------------------------------------------------------------------------------------
    editCell(td) {
      const tr = td.closest("tr");
      const index = +tr.dataset.index;
      const field = td.dataset.field;
      const isNew = index === -1;
      const row = isNew ? { key: "", value: "" } : this.rows[index];
      inlineEdit(td, {
        initial: isNew ? "" : row[field],
        multiline: true,
        onCommit: async (text) => {
          if (isNew && field === "key") {
            if (!text) { this.renderRows(); return; }
            const valueCell = tr.querySelector("td[data-field=value]");
            inlineEdit(valueCell, {
              initial: "", multiline: true,
              onCommit: async (value) => { await this.setEntry(text, value); this.load(); },
              onCancel: () => this.renderRows(),
            });
            return;
          }
          if (isNew) { this.renderRows(); return; }
          if (field === "key") {
            if (text !== row.key) {
              await DevTools.rpc("Storage.removeEntry", { area: this.section, key: row.key }).catch(() => {});
              await this.setEntry(text, row.value);
            }
          } else {
            await this.setEntry(row.key, text);
          }
          this.load();
        },
        onCancel: () => this.renderRows(),
      });
    },

    async setEntry(key, value) {
      try { await DevTools.rpc("Storage.setEntry", { area: this.section, key, value }); }
      catch (err) { DevTools.panels.console?.addLocal("error", err.message); }
    },

    async deleteSelected() {
      const row = this.rows[this.selectedIndex];
      const s = this.section;
      try {
        if (s.startsWith("idb:") && s.includes("/") && row) {
          const [database, store] = s.slice(4).split("/");
          await DevTools.rpc("IndexedDB.deleteRecord", { database, store, key: row.primaryKey });
        } else if (s.startsWith("idb:") && !s.includes("/")) {
          await DevTools.rpc("IndexedDB.deleteDatabase", { name: s.slice(4) });
          this.section = "indexeddb";
        } else if (s.startsWith("cache:") && row) {
          await DevTools.rpc("CacheStorage.deleteEntry", { cache: s.slice(6), url: row.url });
        } else if (!row) {
          return;
        } else if (s === "local" || s === "session") await DevTools.rpc("Storage.removeEntry", { area: s, key: row.key });
        else if (s === "cookies") await DevTools.rpc("Cookies.delete", { name: row.name, domain: row.domain, path: row.path });
        else if (s === "caches") await DevTools.rpc("CacheStorage.deleteCache", { cache: row.name });
        else return;
      } catch (err) { DevTools.panels.console?.addLocal("error", err.message); }
      await this.loadTree();
      await this.load();
    },

    async clearAll() {
      const s = this.section;
      try {
        if (s === "local" || s === "session") await DevTools.rpc("Storage.clear", { area: s });
        else if (s === "cookies") await DevTools.rpc("Cookies.clear");
        else if (s.startsWith("idb:") && s.includes("/")) { const [database, store] = s.slice(4).split("/"); await DevTools.rpc("IndexedDB.clearStore", { database, store }); }
        else if (s.startsWith("cache:")) await DevTools.rpc("CacheStorage.deleteCache", { cache: s.slice(6) });
        else return;
      } catch (err) { DevTools.panels.console?.addLocal("error", err.message); }
      await this.loadTree();
      await this.load();
    },
  };

  DevTools.register("application", panel);
})();
