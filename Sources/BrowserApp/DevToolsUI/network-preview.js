// SimpleBrowser DevTools — Network panel: the Preview and Response tabs.
//
// Preview shows a response for what it is: HTML rendered (scripts off), JSON
// as a searchable tree, XML and RSS as a tree, event streams and NDJSON as
// lists, images, SVG, fonts and media for real, forms and multipart as tables,
// and anything binary as a hex dump. Response is the text itself in a code
// view with line numbers, highlighting, pretty-print, wrap and find, which
// stays fast on multi-megabyte bodies by rendering only the visible lines.
"use strict";

(function () {
  const copyText = (text) => DevTools.rpc("Clipboard.write", { text }).catch(() => {});
  const toast = (text) => { if (window.Toast) Toast.show(text); };

  // ---- bodies ---------------------------------------------------------------------------------------
  // Text bodies are strings; binary ones arrive as data URLs.
  const Body = {
    isDataURL(text) { return typeof text === "string" && text.startsWith("data:"); },

    parseDataURL(text) {
      const comma = text.indexOf(",");
      const meta = text.slice(5, comma < 0 ? text.length : comma);
      const base64 = /;base64$/i.test(meta);
      const mime = (meta.replace(/;base64$/i, "").split(";")[0] || "application/octet-stream").toLowerCase();
      return { mime, base64, data: comma < 0 ? "" : text.slice(comma + 1) };
    },

    // The body's bytes (the first `limit` of them).
    bytes(text, limit = Infinity) {
      if (this.isDataURL(text)) {
        const { base64, data } = this.parseDataURL(text);
        if (!base64) return new TextEncoder().encode(decodeURIComponent(data)).slice(0, limit);
        const chars = limit === Infinity ? data : data.slice(0, Math.ceil(limit / 3) * 4);
        const binary = atob(chars.replace(/[^A-Za-z0-9+/=]/g, ""));
        const n = Math.min(binary.length, limit);
        const out = new Uint8Array(n);
        for (let i = 0; i < n; i++) out[i] = binary.charCodeAt(i);
        return out;
      }
      const sample = limit === Infinity ? text : text.slice(0, limit);
      return new TextEncoder().encode(sample).slice(0, limit);
    },

    byteLength(text) {
      if (text == null) return 0;
      if (this.isDataURL(text)) {
        const { base64, data } = this.parseDataURL(text);
        if (!base64) return decodeURIComponent(data).length;
        const padding = data.endsWith("==") ? 2 : data.endsWith("=") ? 1 : 0;
        return Math.max(0, Math.floor(data.length * 3 / 4) - padding);
      }
      // UTF-8 length without allocating the encoded copy.
      let n = 0;
      for (let i = 0; i < text.length; i++) {
        const c = text.charCodeAt(i);
        if (c < 0x80) n += 1; else if (c < 0x800) n += 2;
        else if (c >= 0xd800 && c < 0xdc00) { n += 4; i++; } else n += 3;
      }
      return n;
    },

    base64(text) {
      if (this.isDataURL(text) && this.parseDataURL(text).base64) return this.parseDataURL(text).data;
      return null;
    },
  };

  // ---- what kind of response is this --------------------------------------------------------------
  function mimeOf(r, text) {
    if (Body.isDataURL(text)) return Body.parseDataURL(text).mime;
    const raw = r.mimeType || SBNet.header(r.responseHeaders, "content-type") || "";
    return raw.split(";")[0].trim().toLowerCase();
  }

  const JSONP_RE = /^\s*(?:\/\*\*\/\s*)?([A-Za-z_$][\w$.]*)\s*\(([\s\S]*)\)\s*;?\s*$/;

  function parseJSONP(text) {
    if (text.length > 20_000_000) return null;
    const m = JSONP_RE.exec(text);
    if (!m) return null;
    try { return { callback: m[1], value: JSON.parse(m[2]) }; } catch (_) { return null; }
  }

  function looksLikeNDJSON(text) {
    const lines = text.split("\n").filter((l) => l.trim());
    if (lines.length < 2) return false;
    return lines.slice(0, 20).every((l) => { try { const v = JSON.parse(l); return v !== null && typeof v === "object"; } catch (_) { return false; } });
  }

  function looksBinary(text) {
    const sample = text.slice(0, 2000);
    if (!sample) return false;
    let odd = 0;
    for (let i = 0; i < sample.length; i++) {
      const c = sample.charCodeAt(i);
      if ((c < 9 || (c > 13 && c < 32) || c === 0xfffd)) odd++;
    }
    return odd / sample.length > 0.1;
  }

  function kindOf(r, text) {
    const mime = mimeOf(r, text);
    if (Body.isDataURL(text)) {
      if (mime === "image/svg+xml") return "svg";
      if (mime.startsWith("image/")) return "image";
      if (isFontMime(mime) || r.resourceType === "font") return "font";
      if (mime.startsWith("audio/") || mime.startsWith("video/")) return "media";
      return "binary";
    }
    const head = text.slice(0, 300).trimStart();
    if (/event-stream/.test(mime)) return "sse";
    if (/ndjson|jsonl|json-seq|jsonlines/.test(mime)) return "ndjson";
    if (mime === "image/svg+xml" || (/^<svg[\s>]/i.test(head) && !/html/.test(mime))) return "svg";
    if (/json/.test(mime)) {
      if (tryParseJSON(text) !== undefined) return "json";
      if (looksLikeNDJSON(text)) return "ndjson";
      return "text";
    }
    if (/html/.test(mime)) return "html";
    if (/xml|rss|atom/.test(mime)) return "xml";
    if (/javascript|ecmascript/.test(mime)) return parseJSONP(text) ? "jsonp" : "js";
    if (/css/.test(mime)) return "css";
    if (/x-www-form-urlencoded/.test(mime)) return "form";
    if (/^multipart\//.test(mime)) return "multipart";
    if (isFontMime(mime) || r.resourceType === "font") return looksBinary(text) ? "binary" : "text";
    if (/^(audio|video|image)\//.test(mime) || /octet-stream|wasm|zip|pdf|protobuf/.test(mime)) return looksBinary(text) ? "binary" : "text";
    // No useful type: sniff.
    if (head.startsWith("{") || head.startsWith("[")) {
      if (tryParseJSON(text) !== undefined) return "json";
      if (looksLikeNDJSON(text)) return "ndjson";
    }
    if (/^<\?xml/i.test(head)) return "xml";
    if (/^<(!doctype html|html|head|body)/i.test(head)) return "html";
    if (parseJSONP(text)) return "jsonp";
    if (r.resourceType === "script") return "js";
    if (r.resourceType === "stylesheet") return "css";
    if (looksBinary(text)) return "binary";
    return "text";
  }

  function isFontMime(mime) { return /^font\/|font-|-font|woff|opentype|truetype|x-font/.test(mime); }

  function tryParseJSON(text) {
    const trimmed = text.trim();
    if (!trimmed || !"{[\"tfn-0123456789".includes(trimmed[0])) return undefined;
    try { return JSON.parse(trimmed); } catch (_) { return undefined; }
  }

  // Language for highlighting and pretty-printing.
  function langOf(r, text, kind) {
    kind = kind || kindOf(r, text);
    if (kind === "json" || kind === "ndjson") return "json";
    if (kind === "html" || kind === "xml" || kind === "svg") return "html";
    if (kind === "css") return "css";
    if (kind === "js" || kind === "jsonp") return "js";
    return Highlighter.language(r.url, r.resourceType, text);
  }

  // ---- linear pretty printers ------------------------------------------------------------------------
  // The same output as the Sources pretty-printer, built line by line so a
  // multi-megabyte bundle formats in linear time.
  const Pretty = {
    LIMIT: 8_000_000,

    print(text, lang) {
      if (text.length > this.LIMIT) return null;
      try {
        if (lang === "json") return JSON.stringify(JSON.parse(text), null, 2) + "\n";
        if (lang === "css") return this.css(text);
        if (lang === "js") return this.js(text);
        if (lang === "html") return this.html(text);
      } catch (_) {}
      return null;
    },

    js(text) {
      const tokens = Highlighter.js(text);
      const lines = [];
      let cur = "", indent = 0, atLineStart = true, parens = 0;
      const parenStack = [];
      const newline = () => { cur = cur.replace(/[ \t]+$/, ""); if (cur !== "") { lines.push(cur); cur = ""; } atLineStart = true; };
      const write = (s) => { if (atLineStart) { cur += "  ".repeat(indent); atLineStart = false; } cur += s; };
      const nextSignificant = (k) => { for (let j = k + 1; j < tokens.length; j++) { if (tokens[j][1].trim()) return tokens[j][1]; } return ""; };
      for (let k = 0; k < tokens.length; k++) {
        const [cls, raw] = tokens[k];
        if (cls === null && !raw.trim()) { if (!atLineStart && !cur.endsWith(" ")) cur += " "; continue; }
        if (cls === "tok-comment") { write(raw); if (raw.startsWith("//") || raw.includes("\n")) newline(); continue; }
        if (cls !== null) { write(raw); continue; }
        if (raw === "{") {
          cur = cur.replace(/[ \t]+$/, "");
          write(atLineStart || cur === "" || /[({\[,]$/.test(cur) ? "{" : " {");
          parenStack.push(parens); parens = 0; indent++; newline(); continue;
        }
        if (raw === "}") {
          newline(); indent = Math.max(0, indent - 1); parens = parenStack.length ? parenStack.pop() : 0; write("}");
          const next = nextSignificant(k);
          if (/^(?:else|catch|finally|while)$/.test(next)) cur += " ";
          else if (!/^[,;).\]]$/.test(next) && next !== "(") newline();
          continue;
        }
        if (raw === ";") { write(";"); if (parens === 0) newline(); continue; }
        if (raw === "(" || raw === "[") parens++;
        if (raw === ")" || raw === "]") parens = Math.max(0, parens - 1);
        if (raw === ",") { write(", "); continue; }
        write(raw);
      }
      if (cur) lines.push(cur);
      return lines.join("\n").replace(/ +\n/g, "\n").replace(/, +/g, ", ").trim() + "\n";
    },

    css(text) {
      const tokens = Highlighter.css(text);
      const lines = [];
      let cur = "", indent = 0, atLineStart = true;
      const newline = () => { cur = cur.replace(/[ \t]+$/, ""); if (cur !== "") { lines.push(cur); cur = ""; } atLineStart = true; };
      const write = (s) => { if (atLineStart) { s = s.replace(/^\s+/, ""); if (!s) return; cur += "  ".repeat(indent); atLineStart = false; } cur += s; };
      const trimBack = () => { cur = cur.replace(/\s+$/, ""); while (cur === "" && lines.length) cur = lines.pop().replace(/\s+$/, ""); };
      for (const [cls, raw] of tokens) {
        if (cls === null && raw === "{") { trimBack(); atLineStart = cur === ""; write(" {"); indent++; newline(); continue; }
        if (cls === null && raw === "}") { newline(); indent = Math.max(0, indent - 1); write("}"); newline(); if (indent === 0) lines.push(""); continue; }
        if (cls === null && raw === ";") { write(";"); newline(); continue; }
        if (cls === "tok-comment") { write(raw); newline(); continue; }
        write(raw.replace(/\s+/g, " "));
      }
      if (cur) lines.push(cur);
      return lines.join("\n").replace(/\n{3,}/g, "\n\n").trim() + "\n";
    },

    VOID: new Set("area base br col embed hr img input keygen link meta param source track wbr".split(" ")),
    RAW: new Set(["script", "style", "pre", "textarea"]),

    html(text) {
      const lower = text.toLowerCase();
      const lines = [];
      let indent = 0;
      const push = (s) => lines.push("  ".repeat(indent) + s);
      const re = /<!--[\s\S]*?(?:-->|$)|<![^>]*>|<\?[\s\S]*?\?>|<\/?([A-Za-z][\w:.-]*)(?:"[^"]*"|'[^']*'|[^'">])*>?|[^<]+|</g;
      let m;
      while ((m = re.exec(text))) {
        const tok = m[0];
        if (!tok) { re.lastIndex++; continue; }
        const name = (m[1] || "").toLowerCase();
        if (tok[0] !== "<" || tok === "<") { const t = tok.replace(/\s+/g, " ").trim(); if (t) push(t); continue; }
        if (!name) { push(tok.trim()); continue; }
        if (tok[1] === "/") { indent = Math.max(0, indent - 1); push(tok); continue; }
        if (this.VOID.has(name) || tok.endsWith("/>")) { push(tok.replace(/\s+/g, " ")); continue; }
        if (!this.RAW.has(name)) {
          // <title>Short text</title> stays on one line.
          const inline = new RegExp("^([^<]{0,160})</" + name.replace(/[.:-]/g, "\\$&") + "\\s*>", "i").exec(text.slice(re.lastIndex, re.lastIndex + 200 + name.length));
          if (inline && !inline[1].includes("\n\n")) {
            push(tok.replace(/\s+/g, " ") + inline[1].replace(/\s+/g, " ").trim() + inline[0].slice(inline[1].length));
            re.lastIndex += inline[0].length;
            continue;
          }
        }
        push(tok.replace(/\s+/g, " "));
        indent++;
        if (this.RAW.has(name)) {
          const close = lower.indexOf("</" + name, re.lastIndex);
          const end = close < 0 ? text.length : close;
          const inner = text.slice(re.lastIndex, end);
          if (inner.trim()) {
            if (name === "pre" || name === "textarea") { lines.push(inner.replace(/^\n/, "").replace(/\s+$/, "")); }
            else {
              const type = /\btype\s*=\s*["']?([^"' >]+)/i.exec(tok);
              const lang = name === "style" ? "css" : (!type || /javascript|module|ecmascript|json/i.test(type[1]) ? "js" : null);
              const pretty = (lang && this.print(inner, lang)) || inner;
              for (const line of pretty.split("\n")) if (line.trim()) push(lang ? line : line.trim());
            }
          }
          re.lastIndex = end;
        }
      }
      return lines.join("\n") + "\n";
    },
  };

  // ---- code view: line numbers, highlighting, pretty-print, wrap, find ---------------------------------
  const LINE_H = 16;
  const VIRTUAL_LINES = 2000;           // past this, only the visible lines are in the DOM
  const VIRTUAL_CHARS = 400_000;
  const HIGHLIGHT_LIMIT = 1_500_000;    // characters tokenized as a whole; past it, line by line
  const LONG_LINE = 100_000;            // characters of one line put on screen
  const MAX_MATCHES = 10_000;

  class CodeView {
    // { text, lang, filename, saveText, saveBase64, pretty, info }
    constructor(options) {
      this.options = options;
      this.raw = options.text;
      this.lang = options.lang || null;
      this.pretty = !!options.pretty && this.canPretty();
      this.wrap = (() => { try { return localStorage.getItem("devtools.network.wrap") !== "false"; } catch (_) { return true; } })();
      this.query = "";
      this.matches = [];
      this.current = -1;
      this.el = h("div", { class: "nv-code-view" });
      this.build();
    }

    canPretty() { return ["js", "css", "json", "html"].includes(this.lang) && this.raw.length <= Pretty.LIMIT; }

    build() {
      const bar = h("div", { class: "nv-bar" });
      this.prettyButton = h("button", { class: "icon-button nv-pretty", title: "Pretty print" }, "{ }");
      this.prettyButton.addEventListener("click", () => this.setPretty(!this.pretty));
      this.prettyButton.hidden = !this.canPretty();
      this.wrapBox = h("input", { type: "checkbox" });
      this.wrapBox.addEventListener("change", () => this.setWrap(this.wrapBox.checked));
      this.wrapLabel = h("label", { class: "check", title: "Wrap long lines" }, this.wrapBox, "Wrap");
      const findButton = h("button", { class: "icon-button", title: "Find in response (⌘F)" }, "⌕");
      findButton.addEventListener("click", () => this.openFind());
      this.infoEl = h("span", { class: "muted nv-info" });
      const copyButton = h("button", { class: "text-button", title: "Copy the response" }, "Copy");
      copyButton.addEventListener("click", () => { copyText(this.raw); toast("Response copied"); });
      const saveButton = h("button", { class: "text-button", title: "Save the response as a file" }, "Save…");
      saveButton.addEventListener("click", () => this.save());
      bar.append(this.prettyButton, this.wrapLabel, findButton, this.infoEl, h("span", { class: "toolbar-spacer" }), copyButton, saveButton);

      this.findInput = h("input", { type: "search", class: "nv-find-input", placeholder: "Find" });
      this.findCount = h("span", { class: "muted nv-find-count" });
      const prev = h("button", { class: "icon-button", title: "Previous match (⇧↩)" }, "▲");
      const next = h("button", { class: "icon-button", title: "Next match (↩)" }, "▼");
      const close = h("button", { class: "icon-button", title: "Close (Esc)" }, "✕");
      this.findBar = h("div", { class: "nv-find", hidden: true }, this.findInput, this.findCount, prev, next, close);
      this.findInput.addEventListener("input", debounce(() => this.find(this.findInput.value), 120));
      this.findInput.addEventListener("keydown", (e) => {
        if (e.key === "Enter") { e.preventDefault(); this.step(e.shiftKey ? -1 : 1); }
        else if (e.key === "Escape") { e.preventDefault(); this.closeFind(); }
        e.stopPropagation();
      });
      prev.addEventListener("click", () => this.step(-1));
      next.addEventListener("click", () => this.step(1));
      close.addEventListener("click", () => this.closeFind());

      this.noticeEl = h("div", { class: "nv-notice", hidden: true });
      this.scroller = h("div", { class: "nv-scroll code-container", tabindex: "-1" });
      this.scroller.addEventListener("scroll", () => { if (this.virtual) this.scheduleWindow(); });
      this.el.append(bar, this.findBar, this.noticeEl, this.scroller);
      this.renderText();
    }

    text() {
      if (!this.pretty) return this.raw;
      if (this.prettyText == null) this.prettyText = Pretty.print(this.raw, this.lang) || this.raw;
      return this.prettyText;
    }

    setPretty(on) {
      this.pretty = on && this.canPretty();
      this.renderText();
      if (this.query) this.find(this.query, true);
    }

    setWrap(on) {
      this.wrap = on;
      try { localStorage.setItem("devtools.network.wrap", String(on)); } catch (_) {}
      this.scroller.classList.toggle("nv-nowrap", !this.wrap || this.virtual);
    }

    renderText() {
      const text = this.text();
      this.lines = text.split("\n");
      if (this.lines.length > 1 && this.lines[this.lines.length - 1] === "") this.lines.pop();
      this.virtual = this.lines.length > VIRTUAL_LINES || text.length > VIRTUAL_CHARS;
      const notices = [];
      this.lineTokens = null;
      this.lazyHighlight = false;
      if (this.lang) {
        if (text.length <= HIGHLIGHT_LIMIT) {
          const tokens = Highlighter.tokenize(text, this.lang);
          if (tokens) this.lineTokens = this.splitTokens(tokens, this.lines.length);
        } else {
          this.lazyHighlight = true;
          this.lineCache = new Map();
          notices.push(`Highlighting is per line past ${formatBytes(HIGHLIGHT_LIMIT)}, so multi-line strings and comments may be coloured wrongly.`);
        }
      }
      if (this.virtual) notices.push(`Large response (${formatBytes(Body.byteLength(this.raw))}, ${this.lines.length.toLocaleString()} lines): only the visible lines are drawn, without word wrap.`);
      if (this.lines.some((l) => l.length > LONG_LINE)) notices.push(`Lines longer than ${LONG_LINE.toLocaleString()} characters are cut on screen` + (this.canPretty() && !this.pretty ? "; { } pretty-prints them." : "; Copy or Save gives the whole text."));
      this.noticeEl.hidden = !notices.length;
      this.noticeEl.textContent = notices.join(" ");
      this.prettyButton.classList.toggle("active", this.pretty);
      this.wrapBox.checked = this.wrap && !this.virtual;
      this.wrapBox.disabled = this.virtual;
      this.wrapLabel.title = this.virtual ? "Word wrap is off for large responses" : "Wrap long lines";
      this.scroller.classList.toggle("nv-nowrap", !this.wrap || this.virtual);
      this.infoEl.textContent = `${this.lines.length.toLocaleString()} line${this.lines.length === 1 ? "" : "s"} · ${formatBytes(Body.byteLength(this.raw))}${this.pretty ? " · formatted" : ""}`;
      this.gutterWidth = Math.max(3, String(this.lines.length).length) + 1;
      this.scroller.style.setProperty("--nv-gutter", this.gutterWidth + "ch");
      this.scroller.textContent = "";
      this.lineEls = new Map();
      if (this.virtual) {
        this.spacer = h("div", { class: "nv-spacer", style: `height:${this.lines.length * LINE_H}px` });
        this.window = h("div", { class: "nv-window" });
        this.spacer.appendChild(this.window);
        this.scroller.appendChild(this.spacer);
        this.renderWindow(true);
      } else {
        const frag = document.createDocumentFragment();
        for (let i = 0; i < this.lines.length; i++) frag.appendChild(this.makeLine(i));
        this.scroller.appendChild(frag);
      }
    }

    // Token stream → per-line segment lists.
    splitTokens(tokens, count) {
      const out = new Array(count);
      let line = 0, current = [];
      for (const [cls, raw] of tokens) {
        if (raw.indexOf("\n") < 0) { current.push([cls, raw]); continue; }
        const parts = raw.split("\n");
        for (let p = 0; p < parts.length; p++) {
          if (p > 0) { if (line < count) out[line] = current; line++; current = []; }
          if (parts[p]) current.push([cls, parts[p]]);
        }
      }
      if (line < count) out[line] = current;
      return out;
    }

    segmentsOf(i) {
      if (this.lineTokens) return this.lineTokens[i] || [];
      const line = this.lines[i];
      if (this.lazyHighlight && line.length < 5000) {
        if (!this.lineCache.has(i)) this.lineCache.set(i, Highlighter.tokenize(line, this.lang) || [[null, line]]);
        return this.lineCache.get(i);
      }
      return [[null, line]];
    }

    makeLine(i) {
      const text = h("span", { class: "code-text" });
      const el = h("div", { class: "code-line", dataset: { line: String(i + 1) } }, h("span", { class: "ln" }, String(i + 1)), text);
      this.fillLine(text, i);
      this.lineEls.set(i, el);
      return el;
    }

    // Writes line `i` with its highlighting, find matches marked, cut at LONG_LINE.
    fillLine(target, i) {
      target.textContent = "";
      let segments = this.segmentsOf(i);
      const length = this.lines[i].length;
      if (length > LONG_LINE) {
        let budget = LONG_LINE;
        const cut = [];
        for (const [cls, raw] of segments) { if (budget <= 0) break; cut.push([cls, raw.slice(0, budget)]); budget -= raw.length; }
        segments = cut;
      }
      const ranges = this.matchesByLine ? this.matchesByLine.get(i) : null;
      let pos = 0, r = 0;
      for (const [cls, raw] of segments) {
        let start = 0;
        while (start < raw.length) {
          const abs = pos + start;
          while (ranges && r < ranges.length && ranges[r][1] <= abs) r++;
          const range = ranges && r < ranges.length ? ranges[r] : null;
          let end = raw.length, marked = false;
          if (range && range[0] <= abs) { end = Math.min(raw.length, range[1] - pos); marked = true; }
          else if (range && range[0] < pos + raw.length) end = range[0] - pos;
          const piece = raw.slice(start, end);
          let node = cls ? h("span", { class: cls }, piece) : document.createTextNode(piece);
          if (marked) node = h("mark", { class: "nv-hit" + (range[2] === this.current ? " current" : "") }, node);
          target.appendChild(node);
          start = end;
        }
        pos += raw.length;
      }
      if (length > LONG_LINE) target.appendChild(h("span", { class: "nv-cut" }, ` … ${(length - LONG_LINE).toLocaleString()} more characters`));
    }

    scheduleWindow() {
      if (this.windowFrame) return;
      this.windowFrame = requestAnimationFrame(() => { this.windowFrame = null; this.renderWindow(); });
    }

    renderWindow(force) {
      const height = this.scroller.clientHeight || 600;
      const first = Math.max(0, Math.floor(this.scroller.scrollTop / LINE_H) - 40);
      const last = Math.min(this.lines.length, Math.ceil((this.scroller.scrollTop + height) / LINE_H) + 40);
      if (!force && first === this.windowFirst && last === this.windowLast) return;
      this.windowFirst = first; this.windowLast = last;
      this.window.style.top = (first * LINE_H) + "px";
      this.window.textContent = "";
      this.lineEls = new Map();
      const frag = document.createDocumentFragment();
      for (let i = first; i < last; i++) frag.appendChild(this.makeLine(i));
      this.window.appendChild(frag);
    }

    // ---- find ----------------------------------------------------------------
    openFind() {
      this.findBar.hidden = false;
      this.findInput.focus();
      this.findInput.select();
      if (this.findInput.value && this.findInput.value !== this.query) this.find(this.findInput.value);
    }

    closeFind() {
      this.findBar.hidden = true;
      this.find("");
      this.scroller.focus();
    }

    find(query, keepPosition) {
      const previousLine = this.current >= 0 && this.matches[this.current] ? this.matches[this.current][0] : -1;
      const dirty = new Set(this.matchesByLine ? this.matchesByLine.keys() : []);
      this.query = query;
      this.matches = [];
      this.matchesByLine = new Map();
      this.current = -1;
      if (query) {
        const needle = query.toLowerCase();
        outer:
        for (let i = 0; i < this.lines.length; i++) {
          const line = this.lines[i];
          if (line.length < needle.length) continue;
          const hay = line.toLowerCase();
          let at = hay.indexOf(needle);
          while (at >= 0) {
            const index = this.matches.length;
            this.matches.push([i, at, at + needle.length]);
            if (!this.matchesByLine.has(i)) this.matchesByLine.set(i, []);
            this.matchesByLine.get(i).push([at, at + needle.length, index]);
            if (this.matches.length >= MAX_MATCHES) break outer;
            at = hay.indexOf(needle, at + Math.max(1, needle.length));
          }
        }
      }
      for (const line of this.matchesByLine.keys()) dirty.add(line);
      if (this.matches.length) {
        let start = 0;
        if (keepPosition && previousLine >= 0) start = Math.max(0, this.matches.findIndex((m) => m[0] >= previousLine));
        this.current = start;
      }
      this.refreshLines(dirty);
      this.updateCount();
      if (this.current >= 0) this.reveal();
      return this.matches.length;
    }

    step(direction) {
      if (!this.matches.length) return;
      const before = this.matches[this.current][0];
      this.current = (this.current + direction + this.matches.length) % this.matches.length;
      this.refreshLines(new Set([before, this.matches[this.current][0]]));
      this.updateCount();
      this.reveal();
    }

    updateCount() {
      this.findCount.textContent = !this.query ? "" : this.matches.length
        ? `${this.current + 1} of ${this.matches.length}${this.matches.length >= MAX_MATCHES ? "+" : ""}` : "No matches";
    }

    refreshLines(lines) {
      for (const i of lines) {
        const el = this.lineEls.get(i);
        if (el) this.fillLine(el.querySelector(".code-text"), i);
      }
    }

    reveal() {
      const [line] = this.matches[this.current];
      if (this.virtual) {
        const target = line * LINE_H - this.scroller.clientHeight / 2;
        this.scroller.scrollTop = Math.max(0, target);
        this.renderWindow(true);
      }
      const mark = this.lineEls.get(line)?.querySelector("mark.current");
      if (mark) mark.scrollIntoView({ block: "center", inline: "nearest" });
    }

    save() {
      const base64 = this.options.saveBase64;
      const params = { name: this.options.filename || "response.txt" };
      if (base64) params.base64 = base64; else params.text = this.raw;
      DevTools.rpc("DevTools.saveFile", params).then((path) => { if (path) toast("Saved to " + path); }).catch((e) => toast(e.message));
    }
  }

  // ---- JSON tree: search, expand/collapse all, copy value and path ---------------------------------------
  const IDENT = /^[A-Za-z_$][\w$]*$/;
  function pathString(tokens) {
    let out = "";
    for (const t of tokens) {
      if (typeof t === "number") out += `[${t}]`;
      else if (IDENT.test(t)) out += (out ? "." : "") + t;
      else out += `[${JSON.stringify(t)}]`;
    }
    return out;
  }

  function jsonPreview(value, budget = 80) {
    if (value === null) return "null";
    if (typeof value === "string") return JSON.stringify(value.length > 40 ? value.slice(0, 40) + "…" : value);
    if (typeof value !== "object") return String(value);
    if (Array.isArray(value)) {
      let out = `(${value.length}) [`;
      for (let i = 0; i < value.length; i++) {
        const v = value[i];
        const piece = v !== null && typeof v === "object" ? (Array.isArray(v) ? `Array(${v.length})` : "{…}") : jsonPreview(v, 20);
        if (out.length + piece.length > budget) { out += "…"; break; }
        out += (i ? ", " : "") + piece;
      }
      return out + "]";
    }
    let out = "{";
    const keys = Object.keys(value);
    for (let i = 0; i < keys.length; i++) {
      const v = value[keys[i]];
      const piece = keys[i] + ": " + (v !== null && typeof v === "object" ? (Array.isArray(v) ? `Array(${v.length})` : "{…}") : jsonPreview(v, 20));
      if (out.length + piece.length > budget) { out += "…"; break; }
      out += (i ? ", " : "") + piece;
    }
    return out + "}";
  }

  function jsonLeaf(v) {
    if (v === null) return h("span", { class: "v-null" }, "null");
    if (typeof v === "string") return h("span", { class: "v-string" }, JSON.stringify(v));
    if (typeof v === "number") return h("span", { class: "v-number" }, String(v));
    if (typeof v === "boolean") return h("span", { class: "v-boolean" }, String(v));
    return h("span", {}, String(v));
  }

  const CHUNK = 200;

  class JSONView {
    constructor(value, { expandDepth = 1, toolbar = true } = {}) {
      this.value = value;
      this.el = h("div", { class: "nv-json-view" });
      this.tree = h("div", { class: "nv-json selectable" });
      this.hits = [];
      this.current = -1;
      if (toolbar) this.el.appendChild(this.buildBar());
      this.el.appendChild(this.tree);
      this.root = this.makeNode(value, null, [], 0);
      this.tree.appendChild(this.root.el);
      if (this.root.isObject && expandDepth > 0) this.expandTo(this.root, expandDepth);
      this.tree.addEventListener("contextmenu", (e) => {
        const el = e.target.closest(".nv-jnode");
        if (!el || !el._node) return;
        e.preventDefault();
        ContextMenu.show(e.clientX, e.clientY, this.menuItems(el._node));
      });
    }

    buildBar() {
      const bar = h("div", { class: "nv-bar" });
      const expand = h("button", { class: "text-button", title: "Expand every node" }, "Expand all");
      expand.addEventListener("click", () => this.expandAll());
      const collapse = h("button", { class: "text-button", title: "Collapse to the top level" }, "Collapse all");
      collapse.addEventListener("click", () => this.collapseAll());
      this.searchInput = h("input", { type: "search", class: "nv-find-input", placeholder: "Search keys and values" });
      this.searchCount = h("span", { class: "muted nv-find-count" });
      this.searchInput.addEventListener("input", debounce(() => this.search(this.searchInput.value), 150));
      this.searchInput.addEventListener("keydown", (e) => {
        if (e.key === "Enter") { e.preventDefault(); this.step(e.shiftKey ? -1 : 1); }
        else if (e.key === "Escape") { e.preventDefault(); this.searchInput.value = ""; this.search(""); }
        e.stopPropagation();
      });
      bar.append(expand, collapse, this.searchInput, this.searchCount);
      return bar;
    }

    openFind() { if (this.searchInput) { this.searchInput.focus(); this.searchInput.select(); } }

    makeNode(value, key, path, depth) {
      const isObject = value !== null && typeof value === "object";
      const node = { value, key, path, depth, isObject, built: false, rendered: 0, kids: new Map() };
      const row = h("div", { class: "nv-jrow" });
      node.el = h("div", { class: "nv-jnode" + (isObject ? "" : " leaf") }, row);
      node.el._node = node;
      node.row = row;
      if (isObject) {
        row.appendChild(h("span", { class: "nv-jtoggle" }));
        row.addEventListener("click", (e) => { if (e.target.closest(".nv-jrow") === row && !getSelection().toString()) this.toggle(node); });
      }
      if (key != null) row.append(h("span", { class: "obj-key" }, String(key)), ": ");
      if (isObject) {
        node.summary = h("span", { class: "obj-desc" }, jsonPreview(value));
        row.appendChild(node.summary);
        node.kidsEl = h("div", { class: "nv-jkids" });
        node.el.appendChild(node.kidsEl);
      } else row.appendChild(jsonLeaf(value));
      return node;
    }

    keysOf(node) { return Array.isArray(node.value) ? node.value.map((_, i) => i) : Object.keys(node.value); }

    renderMore(node, upTo) {
      const keys = this.keysOf(node);
      const limit = Math.min(keys.length, Math.max(upTo ?? 0, node.rendered + CHUNK));
      node.kidsEl.querySelector(":scope > .nv-jmore")?.remove();
      for (let i = node.rendered; i < limit; i++) {
        const k = keys[i];
        const child = this.makeNode(node.value[k], k, node.path.concat([k]), node.depth + 1);
        node.kids.set(String(k), child);
        node.kidsEl.appendChild(child.el);
      }
      node.rendered = limit;
      if (limit < keys.length) {
        const more = h("div", { class: "nv-jmore link" }, `Show ${Math.min(CHUNK, keys.length - limit)} more of ${keys.length - limit} remaining…`);
        more.addEventListener("click", () => this.renderMore(node));
        node.kidsEl.appendChild(more);
      }
      if (!keys.length && !node.kidsEl.firstChild) node.kidsEl.appendChild(h("div", { class: "nv-jrow muted" }, Array.isArray(node.value) ? "(empty array)" : "(empty object)"));
    }

    expand(node) {
      if (!node.isObject) return;
      if (!node.built) { node.built = true; this.renderMore(node); }
      node.el.classList.add("expanded");
    }

    collapse(node) { node.el.classList.remove("expanded"); }
    toggle(node) { if (node.el.classList.contains("expanded")) this.collapse(node); else this.expand(node); }

    expandTo(node, depth) {
      this.expand(node);
      if (depth <= 1) return;
      for (const child of node.kids.values()) if (child.isObject && this.keysOf(child).length <= 50) this.expandTo(child, depth - 1);
    }

    // Every node, breadth first, up to a budget so a huge document stays responsive.
    expandAll(budget = 5000) {
      const queue = [this.root];
      let count = 0;
      while (queue.length && count < budget) {
        const node = queue.shift();
        if (!node.isObject) continue;
        this.expand(node);
        count++;
        for (const child of node.kids.values()) if (child.isObject) queue.push(child);
      }
      if (queue.length) toast(`Expanded the first ${budget} objects; expand the rest by hand.`);
      return count;
    }

    collapseAll() {
      const walk = (node) => { for (const child of node.kids.values()) { if (child.isObject) { this.collapse(child); walk(child); } } };
      walk(this.root);
      this.expand(this.root);
    }

    // The node at `path`, building and expanding what leads to it.
    reveal(path) {
      let node = this.root;
      for (const token of path) {
        this.expand(node);
        if (!node.kids.has(String(token))) {
          const index = this.keysOf(node).findIndex((k) => String(k) === String(token));
          if (index < 0) return null;
          this.renderMore(node, index + 1);
        }
        node = node.kids.get(String(token));
        if (!node) return null;
      }
      return node;
    }

    find(query) { return this.search(query); }

    search(query) {
      for (const hit of this.hits) hit.node?.row.classList.remove("nv-hit-row", "current");
      this.hits = [];
      this.current = -1;
      const needle = String(query || "").toLowerCase();
      if (needle) {
        const walk = (value, path) => {
          if (this.hits.length >= 1000) return;
          if (value !== null && typeof value === "object") {
            const entries = Array.isArray(value) ? value.map((v, i) => [i, v]) : Object.entries(value);
            for (const [k, v] of entries) {
              const p = path.concat([k]);
              const keyHit = typeof k === "string" && k.toLowerCase().includes(needle);
              const valueHit = (v === null || typeof v !== "object") && String(v).toLowerCase().includes(needle);
              if (keyHit || valueHit) this.hits.push({ path: p });
              walk(v, p);
              if (this.hits.length >= 1000) return;
            }
          }
        };
        walk(this.value, []);
        for (const hit of this.hits.slice(0, 300)) { hit.node = this.reveal(hit.path); hit.node?.row.classList.add("nv-hit-row"); }
      }
      if (this.searchCount) this.searchCount.textContent = !needle ? "" : this.hits.length ? `${this.hits.length}${this.hits.length >= 1000 ? "+" : ""} match${this.hits.length === 1 ? "" : "es"}` : "No matches";
      if (this.hits.length) this.step(1);
      return this.hits.length;
    }

    step(direction) {
      if (!this.hits.length) return;
      this.hits[this.current]?.node?.row.classList.remove("current");
      this.current = (this.current + direction + this.hits.length) % this.hits.length;
      const hit = this.hits[this.current];
      if (!hit.node) hit.node = this.reveal(hit.path);
      if (hit.node) { hit.node.row.classList.add("nv-hit-row", "current"); hit.node.row.scrollIntoView({ block: "center" }); }
      if (this.searchCount) this.searchCount.textContent = `${this.current + 1} of ${this.hits.length}`;
    }

    copyValue(node) {
      const v = node.value;
      return typeof v === "string" ? v : JSON.stringify(v, null, 2);
    }

    menuItems(node) {
      const items = [
        { label: "Copy value", action: () => copyText(this.copyValue(node)) },
        { label: "Copy property path", action: () => copyText(pathString(node.path)) },
      ];
      if (node.isObject) {
        items.push({ label: "Copy object as JSON (one line)", action: () => copyText(JSON.stringify(node.value)) });
        items.push("-", { label: "Expand recursively", action: () => {
          const queue = [node]; let n = 0;
          while (queue.length && n < 3000) { const x = queue.shift(); if (!x.isObject) continue; this.expand(x); n++; for (const c of x.kids.values()) queue.push(c); }
        } }, { label: "Collapse children", action: () => { for (const c of node.kids.values()) if (c.isObject) this.collapse(c); } });
      }
      return items;
    }
  }

  // ---- XML tree ------------------------------------------------------------------------------------------
  function xmlTree(doc) {
    const root = h("div", { class: "nv-xml selectable" });
    const attrs = (el) => Array.from(el.attributes || []).map((a) => [" ", h("span", { class: "tok-attr" }, a.name), "=", h("span", { class: "tok-value" }, JSON.stringify(a.value))]);
    const build = (node, depth) => {
      if (node.nodeType === 3) {
        const text = node.nodeValue.trim();
        return text ? h("div", { class: "nv-xrow nv-xtext" }, text) : null;
      }
      if (node.nodeType === 4) return h("div", { class: "nv-xrow" }, h("span", { class: "tok-doctype" }, "<![CDATA["), h("span", { class: "nv-xtext" }, node.nodeValue), h("span", { class: "tok-doctype" }, "]]>"));
      if (node.nodeType === 8) return h("div", { class: "nv-xrow tok-comment" }, `<!--${node.nodeValue}-->`);
      if (node.nodeType === 7) return h("div", { class: "nv-xrow tok-doctype" }, `<?${node.target} ${node.data}?>`);
      if (node.nodeType !== 1) return null;
      const name = node.nodeName;
      const children = Array.from(node.childNodes).filter((c) => !(c.nodeType === 3 && !c.nodeValue.trim()));
      const open = [h("span", { class: "tok-tag" }, "<" + name), ...attrs(node), h("span", { class: "tok-tag" }, children.length ? ">" : "/>")];
      if (!children.length) return h("div", { class: "nv-xrow" }, ...open);
      if (children.length === 1 && children[0].nodeType === 3 && children[0].nodeValue.trim().length < 120) {
        return h("div", { class: "nv-xrow" }, ...open, h("span", { class: "nv-xtext" }, children[0].nodeValue.trim()), h("span", { class: "tok-tag" }, `</${name}>`));
      }
      const el = h("div", { class: "nv-xnode" + (depth < 3 ? " expanded" : "") });
      const head = h("div", { class: "nv-xrow nv-xhead" }, h("span", { class: "nv-jtoggle" }), ...open, h("span", { class: "nv-xellipsis muted" }, `…</${name}>`));
      head.addEventListener("click", (e) => { if (!getSelection().toString()) { el.classList.toggle("expanded"); e.stopPropagation(); } });
      const kids = h("div", { class: "nv-xkids" });
      for (const c of children.slice(0, 2000)) { const built = build(c, depth + 1); if (built) kids.appendChild(built); }
      if (children.length > 2000) kids.appendChild(h("div", { class: "nv-xrow muted" }, `… ${children.length - 2000} more nodes`));
      el.append(head, kids, h("div", { class: "nv-xrow nv-xclose" }, h("span", { class: "tok-tag" }, `</${name}>`)));
      return el;
    };
    for (const node of Array.from(doc.childNodes)) { const built = build(node, 0); if (built) root.appendChild(built); }
    return root;
  }

  function parseXML(text) {
    const doc = new DOMParser().parseFromString(text, "application/xml");
    const error = doc.getElementsByTagName("parsererror")[0];
    return error ? { error: error.textContent.trim().split("\n")[0] } : { doc };
  }

  // ---- event streams, NDJSON, forms, multipart ------------------------------------------------------------
  function parseSSE(text) {
    const events = [];
    let data = [], type = "", id = "", lastId = "", retry = null, comments = 0;
    const dispatch = () => {
      if (data.length) events.push({ id: id || lastId, type: type || "message", data: data.join("\n"), retry });
      if (id) lastId = id;
      data = []; type = ""; id = ""; retry = null;
    };
    for (const line of text.split(/\r\n|\r|\n/)) {
      if (line === "") { dispatch(); continue; }
      if (line.startsWith(":")) { comments++; continue; }
      const colon = line.indexOf(":");
      const field = colon < 0 ? line : line.slice(0, colon);
      let value = colon < 0 ? "" : line.slice(colon + 1);
      if (value.startsWith(" ")) value = value.slice(1);
      if (field === "data") data.push(value);
      else if (field === "event") type = value;
      else if (field === "id") id = value;
      else if (field === "retry" && /^\d+$/.test(value)) { retry = +value; events.retry = +value; }
    }
    dispatch();
    events.comments = comments;
    return events;
  }

  function parseMultipart(text, contentType) {
    let boundary = (/boundary=(?:"([^"]+)"|([^;\s]+))/i.exec(contentType || "") || []).slice(1).find(Boolean);
    if (!boundary) { const m = /^--([^\r\n]+)\r?\n/.exec(text); if (m) boundary = m[1]; }
    if (!boundary) return null;
    const parts = [];
    for (const chunk of text.split("--" + boundary).slice(1)) {
      if (chunk.startsWith("--")) break;
      const body = chunk.replace(/^\r?\n/, "");
      const split = body.search(/\r?\n\r?\n/);
      const head = split < 0 ? body : body.slice(0, split);
      let value = split < 0 ? "" : body.slice(split).replace(/^\r?\n\r?\n/, "").replace(/\r?\n$/, "");
      const headers = {};
      for (const line of head.split(/\r?\n/)) { const i = line.indexOf(":"); if (i > 0) headers[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim(); }
      const disposition = headers["content-disposition"] || "";
      const name = (/\bname="([^"]*)"/i.exec(disposition) || [])[1] || "";
      const filename = (/\bfilename="([^"]*)"/i.exec(disposition) || [])[1];
      parts.push({ name, filename, type: headers["content-type"] || "", value, size: Body.byteLength(value) });
    }
    return parts;
  }

  function formTable(pairs) {
    return h("table", { class: "data-table nv-table selectable" },
      h("thead", {}, h("tr", {}, h("th", { style: "width:35%" }, "Name"), h("th", {}, "Value"))),
      h("tbody", {}, pairs.map(([k, v]) => h("tr", {}, h("td", { class: "mono", title: k }, k), h("td", { class: "mono nv-wrap", title: v }, v)))));
  }

  function multipartTable(parts) {
    return h("table", { class: "data-table nv-table selectable" },
      h("thead", {}, h("tr", {}, h("th", { style: "width:22%" }, "Name"), h("th", { style: "width:22%" }, "File"), h("th", { style: "width:18%" }, "Content-Type"), h("th", {}, "Value"))),
      h("tbody", {}, parts.map((p) => {
        const binary = p.filename != null && (looksBinary(p.value) || !/^text\/|json|xml/.test(p.type || ""));
        return h("tr", {}, h("td", { class: "mono" }, p.name), h("td", { class: "mono" }, p.filename ?? ""), h("td", { class: "mono" }, p.type),
          h("td", { class: "mono nv-wrap" }, binary ? `(binary, ${formatBytes(p.size)})` : p.value.length > 2000 ? p.value.slice(0, 2000) + "…" : p.value));
      })));
  }

  // ---- hex view ------------------------------------------------------------------------------------------
  const HEX_LIMIT = 64 * 1024;

  function hexView(text) {
    const total = Body.byteLength(text);
    const bytes = Body.bytes(text, HEX_LIMIT);
    const wrap = h("div", { class: "nv-hex selectable" });
    const frag = document.createDocumentFragment();
    const hex = (n, w) => n.toString(16).padStart(w, "0");
    for (let offset = 0; offset < bytes.length; offset += 16) {
      let hexPart = "", ascii = "";
      for (let i = 0; i < 16; i++) {
        const b = bytes[offset + i];
        hexPart += (b === undefined ? "  " : hex(b, 2)) + (i === 7 ? "  " : " ");
        ascii += b === undefined ? "" : (b >= 32 && b < 127 ? String.fromCharCode(b) : ".");
      }
      frag.appendChild(h("div", { class: "nv-hex-row" }, h("span", { class: "nv-hex-offset" }, hex(offset, 8)), h("span", { class: "nv-hex-bytes" }, hexPart), h("span", { class: "nv-hex-ascii" }, ascii)));
    }
    wrap.appendChild(h("div", { class: "nv-hex-row nv-hex-head" }, h("span", { class: "nv-hex-offset" }, "Offset"), h("span", { class: "nv-hex-bytes" }, "00 01 02 03 04 05 06 07  08 09 0a 0b 0c 0d 0e 0f "), h("span", { class: "nv-hex-ascii" }, "ASCII")));
    wrap.appendChild(frag);
    const note = total > HEX_LIMIT ? h("div", { class: "nv-notice" }, `Showing the first ${formatBytes(HEX_LIMIT)} of ${formatBytes(total)}. Save the response to see every byte.`) : null;
    return { el: wrap, note, total };
  }

  // ---- the Preview tab -----------------------------------------------------------------------------------
  let fontSequence = 0;

  function infoBar(...items) { return h("div", { class: "nv-bar nv-meta" }, items.filter(Boolean).map((t) => typeof t === "string" ? h("span", {}, t) : t)); }

  function segmented(options, current, onChange) {
    const group = h("div", { class: "nv-seg" });
    for (const [value, label] of options) {
      const b = h("button", { class: "nv-seg-item" + (value === current ? " active" : ""), dataset: { value } }, label);
      b.addEventListener("click", () => { for (const x of group.children) x.classList.toggle("active", x === b); onChange(value); });
      group.appendChild(b);
    }
    return group;
  }

  function filenameFor(r, mime) {
    let name = "";
    try { name = decodeURIComponent(new URL(r.url).pathname.split("/").filter(Boolean).pop() || ""); } catch (_) {}
    if (!name) name = "response";
    if (!/\.[a-z0-9]{1,5}$/i.test(name)) {
      const ext = { "application/json": "json", "text/html": "html", "text/css": "css", "application/javascript": "js", "text/javascript": "js", "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "image/svg+xml": "svg", "text/plain": "txt", "application/xml": "xml", "text/xml": "xml", "text/event-stream": "txt", "font/woff2": "woff2", "font/woff": "woff", "font/ttf": "ttf", "audio/wav": "wav" }[mime];
      if (ext) name += "." + ext;
    }
    return name;
  }

  // Renders `r`'s body into `container` (the detail body). Returns the view that ⌘F should search, if any.
  // A data URL whose type is really text (SVG, XML, JSON) as that text.
  function textOf(text) {
    if (!Body.isDataURL(text)) return text;
    const { mime } = Body.parseDataURL(text);
    if (!/svg|xml|json|^text\/|javascript/.test(mime)) return text;
    try { return new TextDecoder().decode(Body.bytes(text)); } catch (_) { return text; }
  }

  function renderPreview(r, text, container) {
    text = textOf(text);
    const kind = kindOf(r, text);
    const mime = mimeOf(r, text);
    container.dataset.previewKind = kind;
    const size = formatBytes(Body.byteLength(text));
    const fill = () => container.classList.add("nv-fill");

    switch (kind) {
      case "html": {
        let mode = "rendered", view = null;
        const area = h("div", { class: "nv-area" });
        const show = () => {
          area.textContent = "";
          view = null;
          if (mode === "rendered") area.appendChild(htmlFrame(r, text));
          else { view = new CodeView({ text, lang: "html", pretty: true, filename: filenameFor(r, mime) }); area.appendChild(view.el); }
          state.view = view;
        };
        const state = { view: null, kind };
        container.append(infoBar(segmented([["rendered", "Rendered"], ["source", "Source"]], mode, (m) => { mode = m; show(); }), `HTML · ${size}`, h("span", { class: "muted" }, "scripts disabled")), area);
        fill(); show();
        return state;
      }
      case "json": {
        const view = new JSONView(tryParseJSON(text), { expandDepth: 2 });
        container.append(view.el);
        return { view, kind };
      }
      case "jsonp": {
        const parsed = parseJSONP(text);
        const view = new JSONView(parsed.value, { expandDepth: 2 });
        container.append(infoBar("JSONP", h("span", {}, "callback ", h("code", { class: "mono" }, parsed.callback + "(…)")), size), view.el);
        return { view, kind };
      }
      case "ndjson": {
        const lines = text.split("\n").filter((l) => l.trim());
        const list = h("div", { class: "nv-records" });
        lines.slice(0, 2000).forEach((line, i) => {
          let item;
          try { item = new JSONView(JSON.parse(line), { expandDepth: 0, toolbar: false }).el; }
          catch (e) { item = h("div", { class: "v-error mono" }, "Invalid JSON: " + line.slice(0, 200)); }
          list.appendChild(h("div", { class: "nv-record" }, h("span", { class: "nv-record-n muted" }, String(i + 1)), item));
        });
        container.append(infoBar(`NDJSON · ${lines.length} record${lines.length === 1 ? "" : "s"} · ${size}`, lines.length > 2000 ? "first 2000 shown" : null), list);
        return { kind };
      }
      case "sse": {
        const events = parseSSE(text);
        const tbody = h("tbody");
        events.forEach((ev, i) => {
          const json = tryParseJSON(ev.data);
          const row = h("tr", { class: "nv-sse-row" }, h("td", {}, String(i + 1)), h("td", { class: "mono" }, ev.type), h("td", { class: "mono", title: ev.data }, ev.data.replace(/\n/g, "⏎")), h("td", { class: "mono" }, ev.id));
          tbody.appendChild(row);
          const detail = h("tr", { class: "nv-sse-detail", hidden: true }, h("td", { colspan: "4" }, json !== undefined && typeof json === "object" && json ? new JSONView(json, { toolbar: false, expandDepth: 2 }).el : h("pre", { class: "code" }, ev.data)));
          tbody.appendChild(detail);
          row.addEventListener("click", () => { detail.hidden = !detail.hidden; row.classList.toggle("open", !detail.hidden); });
        });
        if (!events.length) tbody.appendChild(h("tr", {}, h("td", { colspan: "4", class: "muted", style: "text-align:center" }, "No events in this stream (yet).")));
        const table = h("table", { class: "data-table nv-table nv-sse selectable" },
          h("thead", {}, h("tr", {}, h("th", { style: "width:36px" }, "#"), h("th", { style: "width:110px" }, "Type"), h("th", {}, "Data"), h("th", { style: "width:70px" }, "ID"))), tbody);
        container.append(infoBar(`EventStream · ${events.length} event${events.length === 1 ? "" : "s"}`, events.retry != null ? `retry ${events.retry} ms` : null, events.comments ? `${events.comments} comment line${events.comments === 1 ? "" : "s"}` : null, "click an event for its data"), table);
        return { kind };
      }
      case "xml": case "svg": {
        const parsed = parseXML(text);
        let mode = kind === "svg" ? "image" : "tree", view = null;
        const area = h("div", { class: "nv-area-scroll" });
        const state = { kind, view: null };
        const show = () => {
          area.textContent = "";
          container.classList.toggle("nv-fill", mode === "source");
          view = null;
          if (mode === "image") area.appendChild(imageBox(r, "data:image/svg+xml;charset=utf-8," + encodeURIComponent(text), mime, Body.byteLength(text)));
          else if (mode === "tree" && parsed.doc) area.appendChild(xmlTree(parsed.doc));
          else {
            if (mode === "tree") area.appendChild(h("div", { class: "nv-notice" }, "Not well-formed XML: " + parsed.error));
            view = new CodeView({ text, lang: "html", pretty: false, filename: filenameFor(r, mime) });
            area.appendChild(view.el);
          }
          state.view = view;
        };
        const modes = kind === "svg" ? [["image", "Image"], ["tree", "XML tree"], ["source", "Source"]] : [["tree", "Tree"], ["source", "Source"]];
        let summary = null;
        if (parsed.doc) {
          const root = parsed.doc.documentElement;
          if (/^(rss|feed|rdf:RDF)$/i.test(root.nodeName)) {
            const title = root.querySelector("channel > title, feed > title, title")?.textContent || "";
            const items = root.querySelectorAll("item, entry").length;
            summary = `${root.nodeName === "feed" ? "Atom" : "RSS"} feed “${title}” · ${items} item${items === 1 ? "" : "s"}`;
          }
        }
        container.append(infoBar(segmented(modes, mode, (m) => { mode = m; show(); }), summary || `${kind === "svg" ? "SVG" : "XML"} · ${size}`), area);
        show();
        return state;
      }
      case "image": return { kind, el: container.appendChild(imageBox(r, text, mime, Body.byteLength(text))) };
      case "font": {
        const box = h("div", { class: "nv-font", dataset: { fontStatus: "loading" } });
        container.append(infoBar(`Font · ${mime} · ${size}`), box);
        const family = "sb-preview-font-" + (++fontSequence);
        let face;
        try { face = new FontFace(family, Body.bytes(text).buffer); }
        catch (e) { box.dataset.fontStatus = "error"; box.appendChild(h("div", { class: "detail-note" }, "This font could not be read: " + e.message)); return { kind }; }
        face.load().then(() => {
          document.fonts.add(face);
          box.dataset.fontStatus = "loaded";
          box.dataset.family = family;
          const sample = "The quick brown fox jumps over the lazy dog";
          box.appendChild(h("div", { class: "nv-font-charset", style: `font-family:"${family}"` }, "ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789 !@#$%&*()?"));
          for (const px of [12, 16, 24, 36, 48, 72]) {
            box.appendChild(h("div", { class: "nv-font-sample" }, h("span", { class: "nv-font-size muted" }, px + "px"), h("span", { style: `font-family:"${family}";font-size:${px}px` }, sample)));
          }
        }, (e) => { box.dataset.fontStatus = "error"; box.appendChild(h("div", { class: "detail-note" }, "This font could not be decoded: " + (e && e.message || e))); });
        return { kind };
      }
      case "media": {
        const tag = mime.startsWith("video/") ? "video" : "audio";
        const player = h(tag, { controls: true, preload: "metadata", src: text, class: "nv-media" });
        const meta = h("span", { class: "muted" });
        player.addEventListener("loadedmetadata", () => {
          meta.textContent = `${isFinite(player.duration) ? player.duration.toFixed(2) + " s" : "live"}${tag === "video" && player.videoWidth ? ` · ${player.videoWidth} × ${player.videoHeight}` : ""}`;
          container.dataset.mediaReady = "true";
        });
        player.addEventListener("error", () => { meta.textContent = "This format cannot be played here."; });
        container.append(infoBar(`${tag === "video" ? "Video" : "Audio"} · ${mime} · ${size}`, meta), h("div", { class: "nv-media-box" }, player));
        return { kind };
      }
      case "form": {
        const pairs = Array.from(new URLSearchParams(text.trim()).entries());
        container.append(infoBar(`Form data · ${pairs.length} field${pairs.length === 1 ? "" : "s"}`), formTable(pairs));
        return { kind };
      }
      case "multipart": {
        const parts = parseMultipart(text, SBNet.header(r.responseHeaders, "content-type") || mime);
        if (parts) { container.append(infoBar(`Multipart · ${parts.length} part${parts.length === 1 ? "" : "s"}`), multipartTable(parts)); return { kind }; }
        break;
      }
      case "binary": {
        const { el, note, total } = hexView(text);
        container.append(infoBar(`Binary · ${mime || "unknown type"} · ${formatBytes(total)}`), note, el);
        return { kind };
      }
      default: break;
    }
    // CSS, JS and any other text: formatted and highlighted.
    const lang = langOf(r, text, kind);
    const view = new CodeView({ text, lang, pretty: true, filename: filenameFor(r, mime) });
    container.appendChild(view.el);
    fill();
    return { view, kind };
  }

  function imageBox(r, src, mime, bytes) {
    const meta = h("span", {});
    const img = h("img", { class: "nv-image", src, alt: fileName(r.url) });
    const box = h("div", { class: "nv-image-box" });
    img.addEventListener("load", () => {
      meta.textContent = `${img.naturalWidth} × ${img.naturalHeight}`;
      box.dataset.width = String(img.naturalWidth);
      box.dataset.height = String(img.naturalHeight);
    });
    img.addEventListener("error", () => { meta.textContent = "The image could not be decoded."; });
    box.append(h("div", { class: "nv-checker" }, img), h("div", { class: "nv-image-meta" }, meta, h("span", { class: "muted" }, formatBytes(bytes)), h("span", { class: "muted" }, mime)));
    return box;
  }

  function htmlFrame(r, text) {
    // No scripts run: `sandbox` without allow-scripts. Same origin only so
    // the DevTools can stop link clicks from navigating anything.
    const base = `<base href="${escapeHTML(r.url)}">`;
    const html = /<head[^>]*>/i.test(text) ? text.replace(/<head[^>]*>/i, (m) => m + base) : base + text;
    const frame = h("iframe", { class: "nv-frame", sandbox: "allow-same-origin", referrerpolicy: "no-referrer" });
    frame.srcdoc = html;
    frame.addEventListener("load", () => {
      try {
        frame.contentDocument.addEventListener("click", (e) => { if (e.target.closest && e.target.closest("a, area, form, button")) e.preventDefault(); }, true);
        frame.contentDocument.addEventListener("submit", (e) => e.preventDefault(), true);
      } catch (_) {}
      frame.dataset.loaded = "true";
    });
    return frame;
  }

  // ---- the Response tab ------------------------------------------------------------------------------------
  function renderResponse(r, text, container) {
    text = textOf(text);
    const mime = mimeOf(r, text);
    if (Body.isDataURL(text)) {
      const { el, note, total } = hexView(text);
      const save = h("button", { class: "text-button" }, "Save…");
      save.addEventListener("click", () => DevTools.rpc("DevTools.saveFile", { name: filenameFor(r, mime), base64: Body.base64(text) || "" }).then((p) => { if (p) toast("Saved to " + p); }).catch((e) => toast(e.message)));
      const copyB64 = h("button", { class: "text-button", title: "Copy the body as a data: URL" }, "Copy as data URL");
      copyB64.addEventListener("click", () => { copyText(text); toast("Copied"); });
      container.append(infoBar(`Binary · ${mime} · ${formatBytes(total)}`, h("span", { class: "toolbar-spacer" }), copyB64, save));
      // An image is shown above its bytes.
      if (mime.startsWith("image/")) container.appendChild(imageBox(r, text, mime, total));
      container.append(note || "", el);
      return { kind: "binary" };
    }
    const kind = kindOf(r, text);
    const view = new CodeView({ text, lang: langOf(r, text, kind), pretty: false, filename: filenameFor(r, mime) });
    container.appendChild(view.el);
    container.classList.add("nv-fill");
    return { view, kind };
  }

  window.SBNetPreview = {
    Body, Pretty, CodeView, JSONView, kindOf, mimeOf, langOf, parseSSE, parseMultipart, parseJSONP, parseXML,
    pathString, hexView, formTable, multipartTable, renderPreview, renderResponse, filenameFor, tryParseJSON, textOf,
  };
})();
