// SimpleBrowser DevTools — syntax highlighting and pretty-printing for the
// Sources panel. Small hand-written tokenizers: good enough to read code by,
// not parsers. Every tokenizer returns [[className|null, text], …] whose
// texts concatenate back to the input exactly.
"use strict";

const Highlighter = {
  JS_KEYWORDS: new Set(("break case catch class const continue debugger default delete do else export extends finally for " +
    "function if import in instanceof let new return super switch this throw try typeof var void while with yield async " +
    "await of static get set null undefined true false").split(" ")),
  // After these, a "/" starts a regex literal rather than a division.
  REGEX_AFTER_KEYWORD: new Set(["return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await"]),

  language(url, type, text) {
    let ext = "";
    try { ext = (new URL(url).pathname.match(/\.([a-z0-9]+)$/i) || [, ""])[1].toLowerCase(); } catch (_) {}
    if (["js", "mjs", "cjs", "jsx", "ts", "tsx"].includes(ext)) return "js";
    if (ext === "css") return "css";
    if (ext === "json" || ext === "map") return "json";
    if (["html", "htm", "xhtml", "svg", "xml"].includes(ext)) return "html";
    // Inline scripts share their document's URL, so a "script" may well be
    // an HTML page: markup at the start of the text wins over the type.
    const head = (text || "").slice(0, 200).trim();
    if (/^<(?:!doctype|html|\?xml|!--|[a-z])/i.test(head)) return "html";
    if (type === "script") return "js";
    if (type === "stylesheet") return "css";
    if (type === "document") return "html";
    if (head.startsWith("{") || head.startsWith("[")) return "json";
    return null;
  },

  tokenize(text, lang) {
    try {
      if (lang === "js") return this.js(text);
      if (lang === "json") return this.json(text);
      if (lang === "css") return this.css(text);
      if (lang === "html") return this.html(text);
    } catch (_) {}
    return null;
  },

  // ---- JavaScript -----------------------------------------------------------
  js(text) {
    const tokens = [];
    const n = text.length;
    let i = 0;
    let lastSignificant = "";     // last non-space, non-comment token text
    const push = (cls, s) => { if (s) tokens.push([cls, s]); };
    const reWs = /\s+/y, reId = /[A-Za-z_$][\w$]*/y, reNum = /(?:0[xX][\da-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*\.?[\d_]*(?:[eE][+-]?\d+)?)n?/y;
    const reRegex = /\/(?:\\.|\[(?:\\.|[^\]\\\n])*\]|[^\/\\\n\[])+\/[a-z]*/y;

    while (i < n) {
      const ch = text[i];
      reWs.lastIndex = i;
      let m = reWs.exec(text);
      if (m) { push(null, m[0]); i += m[0].length; continue; }

      if (ch === "/" && text[i + 1] === "/") {
        let end = text.indexOf("\n", i); if (end < 0) end = n;
        push("tok-comment", text.slice(i, end)); i = end; continue;
      }
      if (ch === "/" && text[i + 1] === "*") {
        let end = text.indexOf("*/", i + 2); end = end < 0 ? n : end + 2;
        push("tok-comment", text.slice(i, end)); i = end; continue;
      }
      if (ch === '"' || ch === "'") {
        let j = i + 1;
        while (j < n && text[j] !== ch && text[j] !== "\n") { if (text[j] === "\\") j++; j++; }
        j = Math.min(n, j + 1);
        push("tok-string", text.slice(i, j)); lastSignificant = "str"; i = j; continue;
      }
      if (ch === "`") {
        // Template literal, including nested ${ } expressions, as one token.
        let j = i + 1, depth = 0;
        while (j < n) {
          const c = text[j];
          if (c === "\\") { j += 2; continue; }
          if (depth === 0 && c === "`") { j++; break; }
          if (c === "$" && text[j + 1] === "{") { depth++; j += 2; continue; }
          if (depth > 0 && c === "}") depth--;
          j++;
        }
        push("tok-string", text.slice(i, j)); lastSignificant = "str"; i = j; continue;
      }
      if (ch === "/") {
        const canBeRegex = lastSignificant === "" || /[(,=:\[!&|?{};+\-*%<>~^]$/.test(lastSignificant) || this.REGEX_AFTER_KEYWORD.has(lastSignificant);
        if (canBeRegex) {
          reRegex.lastIndex = i;
          m = reRegex.exec(text);
          if (m) { push("tok-regex", m[0]); lastSignificant = "regex"; i += m[0].length; continue; }
        }
        push(null, "/"); lastSignificant = "/"; i++; continue;
      }
      if (ch >= "0" && ch <= "9" || (ch === "." && text[i + 1] >= "0" && text[i + 1] <= "9")) {
        reNum.lastIndex = i;
        m = reNum.exec(text);
        if (m && m[0]) { push("tok-number", m[0]); lastSignificant = "num"; i += m[0].length; continue; }
      }
      reId.lastIndex = i;
      m = reId.exec(text);
      if (m) {
        const isKeyword = this.JS_KEYWORDS.has(m[0]) && lastSignificant !== ".";
        push(isKeyword ? "tok-keyword" : null, m[0]); lastSignificant = m[0]; i += m[0].length; continue;
      }
      push(null, ch); lastSignificant = ch; i++;
    }
    return tokens;
  },

  json(text) {
    const tokens = this.js(text);
    for (let k = 0; k < tokens.length; k++) {
      if (tokens[k][0] !== "tok-string") continue;
      let next = k + 1;
      while (next < tokens.length && tokens[next][0] === null && !tokens[next][1].trim()) next++;
      if (next < tokens.length && tokens[next][1] === ":") tokens[k][0] = "tok-prop";
    }
    return tokens;
  },

  // ---- CSS ----------------------------------------------------------------------
  css(text) {
    const tokens = [];
    const n = text.length;
    let i = 0, depth = 0;
    const push = (cls, s) => { if (s) tokens.push([cls, s]); };

    // Reads up to the next top-level `{`, `;` or `}`, skipping strings,
    // comments and parentheses, and returns the end index.
    const scanChunk = (from) => {
      let j = from, parens = 0;
      while (j < n) {
        const c = text[j];
        if (c === "/" && text[j + 1] === "*") { const e = text.indexOf("*/", j + 2); j = e < 0 ? n : e + 2; continue; }
        if (c === '"' || c === "'") { j++; while (j < n && text[j] !== c) { if (text[j] === "\\") j++; j++; } j++; continue; }
        if (c === "(") parens++;
        else if (c === ")") parens = Math.max(0, parens - 1);
        else if (parens === 0 && (c === "{" || c === ";" || c === "}")) return j;
        j++;
      }
      return n;
    };

    const emitValue = (s) => {
      const re = /(\/\*[\s\S]*?\*\/)|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(#[0-9a-fA-F]{3,8}\b|-?\d*\.?\d+(?:[a-zA-Z%]+)?)|(![ \t]*important)/g;
      let last = 0, m;
      while ((m = re.exec(s))) {
        push(null, s.slice(last, m.index));
        push(m[1] ? "tok-comment" : m[2] ? "tok-string" : m[3] ? "tok-number" : "tok-keyword", m[0]);
        last = m.index + m[0].length;
      }
      push(null, s.slice(last));
    };

    const emitWithComments = (s, cls) => {
      const re = /\/\*[\s\S]*?\*\//g;
      let last = 0, m;
      while ((m = re.exec(s))) { push(cls, s.slice(last, m.index)); push("tok-comment", m[0]); last = m.index + m[0].length; }
      push(cls, s.slice(last));
    };

    while (i < n) {
      const c = text[i];
      if (c === "}") { push(null, "}"); depth = Math.max(0, depth - 1); i++; continue; }
      if (c === "{") { push(null, "{"); depth++; i++; continue; }
      if (c === ";") { push(null, ";"); i++; continue; }
      const end = scanChunk(i);
      const chunk = text.slice(i, end);
      const terminator = text[end];
      const lead = chunk.match(/^\s*/)[0];
      push(null, lead);
      const body = chunk.slice(lead.length);
      if (body.startsWith("@")) {
        const m = body.match(/^@[\w-]+/);
        push("tok-atrule", m[0]);
        emitValue(body.slice(m[0].length));
      } else if (terminator === "{" || depth === 0) {
        emitWithComments(body, "tok-selector");
      } else {
        const colon = body.indexOf(":");
        if (colon < 0) emitWithComments(body, null);
        else { emitWithComments(body.slice(0, colon), "tok-prop"); push(null, ":"); emitValue(body.slice(colon + 1)); }
      }
      i = end;
    }
    return tokens;
  },

  // ---- HTML ---------------------------------------------------------------------
  html(text) {
    const tokens = [];
    const n = text.length;
    let i = 0;
    const push = (cls, s) => { if (s) tokens.push([cls, s]); };
    while (i < n) {
      const lt = text.indexOf("<", i);
      if (lt < 0) { push(null, text.slice(i)); break; }
      push(null, text.slice(i, lt));
      i = lt;
      if (text.startsWith("<!--", i)) {
        let end = text.indexOf("-->", i + 4); end = end < 0 ? n : end + 3;
        push("tok-comment", text.slice(i, end)); i = end; continue;
      }
      if (text[i + 1] === "!" || text[i + 1] === "?") {
        let end = text.indexOf(">", i); end = end < 0 ? n : end + 1;
        push("tok-doctype", text.slice(i, end)); i = end; continue;
      }
      const open = /^<\/?[A-Za-z][\w:-]*/.exec(text.slice(i, i + 80));
      if (!open) { push(null, "<"); i++; continue; }
      push("tok-tag", open[0]);
      const tagName = open[0].replace(/^<\/?/, "").toLowerCase();
      const isClosing = open[0][1] === "/";
      i += open[0].length;
      // attributes
      const reAttr = /(\s+)|([^\s=>\/"']+)|(=)|("[^"]*"?|'[^']*'?)|(\/)/y;
      while (i < n && text[i] !== ">") {
        reAttr.lastIndex = i;
        const m = reAttr.exec(text);
        if (!m || !m[0]) { push(null, text[i]); i++; continue; }
        push(m[2] ? "tok-attr" : m[4] ? "tok-value" : m[5] ? "tok-tag" : null, m[0]);
        i += m[0].length;
      }
      if (i < n) { push("tok-tag", ">"); i++; }
      if (!isClosing && (tagName === "script" || tagName === "style")) {
        const closeRe = new RegExp("</" + tagName, "i");
        const rest = text.slice(i);
        const at = rest.search(closeRe);
        const inner = at < 0 ? rest : rest.slice(0, at);
        const sub = (tagName === "script" ? this.js(inner) : this.css(inner)) || [[null, inner]];
        for (const t of sub) tokens.push(t);
        i += inner.length;
      }
    }
    return tokens;
  },

  // ---- pretty printing ---------------------------------------------------------------
  pretty(text, lang) {
    try {
      if (lang === "json") return JSON.stringify(JSON.parse(text), null, 2);
      if (lang === "css") return this.prettyCSS(text);
      if (lang === "js") return this.prettyJS(text);
    } catch (_) {}
    return null;
  },

  prettyCSS(text) {
    const tokens = this.css(text);
    let out = "", indent = 0, atLineStart = true;
    const newline = () => { out = out.replace(/[ \t]+$/, ""); if (!out.endsWith("\n")) out += "\n"; atLineStart = true; };
    const write = (s) => { if (atLineStart) { s = s.replace(/^\s+/, ""); if (!s) return; out += "  ".repeat(indent); atLineStart = false; } out += s; };
    for (const [cls, raw] of tokens) {
      if (cls === null && raw === "{") { out = out.replace(/\s+$/, ""); write(" {"); indent++; newline(); continue; }
      if (cls === null && raw === "}") { newline(); indent = Math.max(0, indent - 1); write("}"); newline(); if (indent === 0) out += "\n"; continue; }
      if (cls === null && raw === ";") { write(";"); newline(); continue; }
      if (cls === "tok-comment") { write(raw); newline(); continue; }
      write(raw.replace(/\s+/g, " "));
    }
    return out.replace(/\n{3,}/g, "\n\n").trim() + "\n";
  },

  prettyJS(text) {
    const tokens = this.js(text);
    let out = "", indent = 0, atLineStart = true, parens = 0;
    const parenStack = [];
    const newline = () => { out = out.replace(/[ \t]+$/, ""); if (!out.endsWith("\n")) out += "\n"; atLineStart = true; };
    const write = (s) => { if (atLineStart) { out += "  ".repeat(indent); atLineStart = false; } out += s; };
    const nextSignificant = (k) => { for (let j = k + 1; j < tokens.length; j++) { if (tokens[j][1].trim()) return tokens[j][1]; } return ""; };
    for (let k = 0; k < tokens.length; k++) {
      const [cls, raw] = tokens[k];
      if (cls === null && !raw.trim()) { if (!atLineStart && !out.endsWith(" ")) out += " "; continue; }
      if (cls === "tok-comment") { write(raw); if (raw.startsWith("//") || raw.includes("\n")) newline(); continue; }
      if (cls !== null) { write(raw); continue; }
      if (raw === "{") { out = out.replace(/[ \t]+$/, ""); write(out.endsWith("\n") || /[({\[,]$/.test(out) ? "{" : " {"); parenStack.push(parens); parens = 0; indent++; newline(); continue; }
      if (raw === "}") {
        newline(); indent = Math.max(0, indent - 1); parens = parenStack.length ? parenStack.pop() : 0; write("}");
        const next = nextSignificant(k);
        if (/^(?:else|catch|finally|while)$/.test(next)) out += " ";
        else if (!/^[,;).\]]$/.test(next) && next !== "(") newline();
        continue;
      }
      if (raw === ";") { write(";"); if (parens === 0) newline(); continue; }
      if (raw === "(" || raw === "[") parens++;
      if (raw === ")" || raw === "]") parens = Math.max(0, parens - 1);
      if (raw === ",") { write(", "); continue; }
      write(raw);
    }
    return out.replace(/ +\n/g, "\n").replace(/, +/g, ", ").trim() + "\n";
  },
};
