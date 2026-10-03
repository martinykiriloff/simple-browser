// Keel DevTools — what the built-in developer extensions share:
// which are on (Develop → Developer Extensions), their tabs, the screen
// colour picker in the toolbar, and turning hook previews into JSON trees.
"use strict";

(function () {
  const SBExt = window.SBExt = {
    states: { claude: true, dataLayer: true, react: true, php: true, node: true, colorPicker: true, jsonViewer: true },
    loaded: false,

    async load() {
      try { this.states = Object.assign(this.states, await DevTools.rpc("Ext.state")); } catch (_) {}
      this.loaded = true;
      for (const [ext, panel] of [["claude", "claude"], ["php", "php"], ["node", "node"]]) this.showTab(panel, this.enabled(ext));
      const picker = document.getElementById("btn-colorpick");
      if (picker) picker.hidden = !this.enabled("colorPicker");
      return this.states;
    },

    enabled(name) { return this.states[name] !== false; },

    showTab(panel, shown) {
      const tab = document.querySelector(`#tabs .tab[data-panel="${panel}"]`);
      if (tab) tab.hidden = !shown;
    },

    /// Hook previews tag what JSON cannot carry ({$t: "function", v: "onClick()"}); the trees show them as text.
    display(v) {
      if (v === null || typeof v !== "object") return v;
      if (Array.isArray(v)) return v.map((x) => this.display(x));
      if (v.$t) {
        switch (v.$t) {
          case "undefined": return "undefined";
          case "function": return "ƒ " + v.v;
          case "map": { const out = {}; for (const [k, x] of v.v) out[typeof k === "object" ? JSON.stringify(k) : String(k)] = this.display(x); return out; }
          case "set": return v.v.map((x) => this.display(x));
          case "promise": return "Promise {…}";
          case "circular": return "[Circular]";
          default: return v.v != null ? String(v.v) : "[" + v.$t + "]";
        }
      }
      const out = {};
      for (const k of Object.keys(v)) out[k] = this.display(v[k]);
      return out;
    },

    tree(value, depth = 1) {
      const shown = this.display(value);
      if (shown === null || typeof shown !== "object") return h("div", { class: "ext-scalar mono selectable" }, JSON.stringify(shown) ?? "undefined");
      return new SBNetPreview.JSONView(shown, { expandDepth: depth, toolbar: false }).el;
    },

    empty(title, ...lines) {
      return h("div", { class: "empty-state ext-empty" }, h("div", { class: "ext-empty-title" }, title), ...lines.map((l) => h("div", {}, l)));
    },

    copy(text, what = "Copied") {
      return DevTools.rpc("Clipboard.write", { text }).then(() => Toast.show(what)).catch(() => {});
    },

    escape(text) {
      return String(text).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
    },

    /// The toolbar's colour picker: any pixel on screen, copied as hex; the other formats one click away.
    async pickColor() {
      try {
        const picked = await DevTools.rpc("ColorPicker.sample");
        if (!picked) return null;
        await DevTools.rpc("Clipboard.write", { text: picked.hex });
        this.showColor(picked);
        return picked;
      } catch (e) { Toast.show(e.message); return null; }
    },

    showColor(picked) {
      let card = document.getElementById("ext-color-card");
      if (card) card.remove();
      card = h("div", { id: "ext-color-card", class: "popup-panel ext-color-card" },
        h("div", { class: "ext-color-swatch", style: `background:${picked.hex}` }),
        h("div", { class: "ext-color-values" }, ...["hex", "rgb", "hsl", "swift"].map((k) => {
          const row = h("button", { class: "ext-color-value mono", title: "Copy" }, picked[k]);
          row.addEventListener("click", () => this.copy(picked[k], "Copied " + picked[k]));
          return row;
        })));
      document.body.appendChild(card);
      const close = (e) => { if (!card.contains(e.target)) { card.remove(); document.removeEventListener("mousedown", close, true); } };
      setTimeout(() => document.addEventListener("mousedown", close, true), 0);
      Toast.show("Copied " + picked.hex);
    },
  };

  document.addEventListener("DOMContentLoaded", () => {
    const picker = document.getElementById("btn-colorpick");
    if (picker) picker.addEventListener("click", () => SBExt.pickColor());
  });
})();

// Tabs for React and the dataLayer appear once the page is seen to use them.
(function () {
  let timer = null;
  const detect = async () => {
    const react = window.SBReact ? await SBReact.detect() : true;
    const layer = window.SBDataLayer ? await SBDataLayer.detect() : true;
    if (react && layer && timer) { clearInterval(timer); timer = null; }
  };
  const watch = () => { if (timer) clearInterval(timer); detect(); timer = setInterval(detect, 4000); };
  window.addEventListener("load", () => setTimeout(async () => { await SBExt.load(); watch(); }, 400));
  DevTools.on("Page.navigated", () => setTimeout(watch, 800));
  DevTools.on("Ext.changed", () => SBExt.load().then(watch));
})();
