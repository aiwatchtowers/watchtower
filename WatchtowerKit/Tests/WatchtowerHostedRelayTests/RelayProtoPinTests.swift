import Foundation
import SwiftProtobuf
import WatchtowerHostedRelay
import WatchtowerRelayProto
import XCTest

final class RelayProtoPinTests: XCTestCase {
    private var kitRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    func testVersionPinsARelayCommitAndTheGenerator() throws {
        let versionURL = kitRoot.appendingPathComponent("Sources/WatchtowerRelayProto/VERSION")
        let lines = try String(contentsOf: versionURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        XCTAssertEqual(lines.count, 2, "VERSION has two lines")
        let first = try XCTUnwrap(lines.first)
        XCTAssertNotNil(
            first.range(of: #"^[0-9a-f]{40} \d{4}-\d{2}-\d{2}T"#, options: .regularExpression),
            "line 1 is '<commit> <ISO 8601 date>': \(first)"
        )
        let second = try XCTUnwrap(lines.last)
        let prefix = "protoc-gen-swift "
        XCTAssertTrue(second.hasPrefix(prefix), "line 2 names protoc-gen-swift: \(second)")
        let tag = String(second.dropFirst(prefix.count))

        let manifest = try String(contentsOf: kitRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let pattern = #"apple/swift-protobuf"\s*,\s*exact:\s*"([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(manifest.startIndex..., in: manifest)
        let match = try XCTUnwrap(regex.firstMatch(in: manifest, range: range), "Package.swift pins swift-protobuf exactly")
        let pinned = try XCTUnwrap(Range(match.range(at: 1), in: manifest)).map { String(manifest[$0]) }
        XCTAssertEqual(tag, pinned)
    }

    func testGeneratedTypesRoundTrip() throws {
        var record = Relay_V1_Record()
        record.zone = "relay/mac-acme/phone-acme"
        record.name = "a-1"
        record.envelope = Data([1, 2, 3])
        var item = Relay_V1_SaveItem()
        item.record = record
        item.mustNotExist = true
        var save = Relay_V1_Save()
        save.items = [item]
        var request = Relay_V1_Request()
        request.save = save
        var frame = Relay_V1_Frame()
        frame.request = request

        let bytes = try frame.serializedData()
        let parsed = try Relay_V1_Frame(serializedBytes: bytes)
        XCTAssertEqual(parsed, frame)
        XCTAssertEqual(parsed.request.save.items.first?.record.envelope, Data([1, 2, 3]))

        XCTAssertEqual(Relay_V1_ErrorCode.attestationFailed.rawValue, 21)
        XCTAssertEqual(HostedRelay.protocolVersion, 1)
    }
}
