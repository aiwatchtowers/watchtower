import XCTest
@testable import WatchtowerSync

final class PaddingTests: XCTestCase {
    func testBucketsThenSixtyFourKiBMultiples() {
        let cap = 10_000_000
        XCTAssertEqual(Padding.paddedLength(0, cap: cap), 256)
        XCTAssertEqual(Padding.paddedLength(256, cap: cap), 256)
        XCTAssertEqual(Padding.paddedLength(257, cap: cap), 1_024)
        XCTAssertEqual(Padding.paddedLength(16_385, cap: cap), 65_536)
        XCTAssertEqual(Padding.paddedLength(65_537, cap: cap), 131_072)
    }

    /// Review Focus 3.
    func testPaddedLengthIsClippedToTheCap() {
        let cap = EnvelopeSealer.frameCap(signed: true)
        XCTAssertEqual(cap, 900_000 - 68 - 16 - 64)
        XCTAssertEqual(Padding.paddedLength(cap - 10, cap: cap), cap)
        XCTAssertEqual(Padding.paddedLength(cap, cap: cap), cap)
        XCTAssertNil(Padding.paddedLength(cap + 1, cap: cap))
        XCTAssertEqual(EnvelopeSealer.sealedLength(frameLength: cap, signed: true), 900_000)
    }
}
