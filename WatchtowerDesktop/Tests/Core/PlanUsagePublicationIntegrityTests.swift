import XCTest
@testable import WatchtowerCore

final class PlanUsagePublicationIntegrityTests: XCTestCase {
    /// Pinned to the Go publicationDigest test: UTF-8 byte lengths, not Swift characters.
    func testUnicodeAndColonFramingMatchesTheGoPublisher() {
        let limits = "[\"квота:é\"]"
        let plot = "{\"😀\":null}"
        let proof = "839dd00ccf8e3fc19427bca23689d4c05a51a6fcd1f9511f7372e38cb54b003d"
        XCTAssertEqual(PlanUsagePublicationIntegrity.verify(limits: limits, plot: plot, proof: proof), .verified)
        XCTAssertEqual(PlanUsagePublicationIntegrity.verify(limits: limits + " ", plot: plot, proof: proof), .unverified)
        XCTAssertEqual(PlanUsagePublicationIntegrity.verify(limits: limits, plot: " " + plot, proof: proof), .unverified)
        XCTAssertEqual(PlanUsagePublicationIntegrity.verify(limits: limits + plot, plot: "", proof: proof), .unverified)
        XCTAssertEqual(PlanUsagePublicationIntegrity.verify(limits: limits, plot: plot, proof: ""), .unverified)
    }
}
