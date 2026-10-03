// Keel DevTools — a syntax-highlighted code input (the console
// prompt, snippets) and the side-effect check behind eager evaluation and
// autocomplete.
//
// CodeInput keeps a plain <textarea> (so selection, undo, IME and the
// system's text services all work) and paints the highlighted text in a
// <pre> behind it; the textarea's own text is transparent.
"use strict";

const CodeInput = window.CodeInput = {
  attach(textarea, { language = "js", gutter = false } = {}) {
    const wrap = h("div", { class: "code-input" + (gutter ? " with-gutter" : "") });
    const mirror = h("pre", { class: "code-input-mirror", "aria-hidden": "true" });
    const lines = gutter ? h("div", { class: "code-input-gutter", "aria-hidden": "true" }) : null;
    textarea.replaceWith(wrap);
    if (lines) wrap.appendChild(lines);
    const stack = h("div", { class: "code-input-stack" }, mirror, textarea);
    wrap.appendChild(stack);
    textarea.classList.add("code-input-text");
    textarea.spellcheck = false;
    textarea.setAttribute("autocomplete", "off");
    textarea.setAttribute("autocapitalize", "off");
    const paint = () => {
      const text = textarea.value;
      mirror.textContent = "";
      const tokens = text.length < 200000 ? Highlighter.tokenize(text, language) : null;
      if (tokens) for (const [cls, raw] of tokens) mirror.appendChild(cls ? h("span", { class: cls }, raw) : document.createTextNode(raw));
      else mirror.textContent = text;
      // A trailing newline needs something after it to take up a line.
      mirror.appendChild(document.createTextNode("\n"));
      if (lines) {
        const count = text.split("\n").length;
        if (lines.childElementCount !== count) {
          lines.textContent = "";
          for (let i = 1; i <= count; i++) lines.appendChild(h("div", {}, String(i)));
        }
      }
    };
    const sync = () => { mirror.scrollTop = textarea.scrollTop; mirror.scrollLeft = textarea.scrollLeft; if (lines) lines.scrollTop = textarea.scrollTop; };
    textarea.addEventListener("input", paint);
    textarea.addEventListener("scroll", sync);
    paint();
    return { wrap, mirror, paint, sync, textarea };
  },

  // Brackets still open at the end of `text`, or an unterminated template
  // or block comment: Enter then continues the input instead of running it.
  isIncomplete(text) {
    const tokens = Highlighter.tokenize(text, "js");
    if (!tokens) return false;
    let depth = 0;
    for (const [cls, raw] of tokens) {
      if (cls === "tok-string" && raw[0] === "`" && (raw.length === 1 || !raw.endsWith("`") || raw.endsWith("\\`"))) return true;
      if (cls === "tok-comment" && raw.startsWith("/*") && !raw.endsWith("*/")) return true;
      if (cls !== null) continue;
      for (const ch of raw) {
        if (ch === "(" || ch === "[" || ch === "{") depth++;
        else if (ch === ")" || ch === "]" || ch === "}") depth--;
      }
    }
    return depth > 0;
  },
};

// ---- side-effect check -----------------------------------------------------------------------
// Best effort, like Chrome's eager evaluation: property reads, operators,
// literals, arrow functions, and calls only to functions known to change
// nothing. Anything else (assignment, ++, delete, new on unknown classes,
// tagged templates, calling a computed value) is refused.
const EagerEval = window.EagerEval = {
  SAFE_CALLS: new Set(("abs acos asin atan atan2 cbrt ceil cos cosh exp floor fround hypot log log10 log1p log2 max min pow round sign sin " +
    "sinh sqrt tan tanh trunc random slice substring substr toUpperCase toLowerCase toLocaleUpperCase toLocaleLowerCase trim trimStart " +
    "trimEnd padStart padEnd includes indexOf lastIndexOf startsWith endsWith at charAt charCodeAt codePointAt split concat join repeat " +
    "match matchAll search normalize localeCompare toString toFixed toPrecision toExponential toISOString toJSON toLocaleString " +
    "toLocaleDateString toLocaleTimeString toDateString toTimeString toUTCString getTime getFullYear getMonth getDate getDay getHours " +
    "getMinutes getSeconds getMilliseconds getTimezoneOffset getUTCFullYear getUTCMonth getUTCDate getUTCHours valueOf keys values entries " +
    "map filter find findIndex findLast findLastIndex some every reduce reduceRight flat flatMap toSorted toReversed toSpliced with has get " +
    "getAll getItem key getAttribute getAttributeNames hasAttribute hasAttributes hasChildNodes querySelector querySelectorAll getElementById " +
    "getElementsByClassName getElementsByTagName getElementsByName closest matches contains compareDocumentPosition isEqualNode isSameNode " +
    "getBoundingClientRect getClientRects getComputedStyle getPropertyValue getPropertyPriority item namedItem isArray from of stringify " +
    "parse isNaN isFinite isInteger isSafeInteger parseInt parseFloat Number String Boolean Date Array Object getOwnPropertyNames " +
    "getOwnPropertySymbols getOwnPropertyDescriptor getOwnPropertyDescriptors getPrototypeOf is isFrozen isSealed isExtensible fromEntries " +
    "hasOwn hasOwnProperty isPrototypeOf propertyIsEnumerable encodeURIComponent decodeURIComponent encodeURI decodeURI escape unescape " +
    "atob btoa now $ $$ $x structuredClone test exec fromCharCode fromCodePoint raw supports escape matchMedia getEntries getEntriesByType " +
    "getEntriesByName getRootNode assignedNodes assignedElements checkValidity getModifierState toSorted").split(" ")),
  SAFE_CONSTRUCTORS: new Set(["Date", "Array", "Map", "Set", "WeakMap", "WeakSet", "URL", "URLSearchParams", "RegExp", "Object", "Error",
    "TypeError", "RangeError", "Intl", "DOMParser", "Uint8Array", "Int8Array", "Uint16Array", "Int16Array", "Uint32Array", "Int32Array",
    "Float32Array", "Float64Array", "ArrayBuffer", "Blob", "TextEncoder", "TextDecoder", "Number", "String", "Boolean"]),
  CALLBACK_METHODS: new Set(["map", "filter", "find", "findIndex", "findLast", "findLastIndex", "some", "every", "reduce", "reduceRight", "flatMap", "toSorted"]),
  STATEMENTS: /\b(?:delete|await|yield|function|class|import|export|throw|var|let|const|debugger|with|while|for|do|if|switch|try|catch|return|super|async)\b/,

  isSafe(expression) {
    const text = String(expression || "").trim();
    if (!text || text.length > 2000) return false;
    const tokens = Highlighter.tokenize(text, "js");
    if (!tokens) return false;
    // Strings, regexes and comments become placeholders, so what is left is code.
    let code = "";
    let previous = "";
    for (const [cls, raw] of tokens) {
      if (cls === "tok-string") {
        if (raw[0] === "`" && (raw.includes("${") || /[\w$)\]]\s*$/.test(previous))) return false;   // interpolation / tagged template
        code += '""';
      } else if (cls === "tok-regex") code += '""';
      else if (cls === "tok-comment") code += " ";
      else code += raw;
      if (raw.trim()) previous = code;
    }
    if (this.STATEMENTS.test(code)) return false;
    if (/\+\+|--/.test(code)) return false;
    if (/(?:^|[^=!<>])=(?![=>])/.test(code)) return false;
    if (/(?:>>>?|<<|\*\*|&&|\|\||\?\?)=/.test(code)) return false;
    if (/[)\]]\s*\(/.test(code) || /\?\.\s*\(/.test(code)) return false;
    for (const m of code.matchAll(/\bnew\s+([\w$.]+)/g)) if (!this.SAFE_CONSTRUCTORS.has(m[1].split(".")[0])) return false;
    for (const m of code.matchAll(/([\w$]+)\s*\(/g)) {
      const name = m[1];
      const before = code.slice(0, m.index).trimEnd();
      if (before.endsWith("new")) continue;
      if (!this.SAFE_CALLS.has(name)) return false;
      if (this.CALLBACK_METHODS.has(name)) {
        // The callback must be written right here, so its body is checked too.
        const args = code.slice(m.index + m[0].length);
        if (!/^\s*(?:\)|(?:[\w$]+|\([^()]*\))\s*=>)/.test(args)) return false;
      }
    }
    return true;
  },
};
