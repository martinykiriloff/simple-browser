// SimpleBrowser inspector agent -- DOM, CSS, overlay and storage commands.
//
// Runs in the isolated world, loaded before agent.js so the two share one
// node registry. The DOM and CSSOM are shared across worlds, so everything
// the Elements, Styles and Application panels need is reachable from here
// without the page being able to interfere.
//
// The native side calls `__sbAgent.handle(method, params)` and relays the
// result to the DevTools UI. Methods follow Chrome's protocol naming loosely.
(function () {
  "use strict";

  const TOKEN = "__TAB_TOKEN__";
  const bridge = window.webkit?.messageHandlers?.inspector;
  const send = bridge ? bridge.postMessage.bind(bridge) : null;
  const post = (kind, payload) => {
    if (!send) return;
    try { send({ kind, source: "agent", tabToken: TOKEN, t: Date.now(), ...payload }); }
    catch (_) {}
  };

  // ---- node registry -------------------------------------------------------
  const idsByNode = new WeakMap();
  const nodesById = new Map();
  let nextId = 1;

  function nodeId(node) {
    let id = idsByNode.get(node);
    if (!id) { id = nextId++; idsByNode.set(node, id); nodesById.set(id, node); }
    return id;
  }
  function nodeFor(id) {
    const node = nodesById.get(Number(id));
    if (!node) throw new Error("Node " + id + " no longer exists");
    return node;
  }
  function elementFor(id) {
    const node = nodeFor(id);
    if (!(node instanceof Element)) throw new Error("Node " + id + " is not an element");
    return node;
  }

  // ---- things we add to the page and must hide from ourselves ----------------
  const OVERLAY_ID = "__sb-devtools-overlay";
  const SHEET_ID = "__sb-devtools-stylesheet";
  let overlay = null;
  let inspectorSheet = null;

  // Overlays the tools agent adds (FPS meter, audit highlights).
  const owned = new Set();

  function isOurs(node) {
    if (!node) return false;
    if (overlay && (node === overlay || overlay.contains(node))) return true;
    for (const el of owned) if (node === el || el.contains(node)) return true;
    if (inspectorSheet && node === inspectorSheet) return true;
    return false;
  }

  // ---- describing nodes ----------------------------------------------------------
  function isIgnorable(node) {
    return (node.nodeType === 3 && !node.nodeValue.trim()) || isOurs(node);
  }
  function childList(node) {
    const out = [];
    for (const child of node.childNodes) if (!isIgnorable(child)) out.push(child);
    return out;
  }
  function describe(node, depth) {
    const d = { nodeId: nodeId(node), nodeType: node.nodeType, nodeName: node.nodeName };
    switch (node.nodeType) {
      case 1: {
        d.nodeName = node.localName;
        const attributes = [];
        for (const a of node.attributes) attributes.push(a.name, a.value);
        d.attributes = attributes;
        if (node.shadowRoot) d.shadowRoot = describe(node.shadowRoot, 0);
        if (node instanceof HTMLTemplateElement) d.templateContent = true;
        break;
      }
      case 3: case 4: case 8:
        d.nodeValue = node.nodeValue.length > 10000 ? node.nodeValue.slice(0, 10000) + "…" : node.nodeValue;
        break;
      case 9:
        d.nodeName = "#document";
        d.documentURL = node.URL;
        d.readyState = node.readyState;
        break;
      case 10:
        d.nodeName = node.name;
        d.publicId = node.publicId;
        d.systemId = node.systemId;
        break;
      case 11:
        d.nodeName = node.host ? "#shadow-root" : "#document-fragment";
        if (node.host) d.shadowRootMode = node.mode;
        break;
    }
    const children = childList(node);
    d.childNodeCount = children.length;
    // Chrome inlines a lone text child so `<p>hello</p>` renders on one line.
    if (depth > 0 || (children.length === 1 && children[0].nodeType === 3 && children[0].nodeValue.length < 200)) {
      d.children = children.map((c) => describe(c, depth - 1));
    }
    return d;
  }

  function shortName(el) {
    if (!(el instanceof Element)) return el.nodeName;
    let s = el.localName;
    if (el.id) s += "#" + el.id;
    const cls = typeof el.className === "string" ? el.className.trim() : "";
    if (cls) s += "." + cls.split(/\s+/).join(".");
    return s;
  }

  // ---- overlay ------------------------------------------------------------------------
  function ensureOverlay() {
    if (overlay && overlay.isConnected) return overlay;
    overlay = document.createElement("div");
    overlay.id = OVERLAY_ID;
    overlay.setAttribute("aria-hidden", "true");
    overlay.style.cssText = "position:fixed;left:0;top:0;width:0;height:0;pointer-events:none;z-index:2147483647;" +
      "display:none;font:11px/1.4 -apple-system,system-ui,sans-serif;color:#222;";
    for (const name of ["margin", "border", "padding", "content"]) {
      const layer = document.createElement("div");
      layer.dataset.layer = name;
      layer.style.cssText = "position:fixed;box-sizing:border-box;pointer-events:none;";
      overlay.appendChild(layer);
    }
    const tip = document.createElement("div");
    tip.dataset.layer = "tip";
    tip.style.cssText = "position:fixed;pointer-events:none;background:#fff;color:#222;padding:4px 8px;" +
      "border-radius:4px;box-shadow:0 2px 6px rgba(0,0,0,.35);white-space:nowrap;font:11px -apple-system,system-ui,sans-serif;";
    overlay.appendChild(tip);
    (document.documentElement || document.body).appendChild(overlay);
    return overlay;
  }

  const COLORS = {
    content: "rgba(111,168,220,0.66)",
    padding: "rgba(147,196,125,0.55)",
    border: "rgba(255,229,153,0.66)",
    margin: "rgba(246,178,107,0.66)",
  };

  function highlight(node) {
    let el = node;
    if (el && el.nodeType === 3) el = el.parentElement;
    if (!(el instanceof Element)) { hideHighlight(); return; }
    const o = ensureOverlay();
    const rect = el.getBoundingClientRect();
    const cs = getComputedStyle(el);
    const px = (v) => parseFloat(v) || 0;
    const m = { t: px(cs.marginTop), r: px(cs.marginRight), b: px(cs.marginBottom), l: px(cs.marginLeft) };
    const b = { t: px(cs.borderTopWidth), r: px(cs.borderRightWidth), b: px(cs.borderBottomWidth), l: px(cs.borderLeftWidth) };
    const p = { t: px(cs.paddingTop), r: px(cs.paddingRight), b: px(cs.paddingBottom), l: px(cs.paddingLeft) };

    const layers = {};
    for (const layer of o.children) layers[layer.dataset.layer] = layer;

    const ring = (layer, left, top, width, height, widths, color) => {
      layer.style.display = "block";
      layer.style.left = left + "px"; layer.style.top = top + "px";
      layer.style.width = Math.max(0, width) + "px"; layer.style.height = Math.max(0, height) + "px";
      layer.style.borderStyle = "solid";
      layer.style.borderWidth = `${widths.t}px ${widths.r}px ${widths.b}px ${widths.l}px`;
      layer.style.borderColor = color;
      layer.style.background = "transparent";
    };
    ring(layers.margin, rect.left - m.l, rect.top - m.t, rect.width + m.l + m.r, rect.height + m.t + m.b, m, COLORS.margin);
    ring(layers.border, rect.left, rect.top, rect.width, rect.height, b, COLORS.border);
    ring(layers.padding, rect.left + b.l, rect.top + b.t, rect.width - b.l - b.r, rect.height - b.t - b.b, p, COLORS.padding);
    const content = layers.content;
    content.style.display = "block";
    content.style.left = (rect.left + b.l + p.l) + "px";
    content.style.top = (rect.top + b.t + p.t) + "px";
    content.style.width = Math.max(0, rect.width - b.l - b.r - p.l - p.r) + "px";
    content.style.height = Math.max(0, rect.height - b.t - b.b - p.t - p.b) + "px";
    content.style.border = "none";
    content.style.background = COLORS.content;

    const tip = layers.tip;
    tip.textContent = "";
    const tag = document.createElement("span");
    tag.style.color = "#881280";
    tag.textContent = el.localName;
    tip.appendChild(tag);
    if (el.id) { const s = document.createElement("span"); s.style.color = "#1a1aa6"; s.textContent = "#" + el.id; tip.appendChild(s); }
    const cls = typeof el.className === "string" ? el.className.trim() : "";
    if (cls) { const s = document.createElement("span"); s.style.color = "#1a1aa6"; s.textContent = "." + cls.split(/\s+/).slice(0, 4).join("."); tip.appendChild(s); }
    const size = document.createElement("span");
    size.style.color = "#666";
    size.textContent = `  ${Math.round(rect.width * 100) / 100} × ${Math.round(rect.height * 100) / 100}`;
    tip.appendChild(size);
    tip.style.display = "block";
    const tipTop = rect.top - m.t - 28;
    tip.style.top = (tipTop < 4 ? rect.bottom + m.b + 6 : tipTop) + "px";
    tip.style.left = Math.max(4, Math.min(rect.left, innerWidth - 300)) + "px";

    o.style.display = "block";
  }

  function hideHighlight() {
    if (overlay) overlay.style.display = "none";
  }

  // ---- element picker ---------------------------------------------------------------------
  let picking = false;
  let lastHover = null;

  function elementAt(x, y) {
    const el = document.elementFromPoint(x, y);
    return isOurs(el) ? null : el;
  }
  const pick = {
    move(e) {
      const el = elementAt(e.clientX, e.clientY);
      if (el && el !== lastHover) { lastHover = el; highlight(el); }
    },
    click(e) {
      e.preventDefault(); e.stopImmediatePropagation();
      const el = elementAt(e.clientX, e.clientY);
      setInspectMode(false);
      if (el) post("inspect", { nodeId: nodeId(el) });
    },
    swallow(e) { e.preventDefault(); e.stopImmediatePropagation(); },
    key(e) {
      if (e.key === "Escape") { e.preventDefault(); e.stopImmediatePropagation(); setInspectMode(false); post("inspectCancelled", {}); }
    },
  };
  function setInspectMode(on) {
    if (on === picking) return;
    picking = on;
    const opts = { capture: true };
    const fn = on ? "addEventListener" : "removeEventListener";
    window[fn]("mousemove", pick.move, opts);
    window[fn]("click", pick.click, opts);
    window[fn]("mousedown", pick.swallow, opts);
    window[fn]("mouseup", pick.swallow, opts);
    window[fn]("keydown", pick.key, opts);
    if (!on) { hideHighlight(); lastHover = null; }
  }

  // ---- CSS -------------------------------------------------------------------------------------
  function sheetLabel(sheet) {
    if (sheet.href) return sheet.href;
    const owner = sheet.ownerNode;
    if (owner) return "<style>" + (owner.id ? "#" + owner.id : "");
    return "constructed stylesheet";
  }

  function collectRules(rules, sheetIndex, path, conditions, out) {
    for (let i = 0; i < rules.length; i++) {
      const rule = rules[i];
      const p = path.concat(i);
      if (rule instanceof CSSStyleRule) {
        out.push({ rule, sheetIndex, path: p, conditions });
        if (rule.cssRules && rule.cssRules.length) {
          // CSS nesting: child rules carry their parent selector context.
          collectRules(rule.cssRules, sheetIndex, p, conditions.concat({ kind: "nest", text: rule.selectorText }), out);
        }
      } else if (rule instanceof CSSMediaRule) {
        collectRules(rule.cssRules, sheetIndex, p, conditions.concat({ kind: "media", text: rule.conditionText || rule.media.mediaText }), out);
      } else if (rule instanceof CSSSupportsRule) {
        collectRules(rule.cssRules, sheetIndex, p, conditions.concat({ kind: "supports", text: rule.conditionText }), out);
      } else if (typeof CSSLayerBlockRule !== "undefined" && rule instanceof CSSLayerBlockRule) {
        collectRules(rule.cssRules, sheetIndex, p, conditions.concat({ kind: "layer", text: rule.name }), out);
      } else if (typeof CSSContainerRule !== "undefined" && rule instanceof CSSContainerRule) {
        collectRules(rule.cssRules, sheetIndex, p, conditions.concat({ kind: "container", text: rule.conditionText }), out);
      } else if (typeof CSSScopeRule !== "undefined" && rule instanceof CSSScopeRule) {
        collectRules(rule.cssRules, sheetIndex, p, conditions.concat({ kind: "scope", text: (rule.start || "") + " to " + (rule.end || "") }), out);
      }
    }
  }

  function allRules() {
    const out = [];
    const inaccessible = [];
    const sheets = Array.from(document.styleSheets);
    sheets.forEach((sheet, sheetIndex) => {
      if (sheet.disabled) return;
      let rules;
      try { rules = sheet.cssRules; }
      catch (_) { inaccessible.push(sheetLabel(sheet)); return; }
      collectRules(rules, sheetIndex, [], [], out);
    });
    return { rules: out, inaccessible };
  }

  function conditionsActive(conditions) {
    return conditions.every((c) => {
      if (c.kind !== "media") return true;
      try { return matchMedia(c.text).matches; } catch (_) { return true; }
    });
  }

  // Splits `a, b:not(.x, .y)` on top-level commas only.
  function splitSelectors(text) {
    const out = []; let depth = 0, quote = null, current = "";
    for (const ch of text) {
      if (quote) { current += ch; if (ch === quote) quote = null; continue; }
      if (ch === '"' || ch === "'") { quote = ch; current += ch; continue; }
      if (ch === "(" || ch === "[") depth++;
      if (ch === ")" || ch === "]") depth--;
      if (ch === "," && depth === 0) { out.push(current.trim()); current = ""; continue; }
      current += ch;
    }
    if (current.trim()) out.push(current.trim());
    return out;
  }

  const PSEUDO_ELEMENT = /::?(before|after|first-line|first-letter|marker|placeholder|selection|backdrop|file-selector-button|cue|part\([^)]*\)|slotted\([^)]*\))\s*$/;

  function specificity(selector) {
    let s = selector.replace(/:(not|is|where|has)\(([^()]*)\)/g, (_, fn, inner) => fn === "where" ? "" : inner);
    s = s.replace(/\([^)]*\)/g, "()");
    const a = (s.match(/#[\w-]+/g) || []).length;
    const b = (s.match(/\.[\w-]+|\[[^\]]*\]|:(?!:)[\w-]+/g) || []).length;
    const c = (s.match(/(^|[\s>+~(])[a-zA-Z][\w-]*|::[\w-]+/g) || []).length;
    return [a, b, c];
  }

  // `style.cssText` re-serialises shorthands, so it reads the way the author
  // wrote the rule, unlike iterating `style[i]` which gives longhands.
  function parseDeclarations(cssText) {
    const out = [];
    let depth = 0, quote = null, current = "";
    const flush = () => {
      const text = current.trim(); current = "";
      if (!text) return;
      const colon = text.indexOf(":");
      if (colon < 0) return;
      let name = text.slice(0, colon).trim();
      let value = text.slice(colon + 1).trim();
      let important = false;
      const m = value.match(/\s*!\s*important\s*$/i);
      if (m) { important = true; value = value.slice(0, m.index).trim(); }
      out.push({ name, value, important });
    };
    for (const ch of cssText) {
      if (quote) { current += ch; if (ch === quote) quote = null; continue; }
      if (ch === '"' || ch === "'") { quote = ch; current += ch; continue; }
      if (ch === "(") depth++;
      if (ch === ")") depth--;
      if (ch === ";" && depth === 0) { flush(); continue; }
      current += ch;
    }
    flush();
    return out;
  }

  function matchedRulesFor(el, catalogue) {
    const matched = [];
    catalogue.rules.forEach((entry, order) => {
      const rule = entry.rule;
      const nested = entry.conditions.filter((c) => c.kind === "nest").map((c) => c.text);
      const selectors = splitSelectors(rule.selectorText).map((text) => {
        let matches = false, pseudo = null;
        const full = nested.length ? nested.map((n) => n + " ").join("") + text.replace(/&\s*/g, "") : text;
        try { matches = el.matches(full); } catch (_) {}
        if (!matches) {
          const pm = full.match(PSEUDO_ELEMENT);
          if (pm) {
            const base = full.slice(0, pm.index).trim() || "*";
            try { if (el.matches(base)) { matches = true; pseudo = pm[0].startsWith("::") ? pm[0] : "::" + pm[0].replace(/^:/, ""); } } catch (_) {}
          }
        }
        return { text, matches, pseudo, specificity: specificity(text) };
      });
      if (!selectors.some((s) => s.matches)) return;
      const best = selectors.filter((s) => s.matches).map((s) => s.specificity)
        .sort((x, y) => y[0] - x[0] || y[1] - x[1] || y[2] - x[2])[0];
      matched.push({
        selectorText: rule.selectorText,
        selectors,
        pseudo: selectors.find((s) => s.matches && s.pseudo)?.pseudo || null,
        origin: sheetLabel(document.styleSheets[entry.sheetIndex]),
        isInspectorSheet: document.styleSheets[entry.sheetIndex].ownerNode === inspectorSheet,
        styleId: { sheetIndex: entry.sheetIndex, path: entry.path },
        conditions: entry.conditions.filter((c) => c.kind !== "nest"),
        active: conditionsActive(entry.conditions),
        declarations: parseDeclarations(rule.style.cssText),
        specificity: best,
        order,
      });
    });
    return matched;
  }

  function inlineStyleOf(el) {
    const text = el.getAttribute("style") || "";
    return { cssText: text, declarations: parseDeclarations(el.style.cssText) };
  }

  function getMatchedStyles({ nodeId: id }) {
    const el = elementFor(id);
    const catalogue = allRules();
    const result = {
      nodeId: nodeId(el),
      inline: inlineStyleOf(el),
      rules: matchedRulesFor(el, catalogue),
      inherited: [],
      inaccessibleStyleSheets: catalogue.inaccessible,
    };
    let parent = el.parentElement, depth = 0;
    while (parent && depth < 40) {
      result.inherited.push({
        nodeId: nodeId(parent),
        name: shortName(parent),
        inline: inlineStyleOf(parent),
        rules: matchedRulesFor(parent, catalogue),
      });
      parent = parent.parentElement; depth++;
    }
    return result;
  }

  function getComputedStyleFor({ nodeId: id }) {
    const el = elementFor(id);
    const cs = getComputedStyle(el);
    const out = [];
    for (let i = 0; i < cs.length; i++) out.push([cs[i], cs.getPropertyValue(cs[i])]);
    out.sort((a, b) => a[0] < b[0] ? -1 : 1);
    return out;
  }

  function ruleAt(styleId) {
    const sheet = document.styleSheets[styleId.sheetIndex];
    if (!sheet) throw new Error("Stylesheet is gone");
    let rules = sheet.cssRules, rule = null;
    for (const index of styleId.path) {
      rule = rules[index];
      if (!rule) throw new Error("Rule is gone");
      rules = rule.cssRules;
    }
    return rule;
  }

  function updateStyle({ nodeId: id, styleId, edits }) {
    const style = styleId ? ruleAt(styleId).style : elementFor(id).style;
    for (const edit of edits || []) {
      if (edit.remove) style.removeProperty(edit.name);
      else style.setProperty(edit.name, edit.value, edit.important ? "important" : "");
    }
    return { declarations: parseDeclarations(style.cssText), cssText: style.cssText };
  }

  function setStyleText({ nodeId: id, styleId, text }) {
    const style = styleId ? ruleAt(styleId).style : elementFor(id).style;
    style.cssText = text;
    return { declarations: parseDeclarations(style.cssText), cssText: style.cssText };
  }

  function ensureInspectorSheet() {
    if (inspectorSheet && inspectorSheet.isConnected) return inspectorSheet;
    inspectorSheet = document.createElement("style");
    inspectorSheet.id = SHEET_ID;
    (document.head || document.documentElement).appendChild(inspectorSheet);
    return inspectorSheet;
  }

  function addRule({ selector }) {
    const style = ensureInspectorSheet();
    const sheet = style.sheet;
    const index = sheet.insertRule(selector + " {}", sheet.cssRules.length);
    const sheetIndex = Array.from(document.styleSheets).indexOf(sheet);
    return { styleId: { sheetIndex, path: [index] }, origin: "inspector-stylesheet" };
  }

  function getBoxModel({ nodeId: id }) {
    const el = elementFor(id);
    const rect = el.getBoundingClientRect();
    const cs = getComputedStyle(el);
    const px = (v) => parseFloat(v) || 0;
    const sides = (prefix, suffix) => ({
      top: px(cs[prefix + "Top" + suffix]), right: px(cs[prefix + "Right" + suffix]),
      bottom: px(cs[prefix + "Bottom" + suffix]), left: px(cs[prefix + "Left" + suffix]),
    });
    const margin = sides("margin", ""), border = sides("border", "Width"), padding = sides("padding", "");
    return {
      margin, border, padding,
      content: {
        width: rect.width - border.left - border.right - padding.left - padding.right,
        height: rect.height - border.top - border.bottom - padding.top - padding.bottom,
      },
      position: cs.position, display: cs.display, boxSizing: cs.boxSizing,
      rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
    };
  }

  // ---- DOM commands ----------------------------------------------------------------------------
  function uniqueSelector(el) {
    if (el.id && document.querySelectorAll("#" + CSS.escape(el.id)).length === 1) return "#" + CSS.escape(el.id);
    const parts = [];
    let node = el;
    while (node && node.nodeType === 1 && node !== document.documentElement) {
      let part = node.localName;
      if (node.id && document.querySelectorAll("#" + CSS.escape(node.id)).length === 1) {
        parts.unshift("#" + CSS.escape(node.id));
        return parts.join(" > ");
      }
      const parent = node.parentElement;
      if (parent) {
        const same = Array.from(parent.children).filter((c) => c.localName === node.localName);
        if (same.length > 1) part += ":nth-child(" + (Array.from(parent.children).indexOf(node) + 1) + ")";
      }
      parts.unshift(part);
      node = parent;
    }
    return (node === document.documentElement ? "html > " : "") + parts.join(" > ");
  }

  function setAttributesAsText({ nodeId: id, text }) {
    const el = elementFor(id);
    const doc = new DOMParser().parseFromString("<div " + text + "></div>", "text/html");
    const parsed = doc.body.firstElementChild;
    if (!parsed) throw new Error("Could not parse attributes");
    for (const a of Array.from(el.attributes)) el.removeAttribute(a.name);
    for (const a of parsed.attributes) el.setAttribute(a.name, a.value);
    return describe(el, 0);
  }

  function performSearch({ query }) {
    const q = String(query || "").trim();
    if (!q) return { nodeIds: [] };
    const ids = new Set();
    try { for (const el of document.querySelectorAll(q)) { if (!isOurs(el)) ids.add(nodeId(el)); if (ids.size >= 500) break; } } catch (_) {}
    if (q.startsWith("/") || q.startsWith("(")) {
      try {
        const r = document.evaluate(q, document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
        for (let i = 0; i < r.snapshotLength && ids.size < 500; i++) ids.add(nodeId(r.snapshotItem(i)));
      } catch (_) {}
    }
    const lower = q.toLowerCase();
    const walker = document.createTreeWalker(document, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT | NodeFilter.SHOW_COMMENT);
    let node;
    while ((node = walker.nextNode()) && ids.size < 500) {
      if (isOurs(node)) continue;
      if (node.nodeType === 1) {
        if (node.localName.includes(lower)) { ids.add(nodeId(node)); continue; }
        for (const a of node.attributes) {
          if (a.name.toLowerCase().includes(lower) || a.value.toLowerCase().includes(lower)) { ids.add(nodeId(node)); break; }
        }
      } else if (node.nodeValue.toLowerCase().includes(lower)) {
        ids.add(nodeId(node.nodeType === 3 && node.parentElement ? node.parentElement : node));
      }
    }
    return { nodeIds: Array.from(ids) };
  }

  const dom = {
    "DOM.getDocument": ({ depth }) => describe(document, depth ?? 2),
    "DOM.requestChildNodes": ({ nodeId: id, depth }) => childList(nodeFor(id)).map((c) => describe(c, (depth ?? 1) - 1)),
    "DOM.describeNode": ({ nodeId: id, depth }) => describe(nodeFor(id), depth ?? 0),
    "DOM.getOuterHTML": ({ nodeId: id }) => { const n = nodeFor(id); return n.outerHTML ?? n.nodeValue ?? ""; },
    "DOM.setOuterHTML": ({ nodeId: id, outerHTML }) => {
      const n = nodeFor(id);
      const parent = n.parentNode;
      if (n.nodeType === 1) n.outerHTML = outerHTML;
      else if (parent) {
        const tpl = document.createElement("template"); tpl.innerHTML = outerHTML;
        parent.replaceChild(tpl.content, n);
      }
      return parent ? describe(parent, 1) : null;
    },
    "DOM.setAttributeValue": ({ nodeId: id, name, value }) => { elementFor(id).setAttribute(name, value); return describe(nodeFor(id), 0); },
    "DOM.setAttributesAsText": setAttributesAsText,
    "DOM.removeAttribute": ({ nodeId: id, name }) => { elementFor(id).removeAttribute(name); return describe(nodeFor(id), 0); },
    "DOM.setNodeValue": ({ nodeId: id, value }) => { nodeFor(id).nodeValue = value; return true; },
    "DOM.removeNode": ({ nodeId: id }) => { const n = nodeFor(id); const parent = n.parentNode; n.remove(); return parent ? nodeId(parent) : null; },
    "DOM.performSearch": performSearch,
    "DOM.getNodePath": ({ nodeId: id }) => {
      const path = []; let n = nodeFor(id);
      while (n) { path.unshift(nodeId(n)); n = n.parentNode || n.host || null; }
      return path;
    },
    "DOM.scrollIntoView": ({ nodeId: id }) => { const n = nodeFor(id); (n.nodeType === 1 ? n : n.parentElement)?.scrollIntoView({ block: "center", inline: "center" }); return true; },
    "DOM.getBoxModel": getBoxModel,
    "DOM.uniqueSelector": ({ nodeId: id }) => uniqueSelector(elementFor(id)),
    "DOM.select": ({ nodeId: id }) => {
      // Lets the page-world console learn `$0` without either world sharing
      // references: the event's target is the same node in every world.
      const n = nodeFor(id);
      try { n.dispatchEvent(new CustomEvent("__sbSelect", { bubbles: false })); } catch (_) {}
      return true;
    },
    "DOM.mark": ({ nodeId: id }) => {
      // See page-hooks.js: lets the inspector protocol find this node.
      const n = nodeFor(id);
      try { n.dispatchEvent(new CustomEvent("__sbMark", { bubbles: false })); } catch (_) {}
      return true;
    },
    "DOM.elementFromPoint": ({ x, y }) => { const el = elementAt(x, y); return el ? nodeId(el) : null; },
    "DOM.focus": ({ nodeId: id }) => { elementFor(id).focus(); return true; },
    "DOM.toggleHidden": ({ nodeId: id }) => {
      const el = elementFor(id);
      el.style.visibility = el.style.visibility === "hidden" ? "" : "hidden";
      return el.style.visibility === "hidden";
    },
  };

  const css = {
    "CSS.getMatchedStyles": getMatchedStyles,
    "CSS.getComputedStyle": getComputedStyleFor,
    "CSS.updateStyle": updateStyle,
    "CSS.setStyleText": setStyleText,
    "CSS.addRule": addRule,
  };

  const overlayCommands = {
    "Overlay.highlightNode": ({ nodeId: id }) => { highlight(nodeFor(id)); return true; },
    "Overlay.hideHighlight": () => { hideHighlight(); return true; },
    "Overlay.setInspectMode": ({ enabled }) => { setInspectMode(!!enabled); return true; },
  };

  // ---- storage ----------------------------------------------------------------------------------------
  function area(name) {
    const store = name === "session" ? window.sessionStorage : window.localStorage;
    if (!store) throw new Error("Storage unavailable");
    return store;
  }
  const storage = {
    "Storage.getEntries": ({ area: name }) => {
      const store = area(name); const out = [];
      for (let i = 0; i < store.length; i++) { const k = store.key(i); out.push([k, store.getItem(k)]); }
      return out;
    },
    "Storage.setEntry": ({ area: name, key, value }) => { area(name).setItem(key, value); return true; },
    "Storage.removeEntry": ({ area: name, key }) => { area(name).removeItem(key); return true; },
    "Storage.clear": ({ area: name }) => { area(name).clear(); return true; },
    "Storage.getCookiesFromDocument": () => document.cookie,
    "Storage.getIndexedDBNames": async () => {
      if (!indexedDB.databases) return [];
      return (await indexedDB.databases()).map((d) => ({ name: d.name, version: d.version }));
    },
  };

  // ---- page & sources ------------------------------------------------------------------------------------
  const page = {
    "Page.getInfo": () => ({
      url: location.href, title: document.title, readyState: document.readyState,
      width: innerWidth, height: innerHeight, devicePixelRatio: devicePixelRatio,
      userAgent: navigator.userAgent, origin: location.origin,
      scrollWidth: document.documentElement ? document.documentElement.scrollWidth : innerWidth,
      scrollHeight: document.documentElement ? document.documentElement.scrollHeight : innerHeight,
    }),
    "Sources.list": () => {
      const seen = new Map();
      const add = (url, type) => { if (url && !seen.has(url)) seen.set(url, { url, type }); };
      add(location.href, "document");
      for (const s of document.querySelectorAll("script[src]")) add(s.src, "script");
      for (const l of document.querySelectorAll("link[rel~='stylesheet'][href]")) add(l.href, "stylesheet");
      for (const e of performance.getEntriesByType("resource")) {
        const t = e.initiatorType;
        if (t === "script") add(e.name, "script");
        else if (t === "link" || t === "css") { if (/\.css(\?|$)/.test(e.name)) add(e.name, "stylesheet"); }
        else if (t === "fetch" || t === "xmlhttprequest") add(e.name, "fetch");
        else if (t === "iframe") add(e.name, "document");
      }
      return Array.from(seen.values());
    },
    "Sources.fetch": async ({ url }) => {
      if (url === location.href) return { text: "<!DOCTYPE html>\n" + document.documentElement.outerHTML, live: true };
      const response = await fetch(url, { credentials: "include", cache: "force-cache" });
      return { text: await response.text(), status: response.status };
    },
  };

  const handlers = Object.assign({}, dom, css, overlayCommands, storage, page);

  async function handle(method, params) {
    const fn = handlers[method];
    if (!fn) throw new Error("Unknown method " + method);
    const result = await fn(params || {});
    // Only JSON-safe values cross the bridge; this drops `undefined` fields.
    return result === undefined ? null : JSON.parse(JSON.stringify(result));
  }

  window.addEventListener("__sbReveal", (e) => {
    if (e.target && e.target.nodeType) post("inspect", { nodeId: nodeId(e.target) });
  }, true);

  // The tools agent (tools-agent.js, injected on demand) adds its commands
  // here, and shares the node registry so its node ids are the tree's.
  const api = {
    handle, nodeId, nodeFor, isOurs, describe, shortName, uniqueSelector,
    has: (method) => Object.prototype.hasOwnProperty.call(handlers, method),
    extend: (more) => { Object.assign(handlers, more); },
    own: (el) => { owned.add(el); return el; },
    disown: (el) => { owned.delete(el); },
  };
  Object.defineProperty(window, "__sbAgent", {
    value: Object.freeze(api),
    enumerable: false, configurable: false, writable: false,
  });
})();
