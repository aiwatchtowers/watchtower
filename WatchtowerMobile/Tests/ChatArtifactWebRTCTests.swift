import ChatUI
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import WatchtowerMobile

/// CHAT-05 on the phone, in a real web view: an html artifact gets no WebRTC, in its own frame or in an
/// `about:blank` iframe its script creates (peer connections are not loads the content rules can block). The page is
/// the phone's artifact viewer, `ChatUI`'s `SandboxedArtifactWebView`, hosted as the sheet hosts it.
@MainActor
final class PhoneArtifactWebRTCTests: XCTestCase {
    private static let page = """
        <html><body><script>
        const frame = document.createElement('iframe');
        document.body.appendChild(frame);
        document.title = [typeof RTCPeerConnection, typeof webkitRTCPeerConnection, typeof RTCDataChannel,
          typeof frames[0].RTCPeerConnection, typeof frame.contentWindow.RTCDataChannel].join(',');
        </script></body></html>
        """

    /// The page's verdict, delivered by events: the page writes it into `document.title`, and the web view's
    /// KVO-observable `title` changes once the script has run. If a load finishes (`isLoading` true to false) with
    /// no title, the title is read once more and, if still empty, "" comes back so the assertions fail with their
    /// messages instead of the suite hanging. No polling budget and no timer.
    private func result(of webView: WKWebView) async -> String {
        var observations: [NSKeyValueObservation] = []
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            var resumed = false
            func finish(_ value: String) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            var sawLoading = false
            observations.append(webView.observe(\.title, options: [.initial, .new]) { web, _ in
                if let title = web.title, !title.isEmpty { finish(title) }
            })
            observations.append(webView.observe(\.isLoading, options: [.initial, .new]) { web, _ in
                if web.isLoading { sawLoading = true; return }
                guard sawLoading, !resumed else { return }
                Task { @MainActor in
                    let title = try? await web.evaluateJavaScript("document.title") as? String
                    finish(title ?? "")
                }
            })
        }
        observations.forEach { $0.invalidate() }
        return value
    }

    func testNoPeerConnectionInThePageOrAScriptMadeIframe() async throws {
        // The control: a plain web view has WebRTC, so "undefined" below is the sandbox's doing.
        let plain = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        plain.loadHTMLString(Self.page, baseURL: nil)
        let control = await result(of: plain)
        XCTAssertEqual(control.split(separator: ",").first, "function", "a plain web view exposes RTCPeerConnection")

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = UIHostingController(rootView: SandboxedArtifactWebView(html: Self.page))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var found: WKWebView?
        for _ in 0..<2_000 where found == nil {
            window.layoutIfNeeded()
            found = Self.webView(in: window)
            await Task.yield()
        }
        let webView = try XCTUnwrap(found, "the viewer hosts a web view")
        let sandboxed = await result(of: webView)
        XCTAssertEqual(sandboxed, "undefined,undefined,undefined,undefined,undefined")
    }

    private static func webView(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for child in view.subviews {
            if let web = webView(in: child) { return web }
        }
        return nil
    }
}
