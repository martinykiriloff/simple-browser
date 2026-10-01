// SimpleBrowser DevTools — the Styles pane's colour picker, as in Chrome:
// a saturation/brightness square, hue and opacity sliders, the value as
// hex, rgb or hsl (click the format to switch), and the eyedropper where
// the web view offers `EyeDropper`. Changes apply live; Escape restores
// the original colour.
"use strict";

const ColorPicker = window.ColorPicker = {
  el: null,
  state: null,

  // Any CSS colour → {r, g, b, a} (0–255, alpha 0–1), via the canvas's parser.
  parse(text) {
    const ctx = this.ctx || (this.ctx = document.createElement("canvas").getContext("2d"));
    ctx.fillStyle = "#010203";
    ctx.fillStyle = String(text);
    const v = ctx.fillStyle;
    if (v === "#010203" && !/^#010203$/i.test(String(text).trim())) {
      if (String(text).trim().toLowerCase() === "transparent") return { r: 0, g: 0, b: 0, a: 0 };
      return null;
    }
    if (v[0] === "#") return { r: parseInt(v.slice(1, 3), 16), g: parseInt(v.slice(3, 5), 16), b: parseInt(v.slice(5, 7), 16), a: 1 };
    const m = v.match(/rgba?\(([^)]+)\)/);
    if (!m) return null;
    const p = m[1].split(/[\s,/]+/).filter(Boolean).map(Number);
    return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
  },

  formatOf(text) {
    const t = String(text).trim().toLowerCase();
    if (t.startsWith("rgb")) return "rgb";
    if (t.startsWith("hsl")) return "hsl";
    return "hex";
  },

  rgbToHsv({ r, g, b }) {
    r /= 255; g /= 255; b /= 255;
    const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
    let hue = 0;
    if (d) {
      if (max === r) hue = ((g - b) / d) % 6;
      else if (max === g) hue = (b - r) / d + 2;
      else hue = (r - g) / d + 4;
      hue *= 60; if (hue < 0) hue += 360;
    }
    return { h: hue, s: max ? d / max : 0, v: max };
  },

  hsvToRgb(hue, s, v) {
    const c = v * s, x = c * (1 - Math.abs(((hue / 60) % 2) - 1)), m = v - c;
    const [r, g, b] = hue < 60 ? [c, x, 0] : hue < 120 ? [x, c, 0] : hue < 180 ? [0, c, x] : hue < 240 ? [0, x, c] : hue < 300 ? [x, 0, c] : [c, 0, x];
    return { r: Math.round((r + m) * 255), g: Math.round((g + m) * 255), b: Math.round((b + m) * 255) };
  },

  rgbToHsl({ r, g, b }) {
    r /= 255; g /= 255; b /= 255;
    const max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2, d = max - min;
    let hue = 0, s = 0;
    if (d) {
      s = d / (1 - Math.abs(2 * l - 1));
      if (max === r) hue = ((g - b) / d) % 6; else if (max === g) hue = (b - r) / d + 2; else hue = (r - g) / d + 4;
      hue *= 60; if (hue < 0) hue += 360;
    }
    return { h: Math.round(hue), s: Math.round(s * 100), l: Math.round(l * 100) };
  },

  format(c, kind) {
    const a = Math.round(c.a * 100) / 100;
    if (kind === "rgb") return a < 1 ? `rgba(${c.r}, ${c.g}, ${c.b}, ${a})` : `rgb(${c.r}, ${c.g}, ${c.b})`;
    if (kind === "hsl") { const l = this.rgbToHsl(c); return a < 1 ? `hsla(${l.h}, ${l.s}%, ${l.l}%, ${a})` : `hsl(${l.h}, ${l.s}%, ${l.l}%)`; }
    const hex = (n) => n.toString(16).padStart(2, "0");
    return "#" + hex(c.r) + hex(c.g) + hex(c.b) + (a < 1 ? hex(Math.round(a * 255)) : "");
  },

  // Opens beside `anchor`. `onChange(text, done)`: live while dragging, and
  // once more with done=true when the picker closes (done=false and the
  // original text after Escape).
  open(anchor, text, onChange) {
    this.close(true);
    const color = this.parse(text) || { r: 0, g: 0, b: 0, a: 1 };
    const hsv = this.rgbToHsv(color);
    this.state = { original: text, kind: this.formatOf(text), h: hsv.h, s: hsv.s, v: hsv.v, a: color.a, onChange, changed: false };

    const area = h("div", { class: "cp-area", tabindex: "0", role: "slider", "aria-label": "Saturation and brightness" }, h("div", { class: "cp-handle" }));
    const hue = h("input", { type: "range", class: "cp-hue", min: "0", max: "360", step: "1", "aria-label": "Hue" });
    const alpha = h("input", { type: "range", class: "cp-alpha", min: "0", max: "100", step: "1", "aria-label": "Opacity" });
    const swatch = h("div", { class: "cp-swatch" }, h("div", { class: "cp-swatch-color" }));
    const value = h("input", { type: "text", class: "cp-value", spellcheck: "false", "aria-label": "Colour value" });
    const kind = h("button", { class: "text-button cp-kind", title: "Switch between hex, rgb and hsl" });
    const dropper = window.EyeDropper ? h("button", { class: "icon-button cp-dropper", title: "Pick a colour from the screen" }, "⌖") : null;
    this.el = h("div", { class: "color-picker popup-panel", role: "dialog", "aria-label": "Colour picker" },
      area, h("div", { class: "cp-row" }, dropper, swatch, h("div", { class: "cp-sliders" }, hue, alpha)),
      h("div", { class: "cp-row" }, value, kind));
    document.body.appendChild(this.el);
    this.parts = { area, hue, alpha, value, kind, swatch };

    const r = anchor.getBoundingClientRect();
    const w = this.el.offsetWidth, ht = this.el.offsetHeight;
    this.el.style.left = Math.max(4, Math.min(r.left, innerWidth - w - 6)) + "px";
    this.el.style.top = (r.bottom + ht + 6 < innerHeight ? r.bottom + 4 : Math.max(4, r.top - ht - 4)) + "px";

    const drag = (e) => {
      const box = area.getBoundingClientRect();
      this.state.s = Math.min(1, Math.max(0, (e.clientX - box.left) / box.width));
      this.state.v = 1 - Math.min(1, Math.max(0, (e.clientY - box.top) / box.height));
      this.update(true);
    };
    area.addEventListener("mousedown", (e) => {
      e.preventDefault(); area.focus(); drag(e);
      const up = () => { document.removeEventListener("mousemove", drag); document.removeEventListener("mouseup", up); };
      document.addEventListener("mousemove", drag); document.addEventListener("mouseup", up);
    });
    area.addEventListener("keydown", (e) => {
      const step = e.shiftKey ? 0.1 : 0.01;
      if (e.key === "ArrowLeft") this.state.s = Math.max(0, this.state.s - step);
      else if (e.key === "ArrowRight") this.state.s = Math.min(1, this.state.s + step);
      else if (e.key === "ArrowUp") this.state.v = Math.min(1, this.state.v + step);
      else if (e.key === "ArrowDown") this.state.v = Math.max(0, this.state.v - step);
      else return;
      e.preventDefault(); this.update(true);
    });
    hue.addEventListener("input", () => { this.state.h = +hue.value; this.update(true); });
    alpha.addEventListener("input", () => { this.state.a = +alpha.value / 100; this.update(true); });
    kind.addEventListener("click", () => { this.state.kind = { hex: "rgb", rgb: "hsl", hsl: "hex" }[this.state.kind]; this.update(true); });
    value.addEventListener("keydown", (e) => {
      e.stopPropagation();
      if (e.key === "Enter") { e.preventDefault(); this.setText(value.value); }
    });
    value.addEventListener("change", () => this.setText(value.value));
    if (dropper) dropper.addEventListener("click", async () => {
      try { const result = await new window.EyeDropper().open(); this.setText(result.sRGBHex); } catch (_) {}
    });
    this.el.addEventListener("keydown", (e) => { if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); this.close(false); } });
    this.outside = (e) => { if (this.el && !this.el.contains(e.target) && e.target !== anchor) this.close(true); };
    setTimeout(() => document.addEventListener("mousedown", this.outside, true), 0);
    this.update(false);
    area.focus();
    return this.el;
  },

  setText(text) {
    const c = this.parse(text);
    if (!c) return;
    const hsv = this.rgbToHsv(c);
    Object.assign(this.state, { h: hsv.s ? hsv.h : this.state.h, s: hsv.s, v: hsv.v, a: c.a, kind: this.formatOf(text) });
    this.update(true);
  },

  current() {
    const s = this.state;
    return Object.assign(this.hsvToRgb(s.h, s.s, s.v), { a: s.a });
  },

  update(notify) {
    const s = this.state, p = this.parts;
    const c = this.current();
    const text = this.format(c, s.kind);
    p.area.style.backgroundColor = `hsl(${s.h}, 100%, 50%)`;
    const handle = p.area.firstChild;
    handle.style.left = (s.s * 100) + "%";
    handle.style.top = ((1 - s.v) * 100) + "%";
    p.hue.value = String(Math.round(s.h));
    p.alpha.value = String(Math.round(s.a * 100));
    p.alpha.style.setProperty("--cp-solid", `rgb(${c.r}, ${c.g}, ${c.b})`);
    p.swatch.firstChild.style.background = text;
    if (document.activeElement !== p.value || !notify) p.value.value = text;
    p.kind.textContent = s.kind.toUpperCase();
    this.value = text;
    if (notify) { s.changed = true; s.onChange(text, false); }
  },

  close(commit) {
    if (!this.el) return;
    const s = this.state;
    document.removeEventListener("mousedown", this.outside, true);
    this.el.remove();
    this.el = null;
    if (!s) return;
    this.state = null;
    if (!commit && s.changed) s.onChange(s.original, true, true);
    else if (s.changed) s.onChange(this.value, true);
  },
};
