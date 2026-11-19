import Foundation
import XCTest

/// Go writes a nil slice or map without omitempty as null. The generated
/// decoder reads that (or a missing key) as empty, so an empty query result
/// never fails a whole response. `Sample` is the generator's sample type
/// (Generated/SampleTypes.swift); sample_nil.json is Go's encoding of a zero
/// one (TestGenerate_NilCollectionsDecodeAsEmpty).
final class NilCollectionsTests: XCTestCase {
    private static let sampleNil = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // …/WatchtowerInterfaceTests
        .deletingLastPathComponent()  // …/Tests
        .deletingLastPathComponent()  // …/WatchtowerInterface
        .deletingLastPathComponent()  // the repository
        .appendingPathComponent("internal/tower/gen/testdata/sample_nil.json")

    func testGoNullCollectionsDecodeAsEmpty() throws {
        let sample = try JSONDecoder().decode(Sample.self, from: Data(contentsOf: Self.sampleNil))
        XCTAssertEqual(sample.tags, [])
        XCTAssertEqual(sample.scores, [:])
        XCTAssertNil(sample.parent)
    }

    func testMissingCollectionsDecodeAsEmptyAndEncodeAsEmpty() throws {
        let json = #"{"request_id":"r","id":"i","count":1,"big":2,"ratio":0.5,"done":true,"inner":{"name":"n"},"mood":"calm"}"#
        let sample = try JSONDecoder().decode(Sample.self, from: Data(json.utf8))
        XCTAssertEqual(sample.tags, [])
        XCTAssertEqual(sample.scores, [:])
        XCTAssertEqual(sample.mood, .calm)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try XCTUnwrap(String(bytes: encoder.encode(sample), encoding: .utf8))
        XCTAssertTrue(encoded.contains(#""scores":{}"#), encoded)
        XCTAssertTrue(encoded.contains(#""tags":[]"#), encoded)
    }

    func testRequiredFieldsStillRequired() {
        XCTAssertThrowsError(try JSONDecoder().decode(Sample.self, from: Data(#"{"tags":null}"#.utf8)))
    }
}
