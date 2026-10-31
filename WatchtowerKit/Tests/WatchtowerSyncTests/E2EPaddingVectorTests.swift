import XCTest
@testable import WatchtowerSync

/// `Padding.paddedLength` over the bucket edges and both symmetric frame caps; frozen in `Fixtures/e2e/padding.json`.
/// `padded` is JSON `null` (not an absent key) when the length does not fit the cap.
struct PaddingVectors: Codable, Equatable {
    struct Case: Codable, Equatable {
        var length: Int
        var cap: Int
        var padded: Int?

        init(length: Int, cap: Int) {
            self.length = length
            self.cap = cap
            padded = Padding.paddedLength(length, cap: cap)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(length, forKey: .length)
            try container.encode(cap, forKey: .cap)
            try container.encode(padded, forKey: .padded)
        }
    }

    var cases: [Case]

    init() {
        cases = [true, false].flatMap { signed -> [Case] in
            let cap = EnvelopeSealer.frameCap(signed: signed)
            return [0, 1, 255, 256, 257, 1_023, 65_536, 65_537, 131_072, cap, cap + 1].map { Case(length: $0, cap: cap) }
        }
    }
}

final class E2EPaddingVectorTests: XCTestCase {
    func testPaddingVectors() throws {
        try E2EFixtures.check(PaddingVectors(), file: "padding")
        let url = E2EFixtures.directory.appendingPathComponent("padding.json")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(#""padded" : null"#), "an over-cap length is an explicit null")
    }
}
