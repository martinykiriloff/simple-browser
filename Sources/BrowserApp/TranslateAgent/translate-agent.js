// Page translation agent. Runs in its own isolated content world in the main
// frame: page script cannot see it, and it cannot be confused by the page's
// own globals.
//
// It never talks to Google. It cuts the page into sentence-sized pieces of
// HTML, the app translates them, and it puts the translations back into the
// same elements -- the page's own <a>, <b> and <button> nodes, moved, not
// copied -- so links, handlers and styles keep working, and "Show Original"
// can put every original text node back where it was.
(function () {
  'use strict';
  if (window.__sbTranslate) return;
  var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.translate;
  function post(message) {
    try { if (handler) handler.postMessage(message); } catch (e) { /* the view is going away */ }
  }

  function set(names) {
    var result = {};
    names.split(' ').forEach(function (name) { result[name] = true; });
    return result;
  }
  // Never translated, and never looked inside.
  var SKIP = set('script style noscript template textarea select option svg math iframe canvas video audio object embed head title pre');
  // Kept as they are, in place, inside a translated sentence.
  var OPAQUE = set('code kbd samp var tt img br wbr input select textarea svg math canvas video audio iframe object embed');
  // Part of a sentence rather than a block of their own.
  var INLINE = set('a abbr b bdi bdo big br button cite code data del dfn em font i img ins kbd label mark q s samp small span strike strong sub sup time tt u var wbr input select');
  var VOID = set('br wbr img input');

  function refuses(el) {
    if (el.getAttribute('translate') === 'no') return true;
    if (el.classList && (el.classList.contains('notranslate') || el.classList.contains('skiptranslate'))) return true;
    return el.isContentEditable === true;
  }

  function isOpaque(el) {
    return !!OPAQUE[el.localName] || refuses(el);
  }

  // Text or an inline element whose whole subtree is inline too.
  var inlineCache = new WeakMap();
  function isInline(node) {
    if (node.nodeType === 3 || node.nodeType === 8) return true;
    if (node.nodeType !== 1) return false;
    if (inlineCache.has(node)) return inlineCache.get(node);
    var el = node, result;
    // Only elements that sit inside a sentence; a refusing or opaque one is
    // carried along whole. Blocks, opaque or not, end the sentence.
    if (!INLINE[el.localName]) result = false;
    else if (isOpaque(el)) result = true;
    else {
      result = true;
      for (var child = el.firstChild; child; child = child.nextSibling) {
        if (!isInline(child)) { result = false; break; }
      }
    }
    inlineCache.set(node, result);
    return result;
  }

  var HAS_WORDS = /\p{L}/u;

  function textOf(nodes) {
    return nodes.map(function (n) { return n.textContent || ''; }).join('');
  }

  function escape(text) {
    return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  // ---------------------------------------------------------------- units

  var units = new Map();            // id → unit
  var nextId = 1;
  var taken = new WeakSet();        // nodes already in a unit, original or translated
  var active = false;
  var target = '';

  // Runs of inline siblings between blocks, found depth-first.
  function gather(root, out) {
    if (root.nodeType === 1 && (SKIP[root.localName] || refuses(root))) return;
    var run = [];
    function flush() {
      if (run.length && !run.some(function (n) { return taken.has(n); }) && HAS_WORDS.test(textOf(run))) out.push(run);
      run = [];
    }
    for (var child = root.firstChild; child; child = child.nextSibling) {
      if (isInline(child)) run.push(child);
      else {
        flush();
        if (child.nodeType === 1) gather(child, out);
      }
    }
    flush();
    if (root.nodeType === 1 && root.shadowRoot) gather(root.shadowRoot, out);
  }

  function serialize(nodes, map) {
    var html = '';
    nodes.forEach(function (node) {
      if (node.nodeType === 3) {
        html += escape(node.data.replace(/\s+/g, ' '));
      } else if (node.nodeType === 1) {
        var i = map.length;
        map.push(node);
        if (VOID[node.localName]) html += '<a i=' + i + '></a>';
        // The words go along for context; the element itself comes back untouched.
        else if (isOpaque(node)) html += '<a i=' + i + ' class=notranslate>' + escape((node.textContent || '').replace(/\s+/g, ' ')) + '</a>';
        else html += '<a i=' + i + '>' + serialize(Array.prototype.slice.call(node.childNodes), map) + '</a>';
      }
    });
    return html;
  }

  function markTaken(nodes) {
    nodes.forEach(function (node) {
      taken.add(node);
      if (node.nodeType === 1 && !isOpaque(node)) markTaken(Array.prototype.slice.call(node.childNodes));
    });
  }

  var ATTRIBUTES = ['placeholder', 'title', 'alt', 'aria-label'];

  function gatherAttributes(out) {
    var selector = ATTRIBUTES.map(function (a) { return '[' + a + ']'; }).join(',') + ',input[type=submit][value],input[type=button][value]';
    Array.prototype.forEach.call(document.querySelectorAll(selector), function (el) {
      if (el.closest('[translate=no], .notranslate, script, style, svg')) return;
      var names = ATTRIBUTES.filter(function (a) { return el.hasAttribute(a); });
      if (el.localName === 'input' && (el.type === 'submit' || el.type === 'button')) names.push('value');
      names.forEach(function (name) {
        var key = name + '\u0000';
        el.__sbAttributes = el.__sbAttributes || {};
        if (el.__sbAttributes[key]) return;
        var value = el.getAttribute(name) || '';
        if (!HAS_WORDS.test(value)) return;
        el.__sbAttributes[key] = true;
        out.push({ kind: 'attribute', el: el, name: name, original: value });
      });
    });
  }

  function rectTop(unit) {
    var el = unit.kind === 'attribute' ? unit.el : unit.nodes[0].parentElement;
    if (!el || !el.getBoundingClientRect) return Infinity;
    var top = el.getBoundingClientRect().top;
    // What is on screen first, then what is below it, then what is above.
    return top < 0 ? 1e9 - top : top;
  }

  function collect() {
    var runs = [];
    if (document.body) gather(document.body, runs);
    var found = runs.map(function (nodes) {
      var map = [];
      var html = serialize(nodes, map).trim();
      markTaken(nodes);
      return { kind: 'text', nodes: nodes, map: map, html: html };
    });
    gatherAttributes(found);
    found.forEach(function (unit) {
      unit.id = nextId++;
      unit.top = rectTop(unit);
      if (unit.kind === 'attribute') unit.html = escape(unit.original);
      units.set(unit.id, unit);
    });
    found.sort(function (a, b) { return a.top - b.top; });
    return found.map(function (unit) { return { id: unit.id, html: unit.html }; });
  }

  // ---------------------------------------------------------------- apply

  var parser = new DOMParser();

  function rebuild(unit, html) {
    var parsed = parser.parseFromString('<!doctype html><body>' + html, 'text/html').body;
    var used = new Set();
    unit.saved = unit.map.map(function (el) { return Array.prototype.slice.call(el.childNodes); });

    function build(nodes) {
      var out = [];
      nodes.forEach(function (p) {
        if (p.nodeType === 3) { out.push(document.createTextNode(p.data)); return; }
        if (p.nodeType !== 1) return;
        var i = parseInt(p.getAttribute('i'), 10);
        var original = unit.map[i];
        if (!original) { out.push.apply(out, build(Array.prototype.slice.call(p.childNodes))); return; }
        // Google occasionally repeats a tag; the second use is a copy.
        var el = used.has(i) ? original.cloneNode(isOpaque(original) || VOID[original.localName]) : original;
        used.add(i);
        if (!isOpaque(original) && !VOID[original.localName]) {
          el.replaceChildren.apply(el, build(Array.prototype.slice.call(p.childNodes)));
        }
        out.push(el);
      });
      return out;
    }

    var built = build(Array.prototype.slice.call(parsed.childNodes));
    // An image or line break Google dropped still belongs to the sentence.
    unit.map.forEach(function (el, i) {
      if (!used.has(i) && (VOID[el.localName] || isOpaque(el)) && unit.nodes.indexOf(el) !== -1) built.push(el);
    });
    // Whitespace at the edges of the run separated it from its neighbours.
    var first = unit.nodes[0], last = unit.nodes[unit.nodes.length - 1];
    if (first.nodeType === 3 && /^\s/.test(first.data)) built.unshift(document.createTextNode(' '));
    if (last.nodeType === 3 && /\s$/.test(last.data)) built.push(document.createTextNode(' '));
    swap(unit.nodes, built);
    unit.current = built;
    markTaken(built);
  }

  function swap(oldNodes, newNodes) {
    var anchor = oldNodes.filter(function (n) { return n.parentNode; })[0];
    if (!anchor) return false;
    var parent = anchor.parentNode;
    var marker = document.createComment('');
    parent.insertBefore(marker, anchor);
    oldNodes.forEach(function (n) {
      if (newNodes.indexOf(n) === -1 && n.parentNode === parent) parent.removeChild(n);
    });
    var fragment = document.createDocumentFragment();
    newNodes.forEach(function (n) { fragment.appendChild(n); });
    parent.insertBefore(fragment, marker);
    parent.removeChild(marker);
    return true;
  }

  function apply(results) {
    var applied = 0;
    quiet(function () {
      results.forEach(function (result) {
        var unit = units.get(result.id);
        if (!unit || unit.current || unit.translated !== undefined) return;
        try {
          if (unit.kind === 'attribute') {
            var text = parser.parseFromString('<!doctype html><body>' + result.html, 'text/html').body.textContent;
            unit.el.setAttribute(unit.name, text);
            if (unit.name === 'value') unit.el.value = text;
            unit.translated = text;
          } else {
            if (!unit.nodes.some(function (n) { return n.isConnected; })) return;   // the page replaced it meanwhile
            rebuild(unit, result.html);
          }
          applied++;
        } catch (e) { /* one odd sentence must not stop the rest */ }
      });
    });
    return applied;
  }

  function restore() {
    active = false;
    stopWatching();
    quiet(function () {
      units.forEach(function (unit) {
        if (unit.kind === 'attribute') {
          if (unit.translated !== undefined && unit.el.getAttribute(unit.name) === unit.translated) {
            unit.el.setAttribute(unit.name, unit.original);
            if (unit.name === 'value') unit.el.value = unit.original;
          }
          if (unit.el.__sbAttributes) unit.el.__sbAttributes = {};
          return;
        }
        if (!unit.current) return;
        // Children first: an element's saved children may be translated
        // elements themselves, restored in the same pass.
        unit.map.forEach(function (el, i) { el.replaceChildren.apply(el, unit.saved[i]); });
        swap(unit.current, unit.nodes);
      });
    });
    units.clear();
    taken = new WeakSet();
    inlineCache = new WeakMap();
    target = '';
  }

  // ---------------------------------------------------------------- watching

  var observer = null, moreTimer = 0;

  function quiet(body) {
    body();
    if (observer) observer.takeRecords();   // our own changes are not new content
  }

  function startWatching() {
    if (observer) return;
    observer = new MutationObserver(function (records) {
      if (!active) return;
      var added = records.some(function (r) {
        return Array.prototype.some.call(r.addedNodes, function (n) { return !taken.has(n) && HAS_WORDS.test(n.textContent || ''); });
      });
      if (!added) return;
      clearTimeout(moreTimer);
      moreTimer = setTimeout(function () { post({ kind: 'more' }); }, 400);
    });
    observer.observe(document.documentElement, { childList: true, subtree: true });
  }

  function stopWatching() {
    if (observer) observer.disconnect();
    observer = null;
    clearTimeout(moreTimer);
  }

  // ---------------------------------------------------------------- language

  function declaredLanguage() {
    var html = document.documentElement;
    var meta = document.querySelector('meta[http-equiv="content-language" i]');
    return (html.getAttribute('lang') || html.getAttribute('xml:lang') || (meta && meta.content) || '').split(',')[0].trim();
  }

  function optedOut() {
    if (document.documentElement.getAttribute('translate') === 'no') return true;
    if (document.documentElement.classList.contains('notranslate')) return true;
    return !!document.querySelector('meta[name=google][content=notranslate i], meta[name=google][value=notranslate i]');
  }

  function sample() {
    // A few hundred characters of real prose, for detecting the language
    // when the page does not declare one, or declares it wrongly.
    var text = '', walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
    while (text.length < 400 && walker.nextNode()) {
      var node = walker.currentNode, parent = node.parentElement;
      if (!parent || SKIP[parent.localName] || OPAQUE[parent.localName]) continue;
      var words = node.data.replace(/\s+/g, ' ').trim();
      if (words.length > 20 && HAS_WORDS.test(words)) text += words + ' ';
    }
    return text.trim();
  }

  function report() {
    post({ kind: 'language', declared: declaredLanguage(), optedOut: optedOut(), sample: sample() });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', report, { once: true });
  else report();

  window.__sbTranslate = {
    // Pieces not translated yet, what is on screen first. Starts watching
    // for content the page adds later.
    collect: function (language) {
      active = true;
      target = language;
      startWatching();
      return collect();
    },
    apply: function (results) { return active ? apply(results) : 0; },
    restore: restore,
    state: function () {
      var translated = 0;
      units.forEach(function (u) { if (u.current || u.translated !== undefined) translated++; });
      return { active: active, target: target, units: units.size, translated: translated };
    }
  };
})();
