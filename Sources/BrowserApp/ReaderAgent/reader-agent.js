// Reader agent. Runs in its own isolated world, in the main frame only.
//
// Two jobs: say whether the page has an article worth a Reader button, and
// when asked, hand the article over as clean markup. "Clean" is decided
// here by copying what is allowed into a new tree, element by element and
// attribute by attribute, not by removing what is not: whatever this does
// not know about never reaches the Reader page.
(function () {
  'use strict';
  if (window.__sbReader || window !== window.top) return;
  var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.reader;
  if (!handler) return;

  var UNLIKELY = /-ad-|\bads?\b|advert|banner|breadcrumb|combx|comment|community|cookie|disqus|extra|footer|gdpr|header|legends|menu|modal|nav\b|navigation|newsletter|pager|pagination|popup|promo|related|remark|replies|rss|share|sharing|shoutbox|sidebar|skyscraper|social|sponsor|subscribe|supplemental|toolbar|widget/i;
  var LIKELY = /article|body|content|entry|hentry|h-entry|main|page|post|story|text|blog/i;
  var NEGATIVE = /-ad-|hidden|\bhid\b|banner|combx|comment|com-|contact|footer|gdpr|masthead|media|meta|outbrain|promo|related|scroll|share|shoutbox|sidebar|skyscraper|sponsor|shopping|tags|widget/i;

  function visible(el) {
    if (el.hidden || el.getAttribute('aria-hidden') === 'true') return false;
    var style = getComputedStyle(el);
    return style.display !== 'none' && style.visibility !== 'hidden';
  }

  function label(el) { return (el.className && el.className.baseVal === undefined ? el.className : '') + ' ' + (el.id || ''); }

  function text(el) { return (el.textContent || '').replace(/\s+/g, ' ').trim(); }

  function linkDensity(el) {
    var all = text(el).length;
    if (!all) return 0;
    var links = 0;
    Array.prototype.forEach.call(el.getElementsByTagName('a'), function (a) { links += text(a).length; });
    return links / all;
  }

  // ------------------------------------------------------------- detection

  // Mozilla's test, which is a good one: paragraphs long enough to be prose,
  // outside the parts of a page that are never the article. A web app has
  // labels and buttons, not paragraphs, and scores nothing.
  function isReaderable() {
    var nodes = document.querySelectorAll('p, pre, article');
    var brs = document.querySelectorAll('div > br');
    var list = Array.prototype.slice.call(nodes);
    Array.prototype.forEach.call(brs, function (br) { if (list.indexOf(br.parentNode) === -1) list.push(br.parentNode); });
    var score = 0;
    for (var i = 0; i < list.length && score <= 20; i++) {
      var node = list[i];
      if (!visible(node)) continue;
      var name = label(node);
      if (UNLIKELY.test(name) && !LIKELY.test(name)) continue;
      if (node.matches('li p')) continue;
      var length = text(node).length;
      if (length < 140) continue;
      score += Math.sqrt(length - 140);
    }
    return score > 20;
  }

  var reported = null;
  function report() {
    var value = false;
    try { value = isReaderable(); } catch (e) { value = false; }
    if (value === reported) return;
    reported = value;
    try { handler.postMessage({ kind: 'readerable', value: value }); } catch (e) { /* going away */ }
  }

  var timer = 0, reports = 0;
  function reportSoon() {
    // Pages that build themselves get a few looks, not an endless watch.
    if (reports > 8) return;
    clearTimeout(timer);
    timer = setTimeout(function () { reports++; report(); }, 600);
  }
  function start() {
    report();
    new MutationObserver(reportSoon).observe(document.documentElement, { childList: true, subtree: true });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
  else start();
  window.addEventListener('load', report);
  // Back from Reader, the page comes out of the page cache as it was left:
  // nothing loads, so nothing above runs again, and the app has to be told.
  window.addEventListener('pageshow', function (event) {
    if (event.persisted) { reported = null; report(); }
  });

  // ------------------------------------------------------------ extraction

  function classWeight(el) {
    var weight = 0, name = label(el);
    if (NEGATIVE.test(name)) weight -= 25;
    if (LIKELY.test(name)) weight += 25;
    return weight;
  }

  function initialScore(el) {
    var score = classWeight(el);
    switch (el.tagName) {
      case 'ARTICLE': score += 10; break;
      case 'MAIN': case 'SECTION': case 'DIV': score += 5; break;
      case 'PRE': case 'TD': case 'BLOCKQUOTE': score += 3; break;
      case 'ADDRESS': case 'OL': case 'UL': case 'DL': case 'DD': case 'DT': case 'LI': case 'FORM': score -= 3; break;
      case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': case 'TH': score -= 5; break;
    }
    return score;
  }

  function findArticle() {
    var scores = new Map();
    var paragraphs = document.querySelectorAll('p, pre, td, blockquote');
    Array.prototype.forEach.call(paragraphs, function (p) {
      if (!visible(p)) return;
      var parent = p.parentElement;
      if (!parent || parent === document.documentElement) return;
      // Inside something that is never the article.
      if (p.closest('nav, aside, footer, form, [role=navigation], [role=complementary], [role=contentinfo]')) return;
      var content = text(p);
      if (content.length < 25) return;
      var points = 1 + content.split(/[,،，]/).length - 1 + Math.min(Math.floor(content.length / 100), 3);
      var level = 0;
      for (var node = parent; node && node !== document.documentElement && level < 4; node = node.parentElement, level++) {
        if (!scores.has(node)) scores.set(node, initialScore(node));
        scores.set(node, scores.get(node) + points / (level === 0 ? 1 : level === 1 ? 2 : level * 3));
      }
    });
    var best = null, bestScore = 0;
    scores.forEach(function (score, node) {
      var label0 = label(node);
      if (UNLIKELY.test(label0) && !LIKELY.test(label0) && node.tagName !== 'ARTICLE') return;
      var adjusted = score * (1 - linkDensity(node));
      if (adjusted > bestScore) { best = node; bestScore = adjusted; }
    });
    if (!best) return null;
    // One <article> around the best candidate is the author saying so.
    var article = best.closest('article');
    if (article && text(article).length < text(best).length * 2.5) best = article;
    return best;
  }

  var ALLOWED = {
    P: [], H1: [], H2: [], H3: [], H4: [], H5: [], H6: [], UL: [], OL: ['start'], LI: [], BLOCKQUOTE: [], PRE: [], CODE: [],
    EM: [], STRONG: [], B: [], I: [], U: [], S: [], SUB: [], SUP: [], SMALL: [], MARK: [], ABBR: ['title'], CITE: [], Q: [], KBD: [],
    BR: [], HR: [], SPAN: [], DIV: [], SECTION: [], FIGURE: [], FIGCAPTION: [], TABLE: [], THEAD: [], TBODY: [], TFOOT: [], TR: [],
    TH: ['colspan', 'rowspan'], TD: ['colspan', 'rowspan'], CAPTION: [], DL: [], DT: [], DD: [], TIME: ['datetime'],
    A: [], IMG: [], DETAILS: [], SUMMARY: []
  };
  var DROP = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|IFRAME|OBJECT|EMBED|FORM|BUTTON|INPUT|SELECT|TEXTAREA|NAV|ASIDE|FOOTER|LINK|META|SVG|CANVAS|DIALOG|MENU|AUDIO|VIDEO)$/;

  function webAddress(value) {
    try {
      var url = new URL(value, document.baseURI);
      return url.protocol === 'http:' || url.protocol === 'https:' ? url.href : null;
    } catch (e) { return null; }
  }

  function imageAddress(img) {
    // Lazy loaders keep the real address anywhere but in src.
    var candidates = [img.currentSrc, img.getAttribute('data-src'), img.getAttribute('data-original'), img.getAttribute('data-lazy-src'), img.getAttribute('src')];
    var set = img.getAttribute('srcset') || img.getAttribute('data-srcset');
    if (set) candidates.push(set.split(',').pop().trim().split(/\s+/)[0]);
    for (var i = 0; i < candidates.length; i++) {
      var value = candidates[i];
      if (!value || /^data:image\/(gif|svg)/.test(value)) continue;   // placeholders
      if (/^data:image\/(png|jpe?g|webp);base64,/.test(value)) return value;
      var url = webAddress(value);
      if (url) return url;
    }
    return null;
  }

  function copy(node, into, doc, title) {
    if (node.nodeType === Node.TEXT_NODE) {
      into.appendChild(doc.createTextNode(node.nodeValue));
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    var tag = node.tagName.toUpperCase();
    if (DROP.test(tag) || !visible(node)) return;
    var name = label(node);
    // Share bars, related links, sign-up boxes: short, mostly links, and named for what they are.
    if (UNLIKELY.test(name) && !LIKELY.test(name) && (linkDensity(node) > 0.3 || text(node).length < 400)) return;
    if (tag === 'H1' && title && text(node) === title) return;        // shown once, above
    // The author's line, which Reader shows under the title.
    if (node.matches('.byline, .author, [rel=author], [itemprop=author]') && text(node).length < 120) return;

    if (tag === 'PICTURE') {
      var inner = node.querySelector('img');
      if (inner) copy(inner, into, doc, title);
      return;
    }
    if (!ALLOWED.hasOwnProperty(tag)) {
      // Unknown wrapper: its contents are kept, it is not.
      Array.prototype.forEach.call(node.childNodes, function (child) { copy(child, into, doc, title); });
      return;
    }
    var element = doc.createElement(tag.toLowerCase());
    ALLOWED[tag].forEach(function (attribute) {
      var value = node.getAttribute(attribute);
      if (value !== null && /^[\w\s:.+-]{1,40}$/.test(value)) element.setAttribute(attribute, value);
    });
    if (node.dir === 'rtl' || node.dir === 'ltr') element.setAttribute('dir', node.dir);
    if (tag === 'A') {
      var href = node.getAttribute('href') ? webAddress(node.getAttribute('href')) : null;
      if (href) element.setAttribute('href', href);
    }
    if (tag === 'IMG') {
      var source = imageAddress(node);
      if (!source) return;
      var width = node.naturalWidth || parseInt(node.getAttribute('width'), 10) || 0;
      if (width && width < 50) return;                                  // tracking pixels, icons
      element.setAttribute('src', source);
      element.setAttribute('alt', node.getAttribute('alt') || '');
      element.setAttribute('loading', 'lazy');
      into.appendChild(element);
      return;
    }
    Array.prototype.forEach.call(node.childNodes, function (child) { copy(child, element, doc, title); });
    // Nothing left in it: a wrapper around what was dropped.
    if (!element.childNodes.length && !/^(BR|HR|TD|TH)$/.test(tag)) return;
    if (/^(P|DIV|SECTION|SPAN|LI|FIGURE)$/.test(tag) && !text(element) && !element.querySelector('img')) return;
    into.appendChild(element);
  }

  function meta(names) {
    for (var i = 0; i < names.length; i++) {
      var el = document.querySelector('meta[property="' + names[i] + '"], meta[name="' + names[i] + '"]');
      var value = el && (el.getAttribute('content') || '').trim();
      if (value) return value;
    }
    return '';
  }

  function articleTitle(article) {
    var heading = article.querySelector('h1') || document.querySelector('h1');
    var fromHeading = heading ? text(heading) : '';
    if (fromHeading.length > 8 && fromHeading.length < 200) return fromHeading;
    var fromMeta = meta(['og:title', 'twitter:title']);
    if (fromMeta) return fromMeta;
    // "Headline | Site": the headline is the long part.
    var parts = document.title.split(/\s+[|\-–—·:]\s+/);
    return (parts.length > 1 ? parts.sort(function (a, b) { return b.length - a.length; })[0] : document.title).trim();
  }

  function byline(article) {
    var fromMeta = meta(['author', 'article:author', 'parsely-author']);
    if (fromMeta && !/^https?:/.test(fromMeta)) return fromMeta.slice(0, 120);
    var el = article.querySelector('[rel=author], [itemprop=author], .byline, .author') || document.querySelector('[rel=author], [itemprop=author], .byline');
    var value = el ? text(el).replace(/^by\s+/i, '') : '';
    return value.length > 0 && value.length < 120 ? value : '';
  }

  window.__sbReader = {
    isReaderable: function () { try { return isReaderable(); } catch (e) { return false; } },

    extract: function () {
      var article = findArticle();
      if (!article) return null;
      var title = articleTitle(article);
      var doc = document.implementation.createHTMLDocument('');
      var root = doc.createElement('div');
      Array.prototype.forEach.call(article.childNodes, function (child) { copy(child, root, doc, title); });
      var words = text(root).split(/\s+/).filter(Boolean).length;
      if (words < 40) return null;
      var time = article.querySelector('time[datetime]') || document.querySelector('time[datetime]');
      return {
        title: title,
        byline: byline(article),
        site: meta(['og:site_name']) || location.hostname.replace(/^www\./, ''),
        published: meta(['article:published_time']) || (time ? time.getAttribute('datetime') : ''),
        language: (document.documentElement.lang || '').slice(0, 20),
        direction: getComputedStyle(article).direction === 'rtl' ? 'rtl' : 'ltr',
        words: words,
        html: root.innerHTML
      };
    }
  };
})();
