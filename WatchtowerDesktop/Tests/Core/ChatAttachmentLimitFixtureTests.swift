import XCTest
@testable import WatchtowerCore

/// The Mac's chat attachment checks over Go's
/// `internal/chatstore/testdata/attachment_limit_cases.json`, which
/// `TestChatAttachment_LimitsSharedCases` runs through the hub's port (the
/// phone's chat_attachment intake): a file the Mac refuses, the hub refuses
/// with the same text. Swift is the reference.
final class ChatAttachmentLimitFixtureTests: XCTestCase {
    private static func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/chatstore/testdata/attachment_limit_cases.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private static func bytes(_ c: [String: Any]) throws -> Data {
        let hex = try XCTUnwrap(c["head_hex"] as? String)
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(try XCTUnwrap(UInt8(hex[index..<next], radix: 16)))
            index = next
        }
        let size = try XCTUnwrap(c["size"] as? Int)
        let fill = try XCTUnwrap((c["fill"] as? String)?.utf8.first)
        if data.count < size { data.append(Data(repeating: fill, count: size - data.count)) }
        return data
    }

    private static func reason(_ r: AttachmentRejection) -> String {
        switch r {
        case .unsupportedType: return "unsupported_type"
        case .tooLarge: return "too_large"
        case .notUTF8: return "not_utf8"
        case .unreadable: return "unreadable"
        case .folder: return "folder"
        }
    }

    func testValidatorMatchesTheGoPort() throws {
        let cases = try XCTUnwrap(Self.fixture()["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            let fileName = try XCTUnwrap(c["file_name"] as? String)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any])
            switch AttachmentValidator.validate(data: try Self.bytes(c), fileName: fileName) {
            case .success(let kind):
                XCTAssertEqual(expect["ok"] as? Bool, true, name)
                XCTAssertEqual(kind.mime, expect["mime"] as? String, name)
                XCTAssertEqual(kind.fileExtension(fallbackName: fileName), expect["ext"] as? String, name)
            case .failure(let rejection):
                XCTAssertEqual(expect["ok"] as? Bool, false, name)
                XCTAssertEqual(Self.reason(rejection), expect["reason"] as? String, name)
                var message = try XCTUnwrap(expect["message"] as? String, name)
                if case let .tooLarge(_, limit) = rejection {
                    XCTAssertEqual(limit, (expect["limit"] as? NSNumber)?.int64Value, name)
                    message = message.replacingOccurrences(
                        of: "{limit}", with: ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))
                }
                XCTAssertEqual(rejection.message, message, name)
            }
        }
    }

    func testPathExtensionMatchesTheGoPort() throws {
        let cases = try XCTUnwrap(Self.fixture()["path_extensions"] as? [[String: Any]])
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            XCTAssertEqual((name as NSString).pathExtension, c["ext"] as? String, name)
        }
    }

    func testOwnerDirectoryMatchesTheGoPort() throws {
        let cases = try XCTUnwrap(Self.fixture()["directories"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let id = try XCTUnwrap((c["conversation_id"] as? NSNumber)?.int64Value)
            XCTAssertEqual(ChatAttachmentOwner.conversation(id).directoryName, c["dir"] as? String)
        }
    }
}
