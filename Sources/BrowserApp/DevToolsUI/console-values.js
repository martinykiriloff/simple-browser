// SimpleBrowser DevTools — values rendered the way Chrome's console renders
// them: `Array(3) [1, 2, 3]`, `{a: 1, b: {…}}`, `Map(1) {'a' => 1}`,
// `Promise {<fulfilled>: 3}`, DOM nodes as inline elements that highlight
// the node on hover and reveal it on click, functions that show their source
// when expanded, and errors with clickable, source-mapped stack frames.
// Replaces the renderer in core.js (ObjectTree), so every panel gets it.
"use strict";

(function () {
  // `fn@https://host/file.js:12:5`, `https://host/file.js:12:5`, `    at fn (file.js:12:5)`
  const FRAME_RE = /^\s*(?:at\s+)?(?:(.*?)@|(.*?)\s+\()?((?:https?|file|webpack|blob):[^\s()]+?|[\w./-]+\.\w+):(\d+)(?::(\d+))?\)?\s*$/;

  function parseFrame(line) {
    const m = FRAME_RE.exec(line);
    if (!m) return null;
    return { functionName: (m[1] || m[2] || "").trim(), url: m[3], line: +m[4], column: m[5] ? +m[5] : 0 };
  }

  function mapped(frame) {
    const original = window.SBSourceMaps && frame.url && frame.line ? SBSourceMaps.original(frame.url, frame.line, frame.column) : null;
    return original || frame;
  }

  // `<div id="a" class="b">` → coloured inline markup.
  function nodeMarkup(description) {
    const frag = h("span", { class: "v-node-markup" });
    const m = /^<([\w:-]+)([\s\S]*?)\/?>$/.exec(description || "");
    if (!m) { frag.appendChild(h("span", { class: "v-node-other" }, description || "node")); return frag; }
    frag.appendChild(h("span", { class: "tag" }, "<" + m[1]));
    for (const a of m[2].matchAll(/\s+([^\s=]+)(?:="([^"]*)")?/g)) {
      frag.appendChild(document.createTextNode(" "));
      frag.appendChild(h("span", { class: "attr-name" }, a[1]));
      if (a[2] !== undefined) { frag.appendChild(h("span", { class: "attr-name" }, "=")); frag.appendChild(h("span", { class: "attr-value" }, "\"" + a[2] + "\"")); }
    }
    frag.appendChild(h("span", { class: "tag" }, ">"));
    frag.appendChild(h("span", { class: "node-ellipsis" }, "…"));
    frag.appendChild(h("span", { class: "tag" }, "</" + m[1] + ">"));
    return frag;
  }

  function previewValue(prop) {
    if (prop.type === "string") {
      const v = /^"[\s\S]*"$/.test(prop.value) ? "'" + prop.value.slice(1, -1) + "'" : prop.value;
      return h("span", { class: "v-string" }, v);
    }
    if (prop.type === "number" || prop.type === "bigint") return h("span", { class: "v-number" }, prop.value);
    if (prop.type === "boolean") return h("span", { class: "v-boolean" }, prop.value);
    if (prop.type === "undefined" || prop.subtype === "null") return h("span", { class: "v-null" }, prop.value || (prop.subtype === "null" ? "null" : "undefined"));
    if (prop.type === "symbol") return h("span", { class: "v-symbol" }, prop.value);
    if (prop.type === "function") return h("span", { class: "v-function" }, "ƒ");
    if (prop.type === "accessor") return h("span", { class: "v-accessor" }, "(...)");
    if (prop.subtype === "node") return h("span", { class: "v-node" }, prop.value);
    if (prop.subtype === "regexp") return h("span", { class: "v-regexp" }, prop.value);
    if (prop.subtype === "error") return h("span", { class: "v-error-inline" }, prop.value);
    return h("span", { class: "obj-desc" }, prop.value);
  }

  // The class-name part: "Array(3)", "Map(2)", "Foo", or nothing for plain objects.
  function headName(obj) {
    const d = obj.description || "";
    if (obj.subtype === "array" || obj.subtype === "typedarray") {
      const n = (d.match(/\((\d+)\)/) || [])[1];
      const name = obj.subtype === "array" ? "Array" : (d.split("(")[0] || obj.className || "TypedArray");
      return name + "(" + (n != null ? n : obj.preview ? obj.preview.properties.length : "?") + ")";
    }
    if (obj.subtype === "promise") return "Promise";
    if (d === "Object" && (!obj.className || obj.className === "Object")) return "";
    return d;
  }

  Object.assign(ObjectTree, {
    render(obj, { quoteStrings = true, expandable = true } = {}) {
      const el = this.renderValue(obj, { quoteStrings, expandable });
      if (obj && obj.objectId) el.__remote = obj;
      else if (obj && obj.type !== "object") el.__remote = obj;
      return el;
    },

    renderValue(obj, { quoteStrings, expandable }) {
      if (!obj) return h("span", { class: "v-undefined" }, "undefined");
      const t = obj.type, sub = obj.subtype;
      if (t === "string") return h("span", { class: "v-string" }, quoteStrings ? JSON.stringify(obj.description) : obj.description);
      if (t === "number" || t === "bigint") return h("span", { class: "v-number" }, obj.description);
      if (t === "boolean") return h("span", { class: "v-boolean" }, obj.description);
      if (t === "symbol") return h("span", { class: "v-symbol" }, obj.description);
      if (t === "undefined") return h("span", { class: "v-undefined" }, "undefined");
      if (sub === "null") return h("span", { class: "v-null" }, "null");
      if (t === "accessor") return h("span", { class: "v-accessor" }, "(...)");
      if (t === "function") {
        const fn = h("span", { class: "v-function" });
        const d = obj.description || "ƒ";
        if (d.startsWith("class ")) fn.append(h("span", { class: "v-keyword" }, "class "), d.slice(6));
        else if (d.startsWith("ƒ ")) fn.append(h("span", { class: "v-keyword" }, "ƒ "), d.slice(2));
        else fn.textContent = d;
        return expandable && obj.objectId ? this.expandableNode(obj, fn) : fn;
      }
      if (sub === "node") return this.renderNode(obj, expandable);
      if (sub === "error") return this.renderError(obj, expandable);
      if (sub === "regexp") return expandable && obj.objectId ? this.expandableNode(obj, h("span", { class: "v-regexp" }, obj.description)) : h("span", { class: "v-regexp" }, obj.description);
      if (sub === "date") return expandable && obj.objectId ? this.expandableNode(obj, h("span", { class: "v-date" }, obj.description)) : h("span", { class: "v-date" }, obj.description);

      const head = h("span", { class: "obj-desc" });
      const name = headName(obj);
      if (name) head.appendChild(h("span", { class: "obj-class" }, name + " "));
      head.appendChild(this.previewNode(obj));
      return expandable && obj.objectId ? this.expandableNode(obj, head) : head;
    },

    previewNode(obj) {
      const p = obj.preview;
      const sub = obj.subtype;
      const isArray = sub === "array" || sub === "typedarray";
      const open = isArray ? "[" : "{", close = isArray ? "]" : "}";
      if (!p) return h("span", { class: "obj-preview" }, sub === "weakmap" || sub === "weakset" ? "" : open + (obj.objectId && !isArray ? "…" : "") + close);
      const out = h("span", { class: "obj-preview" }, open);
      p.properties.forEach((prop, i) => {
        if (i) out.appendChild(document.createTextNode(", "));
        if (sub === "promise") {
          out.appendChild(h("span", { class: "obj-key internal" }, prop.name));
          if (prop.name !== "<pending>") { out.appendChild(document.createTextNode(": ")); out.appendChild(previewValue(prop)); }
        } else if (sub === "map") {
          out.append(h("span", { class: "obj-key" }, prop.name), " => ", previewValue(prop));
        } else if (isArray || sub === "set") {
          out.appendChild(previewValue(prop));
        } else {
          out.append(h("span", { class: "obj-key" }, prop.name), ": ", previewValue(prop));
        }
      });
      if (p.overflow) out.appendChild(document.createTextNode(p.properties.length ? ", …" : "…"));
      out.appendChild(document.createTextNode(close));
      return out;
    },

    // A DOM node: inline markup; hover highlights it in the page, a click
    // reveals it in Elements. Works for objects from the debugger too.
    renderNode(obj, expandable) {
      const d = obj.description || "";
      const label = d.startsWith("<") ? nodeMarkup(d) : h("span", { class: "v-node-other" }, d);
      const node = h("span", { class: "v-node", title: "Click to reveal in the Elements panel" }, label);
      if (obj.objectId) {
        node.addEventListener("mouseenter", () => DevTools.rpc("Runtime.highlightNode", { objectId: obj.objectId }).catch(() => {}));
        node.addEventListener("mouseleave", () => DevTools.rpc("Overlay.hideHighlight").catch(() => {}));
        node.addEventListener("click", (e) => {
          if (getSelection().toString()) return;
          e.stopPropagation();
          DevTools.rpc("Overlay.hideHighlight").catch(() => {});
          DevTools.rpc("Runtime.revealNode", { objectId: obj.objectId }).catch(() => {});
        });
      }
      return expandable && obj.objectId ? this.expandableNode(obj, node) : node;
    },

    // "Name: message" and then the stack, each frame a link to its original source.
    renderError(obj, expandable) {
      const lines = String(obj.description || "Error").split("\n");
      const box = h("span", { class: "v-error" });
      box.appendChild(h("span", { class: "v-error-head" }, lines[0]));
      for (const line of lines.slice(1)) {
        if (!line.trim()) continue;
        const frame = parseFrame(line);
        if (!frame) { box.appendChild(h("span", { class: "v-error-line" }, "\n    " + line.trim())); continue; }
        const where = mapped(frame);
        box.appendChild(h("span", { class: "v-error-line" }, "\n    at " + (frame.functionName ? frame.functionName + " (" : ""),
          h("span", { class: "link", title: where.url, onclick: (e) => { e.stopPropagation(); DevTools.openSource(where.url, where.line, where.column); } },
            fileName(where.url) + ":" + where.line + (where.column ? ":" + where.column : "")),
          frame.functionName ? ")" : ""));
      }
      return expandable && obj.objectId ? this.expandableNode(obj, box) : box;
    },

    expandableNode(obj, headContent) {
      const container = h("span", { class: "obj" });
      const toggle = h("span", { class: "obj-toggle", role: "button", tabindex: "-1", "aria-label": "Expand" });
      const head = h("span", { class: "obj-head" }, toggle, headContent);
      const children = h("div", { class: "obj-children" });
      container.append(head, children);
      container.__remote = obj;
      let loaded = false;
      const flip = async (e) => {
        e.stopPropagation();
        const open = container.classList.toggle("expanded");
        toggle.setAttribute("aria-expanded", open ? "true" : "false");
        if (!open || loaded) return;
        loaded = true;
        children.appendChild(h("div", { class: "obj-row muted" }, "Loading…"));
        try {
          const [props, source] = await Promise.all([
            DevTools.rpc("Runtime.getProperties", { objectId: obj.objectId }),
            obj.type === "function" ? DevTools.rpc("Runtime.getFunctionSource", { objectId: obj.objectId }).catch(() => null) : null,
          ]);
          children.textContent = "";
          if (source && source.source) children.appendChild(this.functionSource(source.source));
          const entries = props.filter((p) => p.isEntry);
          if (entries.length && obj.subtype !== "map" && obj.subtype !== "set") entries.length = 0;
          if (entries.length) {
            const group = this.expandableGroup("[[Entries]]", entries.map((p) => this.propertyRow(obj, p, obj.subtype === "map")));
            children.appendChild(group);
          }
          for (const prop of props) if (!prop.isEntry || !entries.length) children.appendChild(this.propertyRow(obj, prop));
          if (!props.length && !(source && source.source)) children.appendChild(h("div", { class: "obj-row muted" }, "No properties"));
        } catch (err) {
          children.textContent = "";
          children.appendChild(h("div", { class: "obj-row v-error" }, String(err.message || err)));
        }
      };
      toggle.addEventListener("click", flip);
      // Clicking the summary of an object (not a link or a node) expands it, as in Chrome.
      headContent.addEventListener("click", (e) => {
        if (e.target.closest(".link, .v-node") || getSelection().toString()) return;
        if (obj.type === "object" || obj.type === "function") flip(e);
      });
      return container;
    },

    expandableGroup(title, rows) {
      const group = h("div", { class: "obj obj-group" });
      const toggle = h("span", { class: "obj-toggle" });
      const head = h("div", { class: "obj-head obj-row" }, toggle, h("span", { class: "obj-key internal" }, title));
      const body = h("div", { class: "obj-children" }, rows);
      head.addEventListener("click", (e) => { e.stopPropagation(); group.classList.toggle("expanded"); });
      group.append(head, body);
      group.classList.add("expanded");
      return group;
    },

    functionSource(source) {
      const lines = source.split("\n");
      const shown = lines.slice(0, 60).join("\n") + (lines.length > 60 ? "\n…" : "");
      const pre = h("pre", { class: "obj-source" });
      const tokens = Highlighter.tokenize(shown, "js");
      if (tokens) for (const [cls, raw] of tokens) pre.appendChild(cls ? h("span", { class: cls }, raw) : document.createTextNode(raw));
      else pre.textContent = shown;
      return pre;
    },

    propertyRow(parent, prop, asEntry) {
      const key = h("span", { class: "obj-key" + (prop.isInternal ? " internal" : prop.enumerable ? "" : " dim") }, prop.name);
      const row = h("div", { class: "obj-row" });
      if (prop.isReveal) {
        row.appendChild(h("span", { class: "link", onclick: () => DevTools.rpc("Runtime.revealNode", { objectId: parent.objectId }) }, "Reveal in Elements panel"));
        return row;
      }
      let value;
      if (prop.isAccessor) {
        value = h("span", { class: "v-accessor", title: "Invoke property getter" }, "(...)");
        value.addEventListener("click", async (e) => {
          e.stopPropagation();
          try {
            const result = await DevTools.rpc("Runtime.invokeGetter", { objectId: parent.objectId, name: prop.name });
            value.replaceWith(this.render(result));
          } catch (err) { value.replaceWith(h("span", { class: "v-error" }, "[Exception: " + err.message + "]")); }
        });
      } else {
        value = this.render(prop.value);
      }
      if (asEntry) row.append(key, " => ", value);
      else row.append(key, ": ", value);
      return row;
    },

    parseFrame,
  });
})();
