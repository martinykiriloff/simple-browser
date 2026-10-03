// Keel DevTools — the Styles, Computed and Layout panes' tools:
// the colour picker on swatches, .cls (toggle the element's classes), the
// Copy menu on declarations and rules (also as JavaScript), Computed with
// "Show all", grouping and the trace of the rules that set each value, and
// box-model numbers you can edit. Extends the Elements panel.
"use strict";

(function () {
  const panel = DevTools.panels.elements;
  const baseRenderProperty = panel.renderProperty;
  const baseRenderSection = panel.renderSection;
  const baseRefreshSidebar = panel.refreshSidebar;

  // Shorthands whose longhands are not simply "<shorthand>-…".
  const SHORTHANDS = {
    gap: ["row-gap", "column-gap"], "grid-gap": ["row-gap", "column-gap"], inset: ["top", "right", "bottom", "left"],
    overflow: ["overflow-x", "overflow-y"], "place-items": ["align-items", "justify-items"], "place-content": ["align-content", "justify-content"],
    "place-self": ["align-self", "justify-self"], "border-radius": ["border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius", "border-bottom-left-radius"],
    "border-color": ["border-top-color", "border-right-color", "border-bottom-color", "border-left-color"],
    "border-width": ["border-top-width", "border-right-width", "border-bottom-width", "border-left-width"],
    "border-style": ["border-top-style", "border-right-style", "border-bottom-style", "border-left-style"],
    "grid-area": ["grid-row-start", "grid-column-start", "grid-row-end", "grid-column-end"], "grid-row": ["grid-row-start", "grid-row-end"],
    "grid-column": ["grid-column-start", "grid-column-end"], columns: ["column-width", "column-count"], "flex-flow": ["flex-direction", "flex-wrap"],
    "text-decoration": ["text-decoration-line", "text-decoration-color", "text-decoration-style", "text-decoration-thickness"],
  };
  // Shorthands whose longhands are "<shorthand>-…" (color is not one: color-scheme is its own property).
  const PREFIX_SHORTHANDS = new Set(["margin", "padding", "border", "border-top", "border-right", "border-bottom", "border-left", "border-image",
    "background", "font", "flex", "grid-template", "list-style", "transition", "animation", "outline", "text-decoration", "text-emphasis", "mask",
    "column-rule", "scroll-margin", "scroll-padding", "offset", "-webkit-text-stroke", "border-block", "border-inline", "margin-block", "margin-inline",
    "padding-block", "padding-inline", "inset-block", "inset-inline", "contain-intrinsic-size", "container"]);
  const covers = (decl, prop) => decl === prop || (PREFIX_SHORTHANDS.has(decl) && prop.startsWith(decl + "-")) || (SHORTHANDS[decl] || []).includes(prop) ||
    (decl === "border" && /^border-(top|right|bottom|left)-(width|style|color)$/.test(prop)) ||
    (decl === "font" && /^(line-height|font-.*)$/.test(prop)) || (decl === "background" && prop.startsWith("background-"));

  const GROUPS = [
    ["Layout", /^(display|position|top|right|bottom|left|inset|width|height|min-|max-|margin|padding|box-sizing|float|clear|overflow|z-index|visibility|aspect-ratio|contain|vertical-align|clip$|resize|isolation)/],
    ["Flexbox", /^(flex|order|align-|justify-|place-|gap|row-gap|column-gap)/],
    ["Grid", /^grid/],
    ["Text", /^(font|line-height|letter-spacing|word-|text-|white-space|color$|direction|writing-mode|hyphens|tab-size|unicode-|-webkit-text|-webkit-font|caret-color|quotes|font)/],
    ["Appearance", /^(background|border|outline|box-shadow|opacity|filter|backdrop-filter|mix-blend-mode|cursor|clip-path|mask|object-|appearance|accent-color|color-scheme|-webkit-appearance|image-rendering|-webkit-mask)/],
    ["Animation", /^(animation|transition|transform|will-change|perspective|translate|rotate|scale|offset|backface-visibility)/],
    ["Table", /^(table-layout|border-collapse|border-spacing|caption-side|empty-cells)/],
    ["Generated content", /^(content|counter-|list-style)/],
  ];
  const groupOf = (name) => (GROUPS.find(([, re]) => re.test(name)) || ["Other"])[0];

  // font-size → fontSize, -webkit-mask → WebkitMask, --x stays a quoted key.
  const jsName = (name) => name.startsWith("--") ? JSON.stringify(name) : name.replace(/^-(webkit|moz|ms)-/, (m, p) => p[0].toUpperCase() + p.slice(1) + "-").replace(/-([a-z])/g, (m, c) => c.toUpperCase());
  const jsDeclaration = (d) => `${jsName(d.name)}: ${JSON.stringify(d.value + (d.important ? " !important" : "")).replace(/^"|"$/g, "'").replace(/\\"/g, '"')}`;
  const cssDeclaration = (d) => `${d.name}: ${d.value}${d.important ? " !important" : ""};`;

  Object.assign(panel, {
    disabledClasses: new Map(),
    computedOpen: new Set(),
    jsDeclaration,
    cssDeclaration,

    // ---- declarations: colour swatches, copy --------------------------------------------------
    renderSection(section, nodeId, isOverridden, filter, readOnly) {
      const el = baseRenderSection.call(this, section, nodeId, isOverridden, filter, readOnly);
      el.__section = section;
      el.__nodeId = nodeId;
      el.__readOnly = !!readOnly;
      return el;
    },

    renderProperty(section, nodeId, d, overridden, isDisabled, readOnly) {
      const row = baseRenderProperty.call(this, section, nodeId, d, overridden, isDisabled, readOnly);
      row.__decl = d;
      if (readOnly || isDisabled) return row;
      const matches = Array.from(String(d.value).matchAll(this.COLOR_RE));
      $$(".color-swatch", row).forEach((swatch, k) => {
        const m = matches[k];
        if (!m) return;
        swatch.setAttribute("role", "button");
        swatch.setAttribute("tabindex", "0");
        swatch.title = "Open the colour picker";
        const open = (e) => { e.stopPropagation(); e.preventDefault(); this.openColorPicker(swatch, section, nodeId, d, m); };
        swatch.addEventListener("click", open);
        swatch.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") open(e); });
      });
      return row;
    },

    openColorPicker(swatch, section, nodeId, d, match) {
      const before = d.value.slice(0, match.index), after = d.value.slice(match.index + match[0].length);
      const label = swatch.nextSibling;
      const params = (value) => Object.assign(section.kind === "inline" ? { nodeId } : { styleId: section.styleId },
        { edits: [{ name: d.name, value: before + value + after, important: d.important }] });
      let pending = null, busy = false;
      const flush = async () => {
        if (busy || pending == null) return;
        busy = true;
        const value = pending; pending = null;
        try { await this.mutate("CSS.updateStyle", params(value)); } catch (e) { this.notify(e.message); }
        busy = false;
        flush();
      };
      ColorPicker.open(swatch, match[0], (value, done) => {
        swatch.style.background = value;
        if (label && label.nodeType === 3) label.nodeValue = value;
        pending = value;
        flush();
        if (done) setTimeout(() => this.loadStyles(this.selectedId), 150);
      });
    },

    initStylesTools() {
      $("#styles-list").addEventListener("contextmenu", (e) => {
        const sectionEl = e.target.closest(".styles-section");
        if (!sectionEl || !sectionEl.__section) return;
        e.preventDefault();
        const section = sectionEl.__section;
        const row = e.target.closest(".styles-prop");
        const d = row && row.__decl;
        const copy = (text) => DevTools.rpc("Clipboard.write", { text }).catch(() => {});
        const selector = section.kind === "inline" ? "element.style" : section.selectorText;
        const all = section.declarations;
        const items = [];
        if (d) {
          items.push({ label: "Copy declaration", action: () => copy(cssDeclaration(d)) });
          items.push({ label: "Copy property", action: () => copy(d.name) });
          items.push({ label: "Copy value", action: () => copy(d.value) });
          items.push({ label: "Copy declaration as JS", action: () => copy(jsDeclaration(d)) });
          items.push("-");
        }
        items.push({ label: "Copy rule", action: () => copy(this.ruleText(section)) });
        items.push({ label: "Copy all declarations", action: () => copy(all.map(cssDeclaration).join("\n")) });
        items.push({ label: "Copy all declarations as JS", action: () => copy(all.map(jsDeclaration).join(",\n")) });
        if (section.kind === "rule" && section.origin && /^(https?|file):/.test(section.origin)) {
          items.push("-", { label: "Reveal in Sources panel", action: () => DevTools.openSource(section.origin, 0, 0) });
        }
        ContextMenu.show(e.clientX, e.clientY, items);
        this.lastStylesMenu = { selector, items };
      });
      this.initCls();
      $("#computed-show-all").addEventListener("change", () => this.renderComputed());
      $("#computed-group").addEventListener("change", () => this.renderComputed());
    },

    ruleText(section) {
      const selector = section.kind === "inline" ? "element.style" : section.selectorText;
      const body = section.declarations.map((d) => "  " + cssDeclaration(d)).join("\n");
      const rule = `${selector} {\n${body}\n}`;
      return (section.conditions || []).reduceRight((inner, c) => `@${c.kind} ${c.text} {\n${inner.replace(/^/gm, "  ")}\n}`, rule);
    },

    // ---- .cls ----------------------------------------------------------------------------------
    initCls() {
      $("#styles-cls").addEventListener("click", () => {
        const pane = $("#styles-cls-pane");
        pane.hidden = !pane.hidden;
        $("#styles-cls").classList.toggle("on", !pane.hidden);
        $("#styles-cls").setAttribute("aria-expanded", pane.hidden ? "false" : "true");
        this.renderCls();
        if (!pane.hidden) $("#styles-cls-input").focus();
      });
      $("#styles-cls-input").addEventListener("keydown", (e) => {
        e.stopPropagation();
        if (e.key === "Enter") {
          e.preventDefault();
          const names = e.target.value.trim().split(/\s+/).filter(Boolean);
          e.target.value = "";
          if (names.length) this.setClasses(this.selectedId, (list) => { for (const n of names) if (!list.includes(n)) list.push(n); for (const n of names) this.disabledFor(this.selectedId).delete(n); });
        } else if (e.key === "Escape") { e.preventDefault(); e.target.value = ""; }
      });
    },

    disabledFor(id) {
      if (!this.disabledClasses.has(id)) this.disabledClasses.set(id, new Set());
      return this.disabledClasses.get(id);
    },

    classesOf(id) {
      const data = this.nodes.get(id);
      const attrs = (data && data.attributes) || [];
      for (let i = 0; i < attrs.length; i += 2) if (attrs[i] === "class") return attrs[i + 1].trim().split(/\s+/).filter(Boolean);
      return [];
    },

    renderCls() {
      const list = $("#styles-cls-list");
      if (!list || $("#styles-cls-pane").hidden) return;
      list.textContent = "";
      const id = this.selectedId;
      const data = this.nodes.get(id);
      if (!data || data.nodeType !== 1) return;
      const active = this.classesOf(id);
      const disabled = this.disabledFor(id);
      const names = active.concat(Array.from(disabled).filter((n) => !active.includes(n)));
      if (!names.length) list.appendChild(h("div", { class: "muted" }, "No classes"));
      for (const name of names) {
        const box = h("input", { type: "checkbox", "data-class": name });
        box.checked = active.includes(name);
        box.addEventListener("change", () => this.toggleClass(id, name, box.checked));
        list.appendChild(h("label", { class: "check" }, box, "." + name));
      }
    },

    toggleClass(id, name, on) {
      if (on) this.disabledFor(id).delete(name); else this.disabledFor(id).add(name);
      return this.setClasses(id, (list) => {
        const i = list.indexOf(name);
        if (on && i < 0) list.push(name);
        if (!on && i >= 0) list.splice(i, 1);
      });
    },

    async setClasses(id, change) {
      const list = this.classesOf(id);
      change(list);
      try { await this.mutate("DOM.setAttributeValue", { nodeId: id, name: "class", value: list.join(" ") }); }
      catch (e) { this.notify(e.message); }
      await this.refreshNode(id);
      this.renderCls();
    },

    refreshSidebar() {
      baseRefreshSidebar.call(this);
      this.renderCls();
    },

    // ---- Computed: show all, group, trace -------------------------------------------------------
    async loadComputed(id) {
      try {
        const [computed, styles] = await Promise.all([
          DevTools.rpc("CSS.getComputedStyle", { nodeId: id }),
          this.styles && this.styles.nodeId === id ? this.styles : DevTools.rpc("CSS.getMatchedStyles", { nodeId: id }).catch(() => null),
        ]);
        if (id !== this.selectedId) return;
        this.computed = computed;
        this.computedStyles = styles;
        this.renderComputed();
      } catch (err) { $("#computed-list").textContent = err.message; }
    },

    // For each longhand: the declarations that set it, the winning one first.
    computedTrace() {
      const styles = this.computedStyles;
      const trace = new Map();
      if (!styles) return trace;
      const add = (prop, entry) => { if (!trace.has(prop)) trace.set(prop, []); trace.get(prop).push(entry); };
      const names = this.computed.map(([n]) => n);
      const collect = (sections, inheritedFrom) => {
        const ordered = [];
        for (const important of [true, false]) {
          for (const section of sections) {
            if (section.pseudo) continue;
            for (const d of section.declarations) if (!!d.important === important) ordered.push({ section, d });
          }
        }
        for (const { section, d } of ordered) {
          for (const prop of names) {
            if (!covers(d.name, prop)) continue;
            if (inheritedFrom && !this.INHERITED.has(prop) && !d.name.startsWith("--")) continue;
            add(prop, { selector: section.kind === "inline" ? "element.style" : section.selectorText, value: d.value, important: d.important, name: d.name,
                        origin: section.origin || "", active: section.active !== false, inheritedFrom, styleNodeId: inheritedFrom ? inheritedFrom.nodeId : styles.nodeId });
          }
        }
      };
      collect(this.cascadeOrder(styles, styles.nodeId), null);
      for (const ancestor of styles.inherited || []) collect(this.cascadeOrder({ inline: ancestor.inline, rules: ancestor.rules }, ancestor.nodeId), ancestor);
      for (const list of trace.values()) {
        let won = false;
        for (const entry of list) { entry.overridden = won || !entry.active; if (entry.active && !won) won = true; }
      }
      return trace;
    },

    renderComputed() {
      const list = $("#computed-list");
      list.textContent = "";
      if (!this.computed) return;
      const filter = $("#computed-filter").value.trim().toLowerCase();
      const showAll = $("#computed-show-all").checked;
      const grouped = $("#computed-group").checked;
      const trace = this.computedTrace();
      const rows = this.computed.filter(([name, value]) => (showAll || trace.has(name)) &&
        (!filter || name.includes(filter) || value.toLowerCase().includes(filter)));
      const renderRow = ([name, value]) => {
        const entries = trace.get(name) || [];
        const open = this.computedOpen.has(name);
        const v = h("span", { class: "value" });
        this.fillValue(v, value);
        const row = h("div", { class: "computed-row" + (entries.length ? " has-trace" : "") + (open ? " open" : "") + (entries.length ? "" : " inherited-default"),
            "data-name": name, tabindex: entries.length ? "0" : null, role: entries.length ? "button" : null, "aria-expanded": entries.length ? String(open) : null },
          h("span", { class: "computed-arrow" }), h("span", { class: "name" }, name), v);
        const body = h("div", { class: "computed-trace" + (open ? "" : " collapsed") });
        for (const entry of entries) {
          const where = entry.origin ? h("span", { class: "link computed-origin", title: entry.origin, onclick: (e) => { e.stopPropagation(); if (/^(https?|file):/.test(entry.origin)) DevTools.openSource(entry.origin, 0, 0); } }, fileName(entry.origin)) : null;
          const val = h("span", { class: "value" });
          this.fillValue(val, entry.value + (entry.important ? " !important" : ""));
          body.appendChild(h("div", { class: "computed-trace-row" + (entry.overridden ? " overridden" : "") },
            val, h("span", { class: "computed-selector" }, entry.selector), entry.inheritedFrom ? h("span", { class: "muted" }, " (inherited from " + entry.inheritedFrom.name + ")") : null, where));
        }
        const flip = () => {
          if (!entries.length) return;
          if (this.computedOpen.has(name)) this.computedOpen.delete(name); else this.computedOpen.add(name);
          row.classList.toggle("open"); body.classList.toggle("collapsed");
          row.setAttribute("aria-expanded", String(row.classList.contains("open")));
        };
        row.addEventListener("click", flip);
        row.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); flip(); } });
        const frag = document.createDocumentFragment();
        frag.append(row, body);
        return frag;
      };
      if (!rows.length) { list.appendChild(h("div", { class: "styles-note" }, showAll ? "No properties" : "No rule sets a property here. Tick Show all for every computed value.")); return; }
      if (!grouped) { for (const r of rows) list.appendChild(renderRow(r)); return; }
      const byGroup = new Map();
      for (const r of rows) { const g = groupOf(r[0]); if (!byGroup.has(g)) byGroup.set(g, []); byGroup.get(g).push(r); }
      for (const [g] of GROUPS.concat([["Other"]])) {
        if (!byGroup.has(g)) continue;
        list.appendChild(h("div", { class: "computed-group-title" }, g));
        for (const r of byGroup.get(g)) list.appendChild(renderRow(r));
      }
    },

    // ---- Layout: editable box model ---------------------------------------------------------------
    async loadLayout(id) {
      const view = $("#layout-view");
      try {
        const box = await DevTools.rpc("DOM.getBoxModel", { nodeId: id });
        if (id !== this.selectedId) return;
        view.textContent = "";
        const f = (n) => (Math.round(n * 100) / 100).toString().replace(/^0$/, "-");
        const num = (value, prop) => {
          const el = h("span", { class: "box-num", tabindex: "0", role: "button", title: "Edit " + prop, "data-prop": prop }, f(value));
          const edit = (e) => {
            e.stopPropagation();
            inlineEdit(el, { initial: String(Math.round(value * 100) / 100),
              onCommit: (text) => this.editBox(id, prop, text.trim()), onCancel: () => {} });
          };
          el.addEventListener("click", edit);
          el.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); edit(e); } });
          return el;
        };
        const sides = (o, label, cls, prefix, suffix, inner) => h("div", { class: "box " + cls },
          h("span", { class: "label" }, label),
          h("span", { class: "top" }, num(o.top, prefix + "-top" + suffix)),
          h("div", { class: "row" }, num(o.left, prefix + "-left" + suffix), inner, num(o.right, prefix + "-right" + suffix)),
          h("span", { class: "bottom" }, num(o.bottom, prefix + "-bottom" + suffix)));
        const content = h("div", { class: "box content" }, num(box.content.width, "width"), " × ", num(box.content.height, "height"));
        view.appendChild(h("div", { class: "box-model" },
          sides(box.margin, "margin", "margin", "margin", "", sides(box.border, "border", "border", "border", "-width", sides(box.padding, "padding", "padding", "padding", "", content)))));
        view.appendChild(h("div", { class: "layout-meta" }, `position: ${box.position}   display: ${box.display}   box-sizing: ${box.boxSizing}`));
        view.appendChild(h("div", { class: "layout-meta" }, `x: ${Math.round(box.rect.x)}  y: ${Math.round(box.rect.y)}  width: ${Math.round(box.rect.width)}  height: ${Math.round(box.rect.height)}`));
        view.appendChild(h("div", { class: "styles-note" }, "Click a number to change it; it is set on the element's style."));
      } catch (err) { view.textContent = err.message; }
    },

    // A bare number means pixels; anything else (auto, 2em, 10%) is used as typed.
    async editBox(id, prop, text) {
      if (!text || text === "-") return this.loadLayout(id);
      let value = /^-?\d*\.?\d+$/.test(text) ? text + "px" : text;
      // Content size is the content box; with border-box sizing the property includes padding and border.
      if ((prop === "width" || prop === "height") && /px$/.test(value)) {
        const box = await DevTools.rpc("DOM.getBoxModel", { nodeId: id }).catch(() => null);
        if (box && box.boxSizing === "border-box") {
          const extra = prop === "width" ? box.padding.left + box.padding.right + box.border.left + box.border.right : box.padding.top + box.padding.bottom + box.border.top + box.border.bottom;
          value = (parseFloat(value) + extra) + "px";
        }
      }
      try { await this.mutate("CSS.updateStyle", { nodeId: id, edits: [{ name: prop, value }] }); }
      catch (e) { this.notify(e.message); }
      await this.loadLayout(id);
    },
  });

  panel.initStylesTools();
})();
