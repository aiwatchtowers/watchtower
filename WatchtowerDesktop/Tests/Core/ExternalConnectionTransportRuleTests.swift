import XCTest
@testable import WatchtowerCore

/// The add sheet's inline twin of `connections add`'s refusal: headers never
/// go to a remote host over plain http; loopback and https stay allowed.
final class ExternalConnectionTransportRuleTests: XCTestCase {
    func testRemotePlainHTTPSendsTheSecretInCleartext() {
        for url in ["http://mcp.example.com/mcp", "HTTP://mcp.example.com/", "http://10.0.0.5:8080/", " http://mcp.example.com "] {
            XCTAssertTrue(ExternalConnectionTransportRule.sendsSecretInCleartext(url: url), url)
        }
    }

    func testHTTPSAndLoopbackAreAllowed() {
        for url in [
            "https://mcp.example.com/mcp", "http://127.0.0.1:8080/mcp", "http://localhost/mcp",
            "http://LOCALHOST:3000/", "http://[::1]:9000/", "http://127.4.5.6/", ""
        ] {
            XCTAssertFalse(ExternalConnectionTransportRule.sendsSecretInCleartext(url: url), url)
        }
    }

    func testLoopbackHostMatchesGo() {
        for host in ["localhost", "127.0.0.1", "127.255.0.1", "::1", "[::1]", "0:0:0:0:0:0:0:1", "::ffff:127.0.0.1"] {
            XCTAssertTrue(ExternalConnectionTransportRule.isLoopbackHost(host), host)
        }
        for host in ["example.com", "10.0.0.1", "0.0.0.0", "::", "localhost.example.com", "", "::ffff:10.0.0.1"] {
            XCTAssertFalse(ExternalConnectionTransportRule.isLoopbackHost(host), host)
        }
    }
}
