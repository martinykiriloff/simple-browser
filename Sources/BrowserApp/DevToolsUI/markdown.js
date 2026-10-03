// Keel DevTools — Markdown for "Copy for AI": requests, console
// messages and reports as compact, self-describing text an assistant (or a
// bug report) can use without the DevTools in front of it.
"use strict";

const Markdown = window.Markdown = {
  // Secrets never leave in a copy meant to be pasted elsewhere.
  SECRET_HEADERS: /^(cookie|set-cookie|authorization|proxy-authorization|x-api-key|x-auth-token|x-csrf-token)$/i,

  // A code fence longer than any backtick run inside, so content cannot end it.
  fence(text, lang = "") {
    const longest = Math.max(2, ...(String(text).match(/`+/g) || []).map((m) => m.length));
    const ticks = "`".repeat(longest + 1);
    return ticks + lang + "\n" + String(text).replace(/\n$/, "") + "\n" + ticks;
  },

  truncate(text, max) {
    text = String(text ?? "");
    return text.length > max ? text.slice(0, max) + `\n… (${text.length - max} more characters truncated)` : text;
  },

  // `| a | b |` rows; pipes and newlines in cells are escaped.
  table(columns, rows) {
    const cell = (v) => String(v ?? "").replace(/\|/g, "\\|").replace(/\n/g, " ");
    return ["| " + columns.map(cell).join(" | ") + " |", "|" + columns.map(() => " --- ").join("|") + "|",
      ...rows.map((r) => "| " + r.map(cell).join(" | ") + " |")].join("\n");
  },

  headers(headers) {
    return Object.keys(headers || {}).sort().map((k) => `${k}: ${this.SECRET_HEADERS.test(k) ? "<redacted>" : headers[k]}`).join("\n");
  },

  // json/html/css/js for a fence, from a MIME type.
  langFor(mime) {
    mime = (mime || "").toLowerCase();
    if (mime.includes("json")) return "json";
    if (mime.includes("html")) return "html";
    if (mime.includes("css")) return "css";
    if (mime.includes("javascript") || mime.includes("ecmascript")) return "js";
    if (mime.includes("xml") || mime.includes("svg")) return "xml";
    return "";
  },
};
