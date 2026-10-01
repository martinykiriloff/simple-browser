// SimpleBrowser inspector tools agent -- audits, accessibility, storage
// browsers, animations and page overlays.
//
// Runs in the isolated world, injected by DevToolsController the first time
// one of its commands is used rather than at document start, so pages pay
// nothing for it while DevTools is closed. It adds its commands to the DOM
// agent's dispatcher (`__sbAgent.extend`) and shares its node registry, so
// node ids here are the Elements tree's.
(function () {
  "use strict";
  const agent = window.__sbAgent;
  if (!agent || agent.has("Tools.loaded")) return;

  const MAX_ITEMS = 20;
  const snippet = (el) => {
    const html = el.outerHTML || "";
    const open = html.slice(0, html.indexOf(">") + 1) || html;
    return open.length > 160 ? open.slice(0, 157) + "…" : open;
  };
  const item = (el, detail) => ({ nodeId: agent.nodeId(el), selector: agent.uniqueSelector(el), snippet: snippet(el), detail: detail || "" });
  const isOurs = (el) => agent.isOurs(el);

  function isVisible(el) {
    if (!(el instanceof Element) || isOurs(el)) return false;
    const cs = getComputedStyle(el);
    if (cs.display === "none" || cs.visibility === "hidden" || cs.visibility === "collapse") return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 || r.height > 0 || cs.display === "contents";
  }
  function isHiddenFromAT(el) {
    for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
      if (n.getAttribute("aria-hidden") === "true" || n.hidden) return true;
      const cs = getComputedStyle(n);
      if (cs.display === "none" || cs.visibility === "hidden") return true;
    }
    return false;
  }

  // ---- accessibility: roles and names -----------------------------------------------------------
  // A pragmatic subset of HTML-AAM and accname: enough for audits and for the
  // Accessibility pane when the protocol is missing. WebKit's own tree (via
  // the protocol) is preferred where it is available.
  const INPUT_ROLES = { button: "button", submit: "button", reset: "button", image: "button", checkbox: "checkbox", radio: "radio",
                        range: "slider", number: "spinbutton", search: "searchbox", email: "textbox", tel: "textbox", text: "textbox",
                        url: "textbox", password: "textbox", "": "textbox" };
  const NAME_FROM_CONTENT = new Set(["button", "link", "heading", "cell", "columnheader", "rowheader", "option", "tab", "menuitem",
                                     "menuitemcheckbox", "menuitemradio", "treeitem", "checkbox", "radio", "switch", "tooltip", "listitem", "row"]);
  const LANDMARKS = new Set(["banner", "complementary", "contentinfo", "form", "main", "navigation", "region", "search"]);

  function implicitRole(el) {
    const tag = el.localName;
    switch (tag) {
      case "a": case "area": return el.hasAttribute("href") ? "link" : null;
      case "button": return "button";
      case "input": {
        const type = (el.getAttribute("type") || "").toLowerCase();
        if (type === "hidden") return null;
        if (el.hasAttribute("list") && /^(text|search|email|tel|url|)$/.test(type)) return "combobox";
        return INPUT_ROLES[type] || "textbox";
      }
      case "img": return el.getAttribute("alt") === "" ? "presentation" : "img";
      case "nav": return "navigation";
      case "main": return "main";
      case "aside": return "complementary";
      case "header": return el.closest("article, aside, main, nav, section") ? null : "banner";
      case "footer": return el.closest("article, aside, main, nav, section") ? null : "contentinfo";
      case "form": return accessibleName(el) ? "form" : null;
      case "section": return accessibleName(el) ? "region" : null;
      case "search": return "search";
      case "h1": case "h2": case "h3": case "h4": case "h5": case "h6": return "heading";
      case "ul": case "ol": case "menu": return "list";
      case "li": return "listitem";
      case "table": return "table";
      case "tr": return "row";
      case "td": return "cell";
      case "th": return el.closest("thead") || el.getAttribute("scope") === "col" ? "columnheader" : "rowheader";
      case "select": return el.multiple || el.size > 1 ? "listbox" : "combobox";
      case "textarea": return "textbox";
      case "option": return "option";
      case "dialog": return "dialog";
      case "progress": return "progressbar";
      case "meter": return "meter";
      case "hr": return "separator";
      case "article": return "article";
      case "fieldset": case "details": case "optgroup": return "group";
      case "summary": return "button";
      case "p": return "paragraph";
      case "figure": return "figure";
      case "dl": return "list";
      case "output": return "status";
      case "html": return "document";
      default: return null;
    }
  }
  function role(el) {
    const explicit = (el.getAttribute("role") || "").trim().split(/\s+/)[0];
    return explicit || implicitRole(el) || "generic";
  }

  function textFrom(node, seen) {
    if (node.nodeType === 3) return node.nodeValue;
    if (node.nodeType !== 1 || isOurs(node) || (seen.has(node) && node !== seen.root)) return "";
    if (node.getAttribute("aria-hidden") === "true") return "";
    const cs = getComputedStyle(node);
    if (cs.display === "none" || cs.visibility === "hidden") return "";
    if (node.localName === "img") return node.getAttribute("alt") || "";
    if (/^(script|style|template|noscript)$/.test(node.localName)) return "";
    // An embedded control contributes its name, not its subtree.
    if (node !== seen.root && (node.hasAttribute("aria-label") || node.hasAttribute("aria-labelledby"))) return nameOf(node, seen);
    let out = "";
    for (const child of node.childNodes) out += textFrom(child, seen);
    if (cs.display !== "inline" && out) out = " " + out + " ";
    return out;
  }
  const clean = (s) => String(s || "").replace(/\s+/g, " ").trim();

  // Returns { name, source }.
  function nameAndSource(el, seen = new Set()) {
    seen.add(el);
    const labelledby = el.getAttribute("aria-labelledby");
    if (labelledby && !seen.has("labelledby")) {
      const text = labelledby.split(/\s+/).map((id) => document.getElementById(id)).filter(Boolean)
        .map((ref) => { const s = new Set(seen); s.add("labelledby"); s.root = ref; return clean(textFrom(ref, s)); }).join(" ");
      if (clean(text)) return { name: clean(text), source: "aria-labelledby" };
    }
    const label = el.getAttribute("aria-label");
    if (clean(label)) return { name: clean(label), source: "aria-label" };
    const tag = el.localName;
    if ((tag === "img" || tag === "area" || (tag === "input" && el.type === "image")) && el.hasAttribute("alt")) return { name: clean(el.getAttribute("alt")), source: "alt" };
    if (tag === "input" && /^(button|submit|reset)$/.test(el.type)) return { name: clean(el.value || ({ submit: "Submit", reset: "Reset" })[el.type] || ""), source: "value" };
    if (el.labels && el.labels.length) {
      const text = Array.from(el.labels).map((l) => { const s = new Set(seen); s.root = l; return clean(textFrom(l, s)); }).join(" ");
      if (clean(text)) return { name: clean(text), source: "label" };
    }
    if (tag === "fieldset") { const legend = el.querySelector(":scope > legend"); if (legend) return { name: clean(legend.textContent), source: "legend" }; }
    if (tag === "table") { const caption = el.querySelector(":scope > caption"); if (caption) return { name: clean(caption.textContent), source: "caption" }; }
    if (tag === "figure") { const caption = el.querySelector(":scope > figcaption"); if (caption) return { name: clean(caption.textContent), source: "figcaption" }; }
    if (tag === "svg") { const title = el.querySelector(":scope > title"); if (title) return { name: clean(title.textContent), source: "title" }; }
    const r = role(el);
    if (NAME_FROM_CONTENT.has(r) || (r === "generic" && seen.root)) {
      const s = new Set(seen); s.root = el;
      const text = clean(textFrom(el, s));
      if (text) return { name: text, source: "contents" };
    }
    if (clean(el.getAttribute("title"))) return { name: clean(el.getAttribute("title")), source: "title" };
    if ((tag === "input" || tag === "textarea") && clean(el.getAttribute("placeholder"))) return { name: clean(el.getAttribute("placeholder")), source: "placeholder" };
    return { name: "", source: "" };
  }
  function nameOf(el, seen) { return nameAndSource(el, seen).name; }
  function accessibleName(el) { return nameOf(el); }

  function description(el) {
    const ids = el.getAttribute("aria-describedby");
    if (ids) return clean(ids.split(/\s+/).map((id) => document.getElementById(id)?.textContent || "").join(" "));
    const title = el.getAttribute("title");
    return title && nameAndSource(el).source !== "title" ? clean(title) : "";
  }

  function axProperties(el) {
    const props = {};
    const aria = (name) => el.getAttribute("aria-" + name);
    const bool = (v) => v === "true" ? true : v === "false" ? false : v;
    for (const name of ["checked", "pressed", "expanded", "selected", "disabled", "required", "readonly", "invalid", "busy", "current", "haspopup", "level", "live", "modal", "multiline", "multiselectable", "orientation", "valuemin", "valuemax", "valuenow", "valuetext", "controls", "owns"]) {
      if (el.hasAttribute("aria-" + name)) props[name] = bool(aria(name));
    }
    if ("disabled" in el && el.disabled) props.disabled = true;
    if ("required" in el && el.required) props.required = true;
    if ("readOnly" in el && el.readOnly && /^(input|textarea)$/.test(el.localName)) props.readonly = true;
    if (el.localName === "input" && /^(checkbox|radio)$/.test(el.type)) props.checked = el.indeterminate ? "mixed" : el.checked;
    if (/^h[1-6]$/.test(el.localName) && !props.level) props.level = +el.localName[1];
    if (el.localName === "details") props.expanded = el.open;
    props.focusable = el.tabIndex >= 0 || el.isContentEditable;
    if (document.activeElement === el) props.focused = true;
    return props;
  }

  // One node's computed accessibility, for the Elements sidebar.
  function axNode(el) {
    const { name, source } = nameAndSource(el);
    return { nodeId: agent.nodeId(el), role: role(el), name, nameSource: source, description: description(el),
             ignored: isHiddenFromAT(el) || role(el) === "presentation" || role(el) === "none", properties: axProperties(el) };
  }

  // The accessibility tree around a node: its ancestors, then its
  // descendants that are not generic or ignored, Chrome's "full tree" style.
  function axTree(el, depth = 0, budget = { n: 0 }) {
    const out = [];
    for (const child of el.children) {
      if (budget.n > 400 || isOurs(child) || isHiddenFromAT(child)) continue;
      const r = role(child);
      const interesting = r !== "generic" && r !== "presentation" && r !== "none";
      if (interesting) {
        budget.n++;
        out.push({ nodeId: agent.nodeId(child), role: r, name: accessibleName(child).slice(0, 120), children: depth < 12 ? axTree(child, depth + 1, budget) : [] });
      } else {
        out.push(...axTree(child, depth, budget));
      }
    }
    return out;
  }

  // ---- contrast ------------------------------------------------------------------------------------
  function parseColor(text) {
    const m = /rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?\)/.exec(text || "");
    return m ? { r: +m[1], g: +m[2], b: +m[3], a: m[4] == null ? 1 : +m[4] } : null;
  }
  function luminance({ r, g, b }) {
    const c = [r, g, b].map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  }
  const blend = (top, bottom) => ({ r: top.r * top.a + bottom.r * (1 - top.a), g: top.g * top.a + bottom.g * (1 - top.a), b: top.b * top.a + bottom.b * (1 - top.a), a: 1 });
  // The colour behind an element, or null when an image or gradient makes it unknowable.
  function backgroundOf(el) {
    const layers = [];
    for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
      const cs = getComputedStyle(n);
      if (cs.backgroundImage && cs.backgroundImage !== "none") return null;
      const c = parseColor(cs.backgroundColor);
      if (c && c.a > 0) { layers.push(c); if (c.a >= 1) break; }
    }
    let color = { r: 255, g: 255, b: 255, a: 1 };
    for (let i = layers.length - 1; i >= 0; i--) color = blend(layers[i], color);
    return color;
  }
  function contrastRatio(a, b) {
    const [l1, l2] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (l1 + 0.05) / (l2 + 0.05);
  }

  // ---- audits ------------------------------------------------------------------------------------------
  // Each audit: { id, title, failureTitle, description, weight, passed, notApplicable, items, displayValue }.
  // The UI adds the ones that need network, console or vitals data, and scores them.
  function audit(id, title, failureTitle, description, weight, failing, opts = {}) {
    const items = failing.slice(0, MAX_ITEMS);
    return Object.assign({ id, title, failureTitle, description, weight, passed: failing.length === 0, items, total: failing.length }, opts);
  }
  const all = (selector) => Array.from(document.querySelectorAll(selector)).filter((el) => !isOurs(el));

  function accessibilityAudits() {
    const out = [];
    const images = all("img, [role=img], input[type=image], area[href]").filter((el) => !isHiddenFromAT(el));
    out.push(audit("image-alt", "Image elements have [alt] attributes", "Image elements do not have [alt] attributes",
      "Informative images need a short text alternative; decorative ones need alt=\"\".", 10,
      images.filter((el) => el.localName === "img" ? !el.hasAttribute("alt") && !accessibleName(el) : !accessibleName(el)).map((el) => item(el)),
      { notApplicable: !images.length }));

    const controls = all("input:not([type=hidden]):not([type=button]):not([type=submit]):not([type=reset]):not([type=image]), select, textarea").filter((el) => !isHiddenFromAT(el));
    out.push(audit("label", "Form elements have associated labels", "Form elements do not have associated labels",
      "Labels make sure form controls are announced properly by assistive technologies. A placeholder is not a label.", 10,
      controls.filter((el) => { const s = nameAndSource(el).source; return !s || s === "placeholder"; }).map((el) => item(el)),
      { notApplicable: !controls.length }));

    const buttons = all("button, [role=button], input[type=button], input[type=submit], input[type=reset]").filter((el) => !isHiddenFromAT(el));
    out.push(audit("button-name", "Buttons have an accessible name", "Buttons do not have an accessible name",
      "A button without a name is announced as just \"button\".", 10, buttons.filter((el) => !accessibleName(el)).map((el) => item(el)),
      { notApplicable: !buttons.length }));

    const links = all("a[href], [role=link]").filter((el) => !isHiddenFromAT(el));
    out.push(audit("link-name", "Links have a discernible name", "Links do not have a discernible name",
      "Link text that is discernible, unique and focusable helps screen reader users.", 7, links.filter((el) => !accessibleName(el)).map((el) => item(el)),
      { notApplicable: !links.length }));

    const html = document.documentElement;
    const lang = html.getAttribute("lang");
    out.push(audit("html-has-lang", "<html> element has a [lang] attribute", "<html> element does not have a [lang] attribute",
      "Without a page language a screen reader reads the page in the user's default language.", 7, lang ? [] : [item(html)]));
    if (lang) {
      out.push(audit("html-lang-valid", "<html> element has a valid value for its [lang] attribute", "<html> element does not have a valid value for its [lang] attribute",
        "A BCP 47 language tag, such as en or pt-BR.", 7, /^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$/i.test(lang) ? [] : [item(html, "lang=\"" + lang + "\"")]));
    }
    out.push(audit("document-title", "Document has a <title> element", "Document doesn't have a <title> element",
      "The title gives screen reader users an overview of the page.", 7, clean(document.title) ? [] : [item(html)]));

    const mains = all("main, [role=main]").filter((el) => !isHiddenFromAT(el));
    out.push(audit("landmark-one-main", "Document has a main landmark", "Document does not have a main landmark",
      "One main landmark lets screen reader users jump to the content.", 3, mains.length === 1 ? [] : mains.length ? mains.slice(1).map((el) => item(el, "more than one main landmark")) : [item(document.body || html, "no <main> or role=main")]));

    const headings = all("h1, h2, h3, h4, h5, h6, [role=heading]").filter((el) => !isHiddenFromAT(el));
    const skipped = [];
    let last = 0;
    for (const el of headings) {
      const level = el.getAttribute("aria-level") ? +el.getAttribute("aria-level") : /^h[1-6]$/.test(el.localName) ? +el.localName[1] : 2;
      if (last && level > last + 1) skipped.push(item(el, `h${last} → h${level}`));
      last = level;
    }
    out.push(audit("heading-order", "Heading elements appear in a sequentially-descending order", "Heading elements are not in a sequentially-descending order",
      "Headings that skip levels make the structure hard to navigate.", 3, skipped, { notApplicable: !headings.length }));

    const ids = new Map();
    for (const el of all("[id]")) { const id = el.id; if (id) ids.set(id, (ids.get(id) || []).concat(el)); }
    const referenced = new Set(all("[aria-labelledby], [aria-describedby], [aria-controls], label[for]").flatMap((el) =>
      ["aria-labelledby", "aria-describedby", "aria-controls", "for"].flatMap((a) => (el.getAttribute(a) || "").split(/\s+/)).filter(Boolean)));
    out.push(audit("duplicate-id-aria", "ARIA IDs are unique", "ARIA IDs are not unique",
      "An id that labels or describes another element must be unique.", 3,
      Array.from(ids.entries()).filter(([id, els]) => els.length > 1 && referenced.has(id)).map(([id, els]) => item(els[1], "id=\"" + id + "\" ×" + els.length))));

    out.push(audit("tabindex", "No element has a [tabindex] value greater than 0", "Some elements have a [tabindex] value greater than 0",
      "A positive tabindex changes the tab order away from the visual order.", 3, all("[tabindex]").filter((el) => el.tabIndex > 0).map((el) => item(el, "tabindex=" + el.tabIndex))));

    const viewport = document.querySelector("meta[name=viewport]");
    const content = viewport ? viewport.content.toLowerCase() : "";
    const maxScale = /maximum-scale\s*=\s*([\d.]+)/.exec(content);
    out.push(audit("meta-viewport", "[user-scalable=\"no\"] is not used and [maximum-scale] is not less than 5", "Zooming is disabled by the viewport meta tag",
      "Disabling zoom is a problem for users with low vision.", 10,
      viewport && (/user-scalable\s*=\s*(no|0)/.test(content) || (maxScale && +maxScale[1] < 5)) ? [item(viewport)] : [], { notApplicable: !viewport }));

    // Contrast: elements with their own visible text, against the colour behind them.
    const lowContrast = [];
    let checked = 0, unknown = 0;
    const walker = document.createTreeWalker(document.body || html, NodeFilter.SHOW_ELEMENT);
    for (let el = walker.currentNode; el && checked < 600; el = walker.nextNode()) {
      if (isOurs(el) || /^(script|style|noscript|template|option)$/.test(el.localName)) continue;
      const ownText = Array.from(el.childNodes).some((n) => n.nodeType === 3 && n.nodeValue.trim());
      if (!ownText || !isVisible(el) || isHiddenFromAT(el)) continue;
      checked++;
      const cs = getComputedStyle(el);
      const fg = parseColor(cs.color);
      const bg = backgroundOf(el);
      if (!fg || !bg) { unknown++; continue; }
      const ratio = contrastRatio(blend(Object.assign({}, fg, { a: fg.a * (+cs.opacity || 1) }), bg), bg);
      const size = parseFloat(cs.fontSize), bold = +cs.fontWeight >= 700;
      const large = size >= 24 || (bold && size >= 18.66);
      const needed = large ? 3 : 4.5;
      if (ratio < needed) lowContrast.push(item(el, `contrast ${ratio.toFixed(2)}:1, needs ${needed}:1 (${cs.color} on ${`rgb(${Math.round(bg.r)}, ${Math.round(bg.g)}, ${Math.round(bg.b)})`})`));
    }
    out.push(audit("color-contrast", "Background and foreground colors have a sufficient contrast ratio", "Background and foreground colors do not have a sufficient contrast ratio",
      "Low-contrast text is difficult or impossible for many users to read. WCAG AA: 4.5:1, or 3:1 for large text." + (unknown ? ` ${unknown} element(s) over images or gradients were not checked.` : ""),
      7, lowContrast, { notApplicable: !checked }));
    return out;
  }

  const GENERIC_LINK_TEXT = new Set(["click here", "click this", "go", "here", "this", "start", "right here", "more", "learn more", "read more", "link", "continue", "details"]);

  function seoAudits() {
    const out = [];
    const html = document.documentElement;
    out.push(audit("document-title", "Document has a <title> element", "Document doesn't have a <title> element",
      "The title is the first line of a search result.", 1, clean(document.title) ? [] : [item(html)]));
    const description = document.querySelector("meta[name=description]");
    out.push(audit("meta-description", "Document has a meta description", "Document does not have a meta description",
      "Search engines may show the meta description in results.", 1, description && clean(description.content) ? [] : [item(document.head || html, description ? "empty content" : "no <meta name=\"description\">")]));
    const viewport = document.querySelector("meta[name=viewport]");
    out.push(audit("viewport", "Has a <meta name=\"viewport\"> tag with width or initial-scale", "Does not have a <meta name=\"viewport\"> tag with width or initial-scale",
      "Without it, mobile browsers render the page at a desktop width.", 1, viewport && /width|initial-scale/.test(viewport.content) ? [] : [item(document.head || html, "no viewport meta tag")]));
    const canonical = all("link[rel=canonical]");
    const badCanonical = canonical.filter((l) => { try { const u = new URL(l.getAttribute("href"), location.href); return !/^https?:$/.test(u.protocol) || !l.getAttribute("href").match(/^https?:\/\//); } catch (_) { return true; } });
    out.push(audit("canonical", "Document has a valid rel=canonical", "Document does not have a valid rel=canonical",
      "An absolute canonical URL tells search engines which URL to show.", 1,
      canonical.length > 1 ? canonical.slice(1).map((l) => item(l, "more than one canonical")) : badCanonical.map((l) => item(l, "not an absolute http(s) URL")),
      { notApplicable: !canonical.length }));
    const robots = all("meta[name=robots], meta[name=googlebot]").filter((m) => /noindex|none/i.test(m.content));
    out.push(audit("is-crawlable", "Page isn't blocked from indexing", "Page is blocked from indexing",
      "Search engines can only show pages they may index. (The X-Robots-Tag header is checked too.)", 1, robots.map((m) => item(m))));
    const links = all("a[href]").filter((a) => isVisible(a));
    out.push(audit("link-text", "Links have descriptive text", "Links do not have descriptive text",
      "Descriptive link text helps search engines understand the content.", 1,
      links.filter((a) => GENERIC_LINK_TEXT.has(clean(a.textContent).toLowerCase())).map((a) => item(a, "\"" + clean(a.textContent) + "\"")),
      { notApplicable: !links.length }));
    const anchors = all("a");
    out.push(audit("crawlable-anchors", "Links are crawlable", "Links are not crawlable",
      "Search engines follow href attributes, not script.", 1,
      anchors.filter((a) => { const href = a.getAttribute("href"); return a.hasAttribute("onclick") && (!href || /^javascript:/i.test(href)) || (href && /^javascript:/i.test(href)); }).map((a) => item(a))));
    const hreflang = all("link[rel=alternate][hreflang]");
    out.push(audit("hreflang", "Document has a valid hreflang", "Document doesn't have a valid hreflang",
      "hreflang links tell search engines which version of a page to show per language or region.", 1,
      hreflang.filter((l) => !/^(x-default|[a-z]{2,3}(-[A-Za-z]{4})?(-([A-Za-z]{2}|\d{3}))?)$/i.test(l.getAttribute("hreflang")) || !/^https?:\/\//.test(l.getAttribute("href") || ""))
        .map((l) => item(l, "hreflang=\"" + l.getAttribute("hreflang") + "\"")),
      { notApplicable: !hreflang.length }));
    return out;
  }

  const DEPRECATED_ELEMENTS = "applet, acronym, basefont, big, blink, center, dir, font, frame, frameset, isindex, keygen, marquee, nobr, noembed, plaintext, spacer, strike, tt, xmp";

  function bestPracticeAudits() {
    const out = [];
    const doctype = document.doctype;
    out.push(audit("doctype", "Page has the HTML doctype", "Page lacks the HTML doctype, thus triggering quirks mode",
      "Without <!DOCTYPE html> the page renders in quirks mode.", 1, doctype && doctype.name.toLowerCase() === "html" && document.compatMode === "CSS1Compat" ? [] : [item(document.documentElement, document.compatMode)]));
    const charsetMeta = document.querySelector("meta[charset], meta[http-equiv=Content-Type i]");
    out.push(audit("charset", "Properly defines charset", "Charset declaration is missing or occurs too late in the HTML",
      "Declare the character encoding with <meta charset> in the first 1024 bytes, or in the Content-Type header.", 1,
      charsetMeta && document.documentElement.outerHTML.indexOf("charset") < 1024 + 200 ? [] : [item(document.head || document.documentElement, "document.characterSet is " + document.characterSet)]));
    const deprecated = all(DEPRECATED_ELEMENTS).map((el) => item(el, "<" + el.localName + "> is obsolete"));
    for (const el of all("[bgcolor], [align]:not(caption):not(td):not(th):not(tr), table[border]").slice(0, 10)) deprecated.push(item(el, "presentational attribute"));
    out.push(audit("deprecations", "Avoids deprecated APIs", "Uses deprecated APIs",
      "Obsolete HTML elements and attributes found in the document, plus deprecation warnings from the console.", 1, deprecated));
    const badRatio = all("img").filter((img) => {
      if (!img.complete || !img.naturalWidth || !img.naturalHeight || !isVisible(img)) return false;
      const fit = getComputedStyle(img).objectFit;
      if (fit === "cover" || fit === "contain" || fit === "scale-down") return false;
      const r = img.getBoundingClientRect();
      if (r.width < 5 || r.height < 5) return false;
      return Math.abs(r.width / r.height - img.naturalWidth / img.naturalHeight) / (img.naturalWidth / img.naturalHeight) > 0.05;
    });
    out.push(audit("image-aspect-ratio", "Displays images with correct aspect ratio", "Displays images with incorrect aspect ratio",
      "An image drawn at a different aspect ratio than its file looks distorted.", 1,
      badRatio.map((img) => { const r = img.getBoundingClientRect(); return item(img, `displayed ${Math.round(r.width)}×${Math.round(r.height)}, actual ${img.naturalWidth}×${img.naturalHeight}`); }),
      { notApplicable: !all("img").length }));
    // Mixed content seen in the DOM; the UI adds requests from the network log.
    const insecure = location.protocol === "https:" ? all("img[src^='http:'], script[src^='http:'], link[href^='http:'][rel~=stylesheet], iframe[src^='http:'], video[src^='http:'], audio[src^='http:'], source[src^='http:']").map((el) => item(el, el.src || el.href)) : [];
    out.push(audit("mixed-content", "No mixed content", "Loads resources over HTTP on an HTTPS page",
      "Insecure subresources on a secure page are blocked or weaken its security.", 1, insecure, { notApplicable: location.protocol !== "https:" }));
    out.push(audit("is-on-https", "Uses HTTPS", "Does not use HTTPS",
      "Pages should be served over HTTPS; localhost counts as secure.", 1, window.isSecureContext ? [] : [item(document.documentElement, location.protocol + "//" + location.host)]));
    return out;
  }

  // What the Performance audits need from the DOM; the UI joins it with the
  // network log and the vitals.
  function performanceFacts() {
    const dpr = devicePixelRatio || 1;
    const head = document.head;
    const blocking = [];
    if (head) {
      for (const s of head.querySelectorAll("script[src]")) if (!s.async && !s.defer && s.type !== "module") blocking.push(Object.assign(item(s), { url: s.src, kind: "script" }));
      for (const l of head.querySelectorAll("link[rel~=stylesheet][href]")) {
        let applies = true;
        try { applies = !l.media || matchMedia(l.media).matches; } catch (_) {}
        if (applies && !l.disabled) blocking.push(Object.assign(item(l), { url: l.href, kind: "stylesheet" }));
      }
    }
    const oversized = all("img").filter((img) => img.complete && img.naturalWidth && isVisible(img)).map((img) => {
      const r = img.getBoundingClientRect();
      return { img, r, waste: img.naturalWidth * img.naturalHeight - Math.max(1, r.width * dpr) * Math.max(1, r.height * dpr) };
    }).filter((x) => x.r.width > 0 && x.img.naturalWidth > x.r.width * dpr * 1.5 && x.waste > 4096)
      .map((x) => Object.assign(item(x.img, `${x.img.naturalWidth}×${x.img.naturalHeight} shown at ${Math.round(x.r.width)}×${Math.round(x.r.height)}`), { url: x.img.currentSrc || x.img.src }));
    const images = all("img").map((img) => ({ nodeId: agent.nodeId(img), url: img.currentSrc || img.src }));
    return { renderBlocking: blocking, oversizedImages: oversized.slice(0, MAX_ITEMS), images, domSize: document.getElementsByTagName("*").length };
  }

  function runAudits() {
    return {
      url: location.href, title: document.title, fetchedAt: new Date().toISOString(),
      userAgent: navigator.userAgent, viewport: { width: innerWidth, height: innerHeight, devicePixelRatio },
      accessibility: accessibilityAudits(), seo: seoAudits(), bestPractices: bestPracticeAudits(), performance: performanceFacts(),
    };
  }

  // ---- values for display ----------------------------------------------------------------------
  // Structured-clone values (IndexedDB records, keys) as JSON the UI can show
  // as a tree; non-JSON types are tagged with "$type".
  function toJSONValue(v, depth = 0, seen = new WeakSet()) {
    if (v === null || typeof v === "boolean" || typeof v === "string") return v;
    if (typeof v === "number") return Number.isFinite(v) ? v : { $type: "number", value: String(v) };
    if (typeof v === "bigint") return { $type: "bigint", value: String(v) };
    if (typeof v === "undefined") return { $type: "undefined" };
    if (typeof v !== "object") return { $type: typeof v, value: String(v) };
    if (seen.has(v)) return { $type: "circular" };
    if (depth > 8) return { $type: "truncated" };
    seen.add(v);
    if (v instanceof Date) return { $type: "Date", value: isNaN(v) ? "Invalid Date" : v.toISOString() };
    if (v instanceof RegExp) return { $type: "RegExp", value: String(v) };
    if (typeof Blob !== "undefined" && v instanceof Blob) return { $type: v instanceof File ? "File" : "Blob", size: v.size, type: v.type, name: v.name };
    if (v instanceof ArrayBuffer) return { $type: "ArrayBuffer", byteLength: v.byteLength };
    if (ArrayBuffer.isView(v)) return { $type: v.constructor.name, length: v.length, values: Array.from(v.slice ? v.slice(0, 50) : []) };
    if (v instanceof Map) return { $type: "Map", entries: Array.from(v.entries()).slice(0, 200).map(([k, val]) => [toJSONValue(k, depth + 1, seen), toJSONValue(val, depth + 1, seen)]) };
    if (v instanceof Set) return { $type: "Set", values: Array.from(v).slice(0, 200).map((x) => toJSONValue(x, depth + 1, seen)) };
    if (Array.isArray(v)) return v.slice(0, 500).map((x) => toJSONValue(x, depth + 1, seen));
    const out = {};
    for (const key of Object.keys(v).slice(0, 500)) out[key] = toJSONValue(v[key], depth + 1, seen);
    return out;
  }
  // A key back from its JSON form; keys are numbers, strings, dates, binary or arrays of those.
  function fromJSONKey(k) {
    if (Array.isArray(k)) return k.map(fromJSONKey);
    if (k && typeof k === "object" && k.$type === "Date") return new Date(k.value);
    return k;
  }

  // ---- IndexedDB ---------------------------------------------------------------------------------
  // The isolated world shares the page's origin, so it opens the same
  // databases. Opened without a version, so nothing is ever upgraded.
  const request = (req) => new Promise((resolve, reject) => { req.onsuccess = () => resolve(req.result); req.onerror = () => reject(req.error); });
  async function openDatabase(name) {
    const names = indexedDB.databases ? (await indexedDB.databases()).map((d) => d.name) : [name];
    if (!names.includes(name)) throw new Error("No database named " + name);
    return new Promise((resolve, reject) => {
      const req = indexedDB.open(name);
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
      req.onblocked = () => reject(new Error("The database is blocked by another connection"));
    });
  }
  async function withStore(dbName, storeName, mode, fn) {
    const db = await openDatabase(dbName);
    try {
      const tx = db.transaction(storeName, mode);
      const done = new Promise((resolve, reject) => { tx.oncomplete = resolve; tx.onerror = () => reject(tx.error); tx.onabort = () => reject(tx.error || new Error("aborted")); });
      const result = await fn(tx.objectStore(storeName));
      if (mode !== "readonly") await done;
      return result;
    } finally { db.close(); }
  }
  const indexedDBCommands = {
    "IndexedDB.databases": async () => indexedDB.databases ? (await indexedDB.databases()).map((d) => ({ name: d.name, version: d.version })) : [],
    "IndexedDB.database": async ({ name }) => {
      const db = await openDatabase(name);
      try {
        const stores = [];
        for (const storeName of Array.from(db.objectStoreNames)) {
          const tx = db.transaction(storeName, "readonly");
          const store = tx.objectStore(storeName);
          stores.push({
            name: storeName, keyPath: store.keyPath, autoIncrement: store.autoIncrement, count: await request(store.count()),
            indexes: Array.from(store.indexNames).map((n) => { const i = store.index(n); return { name: n, keyPath: i.keyPath, unique: i.unique, multiEntry: i.multiEntry }; }),
          });
        }
        return { name: db.name, version: db.version, objectStores: stores };
      } finally { db.close(); }
    },
    "IndexedDB.records": ({ database, store, index, skip = 0, limit = 50 }) => withStore(database, store, "readonly", async (os) => {
      const source = index ? os.index(index) : os;
      const total = await request(source.count());
      const records = [];
      await new Promise((resolve, reject) => {
        const req = source.openCursor();
        let skipped = false;
        req.onerror = () => reject(req.error);
        req.onsuccess = () => {
          const cursor = req.result;
          if (!cursor) return resolve();
          if (skip && !skipped) { skipped = true; cursor.advance(skip); return; }
          records.push({ key: toJSONValue(cursor.key), primaryKey: toJSONValue(cursor.primaryKey), value: toJSONValue(cursor.value) });
          if (records.length >= limit) resolve(); else cursor.continue();
        };
      });
      return { records, total, hasMore: skip + records.length < total };
    }),
    "IndexedDB.deleteRecord": ({ database, store, key }) => withStore(database, store, "readwrite", (os) => request(os.delete(fromJSONKey(key))).then(() => true)),
    "IndexedDB.clearStore": ({ database, store }) => withStore(database, store, "readwrite", (os) => request(os.clear()).then(() => true)),
    "IndexedDB.deleteDatabase": ({ name }) => request(indexedDB.deleteDatabase(name)).then(() => true),
  };

  // ---- Cache Storage ---------------------------------------------------------------------------------
  function cacheStorage() {
    if (typeof caches === "undefined") throw new Error("Cache Storage is only available in secure contexts (HTTPS or localhost).");
    return caches;
  }
  const cacheCommands = {
    "CacheStorage.caches": async () => cacheStorage().keys(),
    "CacheStorage.entries": async ({ cache }) => {
      const c = await cacheStorage().open(cache);
      const out = [];
      for (const req of (await c.keys()).slice(0, 500)) {
        const res = await c.match(req);
        out.push({ url: req.url, method: req.method, status: res ? res.status : 0, type: res ? res.type : "", contentType: res ? res.headers.get("content-type") || "" : "",
                   contentLength: res ? +(res.headers.get("content-length") || 0) || null : null, date: res ? res.headers.get("date") || "" : "" });
      }
      return out;
    },
    "CacheStorage.response": async ({ cache, url }) => {
      const res = await (await cacheStorage().open(cache)).match(url);
      if (!res) throw new Error("No cached response for " + url);
      const type = res.headers.get("content-type") || "";
      let body;
      if (/^image\//.test(type)) {
        const blob = await res.blob();
        body = await new Promise((resolve) => { const reader = new FileReader(); reader.onload = () => resolve(reader.result); reader.readAsDataURL(blob); });
      } else {
        body = await res.text();
        if (body.length > 1024 * 1024) body = body.slice(0, 1024 * 1024) + "\n… (truncated)";
      }
      return { status: res.status, statusText: res.statusText, type: res.type, headers: Array.from(res.headers.entries()), body };
    },
    "CacheStorage.deleteEntry": async ({ cache, url }) => (await cacheStorage().open(cache)).delete(url),
    "CacheStorage.deleteCache": async ({ cache }) => cacheStorage().delete(cache),
  };

  // ---- Web App Manifest and service workers ---------------------------------------------------------------
  async function manifest() {
    const link = document.querySelector("link[rel~=manifest]");
    if (!link) return { present: false };
    const url = link.href;
    const out = { present: true, url, warnings: [], errors: [] };
    try {
      const res = await fetch(url, { credentials: link.crossOrigin === "use-credentials" ? "include" : "same-origin" });
      out.status = res.status;
      out.raw = await res.text();
      out.manifest = JSON.parse(out.raw);
    } catch (e) {
      out.errors.push(String(e && e.message || e));
      return out;
    }
    const m = out.manifest;
    const resolve = (u) => { try { return new URL(u, url).href; } catch (_) { return u; } };
    if (!m.name && !m.short_name) out.warnings.push("Manifest has no name or short_name.");
    if (!m.start_url) out.warnings.push("Manifest has no start_url; the manifest's own URL's directory is used.");
    if (!m.display) out.warnings.push("Manifest has no display mode (browser is assumed).");
    const icons = Array.isArray(m.icons) ? m.icons : [];
    out.icons = icons.map((i) => ({ src: resolve(i.src), sizes: i.sizes || "", type: i.type || "", purpose: i.purpose || "any" }));
    const sizes = icons.flatMap((i) => String(i.sizes || "").split(/\s+/));
    if (!sizes.includes("192x192")) out.warnings.push("No 192×192 icon.");
    if (!sizes.includes("512x512")) out.warnings.push("No 512×512 icon.");
    if (m.start_url) out.startURL = resolve(m.start_url);
    return out;
  }
  async function serviceWorkers() {
    const sw = navigator.serviceWorker;
    if (!sw) return { supported: false, reason: "navigator.serviceWorker is not available in this web view (WebKit only offers service workers to apps with app-bound domains or a browser entitlement, and on secure origins)." };
    const regs = await sw.getRegistrations();
    const worker = (w) => w ? { scriptURL: w.scriptURL, state: w.state } : null;
    return { supported: true, controller: worker(sw.controller), registrations: regs.map((r) => ({ scope: r.scope, active: worker(r.active), waiting: worker(r.waiting), installing: worker(r.installing), updateViaCache: r.updateViaCache })) };
  }
  const appCommands = {
    "Manifest.get": manifest,
    "ServiceWorker.list": serviceWorkers,
    "ServiceWorker.unregister": async ({ scope }) => {
      const regs = await navigator.serviceWorker.getRegistrations();
      const reg = regs.find((r) => r.scope === scope);
      return reg ? reg.unregister() : false;
    },
    "ServiceWorker.update": async ({ scope }) => {
      const reg = (await navigator.serviceWorker.getRegistrations()).find((r) => r.scope === scope);
      if (reg) await reg.update();
      return !!reg;
    },
  };

  // ---- animations -------------------------------------------------------------------------------------
  // document.getAnimations(): CSS animations, CSS transitions and Web
  // Animations alike, controlled through the Web Animations API.
  const animationIds = new WeakMap();
  const animationsById = new Map();
  let nextAnimation = 1;
  function animationId(a) {
    let id = animationIds.get(a);
    if (!id) { id = nextAnimation++; animationIds.set(a, id); animationsById.set(id, new WeakRef(a)); }
    return id;
  }
  function liveAnimations() {
    return document.getAnimations().filter((a) => {
      const target = a.effect && a.effect.target;
      return !(target && isOurs(target));
    });
  }
  function describeAnimation(a) {
    const effect = a.effect;
    const timing = effect && effect.getComputedTiming ? effect.getComputedTiming() : {};
    const target = effect && effect.target;
    const element = target && (target.nodeType === 1 ? target : target.element) || null;
    const type = typeof CSSTransition !== "undefined" && a instanceof CSSTransition ? "CSS transition"
      : typeof CSSAnimation !== "undefined" && a instanceof CSSAnimation ? "CSS animation" : "Web animation";
    const name = a.animationName || a.transitionProperty || a.id || "(anonymous)";
    return {
      id: animationId(a), type, name, playState: a.playState, playbackRate: a.playbackRate,
      currentTime: a.currentTime == null ? null : Number(a.currentTime),
      duration: typeof timing.duration === "number" ? timing.duration : null, delay: timing.delay || 0, endDelay: timing.endDelay || 0,
      iterations: timing.iterations === Infinity ? "infinite" : timing.iterations, direction: timing.direction, easing: timing.easing,
      progress: timing.progress == null ? null : timing.progress, iteration: timing.currentIteration,
      keyframes: effect && effect.getKeyframes ? effect.getKeyframes().length : 0,
      target: element ? { nodeId: agent.nodeId(element), label: agent.shortName(element) } : null,
      pseudo: target && target.pseudoElement || (effect && effect.pseudoElement) || null,
    };
  }
  function animationsFor(ids) {
    if (!ids) return liveAnimations();
    return ids.map((id) => animationsById.get(id)?.deref()).filter(Boolean);
  }
  const animationCommands = {
    "Animations.list": () => liveAnimations().map(describeAnimation),
    "Animations.pause": ({ ids }) => { for (const a of animationsFor(ids)) a.pause(); return true; },
    "Animations.play": ({ ids }) => { for (const a of animationsFor(ids)) a.play(); return true; },
    "Animations.replay": ({ ids }) => { for (const a of animationsFor(ids)) { a.currentTime = 0; a.play(); } return true; },
    "Animations.setPlaybackRate": ({ ids, rate }) => { for (const a of animationsFor(ids)) a.playbackRate = rate; return true; },
    "Animations.seek": ({ ids, time }) => { for (const a of animationsFor(ids)) a.currentTime = time; return true; },
  };

  // ---- FPS meter ----------------------------------------------------------------------
  // A fixed overlay counting animation frames, like Chrome's Rendering → FPS
  // meter. Frames that took over 1.5× the median are counted as dropped.
  const fps = { el: null, raf: 0, frames: [], value: 0, dropped: 0, history: [] };

  function drawFPS() {
    const now = performance.now();
    fps.frames.push(now);
    while (fps.frames.length && now - fps.frames[0] > 1000) fps.frames.shift();
    const n = fps.frames.length;
    if (n > 1) {
      const deltas = [];
      for (let i = 1; i < n; i++) deltas.push(fps.frames[i] - fps.frames[i - 1]);
      const median = deltas.slice().sort((a, b) => a - b)[deltas.length >> 1];
      fps.value = Math.round(((n - 1) * 1000) / (fps.frames[n - 1] - fps.frames[0]));
      fps.dropped = deltas.filter((d) => d > median * 1.5).length;
    }
    if (!fps.history.length || now - fps.history[fps.history.length - 1].t > 250) {
      fps.history.push({ t: now, v: fps.value });
      if (fps.history.length > 40) fps.history.shift();
      const label = fps.el.firstChild, canvas = fps.el.lastChild, ctx = canvas.getContext("2d");
      label.textContent = fps.value + " fps" + (fps.dropped ? "  ·  " + fps.dropped + " dropped/s" : "");
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      fps.history.forEach((p, i) => {
        const h = Math.min(1, p.v / 60) * canvas.height;
        ctx.fillStyle = p.v >= 50 ? "#7ed36f" : p.v >= 30 ? "#f2c037" : "#f28b82";
        ctx.fillRect(i * 4, canvas.height - h, 3, h);
      });
    }
    fps.raf = requestAnimationFrame(drawFPS);
  }

  function setFPSMeter(on) {
    if (on && !fps.el) {
      const el = document.createElement("div");
      el.setAttribute("aria-hidden", "true");
      el.style.cssText = "position:fixed;top:8px;right:8px;z-index:2147483647;pointer-events:none;background:rgba(32,33,36,.88);" +
        "color:#e8eaed;font:11px/1.4 Menlo,monospace;padding:6px 8px;border-radius:4px;box-shadow:0 2px 8px rgba(0,0,0,.35);";
      const label = document.createElement("div");
      const canvas = document.createElement("canvas");
      canvas.width = 160; canvas.height = 32;
      canvas.style.cssText = "display:block;margin-top:4px;width:160px;height:32px;";
      el.append(label, canvas);
      (document.documentElement || document.body).appendChild(agent.own(el));
      fps.el = el; fps.frames = []; fps.history = [];
      fps.raf = requestAnimationFrame(drawFPS);
    } else if (!on && fps.el) {
      cancelAnimationFrame(fps.raf);
      agent.disown(fps.el);
      fps.el.remove();
      fps.el = null;
    }
    return !!fps.el;
  }

  const handlers = {
    "Tools.loaded": () => true,
    "Rendering.setFPSMeter": ({ enabled }) => setFPSMeter(!!enabled),
    "Rendering.getFPS": () => ({ shown: !!fps.el, fps: fps.value, dropped: fps.dropped }),
    "Audit.run": runAudits,
    "Accessibility.getNode": ({ nodeId: id }) => {
      const el = agent.nodeFor(id);
      if (!(el instanceof Element)) throw new Error("Not an element");
      return axNode(el);
    },
    "Accessibility.getAncestors": ({ nodeId: id }) => {
      const chain = [];
      for (let el = agent.nodeFor(id); el && el.nodeType === 1; el = el.parentElement) chain.unshift({ nodeId: agent.nodeId(el), role: role(el), name: accessibleName(el).slice(0, 120) });
      return chain;
    },
    "Accessibility.getTree": ({ nodeId: id }) => {
      const root = id != null ? agent.nodeFor(id) : document.body || document.documentElement;
      return { nodeId: agent.nodeId(root), role: role(root), name: accessibleName(root).slice(0, 120), children: axTree(root) };
    },
  };

  agent.extend(Object.assign(handlers, indexedDBCommands, cacheCommands, appCommands, animationCommands));
})();
