import AppKit
import Network
import SwiftUI
import WebKit
import XCTest
@testable import WatchtowerCore
@testable import WatchtowerDesktop

/// The in-app view really keeps a page off the network (#535): every
/// attempt — fetch, `<img>`, WebSocket, `location =`, a form — is aimed at a
/// live loopback listener that counts its connections, and it must count
/// none. A plain `WKWebView` given the same page is the control that the
/// listener does see those attempts. Views are hosted off screen (never
/// ordered in).
@MainActor
final class SandboxedHTMLViewTests: XCTestCase {
    private var counter: HitCounter!
    private var hosts: [NSView] = []

    override func setUp() async throws {
        counter = try await HitCounter.start()
    }

    override func tearDown() async throws {
        counter.stop()
        hosts = []
    }

    func testAPageReachesNoServerWhileItsScriptRuns() async throws {
        let base = counter.base
        let page = """
        <html><body><img src="\(base)/img.png"><iframe id="srcdoc" srcdoc="<p>frame</p>"></iframe><script>
        try { new WebSocket("ws://\(counter.hostPort)/ws"); } catch (e) {}
        fetch("\(base)/fetch", { mode: "no-cors" }).then(r => { document.title = "leak:" + r.type })
          .catch(() => { document.title = "blocked" });
        </script></body></html>
        """
        let webView = try host(.page(page))
        let title = try await settledTitle(webView)
        XCTAssertEqual(title, "blocked", "the script ran and its fetch was refused")
        // A grace for a late image/socket attempt; a slow runner can only
        // make this pass vacuously, never fail it.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(counter.hits, 0, "no fetch, image or WebSocket reached the listener")
        XCTAssertFalse(webView.configuration.websiteDataStore.isPersistent)
        let webRTC = try await webView.evaluateJavaScript(
            "[typeof RTCPeerConnection, typeof webkitRTCPeerConnection, typeof RTCDataChannel].join()"
        ) as? String
        XCTAssertEqual(webRTC, "undefined,undefined,undefined", "WebRTC is removed before page script runs")
        let frames = try await webView.evaluateJavaScript("""
        (() => {
          const blank = document.createElement("iframe");
          document.body.appendChild(blank);
          const doc = document.getElementById("srcdoc").contentWindow;
          return [typeof blank.contentWindow.RTCPeerConnection, typeof blank.contentWindow.RTCDataChannel,
                  typeof doc.RTCPeerConnection, typeof doc.RTCDataChannel].join();
        })()
        """) as? String
        XCTAssertEqual(frames, "undefined,undefined,undefined,undefined", "a fresh about:blank and a srcdoc iframe have no WebRTC")

        let plain = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        plain.loadHTMLString(page, baseURL: nil)
        let control = try await settledTitle(plain)
        XCTAssertEqual(control, "leak:opaque")
        XCTAssertGreaterThan(counter.hits, 0, "control: the same page in a plain web view does reach it")
        let plainRTC = try await plain.evaluateJavaScript("typeof RTCPeerConnection") as? String
        XCTAssertEqual(plainRTC, "function", "control: WebKit has WebRTC unless the sandbox removes it")
    }

    func testLocationAndFormNavigationAreCancelled() async throws {
        let base = counter.base
        let page = """
        <html><head><title>page</title></head><body>
        <form id="f" method="get" action="\(base)/form"><input name="q" value="secret"></form>
        </body></html>
        """
        let webView = try host(.page(page))
        // The page is loaded before anything is attempted.
        let loaded = try await waitForTitle(webView) { $0 == "page" }
        XCTAssertEqual(loaded, "page")
        // One attempt at a time, each in its own turn: a later navigation
        // would otherwise replace an earlier one before its policy check.
        for attempt in ["location = \"\(base)/nav?d=secret\"", "document.getElementById(\"f\").submit()",
                        "location = \"file:///etc/hosts\""] {
            let marker = try await webView.evaluateJavaScript("\(attempt); \"attempted\"") as? String
            XCTAssertEqual(marker, "attempted", attempt)
            // The policy decision runs after the script; give it a turn.
            // A navigation that went through would replace the document.
            try await Task.sleep(for: .milliseconds(300))
            let title = try? await webView.evaluateJavaScript("document.title") as? String
            XCTAssertEqual(title, "page", "still on the page after: \(attempt)")
            XCTAssertEqual(webView.url?.absoluteString, "about:blank", attempt)
        }
        XCTAssertEqual(counter.hits, 0)
    }

    func testAFilePreviewLoadsItsSiblingsButNotTheNetwork() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sandbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "body { color: rgb(1, 2, 3); }".write(to: folder.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        try Self.pngPixel().write(to: folder.appendingPathComponent("dot.png"))
        try "<p>other</p>".write(to: folder.appendingPathComponent("other.html"), atomically: true, encoding: .utf8)
        let base = counter.base
        let index = """
        <html><head><link rel="stylesheet" href="style.css"></head><body>
        <img id="dot" src="dot.png"><img src="\(base)/net.png">
        <script>
        fetch("\(base)/fetch", { mode: "no-cors" }).catch(() => {});
        window.onload = () => {
          document.title = getComputedStyle(document.body).color + "|" + document.getElementById("dot").naturalWidth;
          setTimeout(() => { location = "other.html" }, 50);
        };
        </script></body></html>
        """
        let file = folder.appendingPathComponent("index.html")
        try index.write(to: file, atomically: true, encoding: .utf8)
        let webView = try host(.file(file, folder: folder))
        let title = try await waitForTitle(webView) { $0.contains("|") }
        XCTAssertEqual(title, "rgb(1, 2, 3)|1", "the sibling css and image load")
        // The page tries `location = "other.html"` 50 ms after load; this
        // grace can only make the checks below pass vacuously, never fail.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(counter.hits, 0, "no http image or fetch reached the listener")
        XCTAssertEqual(webView.url?.lastPathComponent, "index.html", "a link to another file opens nothing")
    }

    /// WebRTC is off in the preferences themselves (#563), not only by the
    /// page script: a plain view with just these preferences has no WebRTC
    /// in its page or in a fresh iframe.
    func testWebRTCIsOffInThePreferencesForEveryFrame() async throws {
        let config = WKWebViewConfiguration()
        XCTAssertNil(SandboxedHTMLView.lockDown(config.preferences), "this WebKit can turn WebRTC off — a WebKit change shows here")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        webView.loadHTMLString("<html><head><title>p</title></head><body></body></html>", baseURL: nil)
        _ = try await waitForTitle(webView) { $0 == "p" }
        let types = try await webView.evaluateJavaScript("""
        (() => {
          const frame = document.createElement("iframe");
          document.body.appendChild(frame);
          return [typeof RTCPeerConnection, typeof webkitRTCPeerConnection,
                  typeof frame.contentWindow.RTCPeerConnection, typeof frame.contentWindow.webkitRTCPeerConnection].join();
        })()
        """) as? String
        XCTAssertEqual(types, "undefined,undefined,undefined,undefined")
    }

    /// A WebKit without the private preference: `lockDown` says why instead
    /// of raising, and the view still shows the page with the WebRTC globals
    /// removed by its script.
    func testLockDownFallsBackWithAReasonOnAMissingSelector() async throws {
        let config = WKWebViewConfiguration()
        var selectors = SandboxedHTMLView.LockDownSelectors()
        selectors.setPeerConnection = "_setNoSuchPreference:"
        XCTAssertEqual(SandboxedHTMLView.lockDown(config.preferences, selectors: selectors), "WKPreferences has no _setNoSuchPreference:")
        selectors = SandboxedHTMLView.LockDownSelectors()
        selectors.peerConnection = "_noSuchGetter"
        XCTAssertEqual(SandboxedHTMLView.lockDown(config.preferences, selectors: selectors), "WKPreferences has no _noSuchGetter")

        let webView = try host(.page("<html><head><title>page</title></head><body></body></html>"))
        let title = try await waitForTitle(webView) { $0 == "page" }
        XCTAssertEqual(title, "page")
        let rtc = try await webView.evaluateJavaScript("typeof RTCPeerConnection") as? String
        XCTAssertEqual(rtc, "undefined")
    }

    /// Without the content rules nothing of the page is ever loaded: the
    /// view shows a fixed message with the reason (the rules are the
    /// network barrier).
    func testAPageNeverLoadsWhenTheRulesFail() async throws {
        struct Broken: LocalizedError {
            var errorDescription: String? { "rules broke" }
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let coordinator = SandboxedHTMLView.Coordinator()
        coordinator.webView = webView
        coordinator.rules = { _ in throw Broken() }
        coordinator.show(.page("<html><head><title>secret page</title></head><body><img src=\"\(counter.base)/x.png\"></body></html>"),
                         token: 0)
        let text = try await waitForText(webView) { $0.contains("could not be prepared") }
        XCTAssertEqual(text, "The preview could not be prepared: rules broke")
        let title = try await webView.evaluateJavaScript("document.title") as? String
        XCTAssertEqual(title, "", "the page itself never loaded")
        XCTAssertEqual(counter.hits, 0)
    }

    /// A file preview (#563) loads its folder's visible files only — no
    /// dotfile as a script or in a frame, none through a symlink with a
    /// visible name (`notes.js` → `.secrets/config.js`, a folder link to
    /// `.git`) — and nothing from a host off the CDN allowlist, even over
    /// https; its folder may sit in a hidden one.
    func testAFilePreviewLoadsNoDotfileAndNoHostOffTheAllowlist() async throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("sandbox-\(UUID().uuidString)")
        let folder = base.appendingPathComponent(".claude/worktrees/deck")
        try manager.createDirectory(at: folder.appendingPathComponent(".secrets"), withIntermediateDirectories: true)
        try manager.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        try "body { color: rgb(1, 2, 3); }".write(to: folder.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        try "window.leaked = 1;".write(to: folder.appendingPathComponent(".secrets/config.js"), atomically: true, encoding: .utf8)
        try "window.gitLeaked = 1;".write(to: folder.appendingPathComponent(".git/hook.js"), atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(atPath: folder.appendingPathComponent("notes.js").path, withDestinationPath: ".secrets/config.js")
        try manager.createSymbolicLink(atPath: folder.appendingPathComponent("x").path, withDestinationPath: ".git")
        try "<script>parent.postMessage(\"hidden\", \"*\")</script>"
            .write(to: folder.appendingPathComponent(".hidden.html"), atomically: true, encoding: .utf8)
        // A framed own page renders with its folder's style sheet, in an
        // opaque origin (#563).
        try """
        <html><head><link rel="stylesheet" href="style.css"></head><body><script>
        window.onload = () => parent.postMessage("ok:" + getComputedStyle(document.body).color, "*");
        </script></body></html>
        """.write(to: folder.appendingPathComponent("ok.html"), atomically: true, encoding: .utf8)
        try "TOPSECRET".write(to: folder.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        let index = """
        <html><head><link rel="stylesheet" href="style.css"><script src=".secrets/config.js"></script>
        <script src="notes.js"></script><script src="x/hook.js"></script></head><body>
        <img src="https://\(counter.hostPort)/net.png"><iframe src=".hidden.html"></iframe><iframe id="ok" src="ok.html"></iframe>
        <iframe id="secret" src="secret.txt"></iframe>
        <script>
        const readable = (id) => {
          try { const doc = document.getElementById(id).contentDocument; return doc ? "read:" + doc.body.innerText : "opaque" }
          catch (e) { return "opaque" }
        };
        const framed = [];
        let fetched = "pending";
        let evaluated = "off";
        try { evaluated = String(new Function("return 6 * 7")()) } catch (e) {}
        window.addEventListener("message", (e) => { framed.push(e.data) });
        fetch("style.css").then(r => r.text()).then(() => { fetched = "read" }).catch(() => { fetched = "blocked" });
        window.onload = () => setTimeout(() => {
          document.title = [getComputedStyle(document.body).color, window.leaked || 0, window.gitLeaked || 0,
                            framed.sort().join("+"), fetched, evaluated, readable("secret"), readable("ok")].join("|");
        }, 500);
        </script></body></html>
        """
        let file = folder.appendingPathComponent("index.html")
        try index.write(to: file, atomically: true, encoding: .utf8)
        let webView = try host(.file(file, folder: folder))
        let title = try await waitForTitle(webView) { $0.contains("|") }
        XCTAssertEqual(title, "rgb(1, 2, 3)|0|0|ok:rgb(1, 2, 3)|blocked|42|opaque|opaque",
                       "visible siblings load and frame (with their own style sheet); no dotfile does, directly or by a link; "
                           + "no script reads a file as text, by fetch or through a frame; new Function runs")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(counter.hits, 0, "an https image off the allowlist never connects")
    }

    // MARK: helpers

    private func waitForText(_ webView: WKWebView, until done: (String) -> Bool) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        var text = ""
        while clock.now < deadline {
            text = (try? await webView.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String) ?? ""
            if done(text) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return text
    }

    private func host(_ content: SandboxedHTMLContent) throws -> WKWebView {
        let host = NSHostingView(rootView: SandboxedHTMLView(content: content).frame(width: 400, height: 300))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
        hosts.append(host)
        return try XCTUnwrap(Self.findWebView(in: host))
    }

    /// The page's title once `done` accepts it, or the last one read after
    /// `timeout` (generous: CI runners are slow to start a web process).
    private func waitForTitle(
        _ webView: WKWebView, timeout: Duration = .seconds(10), until done: (String) -> Bool
    ) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var title = ""
        while clock.now < deadline {
            title = (try? await webView.evaluateJavaScript("document.title") as? String) ?? ""
            if done(title) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return title
    }

    private func settledTitle(_ webView: WKWebView) async throws -> String {
        try await waitForTitle(webView) { $0 == "blocked" || $0.hasPrefix("leak:") }
    }

    private static func findWebView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for sub in view.subviews {
            if let web = findWebView(in: sub) { return web }
        }
        return nil
    }

    private static func pngPixel() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}

/// A loopback listener that counts every connection made to it and answers
/// each with an empty 200.
private final class HitCounter: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.hit-counter")
    private let lock = NSLock()
    private var count = 0
    let port: UInt16

    var hits: Int { lock.withLock { count } }
    var hostPort: String { "127.0.0.1:\(port)" }
    var base: String { "http://\(hostPort)" }

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> HitCounter {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = OnceResume(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(.success(listener.port?.rawValue ?? 0))
                case let .failed(error): once.resume(.failure(error))
                default: break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: .global())
        }
        let counter = HitCounter(listener: listener, port: port)
        listener.newConnectionHandler = { [counter] connection in counter.accept(connection) }
        return counter
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { count += 1 }
        connection.start(queue: queue)
        let reply = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
            connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() { listener.cancel() }
}

private final class OnceResume: @unchecked Sendable {
    private var continuation: CheckedContinuation<UInt16, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }

    func resume(_ result: Result<UInt16, Error>) {
        lock.withLock {
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}
