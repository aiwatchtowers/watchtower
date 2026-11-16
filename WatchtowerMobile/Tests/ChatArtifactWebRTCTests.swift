import WebKit
import XCTest
@testable import WatchtowerMobile

/// CHAT-05 on the phone, in a real web view: an html artifact gets no WebRTC, in its own frame or in an
/// `about:blank` iframe its script creates (peer connections are not loads the content rules can block).
@MainActor
final class PhoneArtifactWebRTCTests: XCTestCase {
    private static let page = """
        <html><body><script>
        const frame = document.createElement('iframe');
        document.body.appendChild(frame);
        window.wtResult = [typeof RTCPeerConnection, typeof webkitRTCPeerConnection, typeof RTCDataChannel,
          typeof frames[0].RTCPeerConnection, typeof frame.contentWindow.RTCDataChannel].join(',');
        </script></body></html>
        """

    private func result(of webView: WKWebView) async -> String? {
        for _ in 0..<2_000 {
            if let result = try? await webView.evaluateJavaScript("window.wtResult") as? String { return result }
            await Task.yield()
        }
        return nil
    }

    func testNoPeerConnectionInThePageOrAScriptMadeIframe() async throws {
        // The control: a plain web view has WebRTC, so "undefined" below is the sandbox's doing.
        let plain = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        plain.loadHTMLString(Self.page, baseURL: nil)
        let control = await result(of: plain)
        XCTAssertEqual(control?.split(separator: ",").first, "function", "a plain web view exposes RTCPeerConnection")

        let coordinator = SandboxedArtifactWebView.Coordinator()
        let webView = SandboxedArtifactWebView.makeWebView(coordinator: coordinator)
        coordinator.show(Self.page)
        let sandboxed = await result(of: webView)
        XCTAssertEqual(sandboxed, "undefined,undefined,undefined,undefined,undefined")
    }
}
