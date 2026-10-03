# Private API and App Store audit

Scope: every private/SPI use and every App Store blocker in `Sources/` (all targets, Swift and the JavaScript the app evaluates), `packaging/`, `scripts/make-dmg.sh`. Audited at worktree `keel-wt/bench`, 2026-10-03. Line numbers were read from the code; re-check them after edits.

Method: grep for `NSSelectorFromString`, `Selector((`, `@objc(_…)`, `value(forKey:)`/`setValue(_:forKey:)`, `perform(`, `responds(to:`, `method(for:)`, `unsafeBitCast`, `_WK`, `objc_msgSend`, `dlsym`, `dlopen`, `NSClassFromString`, `class_getInstanceMethod`, `class_copyMethodList`, `method_exchangeImplementations`, `@_silgen_name`, `Process(`, `NSTask`, `posix_spawn`, `/usr/bin/`, `NSWorkspace`, `NSAppleScript`, `NWListener`, `SecItem*`, file paths under `~/Library`. Each hit was read in context.

No hits for `objc_msgSend`, `dlsym`, `dlopen`, `NSClassFromString`, `class_getInstanceMethod`, `method_exchangeImplementations`, `@_silgen_name`, `NSAppleScript`, private frameworks, or `#selector` on underscore names. `Selector(("undo:"))`/`Selector(("redo:"))` (MainMenu.swift:123-124) are public responder actions. `perform(_:with:)` hits in `FeatureSelfTest+*` fire public NSControl actions. Every `setValue(_:forHTTPHeaderField:)` hit is public.

## Rules that apply

- **2.5.1, public APIs only.** App Review's scanner reads selector strings in the binary. A `responds(to:)` guard does not hide `"_setPageMuted:"` from it. The App Store flavour has to compile the SPI out (for example `swift build -Xswiftc -DAPP_STORE` and `#if !APP_STORE`). Leaving it in behind a runtime flag is not enough. This includes the JS shim strings in `InspectorProtocolBridge.swift` and the `@objc(_webView:…)` method names.
- **2.4.5, Mac App Store.** The app must be sandboxed with only the entitlements it needs. It must be self-contained and must not download or install code that adds features. It must not spawn processes that keep running after quit. Updates must come through the Mac App Store. It must be packaged with Apple's tooling.
- **2.5.2, self-contained.** The app must not download, install or execute code that changes its features. This covers the self-updater and possibly sideloaded web extensions.
- **2.5.6, WebKit only.** This is an iOS/iPadOS rule; macOS has no WebKit-only requirement. Keel uses WKWebView throughout, so it complies whatever the rule's scope. It matters only if a non-WebKit engine is ever considered.

## 1. Web Inspector / DevTools

### 1.1 `WKWebView._inspector` → `_WKInspector`
- **Where:** WebInspectorSPI.swift:85-90 (`inspector(for:)`), InspectorProtocolBridge.swift:61 and :207-211 (`object(_:_:)`).
- **What:** gets WebKit's inspector object for a page. Every other inspector item below depends on it.
- **Probe:** `guard webView.responds(to: selector), let unmanaged = webView.perform(selector) else { return nil }` (WebInspectorSPI.swift:87-88). If it is missing, `isAvailable` is false and the bridge throws `BridgeError.unavailable("WKWebView has no _inspector")`.
- **Public alternative:** `WKWebView.isInspectable` (macOS 13.3+), already set at BrowserWindowController.swift:333, :870, DevToolsController.swift:85 and Extensions.swift:205. It allows remote inspection from Safari ("Debug in Safari", BrowserWindowController.swift:1400-1410). There is no in-app equivalent.
- **Verdict:** Developer ID only.

### 1.2 `_WKInspector.show` (and the unused `close`, `showConsole`, `showResources`)
- **Where:** WebInspectorSPI.swift:57-75 and :92-97 (`send`). Callers of `show`: BrowserWindowController.swift:1389 (Develop menu item, MainMenu.swift:330), InspectorPanelController.swift:411, DevToolsController.swift:242-244 (`DevTools.openWebKitInspector`). Nothing calls `close`, `showConsole` or `showResources`.
- **What:** opens WebKit's own Web Inspector window.
- **Probe:** `inspector.responds(to: selector)` (:94). If it is missing, `show` returns false: the menu item shows the "Debug in Safari" alert and the recorder panel beeps.
- **Public alternative:** `isInspectable` plus Safari's Develop menu.
- **Verdict:** Developer ID only. Delete the three unused wrappers.

### 1.3 `_WKInspector.isVisible` / KVC `visible`
- **Where:** WebInspectorSPI.swift:77-81. Callers: DevToolsController.swift:234 (`Protocol.state`), BrowserWindowController.swift:1367, :1371 (`protocolProbe`, a developer aid started by a launch flag at AppDelegate.swift:301-308).
- **What:** diagnostics only.
- **Probe:** `responds(to: "isVisible")`. If it is missing, returns false.
- **Public alternative:** none needed.
- **Verdict:** Developer ID only.

### 1.4 `_WKInspector.connect` + `inspectorWebView` (InspectorProtocolBridge)
- **Where:** InspectorProtocolBridge.swift:59-96 (`performAttach`). `connect` is called at :64-67 and `inspectorWebView` is polled at :71-74.
- **What:** creates WebKit's inspector frontend without showing it, then takes over its protocol connection. This one bridge gives the DevTools its real JSC debugger, full network data, heap snapshots, timelines, rendering overrides, interception and DOM/CSS protocol features.
- **Probe:** `guard inspector.responds(to: NSSelectorFromString("connect")) else { throw BridgeError.unavailable("_WKInspector has no connect") }` (:64-66). `inspectorWebView` is probed through `object()` (:209), with 100×50 ms polling, and throws if it never appears (:75). On failure, DevToolsController sets `protocolState` to the error text and emits `Protocol.unavailable` (DevToolsController.swift:385-388). The UI then shows "needs the inspector protocol" for each affected feature.
- **Public alternative:** none. `InspectKit/DebugBackend.swift` defines the `DebugBackend` protocol and plans a public-API `InstrumentedBackend`, but **no type conforms to `DebugBackend` yet** (no `: DebugBackend` anywhere in `Sources/`). Today the App Store flavour would have no debugger at all.
- **Verdict:** Developer ID only. In the App Store flavour, compile out InspectorProtocolBridge.swift and everything that calls `protocolBridge`, or replace it with a stub that always throws.

### 1.5 WebKit inspector frontend JS internals (JS bridging)
- **Where:** InspectorProtocolBridge.swift:229-239 (`readinessProbe`: `InspectorBackend`, `WI.mainTarget.connection`) and :245-331 (`shim`). The shim hooks `window.InspectorFrontendAPI.dispatchMessageAsync/dispatchMessage` (:288-299), falls back to patching `InspectorBackend.Connection.prototype.dispatch` (:300-309), and sends through `WI.mainTarget.connection.sendMessageToBackend` (:321-324). Also :138-157 (`diagnose`: `WI.targets`, `WI.debuggerManager.paused`) and :162-185 (`knownScripts`: `WI.debuggerManager._scriptIdMap`, `_targetDebuggerDataMap`).
- **What:** private JavaScript API of WebKit's Web Inspector UI. It can change in any Safari or macOS release.
- **Probe:** readiness polling, max 200×50 ms (:84-89), and the shim returns `"no message handler"`/`"no dispatch hook"`. Every frontend read sits in `try {}`. On failure the attach throws and DevTools degrades as in 1.4.
- **Public alternative:** none.
- **Verdict:** Developer ID only. Falls with 1.4.

### 1.6 `class_copyMethodList` on `_WKInspector`
- **Where:** InspectorProtocolBridge.swift:213-227 (`inspectorSelectors(for:)`).
- **What:** lists `_WKInspector`'s selectors. **Dead code: nothing calls it.**
- **Probe:** n/a.
- **Public alternative:** n/a.
- **Verdict:** drop everywhere.

### 1.7 KVC `drawsBackground` on the DevTools WKWebView
- **Where:** DevToolsController.swift:86, `view.setValue(false, forKey: "drawsBackground")`.
- **What:** makes the DevTools page's web view transparent. WKWebView has no public `setDrawsBackground:`, so KVC resolves to the SPI `_setDrawsBackground:`.
- **Probe:** **none.** If WebKit drops the setter, KVC throws `NSUnknownKeyException` when DevTools opens.
- **Public alternative:** DevTools is Keel's own HTML. Give its `body` an opaque themed background, and/or set `underPageBackgroundColor` (macOS 12+).
- **Verdict:** replace in both flavours. It is cheap and it removes a crash risk.

## 2. Find

### 2.1 `_findString:options:maxCount:` with `_WKFindOptions`
- **Where:** FindController.swift:38-45 (option bits and selector), :214-224 (call through `method(for:)` and `unsafeBitCast` to a `@convention(c)` function).
- **What:** ⌘F that highlights every match, shows the find indicator and reports "n of m".
- **Probe:** `usesPrivateFind = webView.responds(to: Self.findString) && webView.responds(to: Self.setFindDelegate)` (:103). If it is missing, the public path runs: `WKFindConfiguration` + `webView.find(_:configuration:)` (:226-238). It reports only found / not found, so the status shows "Found" or "Not found" with no count (:270-278).
- **Public alternative:** `find(_:configuration:completionHandler:)` (already the fallback). For counts, count matches in JS (a TreeWalker over text nodes) in an isolated world.
- **Verdict:** replace. The public fallback already ships. FeatureSelfTest+Reading.swift:14 asserts `usesPrivateFind`, so that check has to be skipped in the App Store build.

### 2.2 `_setFindDelegate:` + `_WKFindDelegate` callbacks
- **Where:** FindController.swift:47, :104 (`webView.perform(Self.setFindDelegate, with: self)`), :243-266. The three `@objc(_webView:didCountMatches:forString:)`, `@objc(_webView:didFindMatches:forString:withMatchIndex:)` and `@objc(_webView:didFailToFindString:)` put underscore selector names into the binary.
- **What:** the match count and index for 2.1.
- **Probe:** same as 2.1.
- **Public alternative:** same as 2.1.
- **Verdict:** replace. The `@objc(_…)` methods also have to be compiled out.

### 2.3 `_hideFindUI`
- **Where:** FindController.swift:46, :154.
- **What:** clears the highlights when the bar closes.
- **Probe:** `usesPrivateFind, webView.responds(to: Self.hideFindUI)`. If it is missing, nothing is cleared. The public find leaves only the selection.
- **Public alternative:** n/a, since the public find draws no highlight.
- **Verdict:** replace together with 2.1.

## 3. Media

### 3.1 `_mediaMutedState` (read)
- **Where:** Media.swift:128-131. Callers: BrowserWindowController+Media.swift:7, BrowserWindowController.swift:738 (tab accessory), :2309-2310 (menu title).
- **What:** whether the tab is muted.
- **Probe:** `webView.responds(to: NSSelectorFromString("_mediaMutedState"))`. If it is missing, it returns false.
- **Public alternative:** none. Keep the state in Swift.
- **Verdict:** replace.

### 3.2 `_setPageMuted:`
- **Where:** Media.swift:133-142 (`method(for:)` and `unsafeBitCast` to `(AnyObject, Selector, Int) -> Void`). Callers: Mute Tab (BrowserWindowController+Media.swift:7) and Window → Mute Background Tabs (Media.swift:222-223).
- **What:** WebKit's page mute, which the page cannot undo.
- **Probe:** `webView.responds(to: setter), let method = webView.method(for: setter)`. If it is missing, the call silently does nothing and only `onChange` fires. The tab looks muted to the user but is not.
- **Public alternative:** no public mute. Options: isolated-world JS that sets `muted = true` on every `HTMLMediaElement`, watches with a MutationObserver, and calls `suspend()` on `AudioContext`s. The page can undo it. Or `setAllMediaPlaybackSuspended(_:)`/`pauseAllMediaPlayback()` (macOS 12+), which pause rather than mute.
- **Verdict:** replace, with weaker behaviour. FeatureSelfTest+Media.swift:51-54 asserts that the page cannot undo the mute, and that check will fail.

### 3.3 Preference `allowsPictureInPictureMediaPlayback`
- **Where:** Media.swift:68 (`WebInspectorSPI.setPreference`).
- **What:** lets videos go into Picture in Picture.
- **Probe:** `setPreference` returns false if `_setAllowsPictureInPictureMediaPlayback:` is missing.
- **Public alternative:** none on macOS. `WKWebViewConfiguration.allowsPictureInPictureMediaPlayback` is iOS-only. WebKit's macOS default for this preference is believed to be on (**unverified**). Check it with the PiP checks in FeatureSelfTest+Media in a build that compiles the call out.
- **Verdict:** drop the call if PiP still works without it. Otherwise PiP is an App Store loss.

## 4. Quiet mode

### 4.1 `_setWindowOcclusionDetectionEnabled:`
- **Where:** QuietMode.swift:28-34. Called for every page web view at BrowserWindowController.swift:270 and :865. Active only with `--quiet` and without `--performance` (:29).
- **What:** test runs only. Pages under other windows keep acting as visible.
- **Probe:** `webView.responds(to: setter), let method = webView.method(for: setter)`. If it is missing, it returns.
- **Public alternative:** none needed for users.
- **Verdict:** Developer ID only, or compile out with all self-test code. The selector string is still in the binary even though the code path is test-only.

## 5. Performance

### 5.1 `_webProcessIdentifier`, `_gpuProcessIdentifier` (WKWebView) and `_networkProcessIdentifier` (WKWebsiteDataStore)
- **Where:** Performance.swift:64-69, inside `PerformanceRun.run` (`--performance`, used by `scripts/test-performance.sh`).
- **What:** finds the WebKit child process ids so their memory and CPU can be added up with `proc_pid_rusage` (Performance.swift:12-23). Nothing user-facing uses these, so there is no task manager to lose.
- **Probe:** `responds(to: NSSelectorFromString(key))` for each key. If one is missing, that process is left out of the totals.
- **Public alternative:** none. `proc_pid_rusage` on other processes may also be denied under the sandbox (**unverified**).
- **Verdict:** Developer ID only. Compile it out of the App Store flavour.

## 6. Navigation policy

### 6.1 `WKNavigationAction._isUserInitiated`
- **Where:** BrowserWindowController.swift:2571-2573 (`decidePolicyFor`). It sets `lastActionWasUserInitiated`, which download gating uses at :2567 and :2576 through `allowsDownload` (:1485-1490). It is also read at BrowserWindowController.swift:2701-2703 (`createWebViewWith`), which drives the popup blocker in `permissions.allowsPopup` (PermissionsController.swift:200-208).
- **What:** blocks pop-ups and automatic downloads that the user did not cause.
- **Probe:** `navigationAction.responds(to: NSSelectorFromString("_isUserInitiated")) ? (… as? Bool ?? true) : true`. If it is missing, everything counts as user-initiated: **the popup blocker and the download prompt switch off silently.**
- **Public alternative:** no public flag. Downloads: `navigationType == .linkActivated`/`.formSubmitted`, `buttonNumber`, `modifierFlags`. Pop-ups: set the public `preferences.javaScriptCanOpenWindowsAutomatically = false` (BrowserWindowController.swift:263 sets it true today) so that WebKit applies its own user-gesture rule. Then detect the calls it held back with a page-world `window.open` wrapper that checks `navigator.userActivation.isActive` and reports to a message handler, which keeps the "blocked pop-up" bar.
- **Verdict:** replace.

### 6.2 `_webView:contentRuleListWithIdentifier:performedAction:forURL:` + `_WKContentRuleListAction.blockedLoad`
- **Where:** BrowserWindowController.swift:2618-2630, a private `WKNavigationDelegate` method declared with `@objc(_webView:…)`. It KVC-reads `blockedLoad` (:2623-2624).
- **What:** the blocked-request count on the shield (`blocking.didBlock`) and "Blocked by content blocking" rows in the DevTools Network panel.
- **Probe:** `action.responds(to: NSSelectorFromString("blockedLoad"))`. If WebKit never calls the method, the shield shows no count (comment at :2619-2620). Blocking itself uses public `WKContentRuleList` and is unaffected.
- **Public alternative:** none for counts. `WKContentRuleList` blocks silently.
- **Verdict:** drop from the App Store flavour. The shield works without a number.

### 6.3 `_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:`
- **Where:** BrowserWindowController.swift:2722-2727, a private `WKUIDelegate` method.
- **What:** per-site location permission prompts.
- **Probe:** none needed, because WebKit calls it if it is implemented. If the method is removed, WebKit denies geolocation requests by default.
- **Public alternative:** no public geolocation delegate on macOS. Options: a document-start user script that replaces `navigator.geolocation`, backed by `CLLocationManager` through a `WKScriptMessageHandler`, plus `com.apple.security.personal-information.location`.
- **Verdict:** replace (polyfill), or drop and lose site location.

## 7. Private WebKit preferences (`WebInspectorSPI.setPreference` and `enableDeveloperExtras`)

`setPreference` (WebInspectorSPI.swift:44-50) builds `_set<Key>:`, probes it with `responds(to:)` and sets the value with KVC. If the setter is missing it returns false and nothing is set.

| Key | Value | Caller | Purpose | If missing / removed | Public alternative | App Store |
|---|---|---|---|---|---|---|
| `developerExtrasEnabled` | true | WebInspectorSPI.swift:16-23, from BrowserWindowController.swift:242 | "Inspect Element" menu item, keeps `_inspector` usable | no WebKit inspector | `isInspectable` (Safari remote) | drop |
| `pageVisibilityBasedProcessSuppressionEnabled` | false | WebInspectorSPI.swift:38-40, from BrowserWindowController.swift:243 | a paused debugger in a hidden window keeps answering. Cost: **no page in a hidden window is ever napped** | normal WebKit napping | none needed without a debugger | drop |
| `mediaDevicesEnabled` | true | BrowserWindowController.swift:257 (comment :253-256: "measured … WebKit leaves it off … no `navigator.mediaDevices`") | lets sites ask for camera and mic at all | **no getUserMedia/WebRTC capture** | none known. Re-measure in a sandboxed build signed with `device.camera`/`device.audio-input` (**unverified** whether WebKit then turns it on itself) | needs investigation. Possible loss of video calls |
| `notificationsEnabled` | false | BrowserWindowController.swift:259 | hides the Notification API (`SitePermission.offered`) | pages see `Notification` and requests go unanswered | document-start page-world user script that deletes `window.Notification` / `Notification.requestPermission` | replace |
| `mockCaptureDevicesEnabled` | true | BrowserWindowController.swift:260, only when `usesMockCaptureDevices` (set at FeatureSelfTest+Permissions.swift:21-23) | fake camera for self-tests | n/a | n/a | compile out with the self-tests |
| `allowsPictureInPictureMediaPlayback` | true | Media.swift:68 | PiP | see 3.3 | see 3.3 | drop if the default is on |

## 8. Entitlements and sandbox

### 8.1 What the code ships today
- `packaging/Passkeys.entitlements:10-11` contains only `com.apple.developer.web-browser.public-key-credential`, a managed capability that needs a provisioning profile. `make-dmg.sh:102-106` applies it only when `PASSKEYS_PROVISIONING_PROFILE` is set.
- **No other entitlements file exists.** `make-dmg.sh:95-98` signs `--force --deep --sign … --options runtime --timestamp`, so there is **no `com.apple.security.app-sandbox`** and no hardened-runtime resource entitlements.
- Developer ID side note, outside the SPI scope: under the hardened runtime, TCC-protected resources need `com.apple.security.device.camera`, `device.audio-input`, `personal-information.location` and `personal-information.addressbook`. None of them are passed today. Check camera, mic, location and Contacts on a notarized build.
- `packaging/Info.plist` declares usage strings for Contacts (:41-42), camera (:43-44), microphone (:45-46) and location (:47-50). It sets `NSAllowsArbitraryLoadsInWebContent` (:61-65), which is fine for a browser, and claims http/https (:21-32). It has no `ITSAppUsesNonExemptEncryption` key (App Store Connect will ask about export compliance). Bundle id `dev.simplebrowser.SimpleBrowser` (:14): decide whether both flavours share it. If they do, users who switch between them will hit file-keychain ACLs tied to the other signature for "SimpleBrowser Safe Storage" (PasswordKit/KeychainVaultKeyProvider.swift:4-15).

### 8.2 Entitlements the App Store flavour needs, from the code
| Entitlement | Because of |
|---|---|
| `com.apple.security.app-sandbox` | 2.4.5 |
| `com.apple.security.network.client` | web, TranslateKit/GoogleTranslator.swift:133, PasswordKit/PasswordAudit.swift:187, DevExtensions.swift:176 (Anthropic API), ContentBlocker.swift:261 (filter list refresh), DevToolsController+Extensions.swift:88 (Node debugger at 127.0.0.1:9229) |
| `com.apple.security.network.server` | MCP agent server: `NWListener` bound to loopback, AgentServer.swift:124-147 (default port 9333, :23). It runs in-process, so it stops with the app (PRD requirement met). |
| `com.apple.security.device.camera`, `com.apple.security.device.audio-input` | getUserMedia (BrowserWindowController.swift:2710-2720) |
| `com.apple.security.personal-information.location` | only if 6.3 is polyfilled |
| `com.apple.security.personal-information.addressbook` | `CNContactStore` at AutofillSettingsPane.swift:238 |
| `com.apple.security.files.user-selected.read-write` | open and save panels: uploads, password CSV import/export (PasswordsSettingsPane.swift:426, :463, :527), DevTools save/HAR (DevToolsController.swift:938), recorder export (InspectorPanelController.swift:425), extension install (ExtensionsSettingsPane.swift:229) |
| `com.apple.security.files.downloads.read-write` | default download folder (BrowserSettings.swift:157-160) |
| `com.apple.security.files.bookmarks.app-scope` | a custom download folder is stored as a **plain path** (BrowserSettings.swift:153-166). Under the sandbox it needs a security-scoped bookmark: replace |
| `com.apple.security.print` | `webView.printOperation` (PageContextMenu.swift:301) |
| `com.apple.developer.web-browser.public-key-credential` | passkeys (AutofillSettingsPane.swift:20-27). Allowed on the App Store but managed |

### 8.3 Non-sandbox-safe file access
- **Browser import, DataKit/BrowserImport.swift:139-158:** enumerates `~/Library/Application Support/{Google/Chrome, BraveSoftware/Brave-Browser, Microsoft Edge, Arc/User Data, Vivaldi, Chromium, Firefox}` (:29-40) and `~/Library/Safari` (:144-149). Inside the sandbox, `~` resolves to the container, so automatic discovery finds nothing. **Replace:** the user picks the profile folder in an `NSOpenPanel` (user-selected access). Safari's folder is also TCC-protected: ImportWindowController.swift:232-233 sends users to Full Disk Access. **Drop** that path in the App Store flavour and import Safari's exported bookmarks HTML and passwords CSV instead.
- **Chromium password key, BrowserImporter.swift:95-104:** `SecItemCopyMatching` for another app's "Chrome Safe Storage"-style item (service names at DataKit/BrowserImport.swift:43-53). Under the sandbox, expect this to fail (**unverified**). **Verdict:** drop, and import from the CSV that Chromium exports (PasswordKit/PasswordCSV.swift exists).
- **LegacyMigration.swift:14-27:** moves `Application Support/SimpleBrowser` to `…/Keel`. Under the sandbox this resolves inside the container. Moving existing Developer ID users to the App Store flavour needs a container migration manifest; otherwise profiles do not carry over.
- Keychain items Keel owns (KeychainVaultKeyProvider.swift, AgentTrust.swift:595-617, DevExtensions.swift:134-156) are its own items in the file-based keychain and are fine under the sandbox.

## 9. Processes and updater

### 9.1 Updater, Sources/BrowserApp/Updater.swift
- **What:** checks GitHub Releases on launch and then hourly when idle (:50-55, `IdleWork.repeating`). It downloads the DMG and verifies its Ed25519 signature (:180-216), then spawns `/usr/bin/hdiutil attach/detach`, `/usr/bin/ditto`, `/usr/bin/codesign --verify` and `/usr/bin/xattr -dr com.apple.quarantine` (:231-255, through `run` at :284-302). Finally it writes `swap.sh` and launches `/bin/sh` (:260-281). That script **outlives the app**: it waits for the pid, replaces the bundle and runs `/usr/bin/open` on the new app.
- Started from AppDelegate.swift:14 (`let updater = Updater()`) and :384-408 (`startUpdater`). The menu item is at MainMenu.swift:75 (AppDelegate.swift:410).
- **App Store:** it breaks the update-through-the-App-Store rule (2.4.5) and 2.5.2. It spawns a process that keeps running after quit (2.4.5). It strips quarantine. It would not work in the sandbox anyway, since it cannot write `/Applications`.
- **Verdict:** drop. Compile out `Updater`, its menu item and the UpdateKit dependency of the app target. The `SignUpdate` target is a CI tool and is not bundled (make-dmg builds only `--product Keel`, :44).

### 9.2 ApplicationMover, Sources/BrowserApp/ApplicationMover.swift
- **What:** offers to move the app into /Applications (:33-50), removes quarantine with `removexattr` on every file (:73-77), and relaunches through `/bin/sh -c "while kill -0 …; /usr/bin/open"` (:92-99), which also outlives the app.
- **Verdict:** drop. The App Store installs into /Applications.

### 9.3 Extension unzip, Sources/BrowserApp/Extensions.swift:141-148
- **What:** `Process` runs `/usr/bin/ditto -x -k` to unpack a .zip/.crx when an extension is installed.
- **App Store:** a sandboxed child process inherits the sandbox and exits (`waitUntilExit`), so this is technically allowed, but it is fragile.
- **Verdict:** replace with an in-process unzip, or drop along with 10.1.

### 9.4 Self-test spawns
- FeatureSelfTest+Extensions.swift:122-123 runs `/usr/bin/ditto`. It is test-only. Compile all `FeatureSelfTest*`, `UISelfTest`, `PageSelfTest`, `PasswordSelfTest`, `PerformanceRun` and `protocolProbe` code out of the App Store flavour. They carry SPI (4.1, 5.1, 7: `mockCaptureDevicesEnabled`) and the `CGSSessionScreenIsLocked` key read (UISelfTest.swift:49).

### 9.5 `NSWorkspace` opens (all fine)
- DownloadManager.swift:284 opens a finished download (user action, with a risk prompt at :277-281).
- PasswordsSettingsPane.swift:564-570 opens Apple Passwords.
- AgentWindows.swift:66 opens the logs folder.
- ImportWindowController.swift:233 opens the FDA settings pane (drop with 8.3).
- Updater.swift:116 opens the release page (drop with 9.1).

None of these launch executables Keel downloaded.

### 9.6 `scripts/make-dmg.sh`
- Signing: `--force --deep`, plus `--options runtime --timestamp` with a Developer ID (:95-98). Notarization through `notarytool` (:121-140). The DMG is signed and notarized (:206-215). The Finder layout is driven by `osascript` (:165-187); those Apple Events run at build time, not in the app, and the app sends none (no `NSAppleScript`/`NSAppleEventDescriptor` in `Sources/`). The update is signed with `SignUpdate` (:224-229).
- **App Store:** needs a separate path: an Apple Distribution certificate, an App Store provisioning profile embedded as `Contents/embedded.provisionprofile`, an entitlements file with the 8.2 set, per-component signing without `--deep`, `productbuild --sign "3rd Party Mac Developer Installer"` to a .pkg, and an upload through `xcrun altool`/Transporter. 2.4.5 also expects packaging with Apple's tools, and the SwiftPM + script build has no Xcode archive. Expect to add an Xcode project or verify that a productbuild .pkg is accepted.

## 10. Other

### 10.1 Web extension sideloading, Extensions.swift:60-103, ExtensionsSettingsPane.swift:154, :186, :229
- **What:** the user installs any WebExtension from a folder, .zip or .crx (including "a .crx file from the Chrome Web Store", :154). It loads through the public `WKWebExtension`/`WKWebExtensionController` (:87, :199-214). Nothing is downloaded by Keel itself.
- **App Store:** 2.5.2 and 2.4.5 forbid installing code that adds features. Safari's model is extensions shipped as App Store app extensions. A sideloaded, third-party JavaScript extension is a likely rejection (**reviewer judgment**).
- **Verdict:** drop sideloading from the App Store flavour. Keep `WKWebExtension` only for extensions bundled in the app, if any.

### 10.2 Built-in developer extensions, DevExtensions.swift
- These are bundled scripts (Claude, dataLayer, React, PHP, Node, Color Picker, JSON Viewer), so nothing is downloaded. The Node debugger talks CDP to a local `node --inspect` over HTTP/WebSocket (DevToolsController+Extensions.swift:30, :88-94), which is client networking. The Claude panel calls the Anthropic API with a user key (DevExtensions.swift:176-179).
- **Verdict:** keep.

### 10.3 Agent input, AgentInput.swift
- Uses public `NSEvent.mouseEvent`/`keyEvent` delivered inside the process. No `CGEvent` posting and no Accessibility permission.
- **Verdict:** keep.

## Summary table

| # | Item | file:line | Verdict (App Store) | Public replacement |
|---|---|---|---|---|
| 1 | `WKWebView._inspector` | WebInspectorSPI.swift:85-90; InspectorProtocolBridge.swift:61 | Developer ID only | `isInspectable` (Safari remote) |
| 2 | `_WKInspector.show` (+ unused `close`/`showConsole`/`showResources`) | WebInspectorSPI.swift:57-75 | Developer ID only; delete unused | `isInspectable` |
| 3 | `_WKInspector.isVisible` | WebInspectorSPI.swift:77-81 | Developer ID only | none needed |
| 4 | `_WKInspector.connect` / `inspectorWebView` | InspectorProtocolBridge.swift:64-75 | Developer ID only | none (`DebugBackend` has no implementation) |
| 5 | Inspector frontend JS internals (`WI`, `InspectorFrontendAPI`, `InspectorBackend`) | InspectorProtocolBridge.swift:138-185, 229-331 | Developer ID only | none |
| 6 | `class_copyMethodList` on `_WKInspector` | InspectorProtocolBridge.swift:213-227 | drop (dead code) | n/a |
| 7 | KVC `drawsBackground` (no probe) | DevToolsController.swift:86 | replace (both flavours) | CSS background / `underPageBackgroundColor` |
| 8 | `developerExtrasEnabled` | WebInspectorSPI.swift:16-23 (← BWC:242) | drop | `isInspectable` |
| 9 | `pageVisibilityBasedProcessSuppressionEnabled` | WebInspectorSPI.swift:38-40 (← BWC:243) | drop | none needed |
| 10 | `mediaDevicesEnabled` | BrowserWindowController.swift:257 | investigate; possible camera/mic loss | none known |
| 11 | `notificationsEnabled` | BrowserWindowController.swift:259 | replace | user script removing `Notification` |
| 12 | `mockCaptureDevicesEnabled` | BrowserWindowController.swift:260 | compile out (test) | n/a |
| 13 | `allowsPictureInPictureMediaPlayback` | Media.swift:68 | drop if default on | none (iOS-only config property) |
| 14 | `_findString:options:maxCount:` | FindController.swift:45, 214-224 | replace (fallback exists) | `find(_:configuration:)` + JS count |
| 15 | `_setFindDelegate:` + `@objc(_webView:…)` ×3 | FindController.swift:47, 104, 245-266 | replace | same |
| 16 | `_hideFindUI` | FindController.swift:46, 154 | replace | n/a |
| 17 | `_mediaMutedState` | Media.swift:128-131 | replace | track state in Swift |
| 18 | `_setPageMuted:` | Media.swift:133-142 | replace (weaker) | JS mute; `setAllMediaPlaybackSuspended` |
| 19 | `_setWindowOcclusionDetectionEnabled:` | QuietMode.swift:28-34 | compile out (test) | n/a |
| 20 | `_webProcessIdentifier` / `_gpuProcessIdentifier` | Performance.swift:64-65 | compile out (test) | none |
| 21 | `_networkProcessIdentifier` | Performance.swift:68-69 | compile out (test) | none |
| 22 | `_isUserInitiated` (×2) | BrowserWindowController.swift:2571-2572, 2701-2702 | replace | `navigationType`/`buttonNumber`/`modifierFlags`; `javaScriptCanOpenWindowsAutomatically = false` + `navigator.userActivation` |
| 23 | `_webView:contentRuleListWithIdentifier:performedAction:forURL:` + `blockedLoad` | BrowserWindowController.swift:2621-2630 | drop (shield without count) | none |
| 24 | `_webView:requestGeolocationPermissionForOrigin:…` | BrowserWindowController.swift:2723-2727 | replace or drop | `navigator.geolocation` polyfill over CoreLocation |
| — | No sandbox / missing entitlements | make-dmg.sh:95-107; packaging/ | add App Store entitlements file | see 8.2 |
| — | `network.server` for MCP | AgentServer.swift:124-147 | add entitlement | n/a |
| — | Other browsers' profiles, FDA, Chromium keychain | DataKit/BrowserImport.swift:139-158; BrowserImporter.swift:95-104; ImportWindowController.swift:233 | replace / drop | user-selected folder, CSV/HTML import |
| — | Download folder as path | BrowserSettings.swift:153-166 | replace | security-scoped bookmark |
| — | Self-updater (spawns, outlives app, strips quarantine) | Updater.swift:50-55, 180-302 | drop | Mac App Store updates |
| — | ApplicationMover (spawn, `removexattr`) | ApplicationMover.swift:73-99 | drop | n/a |
| — | `ditto` unzip | Extensions.swift:141-148 | replace or drop | in-process unzip |
| — | Extension sideloading | Extensions.swift:60-103 | drop | bundled only |
| — | Packaging (`--deep`, no pkg, no profile) | make-dmg.sh:95-107 | new App Store script | productbuild + provisioning profile |

**Count: 24 distinct SPI items** (rows 1-24). Of these, 6 are test or diagnostic only (6, 12, 19, 20, 21, and the diagnostic use of 3), and one call site has no runtime probe (7). There are also 9 non-SPI App Store blockers (the rows marked —).

## What the reduced App Store build loses

### Agent MCP tools (AgentKit/BrowserTools.swift:64-322: 40 tools)
The dispatch is AgentToolbox.swift:107-141, plus the trust tools in AgentToolbox+Trust.swift. Most tools go through `callAsyncJavaScript` in an isolated world (`automation`/`toolsAgent`/`script`, AgentToolbox.swift:406-456, AgentToolbox+DevTools.swift:28-39), `takeSnapshot`/`pdf`, `WKHTTPCookieStore`, `WKContentRuleList` or `NSEvent`.

- **Need the inspector bridge, hard (1/40, 2.5%):** `heap_snapshot` sends `Heap.gc`/`Heap.snapshot` (AgentToolbox+DevTools.swift:311-318) and fails with "Heap snapshots need the inspector protocol".
- **Partly need the bridge (4/40, 10%):**
  - `mock_network`: `block`/`list`/`clear` use `WKContentRuleList`, but `override` throws without the protocol (AgentToolbox+DevTools.swift:280-282; DevToolsController+Tools.swift:224-227).
  - `emulate`: device mode is public. Rendering preferences other than `colorScheme` (which falls back to `NSAppearance`, DevToolsController+Tools.swift:320-324) need `Page.overrideUserPreference`/`overrideSetting`/`setEmulatedMedia` (:325-350).
  - `network_request`: the body fallback through `Network.getResponseBody` (AgentToolbox.swift:1059-1064). Fetch and XHR bodies come from page hooks and are unaffected.
  - `network_requests`: complete only while DevTools is attached, because protocol network events feed the recorder (DevToolsController.swift:401-402, :474, :521). Without the bridge the list comes from page hooks only.
- **Public API only (35/40, 87.5%):** the rest, including `screenshot` (public `pdf`/`takeSnapshot`, AgentToolbox.swift:512-556), `diagnose`, `run_audit`, `application_data`, `inspect_element`, `performance_metrics`, `storage` and `evaluate`.

### DevTools UI (Keel's own panels)
**Lost (they need `Protocol.send`):**
- **Sources:** JS debugger, i.e. breakpoints, stepping, call stack, scopes, watches, paused-frame console eval (debugger.js, breakpoints.js, console-prompt.js; DevToolsController.swift:216-219, :586-690). Sources stays readable through the fallback fetch (:348-356).
- **Memory panel:** heap snapshots and tracking (memory.js:163-252).
- **Performance profiler:** Timeline and ScriptProfiler (profiler.js:44-88).
- **Elements:** event listeners, forced pseudo-state and DOM breakpoints (DevToolsController.swift:335-346); engine accessibility properties (DevToolsController+Tools.swift:75).
- **Network:** complete bodies and headers for non-fetch resources, WebSocket frames (DevToolsController.swift:302-305), disable cache (network.js:1387) and local overrides.
- **Rendering drawer:** everything except the FPS meter and the colour-scheme fallback.
- **Screenshots:** full-page and node screenshots.
- **WebKit Inspector:** the "Open WebKit Inspector" items.

**Kept:** Console (log and eval), the Elements tree and styles, Network list/HAR/blocking, Application, Audits, Animations, Performance web vitals, cookies, device mode and developer extensions.

Roughly: 11 of the 40 DevTools UI JS files touch the protocol. The debugger, memory and profiler are lost entirely, and the network and elements extras partly.

### User-visible browser features
- WebKit Web Inspector window (users get "Debug in Safari" instead).
- Find "n of m" counts.
- Unbreakable tab mute (becomes a mute the page can undo).
- Blocked-request count on the shield.
- Pop-up and download gating, until it is reimplemented (6.1). Note that with the SPI simply missing, gating turns off rather than failing closed.
- Site geolocation, unless polyfilled.
- Possibly camera and mic for sites (7, `mediaDevicesEnabled`: measure).
- PiP, if WebKit's default is off.
- In-app updates and Move to Applications.
- One-click import from other browsers' profiles and Safari (users pick a folder or file instead).
- Chromium password import (CSV instead).
- Sideloaded web extensions.

The agent server keeps working with `network.server`.
