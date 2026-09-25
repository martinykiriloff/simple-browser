// SimpleBrowser DevTools — Application panel: storage and cookies.
"use strict";

(function () {
  const panel = {
    initialized: false,
    section: null,
    origin: "",
    host: "",
    rows: [],
    selectedIndex: -1,

    init() {
      $("#application-filter").addEventListener("input", debounce(() => this.renderRows(), 100));
      $("#application-refresh").addEventListener("click", () => this.load());
      $("#application-delete").addEventListener("click", () => this.deleteSelected());
      $("#application-clear").addEventListener("click", () => this.clearAll());
      $("#application-body").addEventListener("click", (e) => {
        const tr = e.target.closest("tr[data-index]");
        if (!tr) return;
        this.selectedIndex = +tr.dataset.index;
        for (const row of $$("#application-body tr")) row.classList.toggle("selected", row === tr);
      });
      $("#application-body").addEventListener("dblclick", (e) => {
        const td = e.target.closest("td[data-field]");
        if (td) this.editCell(td);
      });
      document.addEventListener("keydown", (e) => {
        if (DevTools.activePanel === "application" && (e.key === "Delete" || e.key === "Backspace") && !e.target.closest("input, [contenteditable]")) { e.preventDefault(); this.deleteSelected(); }
      });
      DevTools.on("DOM.documentUpdated", () => this.loadTree());
      this.loadTree();
    },

    show() { if (this.section) this.load(); },

    async loadTree() {
      const tree = $("#application-tree");
      tree.textContent = "";
      let info = {};
      try { info = await DevTools.rpc("Page.getInfo"); } catch (_) {}
      this.origin = info.origin || "";
      try { this.host = new URL(info.url || "").host; } catch (_) { this.host = ""; }
      const item = (label, section, sub) => {
        const el = h("div", { class: "app-item" + (this.section === section ? " selected" : ""), title: sub || "" }, label, sub ? h("span", { class: "muted" }, "  " + sub) : null);
        el.addEventListener("click", () => { this.section = section; this.loadTree(); this.load(); });
        return el;
      };
      tree.appendChild(h("div", { class: "app-section" }, "Storage"));
      tree.appendChild(item("Local storage", "local", this.origin));
      tree.appendChild(item("Session storage", "session", this.origin));
      tree.appendChild(item("Cookies", "cookies", this.host));
      tree.appendChild(item("IndexedDB", "indexeddb", this.origin));
      tree.appendChild(h("div", { class: "app-section" }, "Application"));
      tree.appendChild(item("Page", "page", ""));
      if (!this.section) { this.section = "local"; this.loadTree(); this.load(); }
    },

    async load() {
      const body = $("#application-body");
      $("#application-title").textContent = { local: "Local storage — " + this.origin, session: "Session storage — " + this.origin, cookies: "Cookies — " + this.host, indexeddb: "IndexedDB — " + this.origin, page: "Page" }[this.section] || "";
      this.rows = [];
      this.selectedIndex = -1;
      try {
        if (this.section === "local" || this.section === "session") {
          const entries = await DevTools.rpc("Storage.getEntries", { area: this.section });
          this.rows = entries.map(([key, value]) => ({ key, value }));
        } else if (this.section === "cookies") {
          this.rows = await DevTools.rpc("Cookies.list");
        } else if (this.section === "indexeddb") {
          this.rows = await DevTools.rpc("Storage.getIndexedDBNames");
        } else if (this.section === "page") {
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

    renderRows() {
      const body = $("#application-body");
      body.textContent = "";
      const filter = $("#application-filter").value.trim().toLowerCase();
      const table = h("table", { class: "data-table kv-table" });
      const editable = this.section === "local" || this.section === "session";
      let columns;
      if (this.section === "cookies") columns = ["name", "value", "domain", "path", "expires", "size", "httpOnly", "secure", "sameSite"];
      else if (this.section === "indexeddb") columns = ["name", "version"];
      else columns = ["key", "value"];
      table.appendChild(h("thead", {}, h("tr", {}, columns.map((c) => h("th", {}, c[0].toUpperCase() + c.slice(1))))));
      const tbody = h("tbody");
      const format = (c, v) => {
        if (v == null) return "";
        if (c === "expires") return v ? new Date(v).toISOString() : "Session";
        if (typeof v === "boolean") return v ? "✓" : "";
        return String(v);
      };
      this.rows.forEach((row, index) => {
        const text = columns.map((c) => format(c, row[c])).join(" ").toLowerCase();
        if (filter && !text.includes(filter)) return;
        const tr = h("tr", { dataset: { index: String(index) }, class: index === this.selectedIndex ? "selected" : "" });
        for (const c of columns) tr.appendChild(h("td", { dataset: editable ? { field: c } : null, title: format(c, row[c]) }, format(c, row[c])));
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
      if (this.section === "indexeddb") body.appendChild(h("div", { class: "detail-note" }, "Database contents are not browsable yet; names and versions come from indexedDB.databases()."));
      if (!this.rows.length && this.section !== "local" && this.section !== "session") body.appendChild(h("div", { class: "empty-state" }, "Nothing stored."));
    },

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
      if (!row) return;
      try {
        if (this.section === "local" || this.section === "session") await DevTools.rpc("Storage.removeEntry", { area: this.section, key: row.key });
        else if (this.section === "cookies") await DevTools.rpc("Cookies.delete", { name: row.name, domain: row.domain, path: row.path });
        else return;
      } catch (err) { DevTools.panels.console?.addLocal("error", err.message); }
      this.load();
    },

    async clearAll() {
      try {
        if (this.section === "local" || this.section === "session") await DevTools.rpc("Storage.clear", { area: this.section });
        else if (this.section === "cookies") await DevTools.rpc("Cookies.clear");
        else return;
      } catch (err) { DevTools.panels.console?.addLocal("error", err.message); }
      this.load();
    },
  };

  DevTools.register("application", panel);
})();
