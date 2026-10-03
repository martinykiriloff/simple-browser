// Keel DevTools — Elements panel: DOM tree, Styles, Computed, Layout.
"use strict";

(function () {
  const VOID = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]);
  const INHERITED = new Set([
    "color", "cursor", "direction", "font", "font-family", "font-size", "font-style", "font-variant", "font-weight",
    "font-stretch", "font-feature-settings", "font-variation-settings", "font-kerning", "font-optical-sizing",
    "letter-spacing", "line-height", "list-style", "list-style-type", "list-style-position", "list-style-image",
    "text-align", "text-align-last", "text-indent", "text-transform", "text-shadow", "text-rendering", "text-decoration-skip-ink",
    "visibility", "white-space", "word-spacing", "word-break", "word-wrap", "overflow-wrap", "hyphens", "tab-size",
    "quotes", "caption-side", "border-collapse", "border-spacing", "empty-cells", "orphans", "widows", "pointer-events",
    "image-rendering", "color-scheme", "writing-mode", "text-orientation", "-webkit-text-size-adjust", "-webkit-font-smoothing",
    "-webkit-text-fill-color", "-webkit-text-stroke", "-webkit-user-select", "user-select", "accent-color", "caret-color",
  ]);
  const COLOR_RE = /(#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})\b|\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\([^)]*\)|\b(?:red|blue|green|white|black|gray|grey|orange|yellow|purple|pink|transparent|currentcolor|silver|maroon|navy|teal|olive|lime|aqua|fuchsia|cyan|magenta|gold|coral|salmon|tomato|indigo|violet|brown|tan|beige|ivory|khaki|crimson|steelblue|royalblue|skyblue|slategray|darkgray|lightgray|whitesmoke|gainsboro)\b)/gi;

  const panel = {
    initialized: false,
    nodes: new Map(),
    elements: new Map(),
    textParents: new Map(),
    selectedId: null,
    inspecting: false,
    tree: null,
    pendingRefresh: new Set(),
    refreshTimer: null,
    searchHits: [],
    searchIndex: -1,
    styles: null,
    computed: null,
    disabled: new Map(),
    sidebarTab: "styles",
    COLOR_RE,
    INHERITED,

    init() {
      this.tree = $("#dom-tree");
      document.head.appendChild(h("style", {}, "li.node.expanded > .node-line .collapsed-marker { display: none; }"));
      bindSubtabs($("#styles-tabs"), (name) => { this.sidebarTab = name; this.refreshSidebar(); });

      this.tree.addEventListener("click", (e) => this.onTreeClick(e));
      this.tree.addEventListener("dblclick", (e) => this.onTreeDblClick(e));
      this.tree.addEventListener("mouseover", (e) => {
        const line = e.target.closest(".node-line, .closing-line");
        if (line) this.highlight(+line.parentElement.dataset.nodeId);
      });
      this.tree.addEventListener("mouseleave", () => DevTools.rpc("Overlay.hideHighlight"));
      this.tree.addEventListener("keydown", (e) => this.onKey(e));
      this.tree.addEventListener("contextmenu", (e) => this.onContextMenu(e));

      $("#styles-filter").addEventListener("input", () => this.renderStyles());
      $("#computed-filter").addEventListener("input", () => this.renderComputed());
      $("#styles-add-rule").addEventListener("click", () => this.addRule());

      document.addEventListener("keydown", (e) => {
        if ((e.metaKey || e.ctrlKey) && e.key === "f" && DevTools.activePanel === "elements" && !e.target.closest("#panel-console, #panel-sources")) {
          e.preventDefault(); this.openSearch();
        }
      });
      $("#elements-search").addEventListener("input", debounce(() => this.runSearch(), 150));
      $("#elements-search").addEventListener("keydown", (e) => {
        if (e.key === "Enter") { e.preventDefault(); this.stepSearch(e.shiftKey ? -1 : 1); }
        if (e.key === "Escape") { e.preventDefault(); this.closeSearch(); }
      });
      $("#elements-search-next").addEventListener("click", () => this.stepSearch(1));
      $("#elements-search-prev").addEventListener("click", () => this.stepSearch(-1));
      $("#elements-search-close").addEventListener("click", () => this.closeSearch());

      DevTools.on("DOM.documentUpdated", () => this.loadDocument());
      DevTools.on("DOM.mutated", (batch) => this.onMutations(batch));
      // "documentUpdated" fires at document start; if the tree was read while
      // the parser was still running, read it again once the load finishes.
      DevTools.on("Page.navigated", (p) => { if (p.phase === "finished" && !this.documentComplete) this.loadDocument(); });
      this.loadDocument();
    },

    documentComplete: false,

    show() { if (this.tree && !this.tree.childElementCount) this.loadDocument(); },
    hide() { DevTools.rpc("Overlay.hideHighlight"); },

    // ---- document & tree ------------------------------------------------------
    // Every async continuation checks this so a load that was superseded by
    // a newer document cannot write stale nodes into the maps.
    loadGeneration: 0,

    async loadDocument() {
      const generation = ++this.loadGeneration;
      DevTools.trace("elements.loadDocument", generation);
      // Unknown until the read returns; a "finished" navigation arriving in
      // the meantime must trigger a re-read rather than trust the old flag.
      this.documentComplete = false;
      this.nodes.clear(); this.elements.clear(); this.textParents.clear();
      this.selectedId = null; this.disabled.clear();
      this.tree.textContent = "";
      $("#breadcrumbs").textContent = "";
      try {
        const doc = await DevTools.rpc("DOM.getDocument", { depth: 2 });
        DevTools.trace("elements.getDocument", generation, this.loadGeneration, doc.readyState,
          (doc.children || []).map((c) => c.nodeName + ":" + c.childNodeCount + ":" + (c.children || []).map((g) => g.nodeName + ":" + g.childNodeCount).join(",")));
        if (generation !== this.loadGeneration) return;
        this.documentComplete = doc.readyState === "complete";
        this.nodes.set(doc.nodeId, doc);
        const root = h("ol", { class: "tree" });
        for (const child of doc.children || []) root.appendChild(this.renderNode(child));
        this.tree.appendChild(root);
        const html = (doc.children || []).find((c) => c.nodeType === 1 && c.nodeName === "html");
        if (html) {
          await this.expand(html.nodeId);
          if (generation !== this.loadGeneration) return;
          const body = (this.nodes.get(html.nodeId).children || []).find((c) => c.nodeType === 1 && c.nodeName === "body");
          if (body) {
            await this.expand(body.nodeId);
            if (generation !== this.loadGeneration) return;
            this.select(body.nodeId, { scroll: false });
          } else this.select(html.nodeId, { scroll: false });
        }
      } catch (e) {
        if (generation !== this.loadGeneration) return;
        this.tree.appendChild(h("div", { class: "empty-state" }, "Could not read the document: " + e.message));
      }
    },

    renderNode(data) {
      this.nodes.set(data.nodeId, data);
      const li = h("li", { class: "node", dataset: { nodeId: String(data.nodeId) } });
      this.elements.set(data.nodeId, li);
      this.fillNode(li, data);
      return li;
    },

    isInlineText(data) {
      return data.nodeType === 1 && data.children && data.children.length === 1
          && data.children[0].nodeType === 3 && data.childNodeCount === 1 && !data.shadowRoot;
    },

    // Renders or updates a node's own line. Existing children are kept
    // unless `data.children` is provided, in which case they are reconciled
    // by node id, so refreshing an ancestor never collapses its subtree.
    fillNode(li, data) {
      const old = this.nodes.get(data.nodeId);
      if (old && old.isShadow) data.isShadow = true;
      this.nodes.set(data.nodeId, data);
      const inlineText = this.isInlineText(data);
      const hasChildren = (data.childNodeCount > 0 || data.shadowRoot || data.templateContent) && !inlineText;
      li.classList.toggle("leaf", !hasChildren);
      if (inlineText) { this.nodes.set(data.children[0].nodeId, data.children[0]); this.textParents.set(data.children[0].nodeId, data.nodeId); }

      let line = li.querySelector(":scope > .node-line");
      if (!line) { line = h("div", { class: "node-line" }); li.prepend(line); }
      line.textContent = "";
      line.classList.toggle("selected", data.nodeId === this.selectedId);
      line.appendChild(h("span", { class: "arrow" }));
      // One inline box for the markup: the line is a flex container, and a
      // flex container drops the whitespace-only text between tag and attributes.
      line.appendChild(h("span", { class: "markup" }, this.markup(data, inlineText)));

      let ol = li.querySelector(":scope > ol.children");
      let closing = li.querySelector(":scope > .closing-line");
      if (hasChildren) {
        if (!ol) { ol = h("ol", { class: "children" }); line.after(ol); }
        if (data.nodeType === 1) {
          if (!closing) { closing = h("div", { class: "closing-line" }); li.appendChild(closing); }
          closing.textContent = "";
          closing.appendChild(h("span", { class: "tag" }, "</" + data.nodeName + ">"));
        } else if (closing) {
          closing.remove();
        }
        if (data.children || data.shadowRoot) this.syncChildren(ol, data);
        else if (li.classList.contains("expanded") && !ol.childElementCount) this.loadChildren(data.nodeId);
      } else {
        if (ol) { for (const c of Array.from(ol.children)) this.forget(c); ol.remove(); }
        if (closing) closing.remove();
        li.classList.remove("expanded");
      }
    },

    // Makes `ol` show exactly `data`'s children, reusing the existing `li`
    // for any node that is still there (its expanded state and subtree
    // survive) and creating or removing the rest.
    syncChildren(ol, data) {
      const existing = new Map();
      for (const c of ol.children) existing.set(+c.dataset.nodeId, c);
      const desired = [];
      if (data.shadowRoot) desired.push(Object.assign({}, data.shadowRoot, { isShadow: true }));
      for (const c of data.children || []) desired.push(c);
      const keep = new Set();
      let cursor = null;
      for (const childData of desired) {
        let childLi = existing.get(childData.nodeId);
        if (childLi) { keep.add(childData.nodeId); this.fillNode(childLi, childData); }
        else childLi = this.renderNode(childData);
        if (cursor) cursor.after(childLi); else ol.prepend(childLi);
        cursor = childLi;
      }
      for (const [id, c] of existing) if (!keep.has(id)) { this.forget(c); c.remove(); }
    },

    markup(data, inlineText) {
      const frag = document.createDocumentFragment();
      switch (data.nodeType) {
        case 1: {
          frag.appendChild(h("span", { class: "tag tag-open" }, "<" + data.nodeName));
          const attrs = data.attributes || [];
          for (let i = 0; i < attrs.length; i += 2) {
            frag.appendChild(document.createTextNode(" "));
            const attr = h("span", { class: "attr", dataset: { attr: attrs[i] } }, h("span", { class: "attr-name" }, attrs[i]));
            if (attrs[i + 1] !== "" || attrs[i] === "value") {
              attr.appendChild(h("span", { class: "attr-name" }, "="));
              attr.appendChild(h("span", { class: "attr-value" }, "\"" + attrs[i + 1] + "\""));
            }
            frag.appendChild(attr);
          }
          frag.appendChild(h("span", { class: "tag" }, ">"));
          if (inlineText) {
            frag.appendChild(h("span", { class: "node-text", dataset: { textId: String(data.children[0].nodeId) } }, data.children[0].nodeValue));
            frag.appendChild(h("span", { class: "tag" }, "</" + data.nodeName + ">"));
          } else if (data.childNodeCount > 0 || data.shadowRoot || data.templateContent) {
            frag.appendChild(h("span", { class: "node-ellipsis collapsed-marker" }, "…"));
            frag.appendChild(h("span", { class: "tag collapsed-marker" }, "</" + data.nodeName + ">"));
          } else if (!VOID.has(data.nodeName)) {
            frag.appendChild(h("span", { class: "tag" }, "</" + data.nodeName + ">"));
          }
          break;
        }
        case 3: frag.appendChild(h("span", { class: "node-text" }, "\"" + data.nodeValue + "\"")); break;
        case 4: frag.appendChild(h("span", { class: "node-comment" }, "<![CDATA[" + data.nodeValue + "]]>")); break;
        case 8: frag.appendChild(h("span", { class: "node-comment" }, "<!--" + data.nodeValue + "-->")); break;
        case 10: frag.appendChild(h("span", { class: "node-doctype" }, "<!DOCTYPE " + data.nodeName + ">")); break;
        case 11: frag.appendChild(h("span", { class: "shadow-root-label" }, data.nodeName + (data.shadowRootMode ? " (" + data.shadowRootMode + ")" : ""))); break;
        default: frag.appendChild(h("span", {}, data.nodeName));
      }
      return frag;
    },

    async expand(id) {
      const li = this.elements.get(id);
      DevTools.trace("elements.expand", id, !!li, li && li.className);
      if (!li || li.classList.contains("leaf")) return;
      li.classList.add("expanded");
      const data = this.nodes.get(id);
      const ol = li.querySelector(":scope > ol.children");
      if (data && (!data.children || (ol && !ol.childElementCount))) await this.loadChildren(id);
    },

    collapse(id) {
      const li = this.elements.get(id);
      if (li) li.classList.remove("expanded");
    },

    async loadChildren(id) {
      const data = this.nodes.get(id);
      const li = this.elements.get(id);
      if (!data || !li) return;
      if (data.loadingChildren) return;
      data.loadingChildren = true;
      const generation = this.loadGeneration;
      let children;
      try { children = await DevTools.rpc("DOM.requestChildNodes", { nodeId: id, depth: 1 }); }
      catch (e) { data.loadingChildren = false; DevTools.trace("elements.loadChildren failed", id, e.message); return; }
      data.loadingChildren = false;
      DevTools.trace("elements.loadChildren", id, children.length, generation, this.loadGeneration, this.elements.get(id) === li, li.className);
      if (generation !== this.loadGeneration || this.elements.get(id) !== li) return;
      const current = this.nodes.get(id) || data;
      current.children = children;
      current.childNodeCount = children.length;
      this.fillNode(li, current);
    },

    forget(li) {
      for (const el of [li, ...li.querySelectorAll("li.node")]) {
        const id = +el.dataset.nodeId;
        const data = this.nodes.get(id);
        if (data && this.isInlineText(data)) { this.nodes.delete(data.children[0].nodeId); this.textParents.delete(data.children[0].nodeId); }
        this.elements.delete(id); this.nodes.delete(id);
      }
    },

    nodeData(id) { return this.nodes.get(id); },

    shortName(data) {
      if (!data) return "";
      if (data.nodeType !== 1) return data.nodeName;
      let s = data.nodeName;
      const attrs = data.attributes || [];
      for (let i = 0; i < attrs.length; i += 2) {
        if (attrs[i] === "id" && attrs[i + 1]) s += "#" + attrs[i + 1];
        if (attrs[i] === "class" && attrs[i + 1].trim()) s += "." + attrs[i + 1].trim().split(/\s+/).join(".");
      }
      return s;
    },

    // ---- selection ----------------------------------------------------------------
    select(id, { scroll = true } = {}) {
      if (this.selectedId != null) {
        const old = this.elements.get(this.selectedId);
        if (old) old.querySelector(":scope > .node-line")?.classList.remove("selected");
      }
      this.selectedId = id;
      const li = this.elements.get(id);
      if (li) {
        const line = li.querySelector(":scope > .node-line");
        line.classList.add("selected");
        if (scroll) line.scrollIntoView({ block: "nearest" });
      }
      this.disabled.clear();
      DevTools.rpc("DOM.select", { nodeId: id }).catch(() => {});
      this.renderBreadcrumbs();
      this.refreshSidebar();
    },

    async revealNode(id, fromPicker) {
      if (fromPicker) this.setInspectMode(false, true);
      try {
        const path = await DevTools.rpc("DOM.getNodePath", { nodeId: id });
        for (const ancestor of path.slice(0, -1)) {
          if (this.elements.has(ancestor)) await this.expand(ancestor);
        }
        if (!this.elements.has(id)) {
          // The node lives under a subtree we never loaded (an iframe or a
          // shadow root); fall back to the nearest known ancestor.
          const known = path.slice().reverse().find((n) => this.elements.has(n));
          if (known == null) return;
          id = known;
        }
      } catch (_) {}
      this.select(id);
      this.tree.focus();
    },

    highlight(id) {
      if (id) DevTools.rpc("Overlay.highlightNode", { nodeId: id }).catch(() => {});
    },

    setInspectMode(on, fromAgent) {
      this.inspecting = on;
      $("#btn-inspect").classList.toggle("active", on);
      if (!fromAgent) DevTools.rpc("Overlay.setInspectMode", { enabled: on }).catch(() => {});
    },

    renderBreadcrumbs() {
      const bar = $("#breadcrumbs");
      bar.textContent = "";
      let li = this.elements.get(this.selectedId);
      const chain = [];
      while (li) {
        const data = this.nodes.get(+li.dataset.nodeId);
        if (data && (data.nodeType === 1 || data.nodeType === 11)) chain.unshift(data);
        li = li.parentElement ? li.parentElement.closest("li.node") : null;
      }
      for (const data of chain) {
        bar.appendChild(h("span", {
          class: "crumb" + (data.nodeId === this.selectedId ? " selected" : ""),
          onclick: () => this.select(data.nodeId),
          onmouseenter: () => this.highlight(data.nodeId),
        }, this.shortName(data)));
      }
      bar.lastElementChild?.scrollIntoView({ inline: "end", block: "nearest" });
    },

    // ---- interaction --------------------------------------------------------------
    onTreeClick(e) {
      const line = e.target.closest(".node-line, .closing-line");
      if (!line) return;
      const id = +line.parentElement.dataset.nodeId;
      if (e.target.classList.contains("arrow")) { this.toggle(id); return; }
      this.select(id, { scroll: false });
    },

    toggle(id) {
      const li = this.elements.get(id);
      if (!li) return;
      if (li.classList.contains("expanded")) this.collapse(id); else this.expand(id);
    },

    onTreeDblClick(e) {
      const line = e.target.closest(".node-line");
      if (!line) return;
      const id = +line.parentElement.dataset.nodeId;
      const data = this.nodes.get(id);
      if (!data) return;
      if (e.target.classList.contains("arrow")) return;
      const attr = e.target.closest(".attr");
      if (attr) { this.editAttribute(id, attr); return; }
      if (e.target.classList.contains("node-text")) {
        const textId = e.target.dataset.textId ? +e.target.dataset.textId : id;
        this.editText(textId, e.target, !!e.target.dataset.textId);
        return;
      }
      if (data.nodeType === 1 && e.target.classList.contains("tag-open")) { this.editAttributesAsText(id, line); return; }
      if (data.nodeType === 1) this.toggle(id);
    },

    editAttribute(id, attrEl) {
      const name = attrEl.dataset.attr;
      const data = this.nodes.get(id);
      const attrs = data.attributes || [];
      let value = "";
      for (let i = 0; i < attrs.length; i += 2) if (attrs[i] === name) value = attrs[i + 1];
      inlineEdit(attrEl, {
        initial: name + "=\"" + value + "\"",
        onCommit: async (text) => {
          const t = text.trim();
          try {
            if (!t) await this.mutate("DOM.removeAttribute", { nodeId: id, name });
            else {
              const m = t.match(/^([^\s=]+)(?:=(?:"([^"]*)"|'([^']*)'|(\S*)))?$/);
              if (!m) throw new Error("Could not parse attribute");
              if (m[1] !== name) await this.mutate("DOM.removeAttribute", { nodeId: id, name });
              await this.mutate("DOM.setAttributeValue", { nodeId: id, name: m[1], value: m[2] ?? m[3] ?? m[4] ?? "" });
            }
          } catch (err) { this.notify(err.message); }
          this.refreshNode(id);
        },
        onCancel: () => this.refreshNode(id),
      });
    },

    editAttributesAsText(id, line) {
      const data = this.nodes.get(id);
      const attrs = data.attributes || [];
      const parts = [];
      for (let i = 0; i < attrs.length; i += 2) parts.push(attrs[i] + (attrs[i + 1] === "" ? "" : "=\"" + attrs[i + 1].replace(/"/g, "&quot;") + "\""));
      const editor = h("span", { class: "editing" });
      const open = line.querySelector(".tag-open");
      open.textContent = "<" + data.nodeName + " ";
      for (const el of Array.from(line.querySelectorAll(".attr"))) el.remove();
      open.after(editor);
      inlineEdit(editor, {
        initial: parts.join(" "),
        onCommit: async (text) => {
          try { await this.mutate("DOM.setAttributesAsText", { nodeId: id, text }); }
          catch (err) { this.notify(err.message); }
          this.refreshNode(id);
        },
        onCancel: () => this.refreshNode(id),
      });
    },

    editText(textId, el, inline) {
      const data = this.nodes.get(textId);
      const current = data ? data.nodeValue : el.textContent.replace(/^"|"$/g, "");
      inlineEdit(el, {
        initial: current, multiline: true,
        onCommit: async (text) => {
          try { await this.mutate("DOM.setNodeValue", { nodeId: textId, value: text }); }
          catch (err) { this.notify(err.message); }
          this.refreshNode(inline ? this.textParents.get(textId) : textId);
        },
        onCancel: () => this.refreshNode(inline ? this.textParents.get(textId) : textId),
      });
    },

    async editAsHTML(id) {
      const li = this.elements.get(id);
      if (!li) return;
      let html;
      try { html = await DevTools.rpc("DOM.getOuterHTML", { nodeId: id }); } catch (err) { this.notify(err.message); return; }
      const line = li.querySelector(":scope > .node-line");
      const area = h("textarea", { class: "html-edit", spellcheck: "false" });
      area.value = html;
      area.rows = Math.min(20, html.split("\n").length + 1);
      line.textContent = "";
      line.appendChild(area);
      area.focus();
      let done = false;
      const finish = async (commit) => {
        if (done) return; done = true;
        const parentLi = li.parentElement.closest("li.node");
        const parentId = parentLi ? +parentLi.dataset.nodeId : null;
        if (commit && area.value !== html) {
          try { await this.mutate("DOM.replaceWithHTML", { nodeId: id, outerHTML: area.value }); }
          catch (err) { this.notify(err.message); }
        }
        if (parentId != null) { this.refreshNode(parentId, true); } else { this.loadDocument(); }
      };
      area.addEventListener("keydown", (e) => {
        e.stopPropagation();
        if (e.key === "Escape") { e.preventDefault(); finish(false); }
        if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); finish(true); }
      });
      area.addEventListener("blur", () => finish(true));
    },

    async deleteNode(id) {
      const li = this.elements.get(id);
      const parentLi = li && li.parentElement.closest("li.node");
      const next = li && (li.nextElementSibling || li.previousElementSibling || parentLi);
      try { await this.mutate("DOM.removeNode", { nodeId: id }); } catch (err) { this.notify(err.message); return; }
      if (parentLi) this.refreshNode(+parentLi.dataset.nodeId, true);
      if (next) this.select(+next.dataset.nodeId);
    },

    async copyOuterHTML(id) {
      try { const html = await DevTools.rpc("DOM.getOuterHTML", { nodeId: id }); await DevTools.rpc("Clipboard.write", { text: html }); }
      catch (err) { this.notify(err.message); }
    },

    async copySelector(id) {
      try { const sel = await DevTools.rpc("DOM.uniqueSelector", { nodeId: id }); await DevTools.rpc("Clipboard.write", { text: sel }); }
      catch (err) { this.notify(err.message); }
    },

    notify(message) {
      if (DevTools.panels.console) DevTools.panels.console.addLocal("warn", message);
    },

    visibleLines() {
      return $$(".node-line, .closing-line", this.tree).filter((el) => el.offsetParent !== null);
    },

    onKey(e) {
      if (e.target !== this.tree) return;
      const id = this.selectedId;
      if (id == null) return;
      const li = this.elements.get(id);
      const data = this.nodes.get(id);
      const lines = this.visibleLines();
      const current = li && li.querySelector(":scope > .node-line");
      const index = lines.indexOf(current);
      const meta = e.metaKey || e.ctrlKey;
      switch (e.key) {
        case "ArrowUp": {
          e.preventDefault();
          for (let i = index - 1; i >= 0; i--) { const cand = lines[i]; if (cand.classList.contains("node-line")) { this.select(+cand.parentElement.dataset.nodeId); break; } }
          break;
        }
        case "ArrowDown": {
          e.preventDefault();
          for (let i = index + 1; i < lines.length; i++) { const cand = lines[i]; if (cand.classList.contains("node-line")) { this.select(+cand.parentElement.dataset.nodeId); break; } }
          break;
        }
        case "ArrowRight": {
          e.preventDefault();
          if (li && !li.classList.contains("leaf")) {
            if (!li.classList.contains("expanded")) this.expand(id);
            else { const first = li.querySelector(":scope > ol.children > li.node"); if (first) this.select(+first.dataset.nodeId); }
          }
          break;
        }
        case "ArrowLeft": {
          e.preventDefault();
          if (li && li.classList.contains("expanded")) this.collapse(id);
          else { const parent = li && li.parentElement.closest("li.node"); if (parent) this.select(+parent.dataset.nodeId); }
          break;
        }
        case "Backspace": case "Delete":
          e.preventDefault(); this.deleteNode(id); break;
        case "h": case "H":
          if (!meta) { e.preventDefault(); this.mutate("DOM.toggleHidden", { nodeId: id }).catch(() => {}); }
          break;
        case "Enter":
          e.preventDefault();
          if (data && data.nodeType === 1) this.editAttributesAsText(id, current);
          break;
        case "F2":
          e.preventDefault(); this.editAsHTML(id); break;
        case "c":
          if (meta) { e.preventDefault(); this.copyOuterHTML(id); }
          break;
        default: break;
      }
    },

    onContextMenu(e) {
      const line = e.target.closest(".node-line, .closing-line");
      if (!line) return;
      e.preventDefault();
      const id = +line.parentElement.dataset.nodeId;
      this.select(id, { scroll: false });
      const data = this.nodes.get(id);
      const isElement = data && data.nodeType === 1;
      const items = [];
      if (isElement) {
        items.push({ label: "Add attribute", action: () => this.editAttributesAsText(id, line.classList.contains("node-line") ? line : this.elements.get(id).querySelector(":scope > .node-line")) });
        items.push({ label: "Edit as HTML", action: () => this.editAsHTML(id) });
        items.push("-");
        items.push(...this.copyItems(id), "-");                                // elements-tools.js
        items.push({ label: "Store as global variable", action: () => this.storeAsGlobal(id) });
        items.push({ label: "Hide element", action: () => this.mutate("DOM.toggleHidden", { nodeId: id }).catch(() => {}) });
        items.push({ label: "Scroll into view", action: () => DevTools.rpc("DOM.scrollIntoView", { nodeId: id }) });
        items.push({ label: "Focus", action: () => DevTools.rpc("DOM.focus", { nodeId: id }) });
        if (window.SBScreenshots) items.push({ label: "Capture node screenshot", action: () => SBScreenshots.capture("node", id) });
        items.push("-");
        items.push(...this.breakOnItems(id), "-");                           // elements-extras.js
        items.push({ label: "Expand recursively", action: () => this.expandRecursively(id) });
        items.push({ label: "Collapse children", action: () => this.collapse(id) });
        items.push("-");
      }
      items.push({ label: "Delete node", action: () => this.deleteNode(id) });
      ContextMenu.show(e.clientX, e.clientY, items);
    },

    async expandRecursively(id, depth = 0) {
      if (depth > 8) return;
      await this.expand(id);
      const data = this.nodes.get(id);
      for (const child of data?.children || []) {
        if (child.nodeType === 1 && child.childNodeCount) await this.expandRecursively(child.nodeId, depth + 1);
      }
    },

    // ---- live updates ------------------------------------------------------------------
    onMutations(batch) {
      for (const m of batch.mutations || []) {
        const id = m.nodeID;
        if (this.textParents.has(id)) this.pendingRefresh.add(this.textParents.get(id));
        else if (this.elements.has(id)) this.pendingRefresh.add(id);
      }
      if (batch.dropped && this.selectedId != null) this.pendingRefresh.add(this.selectedId);
      if (this.pendingRefresh.size && !this.refreshTimer) {
        this.refreshTimer = setTimeout(() => { this.refreshTimer = null; this.flushRefresh(); }, 120);
      }
    },

    async flushRefresh() {
      const ids = Array.from(this.pendingRefresh);
      this.pendingRefresh.clear();
      for (const id of ids) await this.refreshNode(id);
    },

    async refreshNode(id, reloadChildren) {
      const li = this.elements.get(id);
      if (!li) return;
      const generation = this.loadGeneration;
      let data;
      try { data = await DevTools.rpc("DOM.describeNode", { nodeId: id, depth: 0 }); }
      catch (_) { return; }
      if (generation !== this.loadGeneration || this.elements.get(id) !== li) return;
      const old = this.nodes.get(id) || {};
      const expanded = li.classList.contains("expanded");
      DevTools.trace("elements.refreshNode", id, data.nodeName, expanded, old.childNodeCount, !!old.children, data.childNodeCount);
      data.isShadow = old.isShadow;
      const childrenChanged = old.childNodeCount !== data.childNodeCount || reloadChildren;
      if (!childrenChanged && old.children && !this.isInlineText(old)) {
        // Only this node's own line changed; keep the loaded subtree.
        data.children = old.children;
      } else if (!expanded && data.childNodeCount === 1) {
        // Might have become a lone text child; fetch it so it renders inline.
        try { const desc = await DevTools.rpc("DOM.describeNode", { nodeId: id, depth: 1 }); data.children = desc.children; } catch (_) {}
      }
      this.fillNode(li, data);
      if (childrenChanged && expanded && !this.isInlineText(data)) {
        await this.loadChildren(id);
      }
      // The root elements were empty when first read (page still parsing);
      // open them now that they have content, as a fresh load would.
      if (!expanded && !old.childNodeCount && data.childNodeCount && (data.nodeName === "body" || data.nodeName === "html")) {
        await this.expand(id);
      }
      if (id === this.selectedId) { this.renderBreadcrumbs(); this.refreshSidebar(); }
    },

    // ---- search ----------------------------------------------------------------------------------
    openSearch() { $("#elements-search-bar").hidden = false; $("#elements-search").focus(); $("#elements-search").select(); },
    closeSearch() {
      $("#elements-search-bar").hidden = true;
      for (const el of $$(".search-hit", this.tree)) el.classList.remove("search-hit");
      this.searchHits = []; this.searchIndex = -1; $("#elements-search-count").textContent = "";
      this.tree.focus();
    },
    async runSearch() {
      const query = $("#elements-search").value;
      for (const el of $$(".search-hit", this.tree)) el.classList.remove("search-hit");
      if (!query.trim()) { this.searchHits = []; $("#elements-search-count").textContent = ""; return; }
      try {
        const { nodeIds } = await DevTools.rpc("DOM.performSearch", { query });
        this.searchHits = nodeIds; this.searchIndex = -1;
        $("#elements-search-count").textContent = nodeIds.length ? `${nodeIds.length} match${nodeIds.length === 1 ? "" : "es"}` : "No matches";
        if (nodeIds.length) this.stepSearch(1);
      } catch (err) { $("#elements-search-count").textContent = err.message; }
    },
    async stepSearch(dir) {
      if (!this.searchHits.length) return;
      this.searchIndex = (this.searchIndex + dir + this.searchHits.length) % this.searchHits.length;
      $("#elements-search-count").textContent = `${this.searchIndex + 1} of ${this.searchHits.length}`;
      const id = this.searchHits[this.searchIndex];
      await this.revealNode(id);
      const li = this.elements.get(id);
      if (li) li.querySelector(":scope > .node-line").classList.add("search-hit");
      $("#elements-search").focus();
    },

    // ---- sidebar -------------------------------------------------------------------------------------
    refreshSidebar() {
      const id = this.selectedId;
      const data = this.nodes.get(id);
      if (!data || data.nodeType !== 1) {
        $("#styles-list").innerHTML = ""; $("#computed-list").innerHTML = ""; $("#layout-view").innerHTML = "";
        $("#styles-list").appendChild(h("div", { class: "styles-note" }, "Select an element to see its styles."));
        $("#listeners-list").textContent = "";
        $("#a11y-view").textContent = "";
        this.syncForcedState();
        return;
      }
      this.syncForcedState();                                              // elements-extras.js
      if (this.sidebarTab === "styles") this.loadStyles(id);
      else if (this.sidebarTab === "computed") this.loadComputed(id);
      else if (this.sidebarTab === "listeners") this.loadListeners(id);   // elements-extras.js
      else if (this.sidebarTab === "accessibility") this.loadAccessibility(id);   // elements-a11y.js
      else this.loadLayout(id);
    },

    async loadStyles(id) {
      try {
        const styles = await DevTools.rpc("CSS.getMatchedStyles", { nodeId: id });
        if (styles.nodeId !== this.selectedId) return;
        this.styles = styles;
        this.renderStyles();
      } catch (err) {
        $("#styles-list").textContent = "";
        $("#styles-list").appendChild(h("div", { class: "styles-note" }, err.message));
      }
    },

    sectionKey(section, nodeId) {
      return section.styleId ? "rule:" + section.styleId.sheetIndex + ":" + section.styleId.path.join(".") : "inline:" + nodeId;
    },

    cascadeOrder(styles, nodeId) {
      const sections = [];
      sections.push({ kind: "inline", key: "inline:" + nodeId, nodeId, declarations: styles.inline.declarations, selectorText: "element.style", active: true, origin: "" });
      const rules = styles.rules.slice().sort((a, b) => {
        const sa = a.specificity, sb = b.specificity;
        return (sb[0] - sa[0]) || (sb[1] - sa[1]) || (sb[2] - sa[2]) || (b.order - a.order);
      });
      for (const rule of rules) sections.push(Object.assign({ kind: "rule", key: this.sectionKey(rule, nodeId) }, rule));
      return sections;
    },

    computeWinners(sections) {
      const winners = new Map();
      for (const important of [true, false]) {
        sections.forEach((section, si) => {
          if (!section.active || section.pseudo) return;
          section.declarations.forEach((d, di) => {
            if (!!d.important !== important) return;
            if (!winners.has(d.name)) winners.set(d.name, si + ":" + di);
          });
        });
      }
      return winners;
    },

    renderStyles() {
      const list = $("#styles-list");
      list.textContent = "";
      const styles = this.styles;
      if (!styles) return;
      const filter = $("#styles-filter").value.trim().toLowerCase();
      const nodeId = styles.nodeId;
      const sections = this.cascadeOrder(styles, nodeId);
      const winners = this.computeWinners(sections);

      const pseudo = sections.filter((s) => s.pseudo);
      const normal = sections.filter((s) => !s.pseudo);
      normal.forEach((section, si) => {
        const index = sections.indexOf(section);
        list.appendChild(this.renderSection(section, nodeId, (d, di) => winners.get(d.name) !== index + ":" + di, filter));
      });
      if (pseudo.length) {
        list.appendChild(h("div", { class: "inherited-header" }, "Pseudo ::" + "element"));
        for (const section of pseudo) list.appendChild(this.renderSection(section, nodeId, () => false, filter, true));
      }

      const taken = new Set(winners.keys());
      for (const ancestor of styles.inherited) {
        const ancestorSections = this.cascadeOrder({ inline: ancestor.inline, rules: ancestor.rules }, ancestor.nodeId)
          .map((s) => Object.assign({}, s, { declarations: s.declarations.filter((d) => INHERITED.has(d.name) || d.name.startsWith("--")) }))
          .filter((s) => s.declarations.length);
        if (!ancestorSections.length) continue;
        const localWinners = this.computeWinners(ancestorSections);
        list.appendChild(h("div", { class: "inherited-header" }, "Inherited from ",
          h("span", { class: "link", onclick: () => this.select(ancestor.nodeId), onmouseenter: () => this.highlight(ancestor.nodeId) }, ancestor.name)));
        ancestorSections.forEach((section, si) => {
          list.appendChild(this.renderSection(section, ancestor.nodeId,
            (d, di) => taken.has(d.name) || localWinners.get(d.name) !== si + ":" + di, filter, true));
        });
        for (const s of ancestorSections) for (const d of s.declarations) taken.add(d.name);
      }

      if (styles.inaccessibleStyleSheets.length) {
        list.appendChild(h("div", { class: "styles-note" },
          styles.inaccessibleStyleSheets.length + " cross-origin stylesheet(s) could not be read: " + styles.inaccessibleStyleSheets.join(", ")));
      }
    },

    renderSection(section, nodeId, isOverridden, filter, readOnly) {
      const el = h("div", { class: "styles-section" + (section.active ? "" : " inactive") });
      const header = h("div", { class: "styles-header" });
      const selector = h("span", { class: "styles-selector" });
      if (section.kind === "inline") selector.textContent = "element.style";
      else {
        section.selectors.forEach((s, i) => {
          if (i) selector.appendChild(document.createTextNode(", "));
          selector.appendChild(h("span", { class: s.matches ? "" : "unmatched" }, s.text));
        });
      }
      selector.appendChild(document.createTextNode(" {"));
      header.appendChild(selector);
      if (section.kind === "rule") header.appendChild(h("span", { class: "styles-origin", title: section.origin }, section.isInspectorSheet ? "inspector-stylesheet" : fileName(section.origin)));
      el.appendChild(header);
      for (const c of section.conditions || []) el.appendChild(h("div", { class: "styles-condition" }, "@" + c.kind + " " + c.text));

      const props = h("div", { class: "styles-props" });
      const disabled = this.disabled.get(section.key) || new Map();
      section.declarations.forEach((d, di) => {
        if (filter && !(d.name + ":" + d.value).toLowerCase().includes(filter)) return;
        props.appendChild(this.renderProperty(section, nodeId, d, isOverridden(d, di), false, readOnly));
      });
      for (const [name, d] of disabled) {
        if (filter && !(name + ":" + d.value).toLowerCase().includes(filter)) continue;
        props.appendChild(this.renderProperty(section, nodeId, { name, value: d.value, important: d.important }, false, true, readOnly));
      }
      if (!readOnly) {
        const add = h("div", { class: "styles-add" });
        add.addEventListener("click", () => this.addProperty(section, nodeId, props, add));
        props.appendChild(add);
      }
      el.appendChild(props);
      el.appendChild(h("div", {}, "}"));
      return el;
    },

    renderProperty(section, nodeId, d, overridden, isDisabled, readOnly) {
      const row = h("div", { class: "styles-prop" + (overridden ? " overridden" : "") + (isDisabled ? " disabled" : "") });
      if (!readOnly) {
        const toggle = h("input", { type: "checkbox", class: "toggle", title: isDisabled ? "Enable" : "Disable" });
        toggle.checked = !isDisabled;
        toggle.addEventListener("change", () => this.toggleProperty(section, nodeId, d, !toggle.checked));
        row.appendChild(toggle);
      }
      const name = h("span", { class: "prop-name" }, d.name);
      const value = h("span", { class: "prop-value" });
      this.fillValue(value, d.value);
      row.append(name, ": ", value);
      if (d.important) row.appendChild(h("span", { class: "prop-important" }, " !important"));
      row.appendChild(document.createTextNode(";"));
      if (!readOnly && !isDisabled) {
        name.addEventListener("click", (e) => { e.stopPropagation(); this.editProperty(section, nodeId, d, name, "name", value); });
        value.addEventListener("click", (e) => { e.stopPropagation(); this.editProperty(section, nodeId, d, value, "value", name); });
      }
      return row;
    },

    fillValue(el, text) {
      el.textContent = "";
      let last = 0;
      for (const m of text.matchAll(COLOR_RE)) {
        el.appendChild(document.createTextNode(text.slice(last, m.index)));
        const swatch = h("span", { class: "color-swatch", style: "background:" + m[0] });
        el.appendChild(swatch);
        el.appendChild(document.createTextNode(m[0]));
        last = m.index + m[0].length;
      }
      el.appendChild(document.createTextNode(text.slice(last)));
    },

    async applyEdits(section, nodeId, edits) {
      const params = section.kind === "inline" ? { nodeId, edits } : { styleId: section.styleId, edits };
      try { await this.mutate("CSS.updateStyle", params); }
      catch (err) { this.notify(err.message); }
      this.loadStyles(this.selectedId);
    },

    editProperty(section, nodeId, d, el, part, other) {
      const initial = part === "name" ? d.name : d.value + (d.important ? " !important" : "");
      inlineEdit(el, {
        initial,
        onCommit: (text) => {
          const t = text.trim();
          if (t === initial) { this.loadStyles(this.selectedId); return; }
          const edits = [];
          if (part === "name") {
            edits.push({ name: d.name, remove: true });
            if (t) edits.push({ name: t, value: d.value, important: d.important });
          } else {
            if (!t) edits.push({ name: d.name, remove: true });
            else {
              const important = /!\s*important\s*$/i.test(t);
              edits.push({ name: d.name, value: t.replace(/!\s*important\s*$/i, "").trim(), important });
            }
          }
          this.applyEdits(section, nodeId, edits);
        },
        onCancel: () => this.loadStyles(this.selectedId),
      });
    },

    toggleProperty(section, nodeId, d, disable) {
      if (!this.disabled.has(section.key)) this.disabled.set(section.key, new Map());
      const map = this.disabled.get(section.key);
      if (disable) { map.set(d.name, { value: d.value, important: d.important }); this.applyEdits(section, nodeId, [{ name: d.name, remove: true }]); }
      else { const saved = map.get(d.name) || d; map.delete(d.name); this.applyEdits(section, nodeId, [{ name: d.name, value: saved.value, important: saved.important }]); }
    },

    addProperty(section, nodeId, props, addLine) {
      const row = h("div", { class: "styles-prop" });
      const name = h("span", { class: "prop-name" });
      const value = h("span", { class: "prop-value" });
      row.append(name, ": ", value, ";");
      props.insertBefore(row, addLine);
      inlineEdit(name, {
        initial: "",
        onCommit: (n) => {
          const propName = n.trim().replace(/:$/, "");
          if (!propName) { row.remove(); return; }
          inlineEdit(value, {
            initial: "",
            onCommit: (v) => {
              const t = v.trim();
              if (!t) { row.remove(); return; }
              const important = /!\s*important\s*$/i.test(t);
              this.applyEdits(section, nodeId, [{ name: propName, value: t.replace(/!\s*important\s*$/i, "").trim(), important }]);
            },
            onCancel: () => row.remove(),
          });
        },
        onCancel: () => row.remove(),
      });
    },

    async addRule() {
      const id = this.selectedId;
      const data = this.nodes.get(id);
      if (!data || data.nodeType !== 1) return;
      let selector = data.nodeName;
      const attrs = data.attributes || [];
      for (let i = 0; i < attrs.length; i += 2) {
        if (attrs[i] === "id" && attrs[i + 1]) { selector = "#" + attrs[i + 1]; break; }
        if (attrs[i] === "class" && attrs[i + 1].trim()) selector = data.nodeName + "." + attrs[i + 1].trim().split(/\s+/)[0];
      }
      try { await DevTools.rpc("CSS.addRule", { selector }); } catch (err) { this.notify(err.message); }
      this.loadStyles(id);
    },

    async loadComputed(id) {
      try {
        this.computed = await DevTools.rpc("CSS.getComputedStyle", { nodeId: id });
        this.renderComputed();
      } catch (err) { $("#computed-list").textContent = err.message; }
    },

    renderComputed() {
      const list = $("#computed-list");
      list.textContent = "";
      if (!this.computed) return;
      const filter = $("#computed-filter").value.trim().toLowerCase();
      for (const [name, value] of this.computed) {
        if (filter && !name.includes(filter) && !value.toLowerCase().includes(filter)) continue;
        const v = h("span", { class: "value" });
        this.fillValue(v, value);
        list.appendChild(h("div", { class: "computed-row" }, h("span", { class: "name" }, name), v));
      }
    },

    async loadLayout(id) {
      const view = $("#layout-view");
      view.textContent = "";
      try {
        const box = await DevTools.rpc("DOM.getBoxModel", { nodeId: id });
        const f = (n) => (Math.round(n * 100) / 100).toString().replace(/^0$/, "-");
        const sides = (o, label, cls, inner) => h("div", { class: "box " + cls },
          h("span", { class: "label" }, label),
          h("span", { class: "top" }, f(o.top)),
          h("div", { class: "row" }, h("span", {}, f(o.left)), inner, h("span", {}, f(o.right))),
          h("span", { class: "bottom" }, f(o.bottom)));
        const content = h("div", { class: "box content" }, `${Math.round(box.content.width * 100) / 100} × ${Math.round(box.content.height * 100) / 100}`);
        view.appendChild(h("div", { class: "box-model" }, sides(box.margin, "margin", "margin", sides(box.border, "border", "border", sides(box.padding, "padding", "padding", content)))));
        view.appendChild(h("div", { class: "layout-meta" }, `position: ${box.position}   display: ${box.display}   box-sizing: ${box.boxSizing}`));
        view.appendChild(h("div", { class: "layout-meta" }, `x: ${Math.round(box.rect.x)}  y: ${Math.round(box.rect.y)}  width: ${Math.round(box.rect.width)}  height: ${Math.round(box.rect.height)}`));
      } catch (err) { view.textContent = err.message; }
    },
  };

  DevTools.register("elements", panel);
})();
