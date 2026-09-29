# SimpleBrowser

A native macOS browser. Swift above the engine, WebKit below it.

## Status

Early. `BlockKit`, `BrowserKit` and `InspectKit` are pure-Foundation packages
with no WebKit or AppKit dependency — they build and test anywhere a Swift
toolchain exists. `BrowserApp` has tabs that sleep when idle, session
restore, history, bookmarks, a smart address bar, content blocking, profiles,
a password manager and dev tools; the proxy is not wired yet. The
[roadmap](https://github.com/martinykiriloff/simple-browser/issues/1) lists
what is left.

The partitioning algorithm in `BlockKit` has been verified against an oracle —
see [Verification](#verification).

## Browsing

Back, Forward, Reload and **Home** in the toolbar, plus an address bar that
takes a URL, a bare host, or a search. Home (also History → Home, ⇧⌘H) opens
the homepage set in **Settings** (⌘,): type a URL or a host such as
`example.com`, or use *Set to Current Page*. Left empty, Home opens the
default, `https://duckduckgo.com/`, which matches the default search engine.
The line under the field always says where Home will actually go; a search
phrase or a `javascript:` URL is not accepted as a homepage. ⇧⌘H also works
while the Settings window is in front: it sends the browser window behind it
home.

**New windows open with** (also in Settings) chooses what ⌘N, launch and a
click on the Dock icon start with: the homepage (the default) or an empty
page. Either way the keyboard stays in the address bar, so ⌘N and typing a
destination works while the homepage loads behind it.

### The address bar

Typing offers a list: open tabs first (**Switch to Tab**, which switches
without reloading), then bookmarks, history, the search itself and the
engine's suggestions. The best matching site is completed inline, so `git`
and Return opens `github.com`. ↑ and ↓ move through the list, ⇥ accepts the
completion, ⌫ drops it, and ⇧⌫ on a history row forgets that page.

While it is not being edited the bar shows the site's name, and the full
address on focus. With the scheme out of sight, the indicator inside the
field is what tells `http` from `https`: a lock for an encrypted page,
**Not Secure** in orange for plain http or for an https page that loaded
parts of itself unencrypted, and a computer for a page on this Mac. Clicking
it says what that means.

**Settings → Search engine** chooses DuckDuckGo, Google, Bing, Ecosia, Kagi,
Startpage, or any address with `%s` where the words go. The address bar, the
start page's search box, *Search … for "…"* in the right-click menu and
**Edit → Paste and Go** (⇧⌘V, which reads *Paste and Search* when the
clipboard holds words) all follow it. *Show search suggestions as you type*
can be switched off; then nothing typed leaves the Mac until Return.

```sh
scripts/test-ui.sh            # the app presses its own keys and buttons, then reports
scripts/test-features.sh      # tabs, sessions, history, bookmarks, the address bar, blocking, Reader, private windows, downloads, the sidebar, ⌘K and split view
scripts/test-downloads.sh     # downloads paused or under way at quit go on after a relaunch
```

`test-features.sh`, `test-downloads.sh` and `test-page.sh` run **quietly**: the app is given
`--quiet`, never becomes active, and keeps its windows beneath yours, so you
can go on working while they run. That is not only politeness. A test that
takes the keyboard also takes whatever you type meanwhile, and fails for it.
`FOCUS=1` runs them in front. `test-ui.sh` and the parts of
`test-passwords.sh` about the list under a sign-in field need the keyboard
and take it; `QUIET=1 scripts/test-passwords.sh` runs the rest.

macOS does not let an outside process press keys without the Accessibility
permission, so this test runs inside the app (`--ui-selftest <file>`). Key
presses are built as the window server builds them and sent through the main
menu, text goes through the field editor, and buttons perform their own
click, so the menu wiring, responder chain and delegates are what is tested.
It uses a scratch settings suite, so your own homepage is never touched. The
app takes focus for about half a minute, and the screen has to be unlocked:
macOS will not make a window key behind the lock screen, which the test
reports as an environment problem rather than a failure.

## Tabs, groups and the sidebar

**View → Show Sidebar** (⇧⌘S, or the sidebar button at the left of the
toolbar) opens a sidebar beside the page: pinned tabs as icons at the top,
then the window's tabs with their groups, then saved groups, favorites and
the reading list. A click shows a tab, ⌘- and ⇧-clicks choose several, and
tabs are dragged to reorder them, into a group or out of it. The divider
sets the width for every window. **Settings → General → Tabs** puts the
tabs *In the sidebar* instead of in a bar above the page: the tab bar goes,
and comes back whenever the sidebar is hidden, so tabs are never out of
reach.

**Tab groups**: *New Tab Group* (Window menu, or right-click tabs in the
sidebar) asks for a name and a colour at once. A group's tabs stay side by
side, and carry its colour in the tab bar; in the sidebar a group
collapses to its name, keeping the tab in front in sight. A page opened
from a grouped tab joins the group; ⌘T opens a tab of its own. *Save
Group* keeps a group after its tabs are closed, under *Saved Groups*, to
open again as it was. **Pin Tab** puts a tab first, as an icon in the
sidebar. Groups and pins come back with the session.

**File → Command Palette** (⌘K) is one box for everything: open tabs,
every command in the menu bar ("Translate Page", "Clear History…", "New
Private Window", "Switch to Profile “Work”"), saved groups, bookmarks and
history, found by fuzzy search (`np w` finds *New Private Window*). ↑ ↓
move, Return opens, ⌘1–⌘9 open the first nine results, Esc closes. With
nothing typed each tab shows its key, such as **G ⌘3**: G then ⌘3 opens
it. So with a hundred tabs open, any of them is two keys away after ⌘K,
which `BrowserKitChecks` measures against a hundred tabs as people have
them, alike on purpose, and every menu command.

### Split view

Two tabs side by side in one window: **View → Open in Split View** (this
tab and the next, or a new one), *Open in Split View* on a tab or two
chosen in the sidebar, *Open Link in Split View* on a link, or a tab
dragged from the sidebar onto the right edge of the page. Each side has a
header with its site and a close button, and keeps its own address: the
toolbar is the side in front's own, so the address bar, the buttons and
the menus (⌘L, ⌘F, ⌘R…) act on that side. The side in front is underlined
in the accent colour; a click, or ⌥⌘← and ⌥⌘→, changes it. The pair is one
tab in the tab bar ("Left | Right"). Where the divider is left is where
the next split starts. Closing a side (its ✕, or ⌘W on it) leaves the other
as a whole tab; **Close Split View** leaves both. A split comes back with
the session, and the page beside never sleeps while it is on screen.

## Find, zoom and Reader

**Find** (⌘F) opens a bar over the top right of the page. Every match is
highlighted and counted, "3 of 12", in frames too; ⌘G and ⇧⌘G go to the next
and the previous, Return and ⇧Return do the same from the bar, Escape closes
it. ⌘E takes the selection as what ⌘G looks for. The bar stays open from
page to page.

**Zoom**: ⌘+, ⌘− and ⌘0, in Chrome's steps from 25% to 500%. The level is
remembered per site and per profile, a site's open tabs follow together, and
while a page is not at its actual size the level shows beside the address;
clicking it goes back to 100%.

**Reader** (⇧⌘R, or the button that appears beside the address when the
page has an article) shows the article alone: headline, author, date,
reading time, text and pictures. The **Aa** button sets colours (white,
sepia, dark, or matching the system), font, size and width, for every
article. Translation works in Reader. Going back to the page returns to
where it was scrolled.

Reader is built to be safe to point at any page. The article is copied into
a new document element by element and attribute by attribute, keeping only
what is on a list; the Reader page forbids all script by policy; and it is
served by the browser itself, so nothing on it can reach the site's cookies.


Ads and trackers are blocked from the first page, with EasyList and
EasyPrivacy. WebKit does the blocking itself, in its network process, before
a request is made: no script runs per request, and nothing in the app sees a
page's traffic.

**The shield** beside the address bar shows how many requests were blocked
on the page. Clicking it lists where they were going, switches blocking off
for the site (remembered per profile; the page reloads unblocked), and opens
*Report a Broken Site…*, which prepares an issue naming the site for you to
read before anything is sent. Blocked requests appear in DevTools' Network
panel as `(blocked)`.

**Settings → Privacy** has the main switch, the filter lists (the EasyList
Cookie List and Fanboy's Annoyances are there to switch on), when they were
last updated, *Update Now*, and the sites blocking is off for. The lists are
checked daily with `If-None-Match`, so an unchanged list costs one small
request, and downloaded without cookies.

Measured with EasyList and EasyPrivacy on 2026-09-28: 132,687 filters become
215,886 rules in 8 compiled lists; WebKit refused none. 904 filters (0.7%)
use what WebKit's blocker cannot express (redirects, scriptlets, regular
expressions, procedural selectors) and are left out rather than
approximated. Converting takes 2 seconds and compiling about 30, in the
background; the compiled lists are kept, so a launch only looks them up.
On three news sites the pages made 9 to 35% fewer requests, to as few as a
fifth of the hosts.

```sh
swift run BlockKitChecks                 # the filter parser; exceptions across partitions
ONLY=blocking scripts/test-features.sh   # against the fixture site's own lists (takes focus)
.build/debug/SimpleBrowser --blocking-probe /tmp/probe.json about:blank   # the real lists, in a scratch folder
```

## The right-click menu

What Safari and Chrome show, for whatever is under the pointer. On a link:
Open Link, Open Link in New Window, Save Link As…, Copy Link. On an image:
Open Image in New Window, Save Image As…, Copy Image, Copy Image Address. On
selected text: Copy, Look Up, Search DuckDuckGo for “…”, Translate “…”,
Share, Speech. On the page: Back, Forward, Reload, Save Page As…
(`.webarchive`), Print…, Translate to …, View Page Source (DevTools →
Sources). Inspect Element is always last and opens our DevTools.

WebKit builds the menu; `PageContextMenu` keeps the items that work as they
are and replaces the ones that expect a browser around the web view. New
windows open in the same profile. A page agent in an isolated world reports
the link, image and selection from the DOM `contextmenu` event, which fires
before the menu opens. Files a page hands over instead of showing
(`Content-Disposition: attachment`, `<a download>`, a zip) download to
~/Downloads under their own name, with the profile's cookies.

## Translation

Google Translate, built in, the way Chrome has it; there is no extension to
install. The Translate button in the toolbar turns blue when a page is in
another language than yours, and offers:

- **Translate to** your language (the first of your macOS preferred languages
  Google supports, or the last one you chose), or any of Google's 130+
  languages under **Translate To**.
- **Show Original**, which puts back exactly what was there.
- **Always Translate *language***, which translates pages in that language as
  they load.

The same items are in the page's right-click menu, View → Translate Page
(⌥⌘T) and View → Show Original. Selected text can be translated on its own,
in a popover, from the right-click menu.

Nothing is sent to Google until you ask for a translation. The page's
language is found on the Mac, by NaturalLanguage, from its declared `lang`
and a sample of its text. Requests carry no cookies, so they are not tied to
your Google account. Pages that say `translate="no"`, `class="notranslate"` or
`<meta name="google" content="notranslate">` are respected, as are code and
preformatted text. Content the page adds after translating (infinite
scrolling, "load more") is translated as it arrives.

Links, buttons and their handlers keep working in a translated page: the
translation is put back into the page's own elements, not copies of them.
The service is the one Google's own translate widget uses (no API key); it
limits heavy use, and when it does the Translate button turns orange and
says so.

```sh
swift run TranslateKitChecks          # languages, batching, requests, responses
swift run TranslateKitChecks --live   # also asks the real Google Translate
scripts/test-page.sh                  # translation, the right-click menu, downloads (takes focus)
```

## Profiles

Like Chrome's and Safari's: each profile is a separate identity with its own
cookies, sessions, local storage, IndexedDB, cache and saved passwords. Signing
in to a site in one profile does not sign you in, or out, in another.

The **Profiles** menu (and the profile button at the right of every toolbar)
lists them: pick one to open a new window browsing as it (⌥⇧⌘1–9). ⌘N opens a
window in the profile of the window in front. **New Profile…**, **Rename…** and
**Delete…** act on that profile; deleting one closes its windows and removes
its website data, its password vault and the vault's Keychain key. The last
profile cannot be deleted. Settings → Passwords shows the vault of the profile
whose window is in front.

A window belongs to exactly one profile, for its whole life (see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)). The rules for names, colours and
removal live in `BrowserKit/ProfileRoster.swift`:

```sh
swift run BrowserKitChecks
```

The profile that existed before profiles were added is carried over as
"Default" with its data store, so nobody is signed out by the upgrade.

## What sites may do

A site asking for the **camera**, the **microphone** or your **location**
is asked about in a question hanging from the lock in the address bar:
*Don't Allow*, *Allow Once* or *Allow*. Allow and Don't Allow are remembered
for the site, per profile; Allow Once lasts while the tab stays on the site.
A site is an origin, so `http://` and `https://` of one name are two sites.
When a frame from elsewhere asks through a page, the question names the page
you chose to visit and says who is really asking. While the camera or
microphone is in use a red indicator shows beside the address and in the
tab; clicking it stops them.

**Pop-up windows** a page opens by itself are held back, with a bar saying
how many and offering *Open* and *Always Allow on this site*. A window
opened by your click is never held back. A page may hand over one **file**
unasked; a second one it starts by itself is asked about.

**The lock** opens the page's information: how the connection is secured
and by whose certificate, what the site may do (each changeable there),
what it has stored on this Mac with *Clear…*, and what was blocked.
**Settings → Websites** lists every site that was allowed or refused
something.

**Certificates.** A site whose certificate cannot be verified is not shown;
a page saying so is, with the certificate's details, *Go Back* and *Visit
this website anyway*. Going on makes an exception for that certificate on
that site until the app quits (or the private session ends), and the site
stays marked *Not Secure*. If the site later presents another certificate,
the warning is back.

Not offered: **notifications**. Measured, a page in an app can be granted
the permission, and the notification it then shows goes nowhere: WebKit
hands page notifications to a provider that only its C API can set. Pages
are given no Notification API, rather than one that does nothing.

## Downloads

A file a page hands over (`Content-Disposition: attachment`, `<a download>`,
a type WebKit cannot show) or **Download Linked File** in the right-click
menu goes to the download folder, with the profile's cookies. A downloads
button appears in the toolbar with the first download of a launch; it
shows how far downloads under way have got and opens their list, with
speed and time left, **Pause**, **Resume** and **Cancel**. A download
goes on from where it stopped, not from the start, and one that loses its
connection is marked as failed, saying why, with **Try Again**.

A file of the same name never replaces another; it is saved beside it with
a number. Every download is marked as coming from the web, so macOS checks
it when it is opened, and a file that can run (an app, a script, an
installer) is asked about the first time it is opened from the list.

**Window → Downloads** (⌥⌘L) lists every download in the profile, each
with the page it came from, **Download Again** for what was cancelled, and
**Clear** for what is over (the files stay where they are).
**Settings → General** chooses the folder, or *Ask where to save each
file*. Downloads under way when the app quits are paused, and are there to
go on with at the next launch. A private window's downloads are listed in
the private session only and kept nowhere.

## Private windows

**File → New Private Window** (⇧⌘N) opens a window with a dark toolbar and
a *Private* badge, in the profile of the window it was opened from. Its
website data store exists only in memory: cookies, caches and stored data
never reach the disk, and closing the last private tab ends the private
session and everything in it.

| | In a private window |
|---|---|
| History, the address bar's suggestions, Reopen Closed Tab | nothing from the window is recorded or offered |
| Session restore | private windows are never saved or restored |
| Signing in | separate from the normal windows, in both directions; shared between the private tabs |
| Saved passwords | filled; new ones are not saved or offered, and strong passwords are not suggested |
| Search suggestions | what is typed is not sent to the search engine |
| Zoom and blocking switched off for a site | hold for the private session, and are not written down |
| Bookmarks you add, files you download | kept: you asked for them |

A tab opened from a private window (⌘T, a link, a page's pop-up) is
private, and private tabs cannot be dragged into a normal window or the
other way round.

## Passwords

A built-in password manager, one encrypted vault per profile with its key in
the login Keychain. It offers to save a sign-in once it has worked, offers to
update a changed password, fills saved sign-ins, and lists a site's accounts
under the field. Settings → Passwords (also App menu → Passwords…) searches,
adds, edits and deletes them. Showing, copying, editing or exporting a
password asks for Touch ID or the Mac's password first.

**Strong passwords.** A new-password field is offered **Use Strong
Password**, and the password is saved the moment it is filled. Sign-up forms
are recognised by `autocomplete=new-password`, a password-and-confirm pair,
or, for the many that say neither, the field's name or the form's
"Create account" / "Sign up" / "Register" button. Any sign of a sign-in wins,
so a sign-in form never loses its autofill. The password follows the site's
rules: the field's `maxlength` and `minlength`, and the
[`passwordrules`](https://developer.apple.com/password-rules/) attribute
(required and allowed characters, max-consecutive). A 16-character limit gets
16 characters, not a 20-character password the page quietly truncates.

**Checkup.** Settings → Passwords → **Checkup…** lists leaked, reused and weak
passwords, worst first, with **Change on Site** to go and fix each one. Weak
means something a person can act on: too short, a common password, one kind
of character, a keyboard or repeated pattern, or containing the username or
the site's name. The leak check uses Have I Been Pwned's range API the
k-anonymous way: only the first 5 hex characters of each password's SHA-1 are
sent, with padding requested, and matching happens on the Mac. It can be
switched off in the sheet. If it cannot reach the service, the rest of the
checkup still reports and says leaks were not checked, never "none leaked".

**Apple Passwords.** Apple gives other browsers no access to iCloud Keychain,
so the two meet through the CSV files the Passwords app itself reads and
writes. The ⋯ menu has **Import from Apple Passwords…** (it explains File →
Export All Passwords to File… in the Passwords app, then imports that file)
and **Export to Apple Passwords…** (it writes Apple's
`Title,URL,Username,Password,Notes,OTPAuth` format and opens the Passwords
app for File → Import Passwords from File…). Import and export also speak
Chrome's CSV, which Chrome, Edge, Brave and Firefox use.

```sh
swift run PasswordKitChecks   # vault, origins, rules, generator, checkup, leak check
scripts/test-passwords.sh     # signs in to a fixture site as a person would (takes focus)
```

## Developer Tools

Our own DevTools, laid out and driven like Chrome's, docked to the page
(bottom, right, or a separate window). Shortcuts match Chrome: **⌥⌘I** toggles,
**⌥⌘J** opens the Console, **⌥⌘C** picks an element, **F12** toggles, and
right-click → *Inspect Element* opens the Elements panel on that node.

| Panel | What works |
|---|---|
| **Elements** | Live DOM tree with lazy loading, hover highlight with Chrome's box-model overlay, element picker, search (⌘F: text, selector or XPath), keyboard navigation, breadcrumbs. Edit attributes, text and outer HTML in place; delete, hide, scroll into view, copy selector, and **Break on…** subtree modifications, attribute modifications or node removal. **Styles** sidebar shows the cascade with overridden declarations struck through, inherited sections, media conditions, colour swatches, per-property enable/disable, in-place editing, adding properties and new rules, and **:hov** to force `:hover`, `:active`, `:focus` and the other states. **Computed** and **Layout** (box model). **Event Listeners**: every listener on the node (and, with *Ancestors*, up to the document and window), grouped by event, with handler name, capture/passive/once flags and a link to its source line; untick one to disable that listener without touching the page's code. |
| **Console** | Every level, `console.group`, `console.table`, repeat counters, uncaught errors and rejections with stacks linking into Sources, "Failed to load resource" for bad requests, filtering, preserve log, timestamps. Objects are expandable trees fetched lazily, like Chrome's. The prompt has history, autocomplete, top-level `await`, and the command-line API (`$0`–`$4`, `$`, `$$`, `$x`, `$_`, `copy`, `inspect`, `keys`, `values`). |
| **Sources** | Navigator grouped by origin, tabs, line numbers, syntax highlighting for JS, CSS, JSON and HTML (including embedded script and style), `{ }` pretty-print for minified JS, CSS and JSON, find in file, and links from console and network entries land on the line. **Source maps**: original files appear in the navigator, pauses, call stacks and console locations are shown at the original position, and a breakpoint set in an original file is placed at the right line and column of the bundle. **A real debugger**: click a line number for a breakpoint (persisted, survives reloads), right-click for a conditional breakpoint or a logpoint, pause, resume, step over / into / out (F8, F10, F11, ⇧F11 or ⌘\\, ⌘', ⌘;), pause on uncaught or all exceptions, `debugger;` statements, call stack, scope variables as lazy trees, watch expressions, and the Console evaluates in the selected frame while paused. **XHR/fetch breakpoints** (URL contains, or any request), **DOM breakpoints** and **Event Listener breakpoints** (mouse, keyboard, timers, animation frames and the rest) pause in the page's own code: the native function and our own hooks are left out of the call stack, and the banner names the node, URL or event. |
| **Network** | Every request from document start, merged from the two agents, WebKit's navigation response and, while DevTools is open, the inspector protocol: real status, request and response headers, and the response body exactly as the page received it, for every resource; WebSocket connections with a live Messages tab; type chips, text filter, sort, preserve log, **Disable cache** (while DevTools is open), right-click for **Copy as cURL / Copy as fetch / Copy URL / Copy response**, waterfall with DNS/connect/TLS/wait/download phases, and a detail pane with Headers, Payload, Preview (JSON tree, images), Response and Timing. HAR export. Where WebKit hides a body, *Fetch body again* re-requests it from the app with the profile's cookies. |
| **Performance** | **Record** (or *Reload and record*) captures a CPU profile and timeline: an event track (script, style, layout, paint), a zoomable flame chart, and Bottom-Up and Event Log tables; frames open their source. WebKit's sampler cannot see into optimised code, so script tasks are timed by the timeline and sparsely sampled stretches are drawn lighter and labelled as estimates. Plus FCP, LCP, CLS, INP, TTFB and long tasks as vitals, collected from document start for every page whether or not DevTools was open. |
| **Application** | Local and session storage (add, edit, delete, clear), cookies from the profile's cookie store including HttpOnly ones, IndexedDB names, page info. |
| **Device mode** | The phone icon gives the page a device's viewport (iPhone, Pixel, Galaxy, iPad presets, rotate) and user agent, centred on a backdrop. Media queries and UA sniffing respond; touch events and pixel ratio are not emulated. |

Not available because this WebKit does not offer them: network throttling
(`Network.setEmulatedConditions` is not in the protocol here) and a Service
Workers pane (no `ServiceWorker` domain).

Three things are structural differences from Chrome rather than features:
recording starts when the tab exists, not when the panel opens; the recording
outlives the document, so it spans reloads; and the observations that must be
trustworthy come from an isolated world page script cannot reach, while the
ones that cannot (console, fetch bodies) are labelled as such.

The UI is an HTML app in its own web view, exactly as Chrome's is, backed by
two injected agents (`InspectKit/Resources`) and a Swift controller
(`DevToolsController.swift`). That much uses public API only and ships
anywhere.

The debugger and the full network data come from the **WebKit Inspector
Protocol**, reached through `InspectorProtocolBridge.swift`: WebKit's own
inspector frontend is connected but never shown, and a shim in it relays
protocol messages to us. That is private API (`_WKInspector`), probed at
runtime: a Developer ID / DMG build gets it, and where it is missing the
Sources sidebar says so and everything else keeps working. While DevTools is
closed nothing is attached, so pages run at full speed.

```sh
scripts/test-devtools.sh      # runs every check below against the debug build
```

### Testing the DevTools

There is no XCTest on a Command Line Tools-only Mac, so the DevTools are
tested by a script that runs *inside* the DevTools UI, drives every panel
against a local fixture site, and writes a pass/fail report:

```sh
python3 Tests/Fixtures/devtools/server.py &
swift run SimpleBrowser --show-devtools \
  --devtools-script Tests/Fixtures/devtools/drive-all.js \
  --devtools-out /tmp/devtools-report.json --devtools-delay 4 http://127.0.0.1:8765/
cat /tmp/devtools-report.json     # "passed": true, "failures": []
```

Launch flags for driving the app from a script:

```sh
.build/debug/SimpleBrowser --show-devtools https://example.com
.build/debug/SimpleBrowser --dump-recording /tmp/rec.json https://example.com
.build/debug/SimpleBrowser --show-devtools --devtools-script drive.js --devtools-out out.json https://example.com
```

## Requirements

- macOS 15.4 or later (floor set by `WKWebExtension`)
- Swift 6.0 / Xcode 16.3 or later

## Build

```sh
swift build
swift test
```

## Architecture

```
BrowserApp          AppKit shell, SwiftUI panels          (not yet written)
  ├─ BrowserKit     Tab / Group / Window / Profile models, residency
  ├─ ProfileKit     Data-store lifecycle, config factory   (not yet written)
  ├─ BlockKit       filter parse → partition → compile
  ├─ InspectKit     agent bridge, recorder, debug backends
  ├─ NetProbe       loopback proxy                         (not yet written)
  └─ Persistence    GRDB, one database per profile         (not yet written)
```

Full design rationale in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## The four pillars

**Profiles.** `WKWebsiteDataStore(forIdentifier:)` gives per-profile isolation of
cookies, localStorage, IndexedDB, service workers and cache at the WebKit level.
A window belongs to exactly one profile.

**Tabs.** A live `WKWebView` costs several processes and 60–150 MB. Background
tabs hibernate: capture `interactionState`, snapshot, tear down the view.
Eviction policy is a pure function in `BrowserKit/EvictionPolicy.swift`.

**Blocking.** `WKContentRuleListStore` compiles rules to bytecode that runs in
WebKit's network process before dispatch. Faster than Chrome MV3 by
construction. The 150,000-rule cap forces partitioning; see below.

**Dev tools.** Injected agent split across an isolated `WKContentWorld`
(tamper-proof: DOM, errors, resource timing) and the page world (console,
fetch and XHR bodies), plus WebKit's Web Inspector, plus — later — a loopback
proxy for ground truth and a `DebugBackend` with two implementations.

## Verification

`BlockKit`'s partitioner is the one piece whose correctness was proven before it
was written. Two bugs were found and fixed at design time:

1. **Dropped whitelists.** `ignore-previous-rules` is scoped to its own compiled
   list. Slicing a rule set naively leaves exceptions in one chunk while the
   blocks they cancel land in another — whitelists fail silently. Every exception
   must be replicated into every chunk.

2. **Order inversion.** Hoisting exceptions to the tail changes meaning when an
   exception originally *preceded* an action rule. Safe at the ABP layer, where
   `@@` exceptions are position-independent; not safe at the WebKit-JSON layer,
   where order is significant. `partition` now rejects non-canonical input rather
   than silently reordering.

Both are locked down by `testNaiveSlicingBreaksWhitelists` and
`testNonCanonicalInputIsRejected`, plus a differential test running 3,000 random
rule sets × 15 probes against a single-list evaluation oracle.

## Distribution

Two builds, one codebase, split at the `DebugBackend` protocol:

| | Mac App Store | Developer ID (DMG) |
|---|---|---|
| Injected agent, proxy, blocking, profiles | yes | yes |
| Response bodies | instrumented mode only | MITM proxy, always |
| JS debugger | source instrumentation, 3–10× slower | `_WKInspector`, no cost |
| DOM / CSS cascade | reconstructed via CSSOM | `_WKInspector` |

## Releases and updates

**CI.** `.github/workflows/build.yml` builds every push and pull request on a
macOS runner, runs the checks and unit tests, and uploads the DMG as a
workflow artifact. Pushing a version tag publishes a release:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

That builds the universal app as version 0.2.0, packages
`SimpleBrowser-0.2.0.dmg`, signs it for the updater, and creates the GitHub
Release with the DMG and its `.sig` attached.

**Updating.** The app checks the latest GitHub Release a few seconds after
launch and then at most once a day (App menu → **Check for Updates…** checks
now). A newer version is offered with **Install Update**, **Remind Me Later**
or **Skip This Version**. Installing downloads the DMG and verifies its
Ed25519 signature against the public key compiled into the app
(`Updater.publicKey`); a DMG that does not verify is never opened, whoever put
it on the release page. It then checks the app inside is SimpleBrowser at the
version offered with an intact code signature, and once the running copy has
quit, swaps it in (putting the old copy back if that fails) and relaunches.
A copy run from the build folder has nothing to replace; it offers the release
page instead.

**The signing key.** The private key is the repository secret
`UPDATE_SIGNING_KEY`; a tag build fails without it rather than publishing an
update no one can install. Locally, `scripts/make-dmg.sh` signs with
`~/.simplebrowser-update-signing-key` when it exists. Losing the private key
means shipping one release by hand with a new public key; leaking it means
anyone can sign an update, so rotate it (`swift run SignUpdate --generate-key`)
and ship the new public key at once.

```sh
swift run UpdateKitChecks     # versions, release parsing, signatures, when to ask
scripts/test-update.sh        # 0.0.1 updates itself to 0.0.2 from a local feed; a tampered DMG is refused
```

## Licence

Not yet chosen.
