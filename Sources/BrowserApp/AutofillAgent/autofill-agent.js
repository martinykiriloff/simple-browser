// Keel AutoFill agent: addresses, cards and one-time codes.
// Runs in its own content world, so the page can neither see nor call it.
// It describes the form around the field in focus; the app decides what
// the fields are for and what to offer, and hands back the values to fill.
(() => {
  "use strict";
  if (window.__simpleBrowserAutofill) return;
  const post = (body) => {
    try { window.webkit.messageHandlers.simpleBrowserAutofill.postMessage(body); } catch (e) {}
  };
  const SKIP = new Set(["hidden", "password", "submit", "button", "checkbox", "radio", "file", "image", "reset", "range", "color"]);

  function isField(el) {
    if (!el || !el.tagName) return false;
    const tag = el.tagName.toLowerCase();
    if (tag === "select" || tag === "textarea") return true;
    return tag === "input" && !SKIP.has((el.type || "text").toLowerCase());
  }

  // Is this field one the person can actually see and type into?
  //
  // The test is deliberately mean, because the alternative is a trap: a page
  // shows one innocuous "Email" box, keeps a block of address and card fields
  // beside it moved off to the left, faded to nothing or laid under something
  // else, and reads back whatever we filled in. A field this cannot prove
  // visible is treated as hidden, and hidden fields are never filled.
  function visible(el) {
    if (!el || !el.isConnected) return false;
    // WebKit's own answer first: it knows about display, visibility,
    // content-visibility and opacity, this element's and its ancestors'.
    if (typeof el.checkVisibility === "function"
        && !el.checkVisibility({ contentVisibilityAuto: true, opacityProperty: true, visibilityProperty: true })) return false;
    const own = getComputedStyle(el);
    if (own.display === "none" || own.visibility !== "visible") return false;
    const r = el.getBoundingClientRect();
    // A real field is not three pixels across. This also catches everything
    // inside a `display: none` subtree, and anything scaled to nothing.
    if (r.width < 6 || r.height < 6) return false;

    // Faded out, or clipped out: opacity multiplies down the tree, and the
    // old way of hiding something that must stay focusable is to clip it to
    // an empty rectangle -- so every ancestor has a say.
    for (let node = el; node && node.nodeType === 1; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (parseFloat(style.opacity) < 0.1) return false;
      if (style.contentVisibility === "hidden") return false;
      if (style.clip && style.clip !== "auto") {
        const sides = (style.clip.match(/-?[\d.]+/g) || []).map(Number);   // rect(top, right, bottom, left)
        if (sides.length === 4 && (sides[2] - sides[0] < 1 || sides[1] - sides[3] < 1)) return false;
      }
      const path = style.clipPath || "";
      if (/inset\(\s*(100%|9\d(\.\d+)?%)/.test(path) || /circle\(\s*0/.test(path)) return false;
    }

    // Pushed outside the page: `left: -10000px`, or a long way past its end.
    // Measured against the document, not the viewport, so a field below the
    // fold -- which the person need only scroll to -- still counts.
    const docX = r.left + window.scrollX, docY = r.top + window.scrollY;
    const width = Math.max(document.documentElement.scrollWidth, window.innerWidth);
    const height = Math.max(document.documentElement.scrollHeight, window.innerHeight);
    if (docX + r.width <= 1 || docY + r.height <= 1 || docX >= width || docY >= height) return false;

    // Inside a box that shows none of it: `height: 0; overflow: hidden` keeps
    // a field in the document and out of sight. A box that can be scrolled to
    // reveal it is left alone -- that is an ordinary long form in a panel.
    for (let node = el.parentElement; node && node !== document.body && node !== document.documentElement; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (style.overflow === "visible" && style.overflowX === "visible" && style.overflowY === "visible") continue;
      const box = node.getBoundingClientRect();
      if (box.width < 2 || box.height < 2) return false;
      const outside = r.right <= box.left || r.left >= box.right || r.bottom <= box.top || r.top >= box.bottom;
      const scrollable = node.scrollHeight > node.clientHeight + 1 || node.scrollWidth > node.clientWidth + 1;
      if (outside && !scrollable) return false;
    }

    // Finally, what is at the middle of it? Something else there -- a sheet
    // over the form, a label covering the box -- means that whatever this
    // field is, it is not the one the person is typing into. Only asked
    // inside the viewport: `elementFromPoint` knows nothing of the rest.
    const x = r.left + r.width / 2, y = r.top + r.height / 2;
    if (x >= 0 && y >= 0 && x <= window.innerWidth && y <= window.innerHeight) {
      let hit = document.elementFromPoint(x, y);
      // A custom element answers for the field in its shadow root.
      while (hit && hit.shadowRoot && hit.shadowRoot.elementFromPoint) {
        const inner = hit.shadowRoot.elementFromPoint(x, y);
        if (!inner || inner === hit) break;
        hit = inner;
      }
      if (!hit) return false;
      if (hit !== el && !el.contains(hit) && !hit.contains(el)) return false;
    }
    return true;
  }

  function labelOf(el) {
    if (el.labels && el.labels.length) return el.labels[0].textContent.trim();
    const aria = el.getAttribute("aria-label");
    if (aria) return aria;
    const by = el.getAttribute("aria-labelledby");
    if (by) { const other = document.getElementById(by); if (other) return other.textContent.trim(); }
    const previous = el.previousElementSibling;
    if (previous && previous.textContent && previous.textContent.length < 60) return previous.textContent.trim();
    return "";
  }

  const GROUPS = "form, fieldset, section, dialog, [role=form], [role=group]";

  // What counts as "this field's form" when the page has no `<form>`, as
  // one-page checkouts often do not: the nearest element above the field that
  // groups it with other fields the person can see. Never the whole document
  // -- a page with one visible box and a block of card fields hidden
  // somewhere else in it would otherwise have us fill the lot.
  function groupAround(el) {
    if (el.form) return el.form;
    let fallback = null;
    for (let node = el.parentElement; node && node !== document.body && node !== document.documentElement; node = node.parentElement) {
      const fields = Array.from(node.querySelectorAll("input, select, textarea")).filter((f) => isField(f) && (f === el || visible(f)));
      if (fields.length < 2) continue;
      if (node.matches(GROUPS)) return node;
      if (!fallback) fallback = node;
    }
    // Nothing above it groups it with anything: this field on its own, then.
    return fallback || el;
  }

  // The fields of the form around `el`, hidden ones left out.
  function fieldsAround(el) {
    const scope = groupAround(el);
    const fields = Array.from(scope.querySelectorAll("input, select, textarea")).filter((f) => isField(f) && (f === el || visible(f)));
    return fields.includes(el) ? fields : [el].concat(fields);
  }

  function describe(f) {
    return {
      tag: f.tagName.toLowerCase(), type: (f.type || "text").toLowerCase(), autocomplete: f.getAttribute("autocomplete") || "",
      name: f.name || "", id: f.id || "", placeholder: f.placeholder || "", label: labelOf(f), value: f.value || "",
    };
  }

  function rectOf(el) {
    const r = el.getBoundingClientRect();
    return { x: r.left, y: r.top, width: r.width, height: r.height };
  }

  let current = [];

  document.addEventListener("focusin", (event) => {
    const el = event.target;
    if (!isField(el)) return;
    // A field the person cannot see can still be focused -- by the page's own
    // script, which is how a trap would open the list over nothing. Nothing
    // is offered for it, and the list that was up goes away.
    if (!visible(el)) { current = []; post({ kind: "dismiss" }); return; }
    current = fieldsAround(el);
    post({ kind: "focus", fields: current.map(describe), focused: current.indexOf(el), rect: rectOf(el), empty: !el.value });
  }, true);
  document.addEventListener("focusout", (event) => { if (isField(event.target)) post({ kind: "blur" }); }, true);
  document.addEventListener("input", (event) => {
    if (isField(event.target) && event.isTrusted) post({ kind: "input" });
  }, true);

  // What was sent, so the app can offer to save an address or a card. Only
  // what the person could see: a hidden field the page filled in itself is
  // not something they typed, and not something to offer to keep.
  function reportSubmit(form) {
    const fields = Array.from(form.querySelectorAll("input, select, textarea")).filter((f) => isField(f) && visible(f));
    if (fields.length) post({ kind: "submit", fields: fields.map(describe) });
  }
  document.addEventListener("submit", (event) => reportSubmit(event.target), true);
  document.addEventListener("click", (event) => {
    const button = event.target.closest && event.target.closest("button, input[type=submit]");
    if (button && button.form && (button.type === "submit" || button.tagName === "BUTTON")) reportSubmit(button.form);
  }, true);

  // Setting the value the way typing does, so the page's own code (React's
  // included) sees it: the prototype's setter, then input and change.
  function setValue(el, value) {
    const proto = el.tagName === "SELECT" ? HTMLSelectElement.prototype : el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, "value").set;
    setter.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }

  const regionNames = (() => { try { return new Intl.DisplayNames(["en", document.documentElement.lang || "en"], { type: "region" }); } catch (e) { return null; } })();
  const norm = (s) => String(s).toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^a-z0-9]/g, "");

  // A select's option for a value: by value, by text, by a country's name
  // for its code, by a month's or a year's number however it is written.
  function optionFor(select, value) {
    const wanted = new Set([norm(value)]);
    if (/^[A-Za-z]{2}$/.test(value) && regionNames) { try { wanted.add(norm(regionNames.of(value.toUpperCase()))); } catch (e) {} }
    if (/^\d+$/.test(value)) {
      const n = parseInt(value, 10);
      wanted.add(String(n));
      if (value.length === 4) wanted.add(value.slice(2));
      if (n >= 1 && n <= 12) {
        try { wanted.add(norm(new Date(2000, n - 1, 1).toLocaleString("en", { month: "long" }))); } catch (e) {}
      }
    }
    const options = Array.from(select.options);
    return options.find((o) => wanted.has(norm(o.value)) || wanted.has(norm(o.text)))
      || options.find((o) => { const t = norm(o.text); return t && Array.from(wanted).some((w) => w.length > 2 && t.startsWith(w)); });
  }

  window.__simpleBrowserAutofill = {
    // `origin` is the origin the app meant to fill. Confirming a card can
    // take a while, and this document may have been replaced in the meantime
    // -- by the page itself, or by a frame navigating somewhere else -- so
    // the address and the card go nowhere unless this is still that page.
    // `location` is read in the agent's world, where page script cannot have
    // redefined it. This is the same rule the password agent keeps.
    fill(request) {
      if (!request || typeof request.origin !== "string" || location.origin !== request.origin) return { filled: 0, refused: 0, reason: "wrong document" };
      let filled = 0, refused = 0;
      for (const [index, value] of Object.entries(request.values || {})) {
        const el = current[Number(index)];
        if (!el) continue;
        // Asked again here, not only when the form was described: a page can
        // hide a field, or lay something over it, the moment the list opens.
        if (!visible(el)) { refused += 1; continue; }
        if (el.tagName === "SELECT") {
          const option = optionFor(el, value);
          if (!option) continue;
          setValue(el, option.value);
        } else {
          setValue(el, value);
        }
        filled += 1;
      }
      return { filled, refused };
    },
  };
})();
