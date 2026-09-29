import XCTest
@testable import WatchtowerCore

final class VoiceExportCodecTests: XCTestCase {
    private static let aliceSample = VoiceExportPayload.Sample(embedding: [0.6, 0.8], channel: .remote, speechSec: 40)
    private static let alicePerson = VoiceExportPayload.Person(personKey: "alice@example.com", displayName: "Alice", samples: [aliceSample])
    private static let sender = VoiceExportPayload.Sender(name: "Colleague A", email: "a@example.com")
    private let payload = VoiceExportPayload(
        formatVersion: 1, modelVersion: VoiceRegistryPolicy.embeddingModelVersion, sender: sender, people: [alicePerson])

    func testRoundTrip() throws {
        XCTAssertEqual(try VoiceExportCodec.open(try VoiceExportCodec.seal(payload, password: "pw"), password: "pw"), payload)
    }

    func testWrongPasswordAndTamperFail() throws {
        var data = try VoiceExportCodec.seal(payload, password: "pw")
        XCTAssertThrowsError(try VoiceExportCodec.open(data, password: "nope")) {
            XCTAssertEqual($0 as? VoiceExportCodec.CodecError, .wrongPasswordOrCorrupt)
        }
        data[data.count - 1] ^= 0xFF
        XCTAssertThrowsError(try VoiceExportCodec.open(data, password: "pw")) {
            XCTAssertEqual($0 as? VoiceExportCodec.CodecError, .wrongPasswordOrCorrupt)
        }
    }

    func testFileNeverContainsPlaintextNames() throws {
        let data = try VoiceExportCodec.seal(payload, password: "pw")
        XCTAssertNil(data.range(of: Data("alice@example.com".utf8)))
    }

    func testEmptyPasswordRejected() {
        XCTAssertThrowsError(try VoiceExportCodec.seal(payload, password: "")) {
            XCTAssertEqual($0 as? VoiceExportCodec.CodecError, .emptyPassword)
        }
    }

    func testOpenRejectsForeignTruncatedAndPasswordlessFiles() throws {
        let sealed = try VoiceExportCodec.seal(payload, password: "pw")
        XCTAssertThrowsError(try VoiceExportCodec.open(Data("not a voices file at all".utf8), password: "pw")) {
            XCTAssertEqual($0 as? VoiceExportCodec.CodecError, .badMagic)
        }
        XCTAssertThrowsError(try VoiceExportCodec.open(VoiceExportCodec.magic, password: "pw")) {
            XCTAssertEqual($0 as? VoiceExportCodec.CodecError, .badMagic, "magic alone, no salt")
        }
        XCTAssertThrowsError(try VoiceExportCodec.open(sealed.prefix(sealed.count - 20), password: "pw")) {
            XCTAssertEqual($0 as? VoiceExportCodec.CodecError, .wrongPasswordOrCorrupt, "a truncated file fails authentication")
        }
        XCTAssertThrowsError(try VoiceExportCodec.open(sealed, password: "")) {
            XCTAssertEqual($0 as? VoiceExportCodec.CodecError, .emptyPassword)
        }
    }
}
