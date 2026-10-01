// SimpleBrowser DevTools — Components: React Developer Tools, built in. The
// page-world hook (devext-hooks.js) is the same global hook React DevTools
// installs; this panel walks the committed fiber tree it collects. Tree,
// search, host elements on demand, props, hooks and state (editable), owners,
// source location, hover highlight, and Elements ↔ Components selection.
"use strict";

(function () {
  const call = (method, params = {}) => DevTools.rpc("React.call", { method, params });

  const panel = {
    initialized: false,
    nodes: [],
    selected: null,
    showHost: false,
    filter: "",
    collapsed: new Set(),
    lastCommits: -1,
    status: null,
    timer: null,

    init() {
      $("#react-refresh").addEventListener("click", () => this.refresh());
      $("#react-host").addEventListener("change", (e) => { this.showHost = e.target.checked; this.refresh(); });
      $("#react-filter").addEventListener("input", (e) => { this.filter = e.target.value.toLowerCase(); this.renderTree(); });
      $("#react-from-elements").addEventListener("click", () => this.selectFromElements());
      $("#react-tree").addEventListener("mouseleave", () => call("React.unhighlight").catch(() => {}));
      $("#react-tree").addEventListener("keydown", (e) => this.key(e));
    },

    show() {
      this.refresh();
      clearInterval(this.timer);
      // Re-read the tree after React commits, while the panel is showing.
      this.timer = setInterval(async () => {
        try {
          const status = await call("React.status");
          if (status.commits !== this.lastCommits) { this.lastCommits = status.commits; this.refresh(true); }
        } catch (_) {}
      }, 1000);
    },

    hide() { clearInterval(this.timer); call("React.unhighlight").catch(() => {}); },

    async detect() {
      if (!SBExt.enabled("react")) { SBExt.showTab("components", false); return false; }
      try {
        const status = await call("React.status");
        if (status && status.__missing) { SBExt.showTab("components", false); return false; }
        SBExt.showTab("components", !!status.detected);
        this.status = status;
        return status.detected;
      } catch (_) { return false; }
    },

    async refresh(quiet) {
      try {
        const status = await call("React.status");
        this.status = status;
        if (status.__missing) {
          this.message("React Developer Tools are off for this tab.", "Turn them on in Develop → Developer Extensions, then open a new tab.");
          return;
        }
        if (!status.detected) {
          this.message("This page does not use React (or has not rendered yet).", "Components appear here as soon as React renders.");
          return;
        }
        const tree = await call("React.tree", { showHost: this.showHost });
        this.nodes = tree.nodes;
        this.lastCommits = status.commits;
        const versions = status.renderers.map((r) => (r.package || "react-dom") + " " + (r.version || "")).join(", ");
        $("#react-status").textContent = `${versions || "React"} · ${tree.nodes.length} components${tree.truncated ? " (first 5000)" : ""}`;
        this.renderTree();
        if (this.selected != null && this.nodes.some((n) => n.id === this.selected)) this.inspect(this.selected, true);
        else if (!quiet && this.nodes.length) this.inspect(this.nodes[0].id);
      } catch (e) {
        this.message("Could not read the component tree.", e.message);
      }
    },

    message(title, line) {
      $("#react-tree").textContent = "";
      $("#react-tree").appendChild(SBExt.empty(title, line));
      $("#react-detail").textContent = "";
      $("#react-status").textContent = "";
    },

    visibleNodes() {
      const hidden = new Set();
      const out = [];
      const q = this.filter;
      const matching = q ? new Set(this.nodes.filter((n) => n.name.toLowerCase().includes(q)).map((n) => n.id)) : null;
      // With a filter, keep the matches and their ancestors.
      const keep = new Set();
      if (matching) {
        const byId = new Map(this.nodes.map((n) => [n.id, n]));
        for (const id of matching) { let n = byId.get(id); while (n && !keep.has(n.id)) { keep.add(n.id); n = byId.get(n.parent); } }
      }
      for (const n of this.nodes) {
        if (n.parent != null && hidden.has(n.parent)) { hidden.add(n.id); continue; }
        if (keep.size && !keep.has(n.id)) { hidden.add(n.id); continue; }
        out.push(n);
        if (!q && this.collapsed.has(n.id)) hidden.add(n.id);
      }
      return { out, matching };
    },

    renderTree() {
      const box = $("#react-tree");
      box.textContent = "";
      const { out, matching } = this.visibleNodes();
      const hasChildren = new Set(this.nodes.map((n) => n.parent));
      for (const n of out) {
        const row = h("div", { class: "react-row" + (n.id === this.selected ? " selected" : "") + (matching && matching.has(n.id) ? " match" : ""), dataset: { id: n.id }, style: `padding-left:${8 + n.depth * 12}px` },
          h("span", { class: "react-twisty" }, hasChildren.has(n.id) ? (this.collapsed.has(n.id) ? "▸" : "▾") : ""),
          h("span", { class: "react-name react-" + n.kind }, n.name),
          n.key != null ? h("span", { class: "react-key" }, ` key="${n.key}"`) : null,
          n.kind === "memo" ? h("span", { class: "react-badge" }, "Memo") : null,
          n.kind === "forwardRef" ? h("span", { class: "react-badge" }, "ForwardRef") : null);
        row.addEventListener("click", (e) => {
          if (e.target.classList.contains("react-twisty")) { this.collapsed.has(n.id) ? this.collapsed.delete(n.id) : this.collapsed.add(n.id); this.renderTree(); return; }
          this.inspect(n.id);
        });
        row.addEventListener("mouseenter", () => call("React.highlight", { id: n.id }).catch(() => {}));
        box.appendChild(row);
      }
      if (!out.length && this.filter) box.appendChild(SBExt.empty("No component matches “" + this.filter + "”."));
    },

    key(e) {
      const { out } = this.visibleNodes();
      const index = out.findIndex((n) => n.id === this.selected);
      if (e.key === "ArrowDown" && index < out.length - 1) { this.inspect(out[index + 1].id); e.preventDefault(); }
      if (e.key === "ArrowUp" && index > 0) { this.inspect(out[index - 1].id); e.preventDefault(); }
      if (e.key === "ArrowLeft" && index >= 0) { this.collapsed.add(out[index].id); this.renderTree(); e.preventDefault(); }
      if (e.key === "ArrowRight" && index >= 0) { this.collapsed.delete(out[index].id); this.renderTree(); e.preventDefault(); }
    },

    async inspect(id, quiet) {
      this.selected = id;
      for (const row of $$("#react-tree .react-row")) row.classList.toggle("selected", +row.dataset.id === id);
      const selectedRow = $(`#react-tree .react-row[data-id="${id}"]`);
      if (selectedRow && !quiet) selectedRow.scrollIntoView({ block: "nearest" });
      let info;
      try { info = await call("React.inspect", { id }); } catch (e) { $("#react-detail").textContent = e.message; return; }
      this.info = info;
      const box = $("#react-detail");
      box.textContent = "";
      const head = h("div", { class: "react-detail-head" }, h("span", { class: "react-name react-" + info.kind }, info.name),
        info.key != null ? h("span", { class: "react-key" }, ` key="${info.key}"`) : null);
      const tools = h("span", { class: "react-detail-tools" });
      if (info.selector) {
        const reveal = h("button", { class: "icon-button", title: "Reveal its DOM element in Elements" }, "⌖");
        reveal.addEventListener("click", async () => {
          const { nodeIds } = await DevTools.rpc("DOM.performSearch", { query: info.selector });
          if (nodeIds && nodeIds.length) { DevTools.showPanel("elements"); DevTools.panels.elements.revealNode(nodeIds[0], true); }
        });
        const scroll = h("button", { class: "icon-button", title: "Scroll into view" }, "↧");
        scroll.addEventListener("click", () => call("React.scrollIntoView", { id }));
        tools.append(reveal, scroll);
      }
      const copy = h("button", { class: "text-button", title: "Copy this component as Markdown for an AI assistant" }, "Copy for AI");
      copy.addEventListener("click", () => SBExt.copy(this.markdown(info), "Component copied"));
      tools.appendChild(copy);
      head.appendChild(tools);
      box.appendChild(head);

      box.appendChild(this.section("props", SBExt.tree(info.props, 1)));
      if (info.hooks && info.hooks.length) box.appendChild(this.section("hooks", this.hooks(info)));
      if (info.state) box.appendChild(this.section("state", this.editable(info.state, (value) => call("React.setState", { id, value }))));
      if (info.context) box.appendChild(this.section("context", SBExt.tree(info.context, 1)));
      if (info.owners && info.owners.length) {
        const list = h("div", { class: "react-owners" });
        for (const o of info.owners) {
          const b = h("button", { class: "react-owner" }, o.name);
          if (o.id != null) b.addEventListener("click", () => this.inspect(o.id)); else b.disabled = true;
          list.appendChild(b);
        }
        box.appendChild(this.section("rendered by", list));
      }
      if (info.source) {
        const link = h("a", { class: "link mono", href: "#" }, `${info.source.file.split("/").pop()}:${info.source.line}`);
        link.title = info.source.file;
        link.addEventListener("click", (e) => { e.preventDefault(); if (window.SBSources) SBSources.open?.(info.source.file, info.source.line); else SBExt.copy(info.source.file + ":" + info.source.line, "Source path copied"); });
        box.appendChild(this.section("source", link));
      }
    },

    section(title, content) {
      return h("div", { class: "react-section" }, h("div", { class: "react-section-title" }, title), content);
    },

    hooks(info) {
      const list = h("div", { class: "react-hooks" });
      info.hooks.forEach((hook) => {
        const label = h("span", { class: "react-hook-kind" }, `${hook.index + 1} · ${hook.kind.replace(/^use/, "")}`);
        const value = hook.editable ? this.editable(hook.value, (v) => call("React.setState", { id: info.id, hookIndex: hook.index, value: v })) : SBExt.tree(hook.value, 0);
        list.appendChild(h("div", { class: "react-hook" }, label, value));
      });
      return list;
    },

    /// Primitive values edit in place (double-click); objects show as a tree with an "Edit JSON" button.
    editable(value, save) {
      const shown = SBExt.display(value);
      const wrap = h("div", { class: "react-editable" });
      if (shown === null || typeof shown !== "object") {
        const text = h("span", { class: "mono selectable react-value", title: "Double-click to edit" }, JSON.stringify(shown) ?? "undefined");
        text.addEventListener("dblclick", () => this.edit(wrap, JSON.stringify(shown), save));
        wrap.appendChild(text);
      } else {
        const button = h("button", { class: "text-button react-edit-json" }, "Edit JSON");
        button.addEventListener("click", () => this.edit(wrap, JSON.stringify(shown, null, 2), save, true));
        wrap.append(SBExt.tree(value, 1), button);
      }
      return wrap;
    },

    edit(wrap, initial, save, multiline) {
      const input = h(multiline ? "textarea" : "input", { class: "react-input mono", spellcheck: "false" });
      input.value = initial;
      wrap.textContent = "";
      wrap.appendChild(input);
      input.focus(); input.select();
      const commit = async () => {
        let value;
        try { value = JSON.parse(input.value); } catch (_) { value = input.value; }
        try { await save(value); await new Promise((r) => setTimeout(r, 60)); this.refresh(true); }
        catch (e) { Toast.show(e.message); this.inspect(this.selected, true); }
      };
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && (!multiline || e.metaKey)) { e.preventDefault(); commit(); }
        if (e.key === "Escape") { e.preventDefault(); this.inspect(this.selected, true); }
      });
      input.addEventListener("blur", () => { if (!multiline) commit(); });
    },

    async selectFromElements() {
      const elements = DevTools.panels.elements;
      const nodeId = elements && elements.selectedId;
      if (nodeId == null) { Toast.show("Select an element in Elements first"); return; }
      const selector = await DevTools.rpc("DOM.uniqueSelector", { nodeId }).catch(() => null);
      const id = selector ? await call("React.fromSelector", { selector }).catch(() => null) : null;
      if (id == null) { Toast.show("No React component rendered that element"); return; }
      await this.refresh(true);
      this.inspect(id);
    },

    markdown(info) {
      const json = (v) => "```json\n" + JSON.stringify(SBExt.display(v), null, 2).slice(0, 6000) + "\n```";
      const out = [`## React component <${info.name}>`, ""];
      if (info.source) out.push(`Source: ${info.source.file}:${info.source.line}`);
      if (info.owners && info.owners.length) out.push(`Rendered by: ${info.owners.map((o) => o.name).join(" ← ")}`);
      if (info.selector) out.push(`DOM: \`${info.selector}\``);
      out.push("", "### Props", json(info.props));
      if (info.hooks && info.hooks.length) out.push("", "### Hooks", ...info.hooks.map((x) => `- ${x.kind}: \`${JSON.stringify(SBExt.display(x.value)).slice(0, 300)}\``));
      if (info.state) out.push("", "### State", json(info.state));
      return out.join("\n");
    },
  };

  DevTools.register("components", panel);
  window.SBReact = panel;
})();
