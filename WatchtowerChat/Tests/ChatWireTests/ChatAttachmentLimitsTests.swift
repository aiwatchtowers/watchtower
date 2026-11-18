import ChatWire
import XCTest

/// The attachment pre-check against the shared `internal/chatstore/testdata/attachment_limit_cases.json` (the Mac's
/// `AttachmentValidator`, Go's `internal/chatstore`): the client only pre-checks, the engine decides.
final class ChatAttachmentLimitsTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            struct Expect: Decodable {
                let ok: Bool
                let mime: String?
                let ext: String?
                let reason: String?
                let limit: Int64?
                let message: String?
            }

            let name: String
            let fileName: String
            let headHex: String
            let fill: String
            let size: Int
            let expect: Expect
        }

        let cases: [Case]
    }

    private func bytes(_ item: Fixture.Case) -> Data {
        var data = Data()
        var hex = Substring(item.headHex)
        while hex.count >= 2 {
            data.append(UInt8(hex.prefix(2), radix: 16) ?? 0)
            hex = hex.dropFirst(2)
        }
        let fill = UInt8(item.fill.utf8.first ?? 0x61)
        if data.count < item.size { data.append(Data(repeating: fill, count: item.size - data.count)) }
        return data
    }

    func testAttachmentLimitsSharedCases() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let url = ChatWireFixtures.goFixture("chatstore/testdata/attachment_limit_cases.json")
        let fixture = try decoder.decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(fixture.cases.count, 20)
        for item in fixture.cases {
            switch ChatAttachmentLimits.validate(data: bytes(item), fileName: item.fileName) {
            case let .success(kind):
                XCTAssertTrue(item.expect.ok, item.name)
                XCTAssertEqual(kind.mime, item.expect.mime, item.name)
                XCTAssertEqual(kind.fileExtension(fallbackName: item.fileName), item.expect.ext, item.name)
            case let .failure(rejection):
                XCTAssertFalse(item.expect.ok, item.name)
                XCTAssertEqual(rejection.reason, item.expect.reason, item.name)
                let limit = item.expect.limit.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
                XCTAssertEqual(rejection.message, item.expect.message?.replacingOccurrences(of: "{limit}", with: limit), item.name)
            }
        }
    }

    func testMessageCapCountsBase64ForBinaries() {
        XCTAssertEqual(ChatAttachmentLimits.encodedSize(mime: "image/png", size: 3), 4)
        XCTAssertEqual(ChatAttachmentLimits.encodedSize(mime: "text/plain", size: 3), 3)
        XCTAssertTrue(ChatAttachmentLimits.fitsMessage([(mime: "text/plain", size: ChatAttachmentLimits.messageLimit)]))
        XCTAssertFalse(ChatAttachmentLimits.fitsMessage([(mime: "application/pdf", size: ChatAttachmentLimits.messageLimit)]))
    }
}
