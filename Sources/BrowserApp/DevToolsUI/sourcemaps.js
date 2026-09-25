// SimpleBrowser DevTools — source maps (revision 3).
//
// Maps between the code the engine runs (bundled, minified, transpiled) and
// the files the developer wrote. Used for: showing original files in the
// Sources navigator, translating a paused location and console stack frames
// back to original positions, and translating a breakpoint set in an
// original file to the generated position the engine understands.
//
// All public positions are 1-based lines and columns, like the rest of the
// UI; the spec's 0-based numbers stay inside this file.
"use strict";

const SourceMaps = window.SBSourceMaps = {
  maps: new Map(),          // generated URL → parsed map
  byOriginal: new Map(),    // original URL → generated URL
  loading: new Map(),       // generated URL → Promise
  listeners: [],
  MAX_BYTES: 40 * 1024 * 1024,
  BASE64: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/",

  onLoad(fn) { this.listeners.push(fn); },

  isOriginal(url) { return this.byOriginal.has(url); },

  // ---- loading ------------------------------------------------------------------
  load(generatedURL, mapURL) {
    if (!generatedURL || !mapURL) return Promise.resolve(null);
    if (this.maps.has(generatedURL)) return Promise.resolve(this.maps.get(generatedURL));
    if (this.loading.has(generatedURL)) return this.loading.get(generatedURL);
    const promise = this.fetchAndParse(generatedURL, mapURL)
      .then((map) => {
        if (map) {
          this.maps.set(generatedURL, map);
          for (const source of map.sources) this.byOriginal.set(source.url, generatedURL);
          for (const fn of this.listeners) { try { fn(generatedURL, map); } catch (_) {} }
        }
        return map;
      })
      .catch((error) => { DevTools.trace("sourcemap failed", generatedURL, String(error && error.message || error)); return null; })
      .finally(() => this.loading.delete(generatedURL));
    this.loading.set(generatedURL, promise);
    return promise;
  },

  // Resolves once a map that is already being fetched has arrived (or failed).
  ready(generatedURL, timeoutMs = 2500) {
    const pending = this.loading.get(generatedURL);
    if (!pending) return Promise.resolve();
    return Promise.race([pending, new Promise((r) => setTimeout(r, timeoutMs))]);
  },

  async fetchAndParse(generatedURL, mapURL) {
    let text;
    let base = generatedURL;
    if (mapURL.startsWith("data:")) {
      const comma = mapURL.indexOf(",");
      const meta = mapURL.slice(5, comma);
      const payload = mapURL.slice(comma + 1);
      text = /;base64/i.test(meta) ? new TextDecoder().decode(Uint8Array.from(atob(payload), (c) => c.charCodeAt(0))) : decodeURIComponent(payload);
    } else {
      base = new URL(mapURL, generatedURL).href;
      const result = await DevTools.rpc("SourceMaps.fetch", { url: base });
      text = result.text;
    }
    if (!text || text.length > this.MAX_BYTES) return null;
    if (text.startsWith(")]}")) text = text.slice(text.indexOf("\n") + 1);      // XSSI guard
    return this.parse(JSON.parse(text), base, generatedURL);
  },

  parse(json, mapURL, generatedURL) {
    if (json.sections) {
      // Index maps: flatten each section at its offset.
      const merged = { generatedURL, sources: [], lines: [] };
      for (const section of json.sections) {
        const part = this.parse(section.map, mapURL, generatedURL);
        const offsetLine = section.offset.line, offsetColumn = section.offset.column;
        const sourceBase = merged.sources.length;
        merged.sources.push(...part.sources);
        part.lines.forEach((segments, line) => {
          const target = line + offsetLine;
          merged.lines[target] = (merged.lines[target] || []).concat(segments.map((s) => [s[0] + (line === 0 ? offsetColumn : 0), s[1] + sourceBase, s[2], s[3], s[4]]));
        });
      }
      this.index(merged);
      return merged;
    }

    const root = json.sourceRoot ? json.sourceRoot.replace(/\/?$/, "/") : "";
    const sources = (json.sources || []).map((source, index) => {
      let url = source || "";
      try { url = new URL(root + url, mapURL).href; } catch (_) { url = root + url; }
      return { url, content: json.sourcesContent ? json.sourcesContent[index] : null };
    });
    const names = json.names || [];

    const lines = [];
    let line = [];
    let source = 0, sourceLine = 0, sourceColumn = 0, name = 0, generatedColumn = 0;
    const mappings = json.mappings || "";
    let i = 0;
    const fields = [];
    while (i <= mappings.length) {
      const ch = mappings[i];
      if (ch === undefined || ch === ";" || ch === ",") {
        if (fields.length) {
          generatedColumn += fields[0];
          if (fields.length >= 4) {
            source += fields[1]; sourceLine += fields[2]; sourceColumn += fields[3];
            if (fields.length >= 5) name += fields[4];
            line.push([generatedColumn, source, sourceLine, sourceColumn, fields.length >= 5 ? names[name] : null]);
          }
          fields.length = 0;
        }
        if (ch === ";" || ch === undefined) { lines.push(line); line = []; generatedColumn = 0; }
        i++;
        continue;
      }
      // one VLQ value
      let value = 0, shift = 0, digit;
      do {
        digit = this.BASE64.indexOf(mappings[i++]);
        if (digit < 0) throw new Error("Invalid source map mappings");
        value += (digit & 31) << shift;
        shift += 5;
      } while (digit & 32);
      fields.push(value & 1 ? -(value >> 1) : value >> 1);
    }
    const map = { generatedURL, sources, lines };
    this.index(map);
    return map;
  },

  // original source index → original line → generated positions, earliest first
  index(map) {
    map.reverse = map.sources.map(() => new Map());
    map.lines.forEach((segments, generatedLine) => {
      segments.sort((a, b) => a[0] - b[0]);
      for (const s of segments) {
        const byLine = map.reverse[s[1]];
        if (!byLine) continue;
        if (!byLine.has(s[2])) byLine.set(s[2], []);
        byLine.get(s[2]).push({ line: generatedLine, column: s[0], sourceColumn: s[3] });
      }
    });
  },

  // ---- lookups ---------------------------------------------------------------------------
  // Generated position → original. Null when the file has no map or the
  // position precedes every mapping on its line.
  original(generatedURL, line, column) {
    const map = this.maps.get(generatedURL);
    if (!map) return null;
    const segments = map.lines[line - 1];
    if (!segments || !segments.length) return null;
    const target = Math.max(0, (column || 1) - 1);
    let lo = 0, hi = segments.length - 1, found = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (segments[mid][0] <= target) { found = mid; lo = mid + 1; } else hi = mid - 1;
    }
    if (found < 0) found = 0;
    const s = segments[found];
    const source = map.sources[s[1]];
    if (!source) return null;
    return { url: source.url, line: s[2] + 1, column: s[3] + 1, name: s[4] || null };
  },

  // Original line → the first generated position that maps to it.
  generated(originalURL, line) {
    const generatedURL = this.byOriginal.get(originalURL);
    const map = generatedURL && this.maps.get(generatedURL);
    if (!map) return null;
    const sourceIndex = map.sources.findIndex((s) => s.url === originalURL);
    if (sourceIndex < 0) return null;
    const byLine = map.reverse[sourceIndex];
    // A line with no code of its own (a lone brace, a comment) binds to the
    // next line that has some, as a debugger would.
    for (let probe = line - 1; probe < line + 20; probe++) {
      const positions = byLine.get(probe);
      if (positions && positions.length) {
        const first = positions.slice().sort((a, b) => a.line - b.line || a.column - b.column)[0];
        return { url: generatedURL, line: first.line + 1, column: first.column + 1, originalLine: probe + 1 };
      }
    }
    return null;
  },

  contentOf(originalURL) {
    const generatedURL = this.byOriginal.get(originalURL);
    const map = generatedURL && this.maps.get(generatedURL);
    const source = map && map.sources.find((s) => s.url === originalURL);
    return source ? source.content : null;
  },

  // Finds a `//# sourceMappingURL=` comment near the end of a script.
  declaredIn(text) {
    if (!text) return null;
    const tail = text.slice(-4096);
    const matches = Array.from(tail.matchAll(/\/[/*][#@]\s*sourceMappingURL=([^\s*]+)/g));
    return matches.length ? matches[matches.length - 1][1] : null;
  },
};
