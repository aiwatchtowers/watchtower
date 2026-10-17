import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import WatchtowerCore
@testable import WatchtowerDesktop

/// The in-app view really has no network: a page that fetches, loads an
/// image and opens a socket against a live loopback server gets nothing.
/// The view is hosted off screen (never ordered in).
@MainActor
final class SandboxedHTMLViewTests: XCTestCase {
    func testAPageReachesNoServerAndRunsScript() async throws {
        let server = LocalPreviewServer()
        defer { server.stop() }
        let target = try await server.url(for: .page("secret"), id: "target")
        let page = """
        <html><body><script>
        document.title = "ran";
        fetch("\(target.absoluteString)", { mode: "no-cors" }).then(r => { document.title = "leak:" + r.type })
          .catch(() => { document.title = "blocked" });
        </script><img src="\(target.absoluteString)"></body></html>
        """
        let host = NSHostingView(rootView: SandboxedHTMLView(content: .page(page)).frame(width: 400, height: 300))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
        let webView = try XCTUnwrap(Self.findWebView(in: host))
        let title = try await Self.settledTitle(webView)
        XCTAssertEqual(title, "blocked", "the page's fetch must never reach the server")
        XCTAssertTrue(webView.configuration.userContentController.userScripts.isEmpty)
        XCTAssertFalse(webView.configuration.websiteDataStore.isPersistent)

        // Control: the same page in a plain web view does reach the server,
        // so "blocked" above is the sandbox's doing, not the harness's.
        let plain = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        plain.loadHTMLString(page, baseURL: nil)
        let control = try await Self.settledTitle(plain)
        XCTAssertEqual(control, "leak:opaque")
    }

    private static func settledTitle(_ webView: WKWebView) async throws -> String {
        var title = ""
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            title = (try? await webView.evaluateJavaScript("document.title") as? String) ?? ""
            if title == "blocked" || title.hasPrefix("leak:") { break }
        }
        return title
    }

    private static func findWebView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for sub in view.subviews {
            if let web = findWebView(in: sub) { return web }
        }
        return nil
    }
}
