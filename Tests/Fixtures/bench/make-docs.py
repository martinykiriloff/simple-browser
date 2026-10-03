#!/usr/bin/env python3
# Generates docs.html: a long, realistic documentation page (site header,
# sidebar nav, article with tables and highlighted code, on-this-page TOC,
# footer), ~3-5k DOM nodes. Deterministic; rerun after editing:
#   python3 make-docs.py > docs.html
import html, random

random.seed(7)
WORDS = ("request response client server cache header token session route handler middleware stream buffer "
         "timeout retry backoff payload schema field value option config default endpoint queue worker job "
         "event listener promise async await error status body query param path origin cookie storage "
         "render component state effect hook layout style module bundle import export build deploy").split()

def sentence(n=None):
    n = n or random.randint(8, 18)
    words = [random.choice(WORDS) for _ in range(n)]
    out = []
    for i, w in enumerate(words):
        r = random.random()
        if r < 0.06: out.append(f'<code class="inline-code">{w}()</code>')
        elif r < 0.09: out.append(f'<a class="doc-link" href="/docs/api/{w}" data-preview="api-{w}">{w}</a>')
        elif r < 0.11: out.append(f"<strong>{w}</strong>")
        else: out.append(w)
    s = " ".join(out)
    return s[0].upper() + s[1:] + "."

def para():
    return '<p class="doc-paragraph">' + " ".join(sentence() for _ in range(random.randint(2, 4))) + "</p>"

KW = {"const", "let", "async", "await", "return", "function", "import", "from", "export", "if", "new", "try", "catch"}
def code_block(lang="js"):
    lines = []
    for i in range(random.randint(6, 12)):
        indent = "  " * random.randint(0, 2)
        toks = []
        for _ in range(random.randint(3, 7)):
            r = random.random()
            if r < 0.25: t = random.choice(sorted(KW)); toks.append(f'<span class="tok-kw">{t}</span>')
            elif r < 0.4: toks.append(f'<span class="tok-str">"{random.choice(WORDS)}"</span>')
            elif r < 0.5: toks.append(f'<span class="tok-num">{random.randint(0, 5000)}</span>')
            elif r < 0.6: toks.append(f'<span class="tok-fn">{random.choice(WORDS)}</span>(')
            else: toks.append(random.choice(WORDS))
        if random.random() < 0.15: toks.append(f'<span class="tok-com">// {random.choice(WORDS)} {random.choice(WORDS)}</span>')
        lines.append(f'<span class="line">{indent}{" ".join(toks)}</span>')
    return (f'<div class="code code-block" data-language="{lang}" data-line-numbers="false"><div class="code-head code-block__header"><span class="code-block__lang">{lang}</span><button class="copy code-block__copy" type="button" data-copy-target="pre" aria-label="Copy code"><svg class="icon icon-copy" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg><span class="sr-only">Copy</span></button></div>'
            f'<pre><code class="language-{lang}">' + "\n".join(lines) + "</code></pre></div>")

def table():
    cols = ["Option", "Type", "Default", "Description"]
    rows = []
    for _ in range(random.randint(6, 10)):
        name = random.choice(WORDS) + random.choice(WORDS).capitalize()
        rows.append(f"<tr><td><code>{name}</code></td><td><code>{random.choice(['string','number','boolean','object','string[]'])}</code></td>"
                    f"<td><code>{random.choice(['undefined','true','false','0','\"auto\"','[]'])}</code></td><td>{sentence(10)}</td></tr>")
    return ('<div class="table-wrap"><table><thead><tr>' + "".join(f"<th>{c}</th>" for c in cols) +
            "</tr></thead><tbody>" + "".join(rows) + "</tbody></table></div>")

def callout():
    kind = random.choice(["note", "warning", "tip"])
    return f'<aside class="callout callout-{kind}" role="note"><p class="callout-title">{kind.capitalize()}</p>{para()}</aside>'

SECTIONS = ["Overview", "Installation", "Quick start", "Configuration", "Routing", "Request handlers", "Middleware",
            "Caching", "Sessions and cookies", "Streaming responses", "Error handling", "Retries and backoff",
            "Background jobs", "Testing", "Deployment", "Observability", "Security", "Migrating from v3",
            "Plugins", "Edge runtime", "Rate limiting", "File uploads", "Websockets", "API reference", "FAQ"]
slug = lambda s: s.lower().replace(" ", "-")

nav_groups = [("Getting started", ["Introduction", "Installation", "Quick start", "Project structure", "Editor setup"]),
              ("Guides", ["Routing", "Data fetching", "Forms", "Authentication", "Sessions", "Caching", "Streaming", "Uploads", "Websockets", "Internationalization", "Testing", "Deployment"]),
              ("Concepts", ["Request lifecycle", "Middleware", "Handlers", "Error boundaries", "Background jobs", "Observability", "Security model"]),
              ("API reference", ["createServer", "route", "use", "cache", "cookies", "headers", "redirect", "notFound", "stream", "json", "defineConfig", "env", "logger", "queue", "schedule", "test"]),
              ("Integrations", ["Postgres", "Redis", "S3", "Stripe", "Sentry", "OpenTelemetry", "Tailwind", "Docker"]),
              ("Resources", ["Changelog", "Migration guides", "Examples", "Community", "Support"])]

out = []
out.append('''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Guide — Harbor framework docs</title>
<meta name="description" content="The complete guide to building servers with Harbor.">
<link rel="icon" href="data:,">
<link rel="canonical" href="https://harbor.example/docs/guide">
<meta property="og:title" content="The Harbor guide"><meta property="og:description" content="The complete guide to building servers with Harbor."><meta property="og:image" content="https://harbor.example/og/docs-guide.png"><meta name="twitter:card" content="summary_large_image">
<script type="application/ld+json">{"@context":"https://schema.org","@type":"TechArticle","headline":"The Harbor guide","dateModified":"2026-09-14","author":{"@type":"Organization","name":"Harbor contributors"}}</script>
<style>
  :root { --fg: #1d1d1f; --muted: #6e6e73; --line: #e5e5ea; --accent: #0a64c8; --code-bg: #f6f8fa; }
  * { box-sizing: border-box; }
  body { margin: 0; font: 15px/1.6 -apple-system, system-ui, sans-serif; color: var(--fg); }
  .site-header { position: sticky; top: 0; display: flex; align-items: center; gap: 16px; padding: 10px 24px; background: #fff; border-bottom: 1px solid var(--line); z-index: 2; }
  .site-header .logo { font-weight: 700; }
  .site-header input[type=search] { flex: 1; max-width: 360px; padding: 6px 10px; border: 1px solid var(--line); border-radius: 8px; }
  .layout { display: grid; grid-template-columns: 240px minmax(0, 1fr) 220px; gap: 32px; max-width: 1400px; margin: 0 auto; padding: 0 24px; }
  .sidebar { position: sticky; top: 56px; align-self: start; max-height: calc(100vh - 56px); overflow: auto; padding: 16px 0; font-size: 14px; }
  .sidebar ul { list-style: none; margin: 0; padding: 0 0 0 8px; }
  .sidebar a { color: var(--muted); text-decoration: none; display: block; padding: 2px 0; }
  .sidebar a[aria-current] { color: var(--accent); font-weight: 600; }
  .sidebar details > summary { font-weight: 600; cursor: pointer; padding: 6px 0; }
  article { padding: 24px 0 64px; min-width: 0; }
  article h2 { margin-top: 48px; padding-top: 8px; border-top: 1px solid var(--line); }
  .anchor { opacity: 0; margin-left: 6px; text-decoration: none; }
  h2:hover .anchor, h3:hover .anchor { opacity: 1; }
  .code { border: 1px solid var(--line); border-radius: 8px; margin: 16px 0; overflow: hidden; }
  .code-head { display: flex; justify-content: space-between; padding: 4px 12px; background: #eef1f4; font-size: 12px; color: var(--muted); }
  pre { margin: 0; padding: 12px; overflow: auto; background: var(--code-bg); font: 13px/1.5 ui-monospace, Menlo, monospace; }
  .line { display: block; } .tok-kw { color: #cf222e; } .tok-str { color: #0a3069; } .tok-num { color: #0550ae; } .tok-fn { color: #8250df; } .tok-com { color: #6e7781; font-style: italic; }
  .table-wrap { overflow-x: auto; } table { border-collapse: collapse; width: 100%; font-size: 14px; } th, td { border-bottom: 1px solid var(--line); padding: 6px 8px; text-align: left; vertical-align: top; }
  .callout { border-left: 4px solid var(--accent); background: #f2f7fd; padding: 8px 16px; margin: 16px 0; border-radius: 4px; }
  .callout-warning { border-color: #bf8700; background: #fff8e5; } .callout-title { font-weight: 600; margin: 0; }
  .toc { position: sticky; top: 56px; align-self: start; padding: 24px 0; font-size: 13px; } .toc ul { list-style: none; padding: 0; } .toc a { color: var(--muted); text-decoration: none; }
  .pager { display: flex; justify-content: space-between; margin-top: 48px; } .feedback { margin-top: 32px; color: var(--muted); }
  .site-footer { border-top: 1px solid var(--line); padding: 32px 24px; color: var(--muted); font-size: 13px; display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; }
</style></head>
<body>
<a class="skip" href="#content">Skip to content</a>
<header class="site-header">
  <a class="logo" href="/">Harbor</a>
  <nav aria-label="Primary"><a href="#">Docs</a> <a href="#">Blog</a> <a href="#">Showcase</a> <a href="#">Pricing</a></nav>
  <input type="search" placeholder="Search docs" aria-label="Search docs">
  <select aria-label="Version"><option>v4.2 (latest)</option><option>v4.1</option><option>v3.x</option></select>
  <button aria-label="Toggle theme">Theme</button>
  <a href="#">GitHub</a>
</header>
<div class="layout">
<nav class="sidebar" aria-label="Documentation">''')
for group, items in nav_groups:
    out.append(f'<details class="sidebar-group" data-group="{slug(group)}" open><summary class="sidebar-group__title">{group}</summary><ul class="sidebar-list">')
    for item in items:
        current = ' aria-current="page"' if item == "Routing" else ""
        out.append(f'<li class="sidebar-item sidebar-item--level-1"><a class="sidebar-link" href="/docs/{slug(group)}/{slug(item)}" data-nav-id="{slug(item)}"{current}>{item}</a>')
        if group in ("Guides", "API reference") and random.random() < 0.5:
            out.append("<ul>" + "".join(f'<li class="sidebar-item sidebar-item--level-2"><a class="sidebar-link sidebar-link--nested" href="/docs/{slug(group)}/{slug(item)}#{k}" data-nav-id="{slug(item)}-{k}">{random.choice(WORDS).capitalize()} {random.choice(WORDS)}</a></li>' for k in range(random.randint(2, 4))) + "</ul>")
        out.append("</li>")
    out.append("</ul></details>")
out.append('</nav>\n<article id="content">')
out.append('<nav aria-label="Breadcrumb"><ol class="crumbs"><li><a href="#">Docs</a></li><li><a href="#">Guides</a></li><li aria-current="page">The Harbor guide</li></ol></nav>')
out.append('<h1>The Harbor guide</h1><p class="lead">' + sentence(24) + "</p>")
for s in SECTIONS:
    out.append(f'<section class="doc-section" data-section="{slug(s)}" aria-labelledby="{slug(s)}"><h2 class="doc-heading doc-heading--h2" id="{slug(s)}">{s}<a class="anchor heading-anchor" href="#{slug(s)}" aria-label="Link to {s}"><svg class="icon icon-link" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7"/><path d="M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"/></svg></a></h2>')
    out.append(para()); out.append(para())
    for k in range(random.randint(1, 3)):
        sub = f"{random.choice(WORDS).capitalize()} {random.choice(WORDS)}"
        out.append(f'<h3 class="doc-heading doc-heading--h3" id="{slug(s)}-{k}">{sub}<a class="anchor heading-anchor" href="#{slug(s)}-{k}" aria-label="Link to {sub}"><svg class="icon icon-link" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7"/><path d="M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"/></svg></a></h3>')
        out.append(para())
        r = random.random()
        if r < 0.5: out.append(code_block(random.choice(["js", "ts", "bash"])))
        elif r < 0.75: out.append(table())
        else: out.append("<ul>" + "".join(f"<li>{sentence(9)}</li>" for _ in range(random.randint(3, 6))) + "</ul>")
        if random.random() < 0.25: out.append(callout())
        out.append(para())
    out.append("</section>")
out.append('<nav class="pager" aria-label="Pagination"><a href="#">← Project structure</a><a href="#">Data fetching →</a></nav>')
out.append('<div class="feedback"><p>Was this page helpful?</p><button>Yes</button> <button>No</button> <a href="#">Edit this page on GitHub</a></div>')
out.append('</article>\n<nav class="toc" aria-label="On this page"><p><strong>On this page</strong></p><ul>')
out.append("".join(f'<li class="toc-item toc-item--h2"><a class="toc-link" href="#{slug(s)}" data-toc-target="{slug(s)}">{s}</a></li>' for s in SECTIONS))
out.append('</ul></nav>\n</div>\n<footer class="site-footer">')
for col in ["Product", "Resources", "Company", "Legal"]:
    out.append(f'<div><p><strong>{col}</strong></p><ul>' + "".join(f'<li><a href="#">{random.choice(WORDS).capitalize()}</a></li>' for _ in range(5)) + "</ul></div>")
out.append('<p>© 2026 Harbor contributors. Released under the MIT license.</p></footer>')
out.append('<script>document.querySelectorAll(".copy").forEach(b => b.addEventListener("click", () => navigator.clipboard.writeText(b.closest(".code").querySelector("pre").innerText)));</script>')
out.append("</body></html>")
print("\n".join(out))
