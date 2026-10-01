// SimpleBrowser DevTools — the Rendering drawer (paint flashing, layer
// borders, FPS meter, CSS media emulation, disable JavaScript) and
// screenshots. The emulation is held natively and undone while DevTools is
// hidden, as in Chrome.
"use strict";

(function () {
  const CHECKS = [
    ["paintFlashing", "Paint flashing", "Highlights areas of the page that need to be repainted."],
    ["layerBorders", "Layer borders", "Shows composited layer borders and tiles."],
    ["repaintCounter", "Layer repaint counters", "Shows how many times each composited layer was repainted."],
    ["rulers", "Rulers", "Shows rulers along the top and left edges of the page."],
    ["fpsMeter", "Frame rendering stats", "Plots frames per second and dropped frames in a corner of the page."],
    ["disableJavaScript", "Disable JavaScript", "The page's scripts stop running; reload to apply to the whole page. DevTools keeps working."],
    ["disableImages", "Disable images", "Images that load after this are not shown; reload to apply to the whole page."],
  ];
  const SELECTS = [
    ["media", "Emulate CSS media type", "Forces the media type for media queries.", [["", "No emulation"], ["print", "print"], ["screen", "screen"]]],
    ["colorScheme", "Emulate CSS media feature prefers-color-scheme", "", [["", "No emulation"], ["light", "prefers-color-scheme: light"], ["dark", "prefers-color-scheme: dark"]]],
    ["reducedMotion", "Emulate CSS media feature prefers-reduced-motion", "", [["", "No emulation"], ["reduce", "prefers-reduced-motion: reduce"], ["no-preference", "prefers-reduced-motion: no-preference"]]],
    ["contrast", "Emulate CSS media feature prefers-contrast", "", [["", "No emulation"], ["more", "prefers-contrast: more"], ["no-preference", "prefers-contrast: no-preference"]]],
  ];

  const SBRendering = window.SBRendering = {
    state: {},
    error: null,

    async set(feature, value) {
      try {
        await DevTools.rpc("Emulation.setRendering", { feature, value });
        if (value === false || value === "" || value == null) delete this.state[feature]; else this.state[feature] = value;
        this.error = null;
      } catch (e) {
        this.error = e.message;
      }
      this.render();
      if (this.error) throw new Error(this.error);
    },

    toggle(feature) { return this.set(feature, !this.state[feature]); },

    render() {
      const body = $("#rendering-body");
      if (!body) return;
      body.textContent = "";
      if (this.error) body.appendChild(h("div", { class: "detail-note v-error" }, this.error));
      for (const [key, title, description] of CHECKS) {
        const box = h("input", { type: "checkbox", "data-feature": key });
        box.checked = !!this.state[key];
        box.addEventListener("change", () => this.set(key, box.checked).catch(() => {}));
        body.appendChild(h("label", { class: "rendering-option" }, box, h("div", {}, h("div", { class: "title" }, title), h("div", { class: "description" }, description))));
      }
      for (const [key, title, description, options] of SELECTS) {
        const select = h("select", { "data-feature": key }, options.map(([value, label]) => h("option", { value }, label)));
        select.value = this.state[key] || "";
        select.addEventListener("change", () => this.set(key, select.value).catch(() => {}));
        body.appendChild(h("div", { class: "rendering-option select" }, h("div", {}, h("div", { class: "title" }, title), description ? h("div", { class: "description" }, description) : null, select)));
      }
    },
  };

  // A new document has no FPS overlay; put it back.
  DevTools.on("DOM.documentUpdated", () => { if (SBRendering.state.fpsMeter) SBRendering.set("fpsMeter", true).catch(() => {}); });

  Drawer.register("rendering", { title: "Rendering", show: () => SBRendering.render() });

  // ---- screenshots -----------------------------------------------------------------------------
  const SBScreenshots = window.SBScreenshots = {
    // `mode`: viewport, full or node. Saved to Downloads, as Chrome does.
    async capture(mode, nodeId, destination = "downloads") {
      const params = { mode, destination };
      if (mode === "node") {
        params.nodeId = nodeId ?? DevTools.panels.elements?.selectedId;
        if (params.nodeId == null) { Toast.show("Select a node in the Elements panel first"); return null; }
      }
      try {
        const result = await DevTools.rpc("Page.captureScreenshot", params);
        if (result.path) Toast.show(`Screenshot saved to ${result.path.replace(/^.*\/Downloads\//, "Downloads/")} (${result.width} × ${result.height})`);
        else if (result.copied) Toast.show("Screenshot copied to the clipboard");
        return result;
      } catch (e) {
        Toast.show("Screenshot failed: " + e.message);
        throw e;
      }
    },
  };

  // Brief messages at the bottom of the window, for actions with no panel of their own.
  const Toast = window.Toast = {
    timer: null,
    show(text) {
      let el = $("#toast");
      if (!el) { el = h("div", { id: "toast" }); document.body.appendChild(el); }
      el.textContent = text;
      el.classList.add("visible");
      clearTimeout(this.timer);
      this.timer = setTimeout(() => el.classList.remove("visible"), 3500);
    },
  };
})();
