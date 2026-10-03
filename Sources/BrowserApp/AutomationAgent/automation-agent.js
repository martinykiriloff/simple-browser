// Keel automation agent -- what AI agents see of a page and how
// they point at it.
//
// Evaluated on demand in the inspector's isolated world (so it shares the
// DevTools node registry, `__sbAgent`, and page script cannot reach it), the
// first time an MCP tool needs it in a document. It reads the page as an
// accessibility tree with refs, resolves refs back to elements, and does the
// parts of an action that belong in the DOM; the real mouse and keyboard
// events come from the native side.
(function () {
  "use strict";
  if (window.__sbAutomation) return;

  // ---- refs ------------------------------------------------------------------------------
  // The same element keeps the same ref across snapshots, until the document goes.
  const refsByElement = new WeakMap();
  const elementsByRef = new Map();
  let nextRef = 1;

  function refFor(el) {
    let ref = refsByElement.get(el);
    if (!ref) {
      ref = "e" + nextRef++;
      refsByElement.set(el, ref);
      elementsByRef.set(ref, new WeakRef(el));
    }
    return ref;
  }

  function target({ ref, selector, text, role }) {
    if (ref) {
      const el = elementsByRef.get(String(ref).replace(/^\[?ref=|\]$/g, ""))?.deref();
      if (!el) throw new Error(`No element with ref ${ref}. Refs come from the latest snapshot; take a new one.`);
      if (!el.isConnected) throw new Error(`Ref ${ref} was removed from the page. Take a new snapshot.`);
      return el;
    }
    if (selector) {
      const el = deepQuery(document, selector);
      if (!el) throw new Error(`Nothing matches the selector ${selector}`);
      return el;
    }
    if (text) return findByText(String(text), role ? String(role) : null);
    throw new Error("Give a ref (from snapshot), a selector, or text.");
  }

  // The element a person would mean by "the Sign in button": its accessible
  // name or visible text equals the words (else contains them), visible,
  // interactive before structural, innermost before its containers.
  function findByText(text, role) {
    const wanted = clean(text).toLowerCase();
    if (!wanted) throw new Error("text is empty");
    const candidates = [];
    const visitAll = (root) => {
      for (const el of root.querySelectorAll("*")) {
        if (el.shadowRoot) visitAll(el.shadowRoot);
        if (el.localName === "iframe") { const doc = frameDocument(el); if (doc) visitAll(doc); }
        if (SKIP.has(el.localName) || isOurs(el)) continue;
        const elRole = roleOf(el) || (isFocusable(el) ? "generic" : null);
        if (role && elRole !== role) continue;
        const name = clean(elRole ? nameOf(el, elRole) : "").toLowerCase();
        const own = name || clean(el.innerText || "").toLowerCase();
        if (!own || own.length > 400 || !own.includes(wanted)) continue;
        if (isHidden(el) || !visibleRect(el)) continue;
        candidates.push({ el, exact: own === wanted || name === wanted, interactive: !!elRole && (INTERACTIVE.has(elRole) || elRole === "generic"), length: own.length });
      }
    };
    visitAll(document);
    if (!candidates.length) throw new Error(`No visible element${role ? " with role " + role : ""} has the text ${quote(text)}. Take a snapshot to see what is there.`);
    candidates.sort((a, b) => (b.exact - a.exact) || (b.interactive - a.interactive) || (a.length - b.length));
    // A container holding only the best match says the same words; take the inner one.
    let best = candidates[0].el;
    for (const c of candidates) if (c.el !== best && best.contains(c.el) && c.exact === candidates[0].exact && c.interactive >= candidates[0].interactive) best = c.el;
    return best;
  }

  // querySelector that also looks inside open shadow roots and same-origin iframes.
  function deepQuery(root, selector) {
    try {
      const direct = root.querySelector(selector);
      if (direct) return direct;
    } catch (e) {
      throw new Error(`Invalid selector ${selector}: ${e.message}`);
    }
    for (const el of root.querySelectorAll("*")) {
      if (el.shadowRoot) {
        const found = deepQuery(el.shadowRoot, selector);
        if (found) return found;
      }
      if (el.localName === "iframe") {
        const doc = frameDocument(el);
        if (doc) { const found = deepQuery(doc, selector); if (found) return found; }
      }
    }
    return null;
  }

  function frameDocument(frame) {
    try { return frame.contentDocument; } catch (_) { return null; }
  }

  // ---- text -----------------------------------------------------------------------------------
  const clean = (s) => (s || "").replace(/[\s​]+/g, " ").trim();
  const clip = (s, n) => (s.length > n ? s.slice(0, n - 1) + "…" : s);
  const quote = (s) => JSON.stringify(s);

  // ---- visibility -----------------------------------------------------------------------------
  const SKIP = new Set(["script", "style", "noscript", "template", "head", "meta", "link", "title", "base"]);

  function isHidden(el) {
    if (SKIP.has(el.localName)) return true;
    if (el.hidden && el.localName !== "details") return true;
    if (el.getAttribute("aria-hidden") === "true") return true;
    if (el.inert) return true;
    if (typeof el.checkVisibility === "function") {
      if (!el.checkVisibility({ visibilityProperty: true, contentVisibilityAuto: false })) {
        // display: contents has no box but its children do.
        return getComputedStyle(el).display !== "contents";
      }
      return false;
    }
    const cs = getComputedStyle(el);
    return cs.display === "none" || cs.visibility === "hidden";
  }

  function isOurs(node) {
    if (node && node.nodeType === 1 && node.hasAttribute && node.hasAttribute("data-keel-spotlight")) return true;
    return !!(window.__sbAgent && window.__sbAgent.isOurs(node));
  }

  // ---- roles ----------------------------------------------------------------------------------
  const LANDMARK_SCOPES = "article, aside, main, nav, section";
  const NAME_FROM_CONTENT = new Set(["button", "link", "heading", "tab", "menuitem", "menuitemcheckbox", "menuitemradio",
    "option", "cell", "columnheader", "rowheader", "treeitem", "tooltip", "switch", "checkbox", "radio", "caption", "legend", "term"]);
  // Leaves: nothing below them is worth listing.
  const LEAF = new Set(["textbox", "searchbox", "combobox", "checkbox", "radio", "slider", "spinbutton", "img", "progressbar",
    "meter", "separator", "switch", "scrollbar"]);
  const STRUCTURAL_NAME = new Set(["cell", "columnheader", "rowheader", "caption", "legend", "term", "treeitem", "tooltip"]);
  const INTERACTIVE = new Set(["button", "link", "textbox", "searchbox", "combobox", "listbox", "checkbox", "radio", "slider",
    "spinbutton", "switch", "tab", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "treeitem", "gridcell"]);

  function inputRole(el) {
    const type = (el.getAttribute("type") || "text").toLowerCase();
    switch (type) {
      case "hidden": return null;
      case "button": case "submit": case "reset": case "image": case "file": return "button";
      case "checkbox": return el.getAttribute("role") === "switch" ? "switch" : "checkbox";
      case "radio": return "radio";
      case "range": return "slider";
      case "number": return "spinbutton";
      case "search": return el.hasAttribute("list") ? "combobox" : "searchbox";
      default: return el.hasAttribute("list") ? "combobox" : "textbox";
    }
  }

  function roleOf(el) {
    const explicit = (el.getAttribute("role") || "").trim().split(/\s+/)[0];
    if (explicit && explicit !== "none" && explicit !== "presentation" && explicit !== "generic") return explicit;
    if (explicit === "none" || explicit === "presentation") return isFocusable(el) ? "generic" : null;
    if (el.isContentEditable && (el.parentElement == null || !el.parentElement.isContentEditable)) return "textbox";
    switch (el.localName) {
      case "a": case "area": return el.hasAttribute("href") ? "link" : null;
      case "button": return "button";
      case "input": return inputRole(el);
      case "select": return el.multiple || el.size > 1 ? "listbox" : "combobox";
      case "textarea": return "textbox";
      case "option": return "option";
      case "optgroup": return "group";
      case "img": return el.getAttribute("alt") === "" && !el.hasAttribute("aria-label") ? null : "img";
      case "svg": return el.hasAttribute("aria-label") || el.querySelector(":scope > title") ? "img" : null;
      case "canvas": return el.hasAttribute("aria-label") ? "img" : null;
      case "h1": case "h2": case "h3": case "h4": case "h5": case "h6": return "heading";
      case "p": return "paragraph";
      case "blockquote": return "blockquote";
      case "pre": return "code";
      case "ul": case "ol": case "menu": return "list";
      case "li": return "listitem";
      case "dl": return "list";
      case "dt": return "term";
      case "dd": return "definition";
      case "nav": return "navigation";
      case "main": return "main";
      case "header": return el.closest(LANDMARK_SCOPES) && el.closest(LANDMARK_SCOPES) !== el ? null : "banner";
      case "footer": return el.closest(LANDMARK_SCOPES) && el.closest(LANDMARK_SCOPES) !== el ? null : "contentinfo";
      case "aside": return "complementary";
      case "section": return el.hasAttribute("aria-label") || el.hasAttribute("aria-labelledby") ? "region" : null;
      case "form": return "form";
      case "search": return "search";
      case "article": return "article";
      case "dialog": return "dialog";
      case "details": return "group";
      case "summary": return "button";
      case "fieldset": return "group";
      case "table": return "table";
      case "tr": return "row";
      case "th": return el.getAttribute("scope") === "row" ? "rowheader" : "columnheader";
      case "td": return "cell";
      case "caption": return "caption";
      case "figure": return "figure";
      case "hr": return "separator";
      case "progress": return "progressbar";
      case "meter": return "meter";
      case "output": return "status";
      case "iframe": return "iframe";
      case "video": return "video";
      case "audio": return "audio";
      default: return null;
    }
  }

  function isFocusable(el) {
    const tabindex = el.getAttribute("tabindex");
    return tabindex !== null && Number(tabindex) >= 0;
  }

  // ---- names ----------------------------------------------------------------------------------
  function textOf(node, depth = 0) {
    if (depth > 20) return "";
    if (node.nodeType === 3) return node.nodeValue;
    if (node.nodeType !== 1 && node.nodeType !== 11) return "";
    if (node.nodeType === 1) {
      if (isHidden(node)) return "";
      if (node.localName === "img") return node.getAttribute("alt") || "";
      if (node.localName === "input" && /^(button|submit|reset)$/i.test(node.type)) return node.value;
      const label = node.getAttribute("aria-label");
      if (label && depth > 0) return label;
    }
    let out = "";
    for (const child of composedChildren(node)) {
      const t = textOf(child, depth + 1);
      out += child.nodeType === 1 && isBlock(child) ? " " + t + " " : t;
    }
    return out;
  }

  function isBlock(el) {
    return /^(div|p|li|tr|td|th|h[1-6]|section|article|br|ul|ol|table|header|footer|nav|form|fieldset|dd|dt|pre|blockquote)$/.test(el.localName);
  }

  function byIds(el, attribute) {
    const ids = (el.getAttribute(attribute) || "").split(/\s+/).filter(Boolean);
    const root = el.getRootNode();
    return ids.map((id) => (root.getElementById ? root.getElementById(id) : document.getElementById(id))).filter(Boolean);
  }

  function labelsOf(el) {
    const out = [];
    if (el.labels) for (const label of el.labels) out.push(label);
    return out;
  }

  function nameOf(el, role) {
    const labelledBy = byIds(el, "aria-labelledby");
    if (labelledBy.length) return clean(labelledBy.map((n) => textOf(n)).join(" "));
    const aria = el.getAttribute("aria-label");
    if (aria && clean(aria)) return clean(aria);
    const tag = el.localName;
    if (tag === "input" || tag === "select" || tag === "textarea" || tag === "meter" || tag === "progress" || tag === "output") {
      const type = (el.getAttribute("type") || "").toLowerCase();
      if (tag === "input" && /^(button|submit|reset)$/.test(type)) return el.value || { submit: "Submit", reset: "Reset" }[type] || "";
      if (tag === "input" && type === "image") return el.getAttribute("alt") || el.value || "Submit";
      if (tag === "input" && type === "file") {
        const own = labelsOf(el).map((l) => clean(textOf(l))).join(" ");
        return own || "Choose File";
      }
      const fromLabels = labelsOf(el).map((label) => {
        // The label's text without the control's own content.
        const copy = label.cloneNode(true);
        copy.querySelectorAll("input, select, textarea").forEach((c) => c.remove());
        return clean(copy.textContent);
      }).filter(Boolean).join(" ");
      if (fromLabels) return fromLabels;
      return clean(el.getAttribute("title") || el.getAttribute("placeholder") || "");
    }
    if (tag === "img" || tag === "area") return clean(el.getAttribute("alt") || el.getAttribute("title") || "");
    if (tag === "svg") return clean(el.querySelector(":scope > title")?.textContent || "");
    if (tag === "fieldset") return clean(el.querySelector(":scope > legend")?.textContent || "");
    if (tag === "table") return clean(el.querySelector(":scope > caption")?.textContent || el.getAttribute("title") || "");
    if (tag === "figure") return clean(el.querySelector(":scope > figcaption")?.textContent || "");
    if (tag === "iframe") return clean(el.getAttribute("title") || "");
    if (role && NAME_FROM_CONTENT.has(role)) {
      const text = clean(textOf(el));
      if (text) return clip(text, 160);
    }
    return clean(el.getAttribute("title") || "");
  }

  // ---- states ---------------------------------------------------------------------------------
  function deepActiveElement() {
    let active = document.activeElement;
    while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
    return active;
  }

  function attributesOf(el, role, focused) {
    const out = [];
    const aria = (name) => el.getAttribute("aria-" + name);
    if (role === "heading") out.push("level=" + (aria("level") || el.localName.slice(1) || "2"));
    if (role === "checkbox" || role === "radio" || role === "switch" || role === "menuitemcheckbox" || role === "menuitemradio") {
      const checked = aria("checked") ?? (typeof el.checked === "boolean" ? String(el.checked) : null);
      if (checked === "true") out.push("checked");
      else if (checked === "mixed" || el.indeterminate) out.push("checked=mixed");
    }
    const expanded = aria("expanded") ?? (el.localName === "summary" && el.parentElement?.localName === "details" ? String(el.parentElement.open) : null);
    if (expanded === "true") out.push("expanded"); else if (expanded === "false") out.push("collapsed");
    if (aria("pressed") === "true") out.push("pressed");
    if (aria("selected") === "true" || (el.localName === "option" && el.selected)) out.push("selected");
    if (aria("current") && aria("current") !== "false") out.push("current=" + aria("current"));
    if (el.matches?.(":disabled") || aria("disabled") === "true") out.push("disabled");
    if (el.required || aria("required") === "true") out.push("required");
    if (el.readOnly || aria("readonly") === "true") out.push("readonly");
    if (aria("invalid") === "true" || (el.matches?.(":user-invalid"))) out.push("invalid");
    if (aria("haspopup") && aria("haspopup") !== "false") out.push("haspopup=" + aria("haspopup"));
    if (el === focused) out.push("focused");
    if (role === "link") {
      const href = el.getAttribute("href") || "";
      if (href && !href.startsWith("javascript:")) out.push("url=" + clip(href, 120));
    }
    if (role === "img" && el.localName === "img" && !el.complete) out.push("loading");
    return out;
  }

  function valueOf(el, role) {
    const tag = el.localName;
    if (tag === "input") {
      const type = (el.getAttribute("type") || "text").toLowerCase();
      if (/^(button|submit|reset|image|checkbox|radio|hidden)$/.test(type)) return null;
      if (type === "password") return el.value ? "•".repeat(Math.min(el.value.length, 12)) : "";
      if (type === "file") return el.files && el.files.length ? [...el.files].map((f) => f.name).join(", ") : "";
      return el.value;
    }
    if (tag === "textarea") return el.value;
    if (tag === "select") return [...el.selectedOptions].map((o) => clean(o.textContent)).join(", ");
    if (tag === "progress" || tag === "meter") return String(el.value);
    if (role === "textbox" && el.isContentEditable) return clip(clean(el.innerText), 200);
    const now = el.getAttribute("aria-valuetext") || el.getAttribute("aria-valuenow");
    return now;
  }

  // ---- the composed tree ------------------------------------------------------------------------
  function composedChildren(node) {
    if (node.nodeType === 1) {
      if (node.shadowRoot) return [...node.shadowRoot.childNodes];
      if (node.localName === "slot") {
        const assigned = node.assignedNodes({ flatten: true });
        return assigned.length ? assigned : [...node.childNodes];
      }
    }
    return [...node.childNodes];
  }

  // ---- snapshot ---------------------------------------------------------------------------------
  // Items are {text} for loose text (raw, so inline markup does not add
  // spaces), or {line, children} for an element.
  function walk(node, ctx, parentPointer) {
    const items = [];
    // A label's words are already the name of the field it labels.
    const isFieldLabel = node.nodeType === 1 && node.localName === "label" && node.control && !isHidden(node.control);
    for (const child of composedChildren(node)) {
      if (child.nodeType === 3) {
        if (!ctx.interactiveOnly && !isFieldLabel && child.nodeValue) items.push({ text: child.nodeValue });
        continue;
      }
      if (child.nodeType !== 1 || isOurs(child)) continue;
      items.push(...visit(child, ctx, parentPointer));
    }
    return items;
  }

  function visit(el, ctx, parentPointer) {
    if (ctx.count++ > ctx.limitNodes) return [];
    if (isHidden(el)) return [];
    let role = roleOf(el);
    let pointer = parentPointer;
    if (!role) {
      // Divs and spans that act as buttons: focusable, or the start of a
      // pointer cursor. Everything else is structure the tree does not need.
      if (isFocusable(el) || el.hasAttribute("onclick")) role = "generic";
      else if (el.childElementCount < 4 || clean(el.textContent).length < 80) {
        pointer = getComputedStyle(el).cursor === "pointer";
        if (pointer && !parentPointer) role = "generic";
      }
      if (!role) {
        const inner = walk(el, ctx, pointer);
        // Block boxes break words apart; inline ones (strong, span) do not.
        return isBlock(el) || /^(label|li|section|aside)$/.test(el.localName) ? [{ text: " " }, ...inner, { text: " " }] : inner;
      }
    }
    if (role === "iframe") return [frameItem(el, ctx)];

    const name = nameOf(el, role);
    const interactive = INTERACTIVE.has(role) || role === "generic" || isFocusable(el);
    const value = valueOf(el, role);
    const attributes = attributesOf(el, role, ctx.focused);

    let children = [];
    let shownName = name;
    const nameCoversContent = NAME_FROM_CONTENT.has(role) && name && !el.querySelector("a[href], button, input, select, textarea, [role=button], [role=link], [tabindex]");
    if (!LEAF.has(role) && !nameCoversContent) {
      children = walk(el, ctx, pointer);
      // A cell or list item named after its own content says it twice.
      if (STRUCTURAL_NAME.has(role) && !el.hasAttribute("aria-label") && !el.hasAttribute("aria-labelledby")) shownName = "";
    }
    if (role === "listbox" || role === "combobox") {
      if (el.localName === "select") children = [...el.options].slice(0, 50).map((o) => ({
        line: { role: "option", name: clean(o.textContent), ref: refFor(o), attributes: o.selected ? ["selected"] : [] },
        children: [],
      }));
    }

    if (ctx.interactiveOnly && !interactive && role !== "heading") return children;
    const line = { role, name: shownName, ref: refFor(el), attributes, value };
    return [{ line, children }];
  }

  function frameItem(frame, ctx) {
    const doc = frameDocument(frame);
    const line = { role: "iframe", name: nameOf(frame, "iframe"), ref: refFor(frame), attributes: [] };
    if (!doc || !doc.body) {
      line.attributes.push("cross-origin", "src=" + clip(frame.getAttribute("src") || "", 100));
      return { line, children: [] };
    }
    return { line, children: walk(doc.body, ctx, false) };
  }

  function render(items, depth, out, ctx) {
    let pendingText = [];
    const flushText = () => {
      const text = clean(pendingText.join(""));
      pendingText = [];
      if (text) out.push("  ".repeat(depth) + "- text: " + quote(clip(text, 400)));
    };
    for (const item of items) {
      if (ctx.length > ctx.maxLength) return;
      if (item.text !== undefined) { pendingText.push(item.text); continue; }
      flushText();
      const { role, name, ref, attributes, value } = item.line;
      let head = "  ".repeat(depth) + "- " + role;
      if (name) head += " " + quote(clip(name, 200));
      for (const a of attributes) head += " [" + a + "]";
      head += " [ref=" + ref + "]";
      const kids = item.children;
      const onlyText = kids.length && kids.every((k) => k.text !== undefined);
      if (value !== null && value !== undefined && value !== "") head += ": " + quote(clip(String(value), 200));
      else if (onlyText) {
        const text = clean(kids.map((k) => k.text).join(""));
        if (text && text !== name) head += ": " + quote(clip(text, 400));
      }
      out.push(head);
      ctx.length += head.length + 1;
      if (kids.length && !onlyText) render(kids, depth + 1, out, ctx);
    }
    flushText();
  }

  function snapshot({ selector, ref, interactiveOnly, maxLength }) {
    const root = ref || selector ? target({ ref, selector }) : document.body || document.documentElement;
    const ctx = { interactiveOnly: !!interactiveOnly, focused: deepActiveElement(), count: 0, limitNodes: 60000, length: 0,
                  maxLength: maxLength || 60000 };
    const items = root === document.body || root === document.documentElement ? walk(root, ctx, false) : visit(root, ctx, false);
    const out = [];
    render(items, 0, out, ctx);
    let text = out.join("\n");
    let truncated = false;
    if (text.length > ctx.maxLength) {
      text = text.slice(0, text.lastIndexOf("\n", ctx.maxLength));
      truncated = true;
    }
    const dialog = document.querySelector("dialog[open]");
    return {
      url: location.href,
      title: document.title,
      text,
      truncated,
      refs: nextRef - 1,
      focused: ctx.focused && ctx.focused !== document.body ? refFor(ctx.focused) : null,
      modal: dialog ? refFor(dialog) : null,
    };
  }

  // ---- acting ---------------------------------------------------------------------------------------
  function describeShort(el) {
    const role = roleOf(el) || el.localName;
    const name = nameOf(el, role);
    return role + (name ? " " + quote(clip(name, 80)) : "") + " [ref=" + refFor(el) + "]";
  }

  // Where to click: the centre of the element's first visible box, in
  // viewport CSS pixels of the top document, after scrolling it into view.
  function prepare(params) {
    const el = target(params);
    const disabled = el.matches?.(":disabled") || el.getAttribute("aria-disabled") === "true";
    if (isHidden(el)) return { describe: describeShort(el), problem: "is not visible (display: none, visibility: hidden or aria-hidden)" };
    let rect = visibleRect(el);
    if (!rect || rect.top < 0 || rect.left < 0 || rect.bottom > innerHeight || rect.right > innerWidth) {
      el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
      rect = visibleRect(el);
    }
    if (!rect) return { describe: describeShort(el), problem: "has no size on the page" };
    const localX = rect.left + rect.width / 2, localY = rect.top + rect.height / 2;
    // What a press there would land on, judged in the element's own document.
    let covered = null;
    const hit = deepElementFromPoint(el.ownerDocument, localX, localY);
    if (hit && hit !== el && !el.contains(hit) && !(hit.contains && hit.contains(el)) && !labelsOf(el).includes(hit) && !isOurs(hit)) {
      covered = describeShort(hit);
    }
    // Inside a same-origin iframe: offset by the frame's position, and the
    // frame itself must be what is on top out here.
    let x = localX, y = localY;
    let win = el.ownerDocument.defaultView;
    while (win && win !== window && win.frameElement) {
      const frame = win.frameElement;
      const frameRect = frame.getBoundingClientRect();
      x += frameRect.left + frame.clientLeft; y += frameRect.top + frame.clientTop;
      const outer = deepElementFromPoint(frame.ownerDocument, x, y);
      if (!covered && outer && outer !== frame && !isOurs(outer)) covered = describeShort(outer);
      win = win.parent;
    }
    return { x, y, width: rect.width, height: rect.height, describe: describeShort(el), covered, disabled,
             tag: el.localName, type: (el.getAttribute("type") || "").toLowerCase(), editable: isEditable(el) };
  }

  function visibleRect(el) {
    for (const r of el.getClientRects()) if (r.width > 0 && r.height > 0) return r;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 ? r : null;
  }

  function deepElementFromPoint(doc, x, y) {
    let el = doc.elementFromPoint(x, y);
    while (el && el.shadowRoot) {
      const inner = el.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === el) break;
      el = inner;
    }
    return el;
  }

  function isEditable(el) {
    if (el.isContentEditable) return true;
    if (el.localName === "textarea") return !el.readOnly && !el.disabled;
    if (el.localName === "input") return !/^(button|submit|reset|image|checkbox|radio|hidden|file|range|color)$/i.test(el.type) && !el.readOnly && !el.disabled;
    return false;
  }

  function setNativeValue(el, value) {
    const proto = el.localName === "textarea" ? HTMLTextAreaElement.prototype : el.localName === "select" ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, "value").set.call(el, value);
  }

  function fire(el, type) {
    el.dispatchEvent(new Event(type, { bubbles: true, composed: true }));
  }

  function fill({ ref, selector, value }) {
    const el = target({ ref, selector });
    if (el.matches?.(":disabled")) throw new Error(describeShort(el) + " is disabled");
    const tag = el.localName, type = (el.getAttribute("type") || "").toLowerCase();
    if (tag === "select") return selectOption({ ref, selector, values: [value] });
    if (tag === "input" && (type === "checkbox" || type === "radio")) {
      const want = !/^(false|0|off|no|unchecked)$/i.test(value);
      if (el.checked !== want) el.click();
      return { describe: describeShort(el), value: String(el.checked) };
    }
    if (tag === "input" && type === "file") throw new Error("Use upload_files for file inputs.");
    if (!isEditable(el)) throw new Error(describeShort(el) + " is not an editable field");
    el.focus();
    if (el.isContentEditable) {
      const range = document.createRange();
      range.selectNodeContents(el);
      const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
      if (!document.execCommand(value ? "insertText" : "delete", false, value)) el.textContent = value;
      return { describe: describeShort(el), value: clip(clean(el.innerText), 200) };
    }
    // Through the editing pipeline first: trusted beforeinput/input events,
    // undo, and frameworks that watch keystroke-level input all see it.
    try { el.select(); } catch (_) {}
    let done = false;
    try { done = document.execCommand(value ? "insertText" : "delete", false, value) && el.value === value; } catch (_) {}
    if (!done) {
      setNativeValue(el, value);
      fire(el, "input");
    }
    fire(el, "change");
    return { describe: describeShort(el), value: type === "password" ? "•".repeat(value.length) : el.value };
  }

  function selectOption({ ref, selector, values }) {
    const el = target({ ref, selector });
    if (el.localName !== "select") throw new Error(describeShort(el) + " is not a <select>; click it and pick an option instead");
    const wanted = values.map(String);
    const matched = [];
    for (const option of el.options) {
      const hit = wanted.includes(option.value) || wanted.includes(clean(option.textContent)) || wanted.includes(option.label);
      if (el.multiple) option.selected = hit;
      else if (hit && !matched.length) option.selected = true;
      if (hit) matched.push(clean(option.textContent));
    }
    if (!matched.length) throw new Error(`No option matches ${wanted.join(", ")}. Options: ${[...el.options].map((o) => quote(clean(o.textContent))).join(", ")}`);
    fire(el, "input"); fire(el, "change");
    return { describe: describeShort(el), value: matched.join(", ") };
  }

  function focus(params) {
    const el = target(params);
    el.focus();
    return { describe: describeShort(el), focused: deepActiveElement() === el };
  }

  // Selects what the focused field holds, so the next key press replaces it.
  function selectContents() {
    const el = deepActiveElement();
    if (!el || el === document.body) return { selected: false };
    if (typeof el.select === "function" && isEditable(el)) { el.select(); return { selected: true }; }
    if (el.isContentEditable) {
      const range = document.createRange();
      range.selectNodeContents(el);
      const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
      return { selected: true };
    }
    return { selected: false };
  }

  function scroll({ ref, selector, direction, amount }) {
    const el = ref || selector ? target({ ref, selector }) : null;
    if (el && !direction) {
      el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
      return { describe: describeShort(el), scrollX, scrollY };
    }
    const scroller = el || document.scrollingElement || document.documentElement;
    const step = amount || Math.round((el ? el.clientHeight : innerHeight) * 0.8);
    const by = { up: [0, -step], down: [0, step], left: [-step, 0], right: [step, 0] }[direction];
    if (by) scroller.scrollBy({ left: by[0], top: by[1], behavior: "instant" });
    else if (direction === "top") scroller.scrollTo({ top: 0, behavior: "instant" });
    else if (direction === "bottom") scroller.scrollTo({ top: scroller.scrollHeight, behavior: "instant" });
    return { describe: el ? describeShort(el) : "page", scrollX: el ? el.scrollLeft : scrollX, scrollY: el ? el.scrollTop : scrollY,
             scrollHeight: scroller.scrollHeight, viewportHeight: innerHeight };
  }

  function setFiles({ ref, selector, files }) {
    const el = target({ ref, selector });
    if (el.localName !== "input" || el.type !== "file") throw new Error(describeShort(el) + " is not an <input type=file>");
    if (files.length > 1 && !el.multiple) throw new Error(describeShort(el) + " takes one file");
    const transfer = new DataTransfer();
    for (const f of files) {
      const bytes = Uint8Array.from(atob(f.base64), (c) => c.charCodeAt(0));
      transfer.items.add(new File([bytes], f.name, { type: f.type || "application/octet-stream", lastModified: f.lastModified || Date.now() }));
    }
    el.files = transfer.files;
    fire(el, "input"); fire(el, "change");
    return { describe: describeShort(el), files: [...el.files].map((f) => f.name + " (" + f.size + " bytes)") };
  }

  function contextMenu(params) {
    const el = target(params);
    const r = visibleRect(el) || el.getBoundingClientRect();
    const init = { bubbles: true, cancelable: true, composed: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: params.button === "middle" ? 1 : 2 };
    if (params.button === "middle") {
      for (const type of ["mousedown", "mouseup", "auxclick"]) el.dispatchEvent(new MouseEvent(type, init));
    } else {
      for (const type of ["mousedown", "mouseup", "contextmenu"]) el.dispatchEvent(new MouseEvent(type, init));
    }
    return { describe: describeShort(el) };
  }

  // ---- waiting --------------------------------------------------------------------------------------
  function visibleText() { return clean(document.body ? document.body.innerText : ""); }

  function anyVisible(selector) {
    try {
      return [...document.querySelectorAll(selector)].some((el) => !isHidden(el) && visibleRect(el));
    } catch (e) {
      throw new Error(`Invalid selector ${selector}: ${e.message}`);
    }
  }

  function check({ text, textGone, selector, selectorGone }) {
    if (text !== undefined) return visibleText().includes(clean(text));
    if (textGone !== undefined) return !visibleText().includes(clean(textGone));
    if (selector !== undefined) return anyVisible(selector);
    if (selectorGone !== undefined) return !anyVisible(selectorGone);
    return true;
  }

  // ---- content ---------------------------------------------------------------------------------------
  function markdown(root) {
    const out = [];
    const abs = (u) => { try { return new URL(u, document.baseURI).href; } catch (_) { return u; } };
    const inline = (node, skip) => {
      let s = "";
      for (const child of composedChildren(node)) {
        if (skip && skip.has(child)) continue;
        if (child.nodeType === 3) { s += child.nodeValue.replace(/\s+/g, " "); continue; }
        if (child.nodeType !== 1 || isHidden(child) || isOurs(child)) continue;
        const t = child.localName;
        if (t === "br") s += "  \n";
        else if (t === "a" && child.hasAttribute("href")) {
          const label = clean(inline(child)); const href = child.getAttribute("href");
          s += label ? (href.startsWith("javascript:") || href === "#" ? label : `[${label}](${abs(href)})`) : "";
        } else if (t === "img") { const alt = child.getAttribute("alt"); if (alt) s += `![${alt}](${abs(child.currentSrc || child.src)})`; }
        else if (t === "strong" || t === "b") { const v = clean(inline(child)); if (v) s += `**${v}**`; }
        else if (t === "em" || t === "i") { const v = clean(inline(child)); if (v) s += `*${v}*`; }
        else if (t === "code" || t === "kbd" || t === "samp") { const v = child.textContent; if (v.trim()) s += "`" + v.replace(/`/g, "\\`") + "`"; }
        else if (t === "del" || t === "s") { const v = clean(inline(child)); if (v) s += `~~${v}~~`; }
        else if (t === "input" && (child.type === "checkbox" || child.type === "radio")) s += child.checked ? "[x] " : "[ ] ";
        else if (t === "input" || t === "textarea" || t === "select") { const v = valueOf(child, roleOf(child)); const n = nameOf(child, roleOf(child)); s += ` [${n || (t === "select" ? "select" : child.type || t)}${v ? ": " + v : ""}] `; }
        else if (t === "button") { const v = clean(inline(child)); if (v) s += ` [${v}] `; }
        else if (isBlock(child)) s += " " + inline(child) + " ";
        else s += inline(child);
      }
      return s;
    };
    const para = (text, prefix = "") => { const t = clean(text); if (t) out.push(prefix + t, ""); };
    const list = (el, depth) => {
      let n = Number(el.getAttribute("start") || 1);
      for (const li of el.children) {
        if (li.localName !== "li" || isHidden(li)) continue;
        const marker = el.localName === "ol" ? `${n++}. ` : "- ";
        const nested = [...li.children].filter((c) => c.localName === "ul" || c.localName === "ol");
        out.push("  ".repeat(depth) + marker + clean(inline(li, new Set(nested))));
        for (const sub of nested) list(sub, depth + 1);
      }
      if (depth === 0) out.push("");
    };
    const table = (el) => {
      const rows = [...el.querySelectorAll("tr")].filter((r) => r.closest("table") === el).map((r) =>
        [...r.children].filter((c) => c.localName === "td" || c.localName === "th").map((c) => clean(inline(c)).replace(/\|/g, "\\|")));
      if (!rows.length) return;
      const width = Math.max(...rows.map((r) => r.length));
      const pad = (r) => r.concat(Array(width - r.length).fill(""));
      out.push("| " + pad(rows[0]).join(" | ") + " |", "|" + " --- |".repeat(width));
      for (const r of rows.slice(1)) out.push("| " + pad(r).join(" | ") + " |");
      out.push("");
    };
    const block = (el, depth) => {
      if (el.nodeType !== 1 || isHidden(el) || isOurs(el)) return;
      const t = el.localName;
      if (/^h[1-6]$/.test(t)) return para(inline(el), "#".repeat(Number(t[1])) + " ");
      if (t === "p" || t === "figcaption" || t === "summary" || t === "caption") return para(inline(el));
      if (t === "ul" || t === "ol") return list(el, 0);
      if (t === "table") return table(el);
      if (t === "pre") {
        const lang = (el.querySelector("code")?.className.match(/language-(\S+)/) || [])[1] || "";
        out.push("```" + lang, el.textContent.replace(/\n$/, ""), "```", ""); return;
      }
      if (t === "blockquote") { const before = out.length; children(el, depth); for (let i = before; i < out.length; i++) out[i] = out[i] ? "> " + out[i] : ">"; return; }
      if (t === "hr") { out.push("---", ""); return; }
      if (t === "img") { const alt = el.getAttribute("alt"); if (alt) out.push(`![${alt}](${abs(el.currentSrc || el.src)})`, ""); return; }
      if (t === "iframe") { const doc = frameDocument(el); if (doc?.body) block(doc.body, depth); return; }
      children(el, depth);
    };
    const children = (el, depth) => {
      let run = "";
      const flush = () => { if (clean(run)) para(run); run = ""; };
      for (const child of composedChildren(el)) {
        if (child.nodeType === 3) { run += child.nodeValue; continue; }
        if (child.nodeType !== 1 || isHidden(child) || isOurs(child)) continue;
        if (isBlock(child) || /^(pre|blockquote|hr|figure|figcaption|main|aside|details|summary|dl|iframe|img|caption)$/.test(child.localName) || child.shadowRoot) {
          flush(); block(child, depth + 1);
        } else {
          run += inline({ childNodes: [child], nodeType: 11 });
        }
      }
      flush();
    };
    block(root, 0);
    return out.join("\n").replace(/\n{3,}/g, "\n\n").trim();
  }

  function content({ ref, selector, format, maxLength }) {
    const root = ref || selector ? target({ ref, selector }) : document.body || document.documentElement;
    let text;
    if (format === "html") text = root.outerHTML;
    else if (format === "text") text = root.innerText;
    else text = markdown(root);
    const limit = maxLength || 100000;
    return { url: location.href, title: document.title, text: text.length > limit ? text.slice(0, limit) + "\n…(truncated)" : text, length: text.length };
  }

  // ---- inspecting ----------------------------------------------------------------------------------------
  const DEFAULT_PROPERTIES = ["display", "position", "top", "right", "bottom", "left", "z-index", "width", "height", "margin", "padding",
    "border", "box-sizing", "overflow", "flex-direction", "justify-content", "align-items", "gap", "grid-template-columns",
    "color", "background-color", "font-family", "font-size", "font-weight", "line-height", "text-align", "opacity", "visibility",
    "transform", "cursor", "pointer-events"];

  async function inspect({ ref, selector, properties, includeRules }) {
    const el = target({ ref, selector });
    const agent = window.__sbAgent;
    const nodeId = agent ? agent.nodeId(el) : null;
    const cs = getComputedStyle(el);
    const computed = {};
    for (const p of properties && properties.length ? properties : DEFAULT_PROPERTIES) computed[p] = cs.getPropertyValue(p);
    const attributes = {};
    for (const a of el.attributes) attributes[a.name] = clip(a.value, 300);
    const result = {
      describe: describeShort(el),
      selector: agent ? await agent.handle("DOM.uniqueSelector", { nodeId }) : null,
      tag: el.localName,
      attributes,
      boxModel: agent ? await agent.handle("DOM.getBoxModel", { nodeId }) : null,
      computed,
      accessibility: { role: roleOf(el), name: nameOf(el, roleOf(el)), states: attributesOf(el, roleOf(el), deepActiveElement()) },
      text: clip(clean(el.innerText || el.textContent || ""), 500),
      childElementCount: el.childElementCount,
    };
    if (includeRules !== false && agent) {
      try {
        const matched = await agent.handle("CSS.getMatchedStyles", { nodeId });
        const rules = (matched.rules || []).slice().sort((a, b) =>
          (b.specificity[0] - a.specificity[0]) || (b.specificity[1] - a.specificity[1]) || (b.specificity[2] - a.specificity[2]) || (b.order - a.order));
        result.inlineStyle = matched.inline?.cssText || "";
        result.matchedRules = rules.filter((r) => r.active !== false).slice(0, 40).map((r) => ({
          selector: r.selectorText + (r.pseudo ? " (" + r.pseudo + ")" : ""),
          source: r.origin,
          conditions: (r.conditions || []).map((c) => c.text || c.kind).join(" "),
          declarations: r.declarations.map((d) => d.name + ": " + d.value + (d.important ? " !important" : "")),
        }));
        if (matched.inaccessibleStyleSheets?.length) result.crossOriginStyleSheets = matched.inaccessibleStyleSheets.length;
      } catch (e) {
        result.matchedRulesError = String(e.message || e);
      }
    }
    return result;
  }

  function rect(params) {
    const el = target(params);
    el.scrollIntoView({ block: "nearest", inline: "nearest", behavior: "instant" });
    const r = el.getBoundingClientRect();
    return { x: r.left, y: r.top, width: r.width, height: r.height, scrollX, scrollY, viewportWidth: innerWidth, viewportHeight: innerHeight,
             describe: describeShort(el) };
  }

  function pageSize() {
    const s = document.scrollingElement || document.documentElement;
    return { width: Math.max(s.scrollWidth, innerWidth), height: Math.max(s.scrollHeight, innerHeight), viewportWidth: innerWidth,
             viewportHeight: innerHeight, scrollX, scrollY, devicePixelRatio };
  }

  // Lets page-world code find the element: a one-off attribute it removes.
  function mark({ ref, selector, token }) {
    const el = target({ ref, selector });
    el.setAttribute("data-sb-agent-target", token);
    return { describe: describeShort(el) };
  }

  function nodeId(params) {
    const el = target(params);
    return { nodeId: window.__sbAgent ? window.__sbAgent.nodeId(el) : null, describe: describeShort(el) };
  }

  function metrics() {
    const nav = performance.getEntriesByType("navigation")[0];
    const paints = Object.fromEntries(performance.getEntriesByType("paint").map((p) => [p.name, Math.round(p.startTime)]));
    const resources = performance.getEntriesByType("resource");
    const byType = {};
    let transfer = 0, decoded = 0, renderBlocking = [];
    for (const r of resources) {
      const t = r.initiatorType || "other";
      byType[t] = byType[t] || { count: 0, transferBytes: 0 };
      byType[t].count++; byType[t].transferBytes += r.transferSize || 0;
      transfer += r.transferSize || 0; decoded += r.decodedBodySize || 0;
      if (r.renderBlockingStatus === "blocking") renderBlocking.push(r.name);
    }
    const slowest = resources.slice().sort((a, b) => b.duration - a.duration).slice(0, 8)
      .map((r) => ({ url: r.name, type: r.initiatorType, ms: Math.round(r.duration), bytes: r.transferSize || 0 }));
    return {
      url: location.href,
      navigation: nav ? {
        type: nav.type, ttfb: Math.round(nav.responseStart), domInteractive: Math.round(nav.domInteractive),
        domContentLoaded: Math.round(nav.domContentLoadedEventEnd), load: Math.round(nav.loadEventEnd),
        transferBytes: nav.transferSize, protocol: nav.nextHopProtocol, redirects: nav.redirectCount,
      } : null,
      paint: paints,
      resources: { count: resources.length, transferBytes: transfer, decodedBytes: decoded, byType, slowest, renderBlocking: renderBlocking.slice(0, 10) },
      dom: { elements: document.getElementsByTagName("*").length, maxDepth: depthOf(document.documentElement) },
      memory: performance.memory ? { usedJSHeapSize: performance.memory.usedJSHeapSize, totalJSHeapSize: performance.memory.totalJSHeapSize } : null,
    };
  }

  function depthOf(el) {
    let max = 0;
    const stack = [[el, 1]];
    let guard = 0;
    while (stack.length && guard++ < 100000) {
      const [n, d] = stack.pop();
      if (d > max) max = d;
      for (const c of n.children) stack.push([c, d + 1]);
    }
    return max;
  }


  // ---- trust: what an action is about to touch -------------------------------------------------------
  // The facts the browser's approval rules need: what the element is, and
  // for a button, the form it would submit. Without a target: the focused element.
  function facts(params) {
    let el = null;
    if (params.ref || params.selector || params.text) el = target(params);
    else el = deepActiveElement();
    if (!el || el === document.body || el === document.documentElement) return { role: "document", name: "", formFields: [] };
    const role = roleOf(el) || el.localName;
    const form = el.form || el.closest?.("form") || null;
    const fields = form ? [...form.querySelectorAll("input, select, textarea")].map((f) => {
      const auto = (f.getAttribute("autocomplete") || "").toLowerCase().trim();
      return auto || (f.type === "password" ? "password" : "");
    }).filter(Boolean) : [];
    return {
      role, name: clip(nameOf(el, role) || clean(el.innerText || el.value || ""), 200),
      type: (el.getAttribute("type") || (el.localName === "button" ? "submit" : "")).toLowerCase() || null,
      autocomplete: (el.getAttribute("autocomplete") || "").toLowerCase() || null,
      formMethod: form ? (form.getAttribute("method") || "get").toLowerCase() : null,
      formAction: form ? (form.action || null) : null,
      formFields: fields, ref: refFor(el),
    };
  }

  // The amber ring and "e14 · Claude" tag on the element an agent is about
  // to act on, so the person sees it before and while it happens.
  let spot = null;
  function spotlight({ ref, selector, text, role, label, waiting }) {
    clearSpotlight();
    const el = target({ ref, selector, text, role });
    const host = document.createElement("div");
    host.setAttribute("data-keel-spotlight", "");
    host.style.cssText = "position:fixed;left:0;top:0;width:0;height:0;z-index:2147483647;pointer-events:none;";
    const root = host.attachShadow({ mode: "closed" });
    root.innerHTML = `<style>
      .ring{position:fixed;border-radius:6px;box-shadow:0 0 0 2px #fff,0 0 0 4px #F2A93B;transition:none}
      .tag{position:fixed;background:#F2A93B;color:#2A1B00;border-radius:6px;padding:2px 8px;font:700 11px -apple-system,BlinkMacSystemFont,sans-serif;white-space:nowrap}
      .waiting .ring{box-shadow:0 0 0 2px #fff,0 0 0 4px #F2A93B,0 0 0 9px rgba(242,169,59,.28)}
    </style><div class="${waiting ? "waiting" : ""}"><div class="ring"></div><div class="tag"></div></div>`;
    root.querySelector(".tag").textContent = label || refFor(el);
    (document.documentElement || document.body).appendChild(host);
    const ring = root.querySelector(".ring"), tag = root.querySelector(".tag");
    const place = () => {
      if (!spot || !el.isConnected) return clearSpotlight();
      const r = el.getBoundingClientRect();
      ring.style.left = r.left + "px"; ring.style.top = r.top + "px"; ring.style.width = r.width + "px"; ring.style.height = r.height + "px";
      const w = tag.offsetWidth || 80;
      tag.style.left = Math.max(4, Math.min(innerWidth - w - 4, r.right - w + 6)) + "px";
      tag.style.top = Math.max(4, r.top - 24) + "px";
      spot.frame = requestAnimationFrame(place);
    };
    spot = { host, frame: 0 };
    place();
    return { describe: describeShort(el), ref: refFor(el) };
  }

  function clearSpotlight() {
    if (spot) { cancelAnimationFrame(spot.frame); spot.host.remove(); spot = null; }
    return { cleared: true };
  }

  // Page text for the injection scanner: what a person cannot see counts
  // too, since an agent reading the DOM sees it.
  function hiddenText() {
    const out = [];
    const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
    let n, total = 0;
    while ((n = walker.nextNode()) && total < 200000) {
      const t = n.nodeValue.trim();
      if (t.length < 12) continue;
      const el = n.parentElement;
      if (!el || isOurs(el)) continue;
      const cs = getComputedStyle(el);
      const tiny = parseFloat(cs.fontSize) < 2;
      const invisible = cs.visibility === "hidden" || cs.display === "none" || parseFloat(cs.opacity) === 0 || tiny || cs.color === cs.backgroundColor;
      out.push({ text: clip(t, 600), hidden: invisible, where: el.localName + (el.className && typeof el.className === "string" ? "." + el.className.trim().split(/\s+/).slice(0, 2).join(".") : ""), ref: refFor(el) });
      total += t.length;
    }
    return { nodes: out };
  }

  const methods = { facts, spotlight, clearSpotlight, hiddenText, snapshot, prepare, fill, selectOption, focus, selectContents, scroll, setFiles, contextMenu, check, content, inspect, rect,
                    pageSize, mark, nodeId, metrics, describe: (p) => ({ describe: describeShort(target(p)) }) };

  async function handle(method, params) {
    const fn = methods[method];
    if (!fn) throw new Error("Unknown automation method " + method);
    // Failures come back as values: a throw would also be reported to the
    // page's error handlers, and show in its console as "Script error."
    try {
      const result = await fn(params || {});
      return result === undefined ? null : JSON.parse(JSON.stringify(result));
    } catch (e) {
      return { __automationError: String(e && e.message || e) };
    }
  }

  Object.defineProperty(window, "__sbAutomation", { value: { handle, target }, enumerable: false, configurable: false, writable: false });
})();
