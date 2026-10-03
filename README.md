# Keel

A native macOS browser for developers and the AI agents they run. Swift
above the engine, WebKit below it. Formerly SimpleBrowser.

Agents connect over MCP and get their own sandboxed session by default:
a fresh profile with none of your cookies, tabs of their own, budgets, and
an approval card before anything consequential. Everything they do is on
the page in amber and in an audit log. See [AI agents](#ai-agents-mcp).

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
scripts/test-features.sh      # tabs, sessions, history, bookmarks, the address bar, blocking, Reader, private windows, downloads, the sidebar, ⌘K, split view, importing, extensions, AutoFill, media and native polish
scripts/test-downloads.sh     # downloads paused or under way at quit go on after a relaunch
scripts/test-performance.sh   # launch, new tabs, memory with 20 and 50 tabs, the processor while idle, against the budget
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
.build/debug/Keel --blocking-probe /tmp/probe.json about:blank   # the real lists, in a scratch folder
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

## Coming from another browser

The first launch opens a welcome window: pick the browser you use now, and
its bookmarks, history, open tabs and passwords come over from its own
files, with nothing to export. It also offers the search engine and
**Make Keel the Default Browser** (macOS confirms in its own
dialog). **File → Import From…** does the same at any time; nothing is
brought over twice.

| | Bookmarks | History | Open tabs | Passwords |
|---|---|---|---|---|
| Chrome, Brave, Edge, Arc, Vivaldi, Chromium (every profile) | ✓ | ✓ | ✓ | ✓ |
| Firefox | ✓ | ✓ | ✓ | from a file: about:logins → Export |
| Safari | ✓ with the reading list | ✓ | – | from a file: Passwords app → Export |

A browser's bookmarks bar becomes the favorites bar; its other bookmarks
go in *Imported from …* in the Bookmarks menu. History comes with its
visit counts, so the start page's frequently visited sites are the same
from the first day. Open tabs open in their windows, asleep until shown.
Chromium browsers encrypt their passwords with a key in your Keychain
("Chrome Safe Storage"): macOS asks you to allow Keel to use it.
Safari's files are kept from other apps until Keel has Full Disk
Access, which the window explains, with a button to the right place in
System Settings.

The other browser's databases are copied before they are read (a running
browser keeps them locked) and never written. `DataKitChecks` and the
`import` self-test read fixture browsers built in a scratch folder, never
yours.

## Extensions

Web extensions, through WebKit's own `WKWebExtension` (the reason macOS
15.4 is the floor): Manifest V3, and V2 where WebKit still runs it.
**Settings → Extensions → Add Extension…** takes an extension's folder
(with its `manifest.json`), a `.zip`, or a `.crx` from the Chrome Web
Store. Before it is added it says, in plain words, what the extension
could do ("Read and change your data on all websites", "See the addresses
and titles of your open tabs"…). Its files are copied in, so it does not
depend on where they came from.

Each extension is turned on per profile: it runs in the profile it was
added in, and in another only once turned on there. Private windows run
none. Its button is in the toolbar, with its badge and its popup; its
items are in the right-click menu; **Options** opens its settings page.
*Site access* is per extension and profile: every site it asks for, only
the page in front when you click it, or a list of sites. What it asks for
while running is asked of you, in the same words.

Extensions see the browser's windows and tabs as they are: a window is a
tab bar, and pinned tabs, the tab in front, a split view's pages, closing,
reloading and zoom all read and act as `chrome.tabs` and `chrome.windows`
expect.

Measured, not yet overcome: this WebKit does not deliver
`runtime.onInstalled`, in a persistent or a non-persistent store, with or
without its background page loaded. An extension that only sets things up
there (a right-click menu, say) finds them missing until it sets them up
another way; set up when its worker starts, they work. The self-test's
extension does it that way.

Not yet verified here: which popular Chrome extensions work unmodified.
That needs them downloaded from the Chrome Web Store and tried one by one,
and a password manager's needs an account signed in; the self-test covers
the same ground with an extension of its own: a content script, a popup
that fills a sign-in form through `chrome.tabs.sendMessage`, a background
worker with a badge and a right-click item, per-profile isolation and site
access.

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

## Media

A tab playing sound shows a speaker on its tab; a click on it mutes the
tab, WebKit's own mute, which the page cannot undo. **Window → Mute Tab**
does the same, and **Mute Background Tabs** quietens every tab but the one
in front.

Whatever is playing, in whichever tab, is in the toolbar of every window
as a **now-playing** control: its title (the page's Media Session
metadata, or the tab's title), play/pause, and next where the page offers
it; a click on the title shows the tab. The Mac's own controls follow it:
the media keys and the Now Playing panel in Control Center see the tab
playing, and the keys go to the tab that started playing last, wherever
it is, not to the tab in front. A page's own next and previous handlers
are called for the next and previous keys.

**View → Enter Picture in Picture**, or the button that appears in the
toolbar when a page has a video, takes the video out of the page into a
window of its own, over everything; again puts it back. With
**Settings → General → Picture in Picture when you leave a tab playing a
video** on, a playing video goes out by itself as another tab is chosen,
and comes back into its page when the tab is chosen again. Pages may go
full screen.

## Keyboard, trackpad and accessibility

Every shortcut, beside what Safari and Chrome use for the same thing. The
table is made from the catalogue in `BrowserKit/Shortcuts.swift`, which
also holds the keys macOS keeps for itself (Spotlight, screenshots,
Mission Control, Force Quit…); `BrowserKitChecks` fails if two commands
share a key, if one is the Mac's own, or if this table drifts from the
catalogue, and the feature self-test fails if the menu bar drifts from it.

| Command | Keel | Safari | Chrome |
|---|---|---|---|
| New Window | ⌘N | ⌘N | ⌘N |
| New Private Window | ⇧⌘N | ⇧⌘N | ⇧⌘N |
| New Tab | ⌘T | ⌘T | ⌘T |
| Open Location… | ⌘L | ⌘L | ⌘L |
| Command Palette… | ⌘K | — | — |
| Close Tab | ⌘W | ⌘W | ⌘W |
| Close Window | ⇧⌘W | ⇧⌘W | ⇧⌘W |
| Reopen Closed Tab | ⇧⌘T | ⇧⌘T | ⇧⌘T |
| Undo | ⌘Z | ⌘Z | ⌘Z |
| Redo | ⇧⌘Z | ⇧⌘Z | ⇧⌘Z |
| Cut | ⌘X | ⌘X | ⌘X |
| Copy | ⌘C | ⌘C | ⌘C |
| Paste | ⌘V | ⌘V | ⌘V |
| Paste and Go | ⇧⌘V | ⇧⌘V (Paste and Match Style) | ⇧⌘V (Paste and Match Style) |
| Select All | ⌘A | ⌘A | ⌘A |
| Find… | ⌘F | ⌘F | ⌘F |
| Find Next | ⌘G | ⌘G | ⌘G |
| Find Previous | ⇧⌘G | ⇧⌘G | ⇧⌘G |
| Use Selection for Find | ⌘E | ⌘E | ⌘E |
| Show Sidebar | ⇧⌘S | ⇧⌘L | — |
| Show All Tabs | ⇧⌘\ | ⇧⌘\ | — |
| Reload Page | ⌘R | ⌘R | ⌘R |
| Reload Page From Origin | ⌥⌘R | ⌥⌘R | ⇧⌘R |
| Stop | ⌘. | ⌘. | ⌘. / Esc |
| Actual Size | ⌘0 | ⌘0 | ⌘0 |
| Zoom In | ⌘+ | ⌘+ | ⌘+ |
| Zoom Out | ⌘- | ⌘- | ⌘- |
| Show Reader | ⇧⌘R | ⇧⌘R | — |
| Translate Page | ⌥⌘T | — | — |
| Back | ⌘[ | ⌘[ | ⌘[ |
| Forward | ⌘] | ⌘] | ⌘] |
| Home | ⇧⌘H | ⇧⌘H | ⇧⌘H |
| Show All History | ⌘Y | ⌘Y | ⌘Y |
| Add Bookmark… | ⌘D | ⌘D | ⌘D |
| Add to Reading List | ⇧⌘D | ⇧⌘D | ⇧⌘D (bookmark all tabs) |
| Show Bookmarks | ⌥⌘B | ⌥⌘B | ⌥⌘B |
| Show Favorites Bar | ⇧⌘B | ⇧⌘B | ⇧⌘B |
| Show Developer Tools | ⌥⌘I | ⌥⌘I | ⌥⌘I |
| JavaScript Console | ⌥⌘J | ⌥⌘C | ⌥⌘J |
| Inspect Elements | ⌥⌘C | — | ⌥⌘C |
| Show Recording Log | ⌃⌥⌘L | — | — |
| Pick Color… | ⌃⌥⌘C | — | — (Color Picker extension) |
| Pair a New Agent… | ⌥⌘P | — | — |
| Agent Activity Log | ⌥⌘A | — | — |
| Pause All Agents | ⇧⌘. | — | — |
| Copy Snapshot for AI | ⌥⇧⌘C | — | — |
| Downloads | ⌥⌘L | ⌥⌘L | ⇧⌘J |
| Show tab 1–9 | ⌘1–⌘9 | ⌘1–9 | ⌘1–8, ⌘9 last |
| Next tab | ⇧⌘] | ⇧⌘] / ⌃⇥ | ⌥⌘→ / ⌃⇥ |
| Previous tab | ⇧⌘[ | ⇧⌘[ / ⌃⇧⇥ | ⌥⌘← / ⌃⇧⇥ |
| Next tab (also) | ⌥⌘→ | — | ⌥⌘→ |
| Previous tab (also) | ⌥⌘← | — | ⌥⌘← |
| Developer Tools | F12 | — | F12 |
| Switch to profile 1–9 | ⌥⇧⌘1–9 | — | — |

**Settings → Advanced** changes any of them: choose the command, click the
box and press the keys. A key the Mac keeps, or another command already
has, is refused and the reason shown; the keys every Mac app has (Quit,
Hide, Minimize, Settings, Full Screen) stay where they are. ⌘1–⌘9, the
tab keys and F12 are handled by the window itself and cannot be changed.

**Trackpad**: swipe with two fingers for Back and Forward, pinch to zoom
the page and double-tap with two fingers to zoom in on a part (WebKit's
own smart zoom), and pinch in on a page that is not zoomed to see every
tab. **View → Show All Tabs** (⇧⌘\) is the same overview: every tab of
the window as a picture with its title; a click or Return opens one, ✕
closes it, typing narrows the tabs to those matching, arrows move, Esc
leaves. A tab in the background is shown as it last looked in front, and
one never seen as its site's initial.

**Accessibility**: every control has a name for VoiceOver, which the
self-test checks in the browser window and every Settings pane. With
*Reduce Motion* on, nothing fades or slides: the overview and the Settings
window are simply there. With *Increase Contrast* on, the start and error
pages use full lines and colours (`prefers-contrast: more`), and the
overview's backdrop is opaque. Full Keyboard Access reaches every button.

**Settings** has eight panes: General (start-up, homepage, search,
downloads), Tabs (where tabs go, what new windows open with, Picture in
Picture on leaving a tab, Memory Saver), Passwords, AutoFill, Privacy,
Websites, Extensions and Advanced (shortcuts). The start page, Reader,
certificate warnings and the error page follow the system's light or dark
look and its accent colour.

**Handoff**: the page in front is offered to your other devices, as Safari
does (`NSUserActivityTypeBrowsingWeb`), and a page handed over from an
iPhone or another Mac opens here as a new tab. Private windows offer
nothing. Handoff needs the app signed with a Developer ID, as the DMG is.

**The error page**: a load that fails says what went wrong in plain words
(you're offline; the site can't be found, refused the connection, took
too long; the connection isn't secure), with *Try Again* and the system's
own wording under *Details*.

## Performance budget

"Fast" and "doesn't drain the battery" are numbers here, not impressions.
`scripts/test-performance.sh` launches the app cold onto the start page,
opens tabs of the fixture site to 20 and then 50, lets Memory Saver run,
then idles with ten busy background pages (a timer and an animation each),
measuring the app and its web, network and GPU processes together. The
numbers are judged against this budget, which lives in
`BrowserKit/PerformanceBudget.swift`; over it, the script fails.

| What | Budget |
|---|---|
| Cold launch to first window | 1.20 s |
| Cold launch to start page | 1.60 s |
| New tab to page loaded, median | 0.40 s |
| New tab to page loaded, slowest | 1.00 s |
| Memory with 20 tabs | 1100 MB |
| Memory with 50 tabs | 2200 MB |
| Memory with 50 tabs after Memory Saver | 1300 MB |
| Processor, 10 busy background tabs idle | 5.00 % of a core |

Measured on a debug build on an M-series Mac, with about half again as
headroom over what was seen; `RELEASE=1` measures the release build. The
idle figure is processor time over the idle period as a share of one core.

What keeps the numbers down: background tabs are WebKit's own affair
(timers throttled, animations stopped, media paused when a page is not
visible) plus Memory Saver, which puts tabs to sleep after half an hour
unused or when more than a dozen are in the background, and the app's
own timers carry a tolerance so the system can group their wake-ups.
Housekeeping waits for a quiet moment: filter-list updates, update checks
and history pruning run through `NSBackgroundActivityScheduler`, never
while the Mac is napping the app, and never while a page is loading.

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

## AutoFill: addresses, cards, codes and passkeys

**Settings → AutoFill** keeps addresses and cards, in an encrypted file
beside the passwords and sealed with the same Keychain key. A card's
security code is never kept, and never filled. *Add My Card from Contacts*
takes your own card from Contacts.

In a form, the fields are recognised by what the page says they are
(`autocomplete`), and failing that by their names and labels, in English
and the languages of the largest shops. The list under the field offers
the whole form first, **Home · Visa •••• 4242**: one choice, confirmed with
Touch ID or your Mac's password when there is a card in it, fills name,
address and card, and the page's own code sees each field change as if it
had been typed. Countries, months and years in drop-downs are matched
however the shop writes them. An address or card typed into a form is
offered to be kept; a private window keeps nothing.

**One-time codes**: a field for a code sent by text message or email
(`autocomplete="one-time-code"`) opens a small field of the Mac's own,
where macOS AutoFill offers the code that just arrived in Messages or
Mail; it goes into the page.

**Passkeys**: WebKit signs in with passkeys, from iCloud Keychain or any
passkey app, once the browser holds Apple's browser passkey entitlement
and you have allowed it (Settings → AutoFill, or the first time a site asks
for one). The entitlement is granted by Apple on request; `scripts/make-dmg.sh`
adds it only when `PASSKEYS_PROVISIONING_PROFILE` points at the profile
that grants it, since an app signed with it and without the profile does
not launch. Builds without it say so in Settings, and sites fall back to
their other ways of signing in.

## Developer Tools

Our own DevTools, laid out and driven like Chrome's, docked to the page
(bottom, right, or a separate window). Shortcuts match Chrome: **⌥⌘I** toggles,
**⌥⌘J** opens the Console, **⌥⌘C** picks an element, **F12** toggles, and
right-click → *Inspect Element* opens the Elements panel on that node.

| Panel | What works |
|---|---|
| **Elements** | Live DOM tree with lazy loading, hover highlight with Chrome's box-model overlay, element picker, search (⌘F: text, selector or XPath), keyboard navigation, breadcrumbs. Edit attributes, text and outer HTML in place; delete, hide, scroll into view, copy selector, and **Break on…** subtree modifications, attribute modifications or node removal. **Styles** sidebar shows the cascade with overridden declarations struck through, inherited sections, media conditions, colour swatches, per-property enable/disable, in-place editing, adding properties and new rules, and **:hov** to force `:hover`, `:active`, `:focus` and the other states. **Computed** and **Layout** (box model). **Accessibility**: the accessibility tree from the root down to the node and its accessible children (click to select, hover to highlight), and the node's computed name (with where it came from: contents, label, `aria-label`, `alt`, placeholder…), role, description and states. Role, name and states are WebKit's own accessibility object (`DOM.getAccessibilityPropertiesForNode`), what VoiceOver gets; without the protocol they are computed by DevTools and labelled as such. **Event Listeners**: every listener on the node (and, with *Ancestors*, up to the document and window), grouped by event, with handler name, capture/passive/once flags and a link to its source line; untick one to disable that listener without touching the page's code. **Badges** in the tree: `grid` and `flex` (click for an on-page overlay with grid lines and track sizes, or the flex container and its items), `scroll`, `event` (has listeners; opens Event Listeners), `slot` (reveals the slot), and `#shadow-root (open)` with shadow roots in the breadcrumbs. **Drag and drop** to move nodes; **⌘Z / ⇧⌘Z** undo and redo every edit (attributes, text, Edit as HTML, delete, move, hide, styles), keeping the same nodes and their listeners. Search matches are highlighted in the tree. Right-click → **Copy** selector, JS path (into shadow roots), XPath, full XPath, styles, outerHTML, or **element for AI** (Markdown: tag, accessibility role and name, attributes, box, key computed styles, matched rules, HTML); **Store as global variable** (`temp1`). Colour swatches open a **colour picker** (saturation/brightness, hue, opacity, hex/rgb/hsl, the eyedropper where the web view has `EyeDropper`, which WebKit does not), **.cls** toggles and adds classes, right-click a declaration or rule for **Copy declaration / property / value / rule / all declarations**, also **as JS** (camelCase). **Computed** shows the properties rules set (or **Show all**), optionally **grouped**, and each expands to the trace of the declarations behind it, overridden ones struck. **Layout**: box-model numbers are editable (set on the element's style). |
| **Console** | Every level, `console.group`, `console.table`, repeat counters, uncaught errors and rejections with stacks linking into Sources, "Failed to load resource" for bad requests, filtering, preserve log, timestamps. Objects are expandable trees fetched lazily, like Chrome's. The prompt has history, autocomplete, top-level `await`, and the command-line API (`$0`–`$4`, `$`, `$$`, `$x`, `$_`, `copy`, `inspect`, `keys`, `values`). **Live expressions** (the eye button) are pinned above the messages and re-evaluated four times a second while the Console shows, without logging or keeping objects alive; they are remembered. Right-click a message for **Copy for AI** (level, text, source location mapped through source maps, and the stack, as Markdown), **Copy all errors as Markdown** and **Copy console as Markdown**. Values render as Chrome's: `Array(3) [1, 2, 3]`, `{a: 1, b: {…}}`, `Map(1) {'a' => 1}`, `Promise {<fulfilled>: 3}` (state known for promises the console produced; a promise from `console.log` shows `<pending>` unless already seen), class names, DOM nodes as inline elements that highlight on hover and reveal on click, functions with their source when expanded, errors with source-mapped, clickable frames. The prompt is **syntax highlighted**, **multi-line** (⇧↩; ↩ continues while brackets are open), shows an **eager evaluation** preview for side-effect-free expressions (reads, operators and an allow-list of pure calls; best effort, getters still run) and **autocompletes** the properties of whatever is before the dot, with their kind (method, property, getter…; in the paused frame, its variables too). History is kept by the app across sessions. The **sidebar** counts messages, user messages, errors, warnings, info and verbose, each by file, and filters by them; settings (⚙) for **Group similar**, **Hide network**, **Log XMLHttpRequests** and eager evaluation. Right-click a message for **Copy stack**, **Copy for AI** (now with the lines of code around the location), **Store as global variable**, **Reveal in Sources panel** and **Save as…** (the whole console as text). |
| **Sources** | Navigator grouped by origin, tabs, line numbers, syntax highlighting for JS, CSS, JSON and HTML (including embedded script and style), `{ }` pretty-print for minified JS, CSS and JSON, find in file, and links from console and network entries land on the line. **Source maps**: original files appear in the navigator, pauses, call stacks and console locations are shown at the original position, and a breakpoint set in an original file is placed at the right line and column of the bundle. **A real debugger**: click a line number for a breakpoint (persisted, survives reloads), right-click for a conditional breakpoint or a logpoint, pause, resume, step over / into / out (F8, F10, F11, ⇧F11 or ⌘\\, ⌘', ⌘;), pause on uncaught or all exceptions, `debugger;` statements, call stack, scope variables as lazy trees, watch expressions, and the Console evaluates in the selected frame while paused. **XHR/fetch breakpoints** (URL contains, or any request), **DOM breakpoints** and **Event Listener breakpoints** (mouse, keyboard, timers, animation frames and the rest) pause in the page's own code: the native function and our own hooks are left out of the call stack, and the banner names the node, URL or event. **⌥⌘F** searches every loaded source, original (source-mapped) files included, with match case and regular expressions, in the drawer; **⌃G / ⌘L** go to line, **⇧⌘O** go to symbol (functions, classes and methods found by pattern; rules in CSS). The current line is marked, brackets are matched at the caret, a selected word is highlighted throughout the file, and `{}` / `[]` blocks fold from the gutter (⌥⌘[ / ⌥⌘]). **Snippets** (navigator tab): scripts you keep (by the app), edit in a highlighted editor and run with ⌘↩ or ▶ (in the paused frame when paused). While paused, **hover** a variable or property chain to see its value, and the paused function's variables are shown **inline** at the end of the lines that use them (best effort: found by name from the function's start). The gutter menu has **Continue to here** and **Never pause here** (a breakpoint whose condition is `false`); **Add script to ignore list** (code or call-stack menu, listed under *Ignore List*, kept) makes stepping skip a script and folds its frames away in the call stack; right-click the call stack for **Copy call stack** and **Copy for AI** (reason, code around the line, mapped stack, scope values, watches). |
| **Network** | Every request from document start, merged from the two agents, WebKit's navigation response and, while DevTools is open, the inspector protocol: real status, request and response headers, and the response body exactly as the page received it, for every resource (binary ones too); WebSocket connections with a live Messages tab. **Request list**: type chips, preserve log, **Disable cache** (while DevTools is open), sort by any column, ↑/↓ to move through requests, and a filter box with Chrome's syntax (`status-code:404`, `-status-code:200`, `domain:*.example.com`, `method:POST`, `mime-type:`, `larger-than:100k`, `is:running`, `is:from-cache`, `has-response-header:`, `resource-type:`, `scheme:`, `cookie-name:`, `set-cookie-name:`, `priority:`, `protocol:`, `remote-address:`, `-` to negate any term, `/regex/`) with **Invert**. Right-click the header to show or hide columns (Name, Status, Method, Domain, Type, Initiator, Protocol, Remote Address, Cookies, Set-Cookies, Priority, Size, Time, Waterfall); status codes carry their reason phrase, coloured by class; Size says when a response came from the memory or disk cache. The waterfall shows DNS/connect/TLS/wait/download phases with DOMContentLoaded and load lines, and the summary bar shows requests, transferred, resources, Finish, DOMContentLoaded and Load. **Explain failures** narrows the list to failed, blocked, CORS-failed, 4xx/5xx and slow (over 1 s) requests with the reason under each, and copies them for an AI. **Headers**: General (URL, method, status, Remote Address, Referrer Policy, protocol, priority, cache source, redirects, issues), Response and Request sections each with a **Raw** HTTP/1.1 view, a filter box, Copy on every header, links on URL-valued headers (Location, Link, Referer…), and cache, cookie, CORS, CSP, encoding and HSTS headers marked. **Payload**: query string, form data, multipart parts and JSON as tables or a tree, with view source. **Preview** by content type: HTML rendered in a sandboxed frame (no scripts, relative URLs resolved) or as formatted source; JSON as a tree with expand/collapse all, search, and right-click *Copy value* / *Copy property path* (`data.items[3].id`); JSONP; NDJSON as records; `text/event-stream` as a list of events; XML, RSS/Atom and SVG as a collapsible tree; images with natural size, bytes and MIME on a checkerboard; SVG rendered; fonts loaded and set as a pangram at six sizes; audio and video players; CSS, JS and other text formatted and highlighted; `x-www-form-urlencoded` and multipart as tables; anything binary as a hex dump (offset, bytes, ASCII; the first 64 KB). **Response**: line numbers, syntax highlighting, `{ }` pretty-print for JS, CSS, JSON and HTML, word wrap, **⌘F** find inside the pane with every match marked and next/previous, Copy and *Save…*; a multi-megabyte body draws only its visible lines (highlighting goes line by line past 1.5 MB, and lines over 100,000 characters are cut on screen), so a 2.6 MB minified bundle opens and pretty-prints in well under a second. **Cookies**: request cookies (with domain, path, expiry and flags from the cookie store) and every Set-Cookie with all its attributes, flagging missing Secure or SameSite, SameSite=None without Secure, broken `__Secure-`/`__Host-` prefixes and session-like cookies readable from script. **Initiator**: the chain from the document, the engine's initiator (parser or script and where) and the JavaScript call stack that started the request, linking into Sources, plus the requests this one started. **Timing**: queued and started times, the phase bars, and the server's own `Server-Timing` entries. Right-click → **Copy** ▸ URL, cURL (bash), fetch, fetch (Node.js), PowerShell, response, HAR entry, Markdown for AI, and all URLs / all as cURL / all as HAR / summary / failures. **Import HAR…** (or drop a `.har` on the panel) opens a file as a read-only log beside the live one; **Export HAR**. Where WebKit hides a body, *Fetch body again* re-requests it from the app with the profile's cookies; a body the page hooks cut at 256 KB is read whole from the engine. **Request blocking** (right-click → *Block request URL* / *Block request domain*, or the *Network request blocking* drawer: patterns with `*` wildcards, per-pattern and global switches) is enforced by a WebKit content rule list on the tab, so every resource type is blocked before it is requested, with or without the inspector protocol, and only while DevTools is open. **Local overrides** (right-click → *Override content…* / *Override headers…*, or the *Local overrides* drawer) answer matching URLs with your status, headers and body through the protocol's request interception, so the server is never asked; *keep the original body* has the app fetch it and serve it under your headers. Needs the protocol; the drawer says so when it is missing. **⌘F** (outside the response pane) searches every request's URL, request and response headers, payload and body. **Copy for AI**: *Copy as Markdown* gives the method, URL and status line, size, time, protocol, remote address, initiator, phase timing and Server-Timing, a one-line list of issues (4xx/5xx, failed, blocked, CORS, slow over 1 s, larger than 1 MB, uncompressed text, no caching headers), only the headers that matter with cookies and credentials redacted, the payload, and the body cut to 4,000 characters keeping its shape (JSON arrays and strings shortened, long text as head and tail, binary named but left out); also *Copy all as Markdown summary*, *Copy failures for AI* and *Copy all as HAR*. Remote address, priority, cache source and initiator stacks come from the inspector protocol, so requests that finished before it attached have none. |
| **Performance** | **Record** (or *Reload and record*) captures a CPU profile and timeline: an event track (script, style, layout, paint), a zoomable flame chart, and Bottom-Up and Event Log tables; frames open their source. WebKit's sampler cannot see into optimised code, so script tasks are timed by the timeline and sparsely sampled stretches are drawn lighter and labelled as estimates. Plus FCP, LCP, CLS, INP, TTFB and long tasks as vitals, collected from document start for every page whether or not DevTools was open. |
| **Memory** | **Heap snapshots** from JavaScriptCore (`Heap.snapshot`), summarised by constructor with count, shallow size and **retained size** computed from the dominator tree (an instance kept alive by another of its class counts once); expand a class for its instances. **Comparison** of two snapshots by object id (# New, # Deleted, # Delta, allocated, freed and size delta). **Collect garbage** (`Heap.gc`). **JS heap size over time** (and the page's total) from WebKit's `Memory` domain, sampled while the panel shows. *Copy summary* gives the top classes as Markdown. JSC snapshots have no retainer paths by property name in this UI, no allocation timelines and no sampling profiler; it all needs the protocol. |
| **Audits** | Lighthouse-style report in four scored categories. **Accessibility**: image alt text, form labels (a placeholder is not a label), button and link names, `lang` present and valid, title, one main landmark, heading order, unique ARIA ids, positive `tabindex`, zoom not disabled, and **colour contrast** (WCAG AA against the computed background; text over images or gradients is counted as unchecked). **SEO**: title, meta description, viewport, valid canonical, not blocked from indexing (meta or `X-Robots-Tag`), descriptive link text, crawlable links, valid `hreflang`, HTTP status. **Best practices**: HTTPS, mixed content (DOM and network), console errors and failed requests, deprecated HTML and deprecation warnings, image aspect ratio, doctype, charset. **Performance**: FCP, LCP, Total Blocking Time (from long tasks), CLS and TTFB, scored on Lighthouse's thresholds, plus render-blocking resources, oversized and large images, total bytes, DOM size and long tasks. DOM checks run in the isolated world; every finding links to its node in Elements or its request in Network; *Copy* / *Export* as JSON or Markdown. Unlike Lighthouse it audits the page as it is (tick *Reload first* for fresh load metrics) with no simulated throttling, and "deprecated APIs" means obsolete HTML plus console deprecation warnings, since WebKit has no deprecation reports. |
| **Application** | Local and session storage (add, edit, delete, clear), cookies from the profile's cookie store including HttpOnly ones, page info. **IndexedDB**: databases → object stores (key path, indexes, count) → records, 50 to a page, with the key and the value as an expandable tree (dates, maps, sets, blobs and binary are shown for what they are); delete a record, clear a store, delete a database. **Cache Storage**: caches → entries (status, type, size) → the cached response's headers and body; delete an entry or a cache. **Manifest**: the Web App Manifest from `<link rel="manifest">`, with identity, presentation, colours, icons, raw JSON and installability warnings. **Service workers**: registrations with their active, waiting and installing workers, *Update* and *Unregister*, read through `navigator.serviceWorker` (where this web view offers service workers at all; the pane says when it does not). **Storage** shows usage and **Clear site data** (cookies, storage, IndexedDB, caches and service workers for the site, in this profile). These run in the isolated world, which shares the page's origin. |
| **Animations** (drawer) | Every running CSS animation, CSS transition and Web Animation (`document.getAnimations()`), with its target node (click to reveal), duration, delay, iterations and easing, and a timeline you can click to scrub; pause, resume and replay one or all, playback rate 100 %, 25 % or 10 %. WebKit's `Animation` domain only reports animations, it cannot pause or seek them, so control goes through the Web Animations API from the isolated world; the rate applies to the animations running when you set it, not ones that start later. |
| **Command menu** | **⇧⌘P** runs any command by fuzzy name, as in Chrome: show a panel or drawer tool, the Rendering toggles and media emulation, *Disable JavaScript*, *Capture screenshot* / *full size* / *node*, *Clear site data*, cache, dock side, theme, *Copy network log* and *Copy all console errors* as Markdown, *Export HAR*. **⌘P** opens any file the Sources navigator knows. Both are also in the **⋮** menu. |
| **Rendering** (drawer) | Paint flashing, layer borders, layer repaint counters and rulers (WebKit's own overlays, through the protocol), a **frame rendering stats** overlay drawn in the page (frames per second and dropped frames, counted from animation frames), **emulated CSS media** type (`print`, `screen`) and media features `prefers-color-scheme`, `prefers-reduced-motion` and `prefers-contrast`, **Disable JavaScript** and **Disable images** (the page's own scripts stop; the DevTools agents keep working; reload to apply to the whole page). Everything is undone while DevTools is hidden, as in Chrome. All but the FPS overlay need the protocol (without it, `prefers-color-scheme` still follows the web view's appearance); the drawer shows the error when it is missing. WebKit has no FPS meter, scrolling-performance or layout-shift-region overlays of its own. |
| **Screenshots** | *Capture screenshot* (the viewport, `WKWebView.takeSnapshot`), *Capture full size screenshot* (the whole document, `Page.snapshotRect`) and *Capture node screenshot* (from the command menu or right-click in Elements; `Page.snapshotNode`, or without the protocol the visible part of the node's box), saved to Downloads as PNG. |
| **Device mode** | The phone icon gives the page a device's viewport (iPhone, Pixel, Galaxy, iPad presets, rotate) and user agent, centred on a backdrop. Media queries and UA sniffing respond; touch events and pixel ratio are not emulated. |

Not available because this WebKit does not offer them: network throttling
(`Network.setEmulatedConditions` is not in the protocol here); service worker
start/stop, push, sync and offline emulation (no `ServiceWorker` domain for
pages; the Application panel lists registrations through the page's own API);
Chrome's layer-border command (`Page.setCompositingBordersVisible` is missing,
so *Layer borders* uses WebKit's `ShowDebugBorders` setting instead); an FPS
meter of WebKit's own (ours counts animation frames in the page, so an
occluded window, which gets none, shows 0); retainer paths and allocation
timelines in the Memory panel.

Every tool added on top of WebKit's protocol says so in its own pane when the
protocol is missing, and keeps working where it can without it: request
blocking (a content rule list), the FPS meter, the Accessibility pane
(computed), screenshots of the viewport, Audits, Application storage and
Animations.

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

### Developer extensions

Seven developer extensions ship with the browser, each on by default and
switched in **Develop → Developer Extensions**. They are built in rather than
installed: React DevTools, Clockwork and their kind are Chrome extensions
written against `chrome.devtools`, which WebKit's extension API does not
have, so each is rebuilt on these DevTools.

| Extension | What it does |
|---|---|
| **React Developer Tools** | A **Components** panel, shown once a page renders with React: the component tree (host elements on request), search, props, hooks with `useState` / `useReducer` values editable in place, class state, owners, source location, hover to highlight, *From Elements* to find the component that rendered the selected element, *Copy for AI*. It installs the same global hook React DevTools does, before the page's scripts run. |
| **dataLayer Inspector** | A **dataLayer** panel, shown once a page uses one: every push to `window.dataLayer` from document start, including gtag's `arguments` and pushes made after Tag Manager replaces `push`, beside the GA4 hits the page sent (parsed from the network log). Containers found on the page, the merged model, a test push, export as JSON. Renamed layers (`gtm.js?l=…`) are followed. |
| **Laravel / PHP Debug** | A **PHP** panel for apps with Clockwork or Laravel Debugbar: each instrumented request's server profile, fetched by the app with the page's cookies. Overview, database queries with repeated query shapes (N+1) marked, logs, timeline, views, *Copy for AI*. The Xdebug triggers the "Xdebug helper" extensions set — `XDEBUG_SESSION`, `XDEBUG_PROFILE`, `XDEBUG_TRACE` with your IDE key — are a click away and need neither. |
| **Node.js Debugger** | A **Node** panel that finds processes started with `node --inspect` on the ports you list, as chrome://inspect does, and debugs them over the Chrome DevTools Protocol: console output, a REPL (in the paused frame when paused), scripts, breakpoints from the gutter, pause on uncaught exceptions, pause, resume, step, call stack and scope. |
| **Claude** | A **Claude** panel: ask about the page with what DevTools sees attached — the page, the selected element with its HTML and matched CSS, console errors with stacks, failed requests, the selected request with its bodies, the selected React component. Answers stream in from Claude Opus 5.5. The app makes the call with your Anthropic API key, kept in the macOS keychain (or `ANTHROPIC_API_KEY`); pages never see it. |
| **Color Picker** | **Develop → Pick Color…** (⌃⌥⌘C) and the eyedropper button in DevTools' toolbar sample any pixel on screen with macOS's colour sampler and copy its hex; RGB, HSL and SwiftUI forms one click away. The Styles colour picker's eyedropper uses it too, since WebKit has no `EyeDropper`. |
| **JSON Viewer** | A JSON document opened in a tab shows as a collapsible tree with Raw and Pretty views, a filter, *Expand all*, and paths copied with a click (`orders[1].total`); light and dark. In DevTools, Network's Response tab shows JSON responses as the same kind of tree, or as code, as you last chose. |

React, dataLayer and JSON Viewer add scripts to pages, so turning them on or
off applies to tabs opened afterwards; the panels follow at once. Not done:
the Profiler tab of React DevTools; profiling Node (CPU and heap) — the Node
panel debugs; Clockwork's own XHR history beyond what the page loaded.

### AI agents (MCP)

The browser is also an MCP server, so Claude Code, Cursor, Codex or any
other MCP client can drive it and see what DevTools sees. Turn it on in
**Settings → Agents & permissions → Allow agent connections**.

**Pairing.** Every client pairs once and gets a token of its own, which
you can pause or revoke on its own. Two ways:

- From the client: `keel pair` (the [command-line tool](docs/CLI.md)) asks
  Keel to pair; Keel shows the request with the client's name and process,
  you choose its grants and press **Pair**. For stdio clients, the launcher
  pairs by itself on first use:

  ```sh
  claude mcp add keel -- keel mcp
  ```

- From Keel: **Agent → Pair a New Agent…** (⌥⌘P) makes a token and gives
  you the command for the client, for example
  `claude mcp add --transport http keel http://127.0.0.1:9333/mcp --header "Authorization: Bearer keel_…"`,
  or the `mcpServers` JSON for Cursor, Windsurf and VS Code.

Tokens live in the login Keychain; Keel keeps only their hashes. A token
from before pairing existed keeps working as a client called "Shared token
(before pairing)" until you revoke it.

**Sessions.** Each client gets a session (`session a91f`). By default it is
a **sandbox**: its tabs open in a window of their own with an in-memory
data store, so the agent has none of your cookies, logins or history, and
everything is wiped when the session ends. It sees only its own tabs, never
yours. For debugging an app you are signed in to, **Agent → Session →
Borrowed…** lends chosen origins of your profile for 15 minutes, an hour or
until you stop it: the agent can then act as you on those origins only, a
coral banner says so with *End now*, and navigation anywhere else is
blocked and logged. Email, banking and password managers are never
lendable. **Agent → Hand Tab to Agent…** gives one of your tabs to the
session the same way.

**What always asks first.** Paying or placing an order, typing a card
number or a password, sending or publishing, deleting, uploading or
downloading files, running JavaScript in a borrowed session, and anything
on a page whose text tries to instruct agents. The page shows an amber ring
and the ref (`e14 · Claude`) on the element, and an approval card says what,
where and why: *Allow once*, *Deny*, *Always allow on this origin for 1 h*
(never for payments or passwords), or *Stop & revoke*. No answer within two
minutes counts as denied. The policy, the timeout and per-origin rules
(Ask, Allow, Never) are in Settings → Agents & permissions.

**Page content is untrusted.** Text a page controls comes back to the
agent inside `<untrusted-page-content origin="…">`, and text addressed to AI
agents ("ignore previous instructions…", hidden or not) is flagged beside
it and shown to you. No control eliminates prompt injection; the sandbox,
the origin limits and the approvals keep what an obeyed injection can reach
small.

**Budgets and the kill switch.** A session has an action budget (200), a
navigation rate (30 a minute), a snapshot size (8,000 tokens), a tab limit
(10) and a time limit (60 minutes), all adjustable per client.
**Pause All Agents** (⇧⌘.) stops every session where it is; **Stop &
Revoke All** deletes every token, ends every session, wipes the sandboxes,
and tells you what it did.

**Seeing what happened.** Agent tabs are amber: a 3-point edge along the
top of the page, a marker with the client's name in the tab strip, and the
identity chip (*Sandbox · ephemeral* in green, *Borrowed · origin · 42 min*
in coral) and *N waiting* in the toolbar. **Agent Activity Log** (⌥⌘A)
lists every session with its timeline, exports it as JSON, and exports a
*replay* that `keel replay` runs again. Logs are append-only JSON Lines in
`~/Library/Application Support/Keel/Agents/Logs`, kept for 30 days, with
card numbers left out.

| Tools | What they do |
|---|---|
| `list_tabs` `new_tab` `select_tab` `close_tab` | The session's own tabs. Tools act on the tab the agent last opened or selected; each takes a `tabId`. `new_tab` opens in the session's sandbox (or borrowed) window. |
| `navigate` `wait_for` | Go to a URL, back, forward, reload; wait for the load, text, a selector, network idle. Results give the final URL, title and HTTP status. |
| `snapshot` | The page as an accessibility tree with a ref on every element, the way Playwright's MCP server does it: roles, names, states, values, link targets; open shadow roots and same-origin iframes included. 10–20 ms on a large page. Held to `maxTokens` (the session's snapshot budget by default), with its token count. |
| `click` `hover` `fill` `fill_form` `type_text` `press_key` `select_option` `scroll` `drag` `upload_files` | Act by ref or CSS selector. Clicks and keys are real `NSEvent`s delivered to the web view (`isTrusted`), not DOM events, at the element's centre after scrolling it into view; a click on something covered is refused and names what covers it. Each result reports a navigation it started, new console errors and failed requests, and a dialog it opened. |
| `handle_dialog` | `alert`, `confirm` and `prompt` show as sheets; an agent answers them with the same buttons. Accepting a "Delete…?" asks you first. |
| `console_messages` `network_requests` `network_request` | Everything the recorder has kept since the tab opened: console with stacks, requests with headers, bodies, timing. `afterId` returns only what is new. |
| `evaluate` `inspect_element` `performance_metrics` `storage` | JavaScript in the page or the isolated world (a function receives the element); the box model, computed styles and matched CSS rules in cascade order; Core Web Vitals rated, navigation timing, slowest resources; cookies including HttpOnly, local and session storage. |
| `screenshot` `get_page_content` | Viewport, element or full page as PNG or JPEG, optionally saved; the page as Markdown, text or HTML. |
| `emulate` | Device mode presets or a size, and the Rendering emulations: `prefers-color-scheme`, `prefers-reduced-motion`, `prefers-contrast`, print media, JavaScript or images off. |
| `diagnose` | The call to start with: grouped console errors with their source, failed, slow and oversized requests, mixed content, Core Web Vitals rated, and the worst audit failures with selectors, in one Markdown report. |
| `run_audit` | The Audits panel's checks (accessibility, SEO, best practices, performance), scored the way Lighthouse scores them, each failure with the elements involved and why it matters. |
| `mock_network` | Block URLs, or answer them with a status, headers and body of the agent's choosing (DevTools' request blocking and local overrides), to test error states and fallbacks. |
| `heap_snapshot` | JavaScript heap by class after garbage collection; `compare: true` shows what grew since the previous snapshot, for leaks. |
| `application_data` | IndexedDB databases, stores and records; Cache Storage; the web app manifest; service workers; running animations. |
| `devtools` `devtools_selection` | Open DevTools for the person on a panel or an element; and the other way round, read the element and the request the person has selected in DevTools ("why is *this* blue?"). |
| `session_info` `session_events` | The session's identity, origins, budgets left and expiry; and what happened since an event id (`afterId`), instead of polling pages. |
| `request_human` | Hands the tab to the person for a sign-in, a CAPTCHA, payment details or a confirmation; a banner asks them, and the call returns when they press *Done — hand back*. |
| `page_tools` `call_page_tool` | WebMCP (experimental, off by default): tools a page registers with `document.modelContext`, also listed as `webmcp__<origin>__<name>`. Their descriptions and results are untrusted; tools that change something ask first. |

Targets are a `ref` from `snapshot`, a CSS `selector`, or the visible `text`
(with an optional `role`), as a person would say "the Sign up button".
`snapshot` with `diff: true` returns only the lines that changed since the
agent's previous snapshot of that tab, which keeps long sessions cheap.

**Results and errors.** Every result carries `structuredContent`: `ok`,
the tab, its URL, whether the call navigated, actions left and tokens; a
failure carries `error: {code, message, retryable}`, with codes such as
`approval_denied`, `origin_blocked`, `budget_exhausted`, `rate_limited`,
`session_paused`, `needs_human`, `element_not_found` and `timeout`. The
tool schema is versioned (`toolSchemaVersion`, now 1.1.0): within a major
version tools are only added and arguments only gain optional fields. The
whole contract is served at `http://127.0.0.1:9333/schema` and printed by
`keel schema`.

**Prompts.** Clients that support MCP prompts offer these as commands (in
Claude Code, `/mcp__keel__debug_page` and so on): `debug_page`,
`audit_page`, `fix_layout`, `test_flow` and `performance_review`. Each one
walks the agent through the tools in the order that works.

**DevTools' Agent panel.** Once an agent acts in a tab, an **Agent** tab
appears in that tab's DevTools: every tool call with its arguments, time
taken, result and screenshots, failures marked, filterable, *Reveal element*
for selector-based calls, and *Copy session* as Markdown for a bug report or
to hand to another agent. Calls made before DevTools opened are there too.

**Transport.** It listens on 127.0.0.1 only. A request from a web page (an
`Origin` that is not this machine) is refused, a `Host` that is not
loopback is refused, so DNS rebinding goes nowhere, and a web page cannot
ask to pair.

Right and middle clicks are DOM events: a real right click opens a context
menu that holds the main thread. HTML5 drag and drop needs a drag session
`drag` cannot start; pointer-driven dragging works.

```sh
scripts/test-agent.sh         # AgentKit's checks, then an MCP client drives the real app through every tool
scripts/test-trust.sh         # the trust layer: isolation, approvals, origins, budgets, untrusted content, the log
.build/debug/Keel --mcp-port 9399 --mcp-token secret --agent-approve deny   # a scripted client; approvals answered for it
```

### Testing the DevTools

There is no XCTest on a Command Line Tools-only Mac, so the DevTools are
tested by a script that runs *inside* the DevTools UI, drives every panel
against a local fixture site, and writes a pass/fail report:

```sh
python3 Tests/Fixtures/devtools/server.py &
swift run Keel --show-devtools \
  --devtools-script Tests/Fixtures/devtools/drive-all.js \
  --devtools-out /tmp/devtools-report.json --devtools-delay 4 http://127.0.0.1:8765/
cat /tmp/devtools-report.json     # "passed": true, "failures": []
```

Launch flags for driving the app from a script:

```sh
.build/debug/Keel --show-devtools https://example.com
.build/debug/Keel --dump-recording /tmp/rec.json https://example.com
.build/debug/Keel --show-devtools --devtools-script drive.js --devtools-out out.json https://example.com
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
  ├─ AgentKit       MCP for AI agents: JSON-RPC, HTTP, access, tool catalog
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
`Keel-0.2.0.dmg`, signs it for the updater, and creates the GitHub
Release with the DMG and its `.sig` attached.

**Opening with no warning.** A release is signed with the Developer ID and
notarized: the app and the DMG are sent to Apple, and the ticket is stapled
to both, so a downloaded DMG opens with no Gatekeeper warning, online or
not, and CI checks it the way Gatekeeper will (`spctl`, `stapler validate`).
The secrets it needs are listed at the top of `build.yml`: the Developer ID
certificate as a `.p12`, and an App Store Connect API key for `notarytool`.
A tag build without them still releases, ad-hoc signed, with a warning in
the run, and Gatekeeper warns the first time that DMG is opened; set the
repository variable `REQUIRE_NOTARIZED_RELEASE` to `true` to have such a
build fail instead. By hand:

```sh
CODESIGN_IDENTITY="Developer ID Application: …" NOTARY_KEYCHAIN_PROFILE=keel scripts/make-dmg.sh
```

The DMG's window shows the app and the Applications folder with an arrow
between them (`packaging/render-dmg-background.swift`, laid out through the
Finder; `DMG_LAYOUT=0` makes a plain one). Opened from anywhere but an
Applications folder (the DMG itself, Downloads), the app offers **Move to
Applications**: it copies itself there without the download's quarantine,
so macOS does not run it from a temporary place, where it could not
update, puts a copy in Downloads in the Trash, and opens again from there.

**Updating.** The app checks the latest GitHub Release a few seconds after
launch and then at most once a day (App menu → **Check for Updates…** checks
now). A newer version is offered with **Install Update**, **Remind Me Later**
or **Skip This Version**. Installing downloads the DMG and verifies its
Ed25519 signature against the public key compiled into the app
(`Updater.publicKey`); a DMG that does not verify is never opened, whoever put
it on the release page. It then checks the app inside is Keel at the
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
