# HTML artifacts and previews (2026-10-17, board #535; CDN allowlist, WebRTC, dotfiles and streaming #563)

HTML the owner wants to look at, such as a slide deck or a visual report, renders in the app. A chat artifact is shown in the app only. An `.html` file an agent wrote into a workbench folder can also open in the browser.

## Pieces

- **Artifact kind `html`.** The Go prompt's `ArtifactsContract` (`internal/chat/artifacts_contract.go`) teaches it: one complete, self-contained page, with CSS/JS inline, images as `data:` URLs and arrow keys for a deck. The shared fixture `internal/chat/artifacts_examples.md` gains an html example, so Go (`TestArtifactsContract_EmbedsTheSharedExamples`) and Swift (`ArtifactContractFixtureTests`) pin the same grammar. Swift `ArtifactParser.knownKinds` gains `html`, and like `code` an html body never tracks inner ``` fences. Migration `00129` widens the `chat_artifacts.kind` CHECK (table recreation; the Down maps `html` rows to `document`). Export writes `.html`.
- **Panel (view-only).** A complete html version renders in `SandboxedHTMLView` (`Views/Common/SandboxedHTMLView.swift`); a version still streaming shows its source. The toolbar has Edit, Copy and Export…, plus three view controls: **Reload**, **Open in Window**, and **Present** (the window, full screen at once; Esc leaves full screen). `kindActions` has nothing for `html`. Nothing hands the artifact's content to a browser or any other networked app. That is deliberate: a CSP cannot stop a page navigating itself (`location = …`, a meta refresh) and carrying its text out in the URL. Html takes no passage comments (the Comments toggle is hidden; the rendered page has no text anchor).
- **Code viewer.** An active `.html`/`.htm` tab gets **Source | Preview** plus Reload, Present and **Open in Browser** (`Views/Workbench/CodeHTMLPreview.swift`, which also holds `HTMLBrowserOpener`).
  - Preview overlays the web view on the still-mounted Monaco editor and loads the file with `loadFileURL(_:allowingReadAccessTo:)`, scoped to the file's folder.
  - It loads again on every `CodeFileBuffer.diskText` change (an autosave, or another process writing the file, through the existing watcher) and on Reload.
  - It shows the disk version, so an unsaved edit appears after its autosave.
  - **Blocked-resources line (#563).** Under the bar, `CodeHTMLBlockedBanner` shows **Blocked N external resources: host1, host2, host3…** (at most three hosts) whenever the file's disk text names a resource off the CDN allowlist. `HTMLPreviewPolicy.blockedResources` reads the source, not the running page: resource attributes (`src`, `srcset`, `href`, `poster`, `data`, `background`) of every tag but `<a>`, `<area>` and `<form>`, plus CSS `url(…)` and `@import`. Anything not `https:` on a `cdnHosts` host counts: http, protocol-relative `//host`, any other host; distinct URLs are counted once. A URL a script builds is blocked the same way but not counted. Blocked resources are never fetched on the page's behalf (owner decision, ask #318: no local download). The line applies to Preview, Present and Open in Browser alike.
- **`SandboxedHTMLView`.**
  - Setup: `WKWebsiteDataStore.nonPersistent()`, no `WKScriptMessageHandler` (no bridge), JavaScript and element full screen on.
  - UI delegate: `createWebView` returns nil, camera and microphone requests are denied, the file picker returns nothing.
  - WebRTC is off in the preferences, so in every frame, a fresh `about:blank` iframe included (#563): `SandboxedHTMLView.lockDown` calls WebKit's `_setPeerConnectionEnabled:` (no public API) and reads it back. When it cannot (a WebKit without the selector), the view fails closed and shows the fixed message instead of the page. DNS prefetch goes off the same way (`_setDNSPrefetchingEnabled:`), best effort. Content rules cover neither.
  - A document-start user script in every frame also removes `RTCPeerConnection`, `webkitRTCPeerConnection` and `RTCDataChannel` (defence in depth).
  - Nothing loads until a content rule list (`HTMLPreviewPolicy.contentRules`) is installed. A new list is added before the old one goes, so the view is never without a block. A list that does not compile shows a fixed message instead of the page (fail closed).
  - Every navigation goes through `HTMLPreviewPolicy.allowsNavigation`. Allowed: the page itself (any fragment), `about:` documents, and in file mode a subframe under the folder with no hidden (dot) component below it. A clicked link, `location = …` or a form is cancelled.
  - Focus: the panel does not take keyboard focus on load (the owner may be typing in the composer). The window and the code preview do, so the arrow keys reach a deck at once.
- **Content rules per mode.**
  - Chat artifact: block `.*`, then allow back only `about:`/`data:`/`blob:`. No network of any scheme.
  - Workbench file (#563): the same plus the folder's visible files, and https loads of resource type `script`, `style-sheet`, `font` and `image` from the CDN allowlist only (`HTMLPreviewPolicy.cdnHosts`: `cdn.jsdelivr.net`, `cdnjs.cloudflare.com`, `unpkg.com`, `fonts.googleapis.com`, `fonts.gstatic.com`; owner decision, asks #305/#318), so a CDN deck (reveal.js) works in the app.
    - Files: one rule per previewed folder, `visibleFilesFilter` = `^<folder URL>/([^./][^/]*/)*[^./][^/]*$`. Files under the folder load unless a component below it starts with a dot, so `.env`, `.git/config` or `sub/.secrets/x.js` never load as a script, style, image or frame. The folder itself may sit in a hidden folder (a session worktree under `.claude/worktrees`). It fails closed: a URL WebKit spells differently from the prefix loads nothing. `CodeHTMLPreview.content` standardizes the file URL so the page matches.
    - Per-folder rule lists are compiled once per launch into a store in the temporary folder (`watchtower-html-preview-rules`, identifier `watchtower.html-preview.v3.<sha256 of the rules>`).
  - Still blocked in file mode: fetch/XHR, WebSocket, media and raw loads, documents and frames over the network, every host off the allowlist, and plain http/ws for any type.
- **`LocalPreviewServer`** (WatchtowerCore, Network.framework): workbench folders only.
  - Lifetime: one per app, started by the first **Open in Browser**, stopped on every termination (`TrayAppDelegate.applicationWillTerminate`, so it stops whether the quit closes or keeps the sessions).
  - Binding: `NWListener` with `requiredLocalEndpoint` 127.0.0.1, port `.any`, `acceptLocalOnly`.
  - Registrations: each folder (`folder:<path>`) gets a 32-byte random hex token as the first path segment. A folder is registered only when `LocalPreviewHTTP.servableFolder` accepts it within the tab's code root (the workbench folder or its session worktree). It must lie inside the root, and no component of its path below the root may be hidden. The root itself may sit in a hidden folder (`<repo>/.claude/worktrees/<slug>`), but `~/.ssh` under a home-folder workbench is refused (`Failure.refused`). Registering the folder again keeps its token. `unregister(id:)` removes one; `stop()` forgets all.
  - Threads: requests are read on a serial queue and answered on a concurrent queue, so a big file never holds up another connection. A client that has not finished its request header within 15 s is dropped; the send itself is not timed.
  - Streaming (#563): `respond` never reads a file; a 200 carries `file` and its stat'ed `Content-Length`. The server sends the head, then the file in 256 KB chunks, reading the next only after the last is sent, so a reply holds at most one chunk in memory. A HEAD never opens the file. A file that shrank since the stat cuts the connection rather than send a short body as whole; an unopenable one answers 404.
  - URLs: file names are percent-encoded with `%` itself encoded, so `report%20final.html` round-trips.
- **`LocalPreviewHTTP`** (`LocalPreviewRouting.swift`), the pure half of the server:
  - Parsing: request line and `Host` header, 16 KB header cap, origin-form targets only, HTTP/1.0 and 1.1, a doubled Host refused.
  - Host check: the Host must be `127.0.0.1:<port>` or `localhost:<port>`, else 403 (DNS rebinding).
  - Methods: GET/HEAD only (405 with `Allow`). Routing: by token (an unknown token is 404), with percent-decoding per segment.
  - `resolve`: no empty, `.`, `..` or dot-prefixed segment, and no separator or NUL inside one. The symlink-resolved file must lie under the symlink-resolved root, and no component of its real path below the root may be hidden, so a symlink to `.env` or `.git/config` is refused. Only regular files are served, so there is no directory listing.
  - Size: a file over 100 MB (`maxFileBytes`) is refused with 413 after a stat, never read.
  - Content types: a fixed table. No video, since there is no Range support and Safari needs it; audio plays but may not seek.
  - On every response: `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Connection: close`, and `LocalPreviewHTTP.contentSecurityPolicy`:
    `sandbox allow-scripts; default-src 'self'; script-src 'self' 'unsafe-inline' <cdns>; style-src 'self' 'unsafe-inline' <cdns>; img-src 'self' data: blob: <cdns>; font-src 'self' data: <cdns>; media-src 'self' blob:; connect-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'`, where `<cdns>` is `https://<host>` for each `cdnHosts` entry (#563; any `https:` before).

## Threat model

HTML in a chat artifact can come from synced data (a Slack message, a mail, a Jira issue) through a prompt injection. An agent-written file is no more trusted, but it is the owner's own file in the owner's own folder.

- **Chat artifacts stay in the app, with no network.** The page runs JavaScript but loads nothing over any network scheme. It has no bridge to Swift, no persistent storage, no new windows, no camera or microphone, and no navigation away. WebRTC and DNS prefetch are off in the preferences, in every frame (#563). Its controls are view-only, and its content is never handed to a browser or any networked app (CHAT-05).
- **A workbench file in the app** may load scripts, styles, fonts and images from the five allowlisted CDN hosts over https, and nothing else from the network (#563). Before #563 any https host was allowed, so a repo- or agent-written page could carry data out in an image URL on the Preview click. A request to an allowlisted CDN can still carry data in its path, but none of those hosts hands its request logs to the page's author. WebKit limits its file reads to the file's folder, and the content rules keep its hidden files out.
- **A workbench file in the browser** runs under the CSP above.
  - Sandboxed: the `sandbox` directive without `allow-same-origin` gives it an opaque origin. It shares no cookies or storage with anything else on 127.0.0.1, opens no popups and submits no forms.
  - No reads of sibling files: `connect-src`, `frame-src`, `child-src` and `worker-src` are `'none'`, so the page's script cannot read the folder's other files as text (no fetch, XHR, WebSocket, frame or worker). It can still pull in sibling scripts, styles, images and fonts, and the same from the allowlisted CDNs only.
  - **It can still navigate to other sites** (`location = …`, a link). That is fine for the owner's own files; the token never leaks in a Referer.
- **The loopback server is not a door.**
  - Binding: 127.0.0.1 only, local connections only, and a Host other than its own loopback name is refused.
  - Token: without a registration's 256-bit token a request gets 404. A known token reaches only that folder: never `..`, a hidden file or folder (directly or through a symlink), a directory listing, or a symlink out of it. A folder hidden below the workbench (such as `~/.ssh` when the workbench is the home folder) is never registered.
  - Read-only: GET/HEAD only.
  - Outbound: it opens no connection (`testChat05LoopbackServerNeverConnectsOut` scans `LocalPreviewServer.swift` for `URLSession`, `NWConnection(`, `Process(`, `CLIRunner`).
- **CHAT-05 holds.** `ArtifactChat05ScanTests` scans `SandboxedHTMLView.swift` and `HTMLPreviewPolicy.swift` too, and forbids `LocalPreviewServer`, `HTMLBrowserOpener`, `NWConnection` and `NWListener` on every artifact-side file.

## Tests

- **Routing:** `Tests/Core/LocalPreviewRoutingTests.swift`. Covers parsing and Host, the Host check (403), wrong token and method not allowed, path traversal (including encoded `..` and `%2F`), dot-files and `.git/config`, directory requests, symlink escape, symlinks into hidden files (vs. a link that stays inside), a root inside a hidden folder (session worktrees), the CSP on every response and its directives, registry tokens, and content types.
- **Live server:** `Tests/Core/LocalPreviewServerTests.swift`, against a server on 127.0.0.1. Covers GET with the CSP header, POST → 405, re-registration keeping the URL, unregister → 404, a space and a literal `%20` in file names round-tripping, and a 12 MB file arriving whole while another request is answered.
- **Policy:** `Tests/Core/HTMLPreviewPolicyTests.swift`. Covers the rule JSON shape per mode (only the allowlisted CDN hosts, for the four CDN types, in file mode; nothing for chat), the owner's allowlist, the visible-files filter (dotfiles refused, a folder inside a hidden folder fine), that the rules compile in WebKit (a folder with regex metacharacters too), navigation decisions (no dotfile frame), and the blocked-resources line.
- **Streaming:** `LocalPreviewRoutingTests.testAFileIsHandedToTheServerUnread` and `LocalPreviewServerTests.testHeadEmptyAndMultiChunkFilesOverTheWire` (HEAD, an empty file, a file of several chunks); the CSP allowlist in `testThePolicyAllowsOnlyTheCDNAllowlist`.
- **Sandboxed view:** `Tests/SandboxedHTMLViewTests.swift`, off-screen views aimed at a live loopback listener that counts connections.
  - Chat mode: fetch, `<img>` and WebSocket never reach the listener, and WebRTC globals are undefined. A plain `WKWebView` with the same page does reach the listener (the control).
  - Navigation: `location =` (http and `file:`) and a form submit are cancelled, the page stays `about:blank`, and the listener counts nothing.
  - File mode: a sibling CSS and PNG load, an http image and fetch do not, and a link to another file in the folder opens nothing. In a folder inside a hidden folder, a dotfile script and a dotfile frame do not load, and an https image on a host off the allowlist never connects (#563).
  - WebRTC: a plain web view with only `lockDown`'s preferences has no WebRTC in its page or a fresh iframe (#563).
- **CHAT-05 and actions:** `ArtifactActionsTests.testHTMLArtifactHasOnlyCopyExportAndView`, `ArtifactChat05ScanTests` (both tests).
- **Parser and Go:** `ArtifactParserTests.testHTMLKindIsKnownAndDoesNotTrackInnerFences`, `ArtifactContractFixtureTests`, and the Go `internal/chat` contract and prompt golden.

## v1 limits

- Chat html artifacts have no browser view (deliberate, see above). To share one, Export the `.html` file and open it yourself.
- The browser does not live-reload; refresh by hand.
- A preview's resources outside the file's folder (`../assets/…`) do not load, in the app or the browser.
- Links inside a page open nothing in the app.
- No video in the browser (no Range support), and no file over 100 MB.
- Frames showing the folder's other files work in the app but are blank in the browser (`frame-src 'none'`).
- Html artifacts take no passage comments.
- Folder registrations are not removed before quit.
