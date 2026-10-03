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

  function visible(el) {
    const style = getComputedStyle(el);
    if (style.display === "none" || style.visibility === "hidden") return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
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

  // The fields of the form around `el`, or of the page when it has none.
  function fieldsAround(el) {
    const scope = el.form || document;
    return Array.from(scope.querySelectorAll("input, select, textarea")).filter((f) => isField(f) && (f === el || visible(f)));
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
    current = fieldsAround(el);
    post({ kind: "focus", fields: current.map(describe), focused: current.indexOf(el), rect: rectOf(el), empty: !el.value });
  }, true);
  document.addEventListener("focusout", (event) => { if (isField(event.target)) post({ kind: "blur" }); }, true);
  document.addEventListener("input", (event) => {
    if (isField(event.target) && event.isTrusted) post({ kind: "input" });
  }, true);

  // What was sent, so the app can offer to save an address or a card.
  function reportSubmit(form) {
    const fields = Array.from(form.querySelectorAll("input, select, textarea")).filter(isField);
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
    fill(values) {
      let filled = 0;
      for (const [index, value] of Object.entries(values)) {
        const el = current[Number(index)];
        if (!el) continue;
        if (el.tagName === "SELECT") {
          const option = optionFor(el, value);
          if (!option) continue;
          setValue(el, option.value);
        } else {
          setValue(el, value);
        }
        filled += 1;
      }
      return filled;
    },
    fillFocused(value) {
      const el = document.activeElement;
      if (!isField(el)) return false;
      setValue(el, value);
      return true;
    },
  };
})();
