import CloudBridgeCore
import XCTest

/// The hand-coded frames against the Go side's shared fixture (internal/hub/transport/cloudkit/testdata/
/// frames.json): every case decodes to the values its protojson names and encodes back to the same bytes.
final class BridgeFramesFixtureTests: XCTestCase {
    private struct Case {
        let name: String
        let message: String
        let json: [String: Any]
        let bytes: Data
    }

    private func cases() throws -> [Case] {
        let url = repoRoot().appendingPathComponent("internal/hub/transport/cloudkit/testdata/frames.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let list = try XCTUnwrap(root["cases"] as? [[String: Any]])
        return try list.map { item in
            Case(
                name: try XCTUnwrap(item["name"] as? String),
                message: try XCTUnwrap(item["message"] as? String),
                json: try XCTUnwrap(item["json"] as? [String: Any]),
                bytes: try XCTUnwrap(Self.hex(try XCTUnwrap(item["hex"] as? String))))
        }
    }

    func testFramesFixture() throws {
        let all = try cases()
        XCTAssertGreaterThanOrEqual(all.count, 24, "the fixture lost cases")
        var requests = 0, responses = 0
        for c in all {
            switch c.message {
            case "Request":
                requests += 1
                let decoded = try BridgeRequest.decode(c.bytes)
                XCTAssertEqual(decoded.encoded(), c.bytes, "\(c.name): re-encoded bytes differ")
                XCTAssertTrue(NSDictionary(dictionary: decoded.protoJSON).isEqual(to: c.json), "\(c.name): \(decoded.protoJSON) vs \(c.json)")
            case "Response":
                responses += 1
                let decoded = try BridgeResponse.decode(c.bytes)
                XCTAssertEqual(decoded.encoded(), c.bytes, "\(c.name): re-encoded bytes differ")
                XCTAssertTrue(NSDictionary(dictionary: decoded.protoJSON).isEqual(to: c.json), "\(c.name): \(decoded.protoJSON) vs \(c.json)")
            default:
                XCTFail("\(c.name): unknown message \(c.message)")
            }
        }
        XCTAssertGreaterThan(requests, 0)
        XCTAssertGreaterThan(responses, 0)
    }

    func testFramingCapsTheMessage() throws {
        let frame = try BridgeFraming.frame(Data([1, 2, 3]))
        XCTAssertEqual([UInt8](frame), [0, 0, 0, 3, 1, 2, 3])
        XCTAssertEqual(try BridgeFraming.length(ofHeader: Data([0, 0x40, 0, 0])), 4 << 20)
        XCTAssertThrowsError(try BridgeFraming.length(ofHeader: Data([0, 0x40, 0, 1])))
        XCTAssertThrowsError(try BridgeFraming.frame(Data(count: (4 << 20) + 1)))
    }

    func testUnknownFieldsAreSkippedAndBadUTF8Refused() throws {
        // id 7, an unknown varint field 15, account_status {}.
        let withUnknown = Data([0x08, 0x07, 0x78, 0x05, 0x3a, 0x00])
        XCTAssertEqual(try BridgeRequest.decode(withUnknown), BridgeRequest(id: 7, op: .accountStatus))
        // participants { zone: 0xff } — not UTF-8.
        XCTAssertThrowsError(try BridgeRequest.decode(Data([0x08, 0x01, 0x52, 0x03, 0x0a, 0x01, 0xff])))
        XCTAssertThrowsError(try BridgeRequest.decode(Data([0x08])), "a truncated varint")
    }

    private static func hex(_ s: String) -> Data? {
        var out = Data()
        var it = s.makeIterator()
        while let hi = it.next() {
            guard let lo = it.next(), let byte = UInt8(String([hi, lo]), radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }
}

// MARK: - protojson views (the fixture's `json` field)

private func u64(_ v: UInt64) -> String { String(v) }

private extension BridgeExpect {
    var protoJSON: [String: Any] {
        var d: [String: Any] = [:]
        switch mode {
        case .none: break
        case .absent: d["mode"] = "EXPECT_ABSENT"
        case .seq: d["mode"] = "EXPECT_SEQ"
        }
        if tagSeq != 0 { d["tag_seq"] = u64(tagSeq) }
        if !generation.isEmpty { d["generation"] = generation }
        return d
    }
}

private extension BridgeRecord {
    var protoJSON: [String: Any] {
        var d: [String: Any] = [:]
        if !name.isEmpty { d["name"] = name }
        if !envelope.isEmpty { d["envelope"] = envelope.base64EncodedString() }
        if tagSeq != 0 { d["tag_seq"] = u64(tagSeq) }
        if serverAtMs != 0 { d["server_at_ms"] = String(serverAtMs) }
        if !assetID.isEmpty { d["asset_id"] = assetID }
        return d
    }
}

extension BridgeRequest {
    var protoJSON: [String: Any] {
        var d: [String: Any] = [:]
        if id != 0 { d["id"] = u64(id) }
        switch op {
        case let .hello(version, hubID):
            var m: [String: Any] = [:]
            if version != 0 { m["version"] = Int(version) }
            if !hubID.isEmpty { m["hub_id"] = hubID }
            d["hello"] = m
        case .save(let items):
            d["save"] = items.isEmpty ? [:] : ["items": items.map { item -> [String: Any] in
                var m: [String: Any] = [:]
                if !item.zone.isEmpty { m["zone"] = item.zone }
                if !item.name.isEmpty { m["name"] = item.name }
                if !item.envelope.isEmpty { m["envelope"] = item.envelope.base64EncodedString() }
                if !item.assetPath.isEmpty { m["asset_path"] = item.assetPath }
                if let expect = item.expect { m["expect"] = expect.protoJSON }
                return m
            }]
        case let .delete(zone, items):
            var m: [String: Any] = [:]
            if !zone.isEmpty { m["zone"] = zone }
            if !items.isEmpty {
                m["items"] = items.map { item -> [String: Any] in
                    var i: [String: Any] = [:]
                    if !item.name.isEmpty { i["name"] = item.name }
                    if let expect = item.expect { i["expect"] = expect.protoJSON }
                    return i
                }
            }
            d["delete"] = m
        case let .changes(zone, since, generation):
            var m: [String: Any] = [:]
            if !zone.isEmpty { m["zone"] = zone }
            if since != 0 { m["since"] = u64(since) }
            if !generation.isEmpty { m["generation"] = generation }
            d["changes"] = m
        case let .download(zone, assetID, dst):
            var m: [String: Any] = [:]
            if !zone.isEmpty { m["zone"] = zone }
            if !assetID.isEmpty { m["asset_id"] = assetID }
            if !dst.isEmpty { m["dst"] = dst }
            d["download"] = m
        case .accountStatus:
            d["account_status"] = [String: Any]()
        case .ensureShares:
            d["ensure_shares"] = [String: Any]()
        case .setPublicLink(let open):
            d["set_public_link"] = open ? ["open": true] : [:]
        case .participants(let zone):
            d["participants"] = zone.isEmpty ? [:] : ["zone": zone]
        case let .removeParticipants(zone, names):
            var m: [String: Any] = [:]
            if !zone.isEmpty { m["zone"] = zone }
            if !names.isEmpty { m["user_record_names"] = names }
            d["remove_participants"] = m
        case nil:
            break
        }
        return d
    }
}

extension BridgeResponse {
    var protoJSON: [String: Any] {
        var d: [String: Any] = [:]
        if id != 0 { d["id"] = u64(id) }
        switch result {
        case let .hello(version, generation):
            var m: [String: Any] = [:]
            if version != 0 { m["version"] = Int(version) }
            if !generation.isEmpty { m["generation"] = generation }
            d["hello"] = m
        case .outcomes(let items):
            d["outcomes"] = items.isEmpty ? [:] : ["items": items.map { outcome -> [String: Any] in
                var m: [String: Any] = [:]
                if outcome.saved { m["saved"] = true }
                if outcome.tagSeq != 0 { m["tag_seq"] = u64(outcome.tagSeq) }
                if let conflict = outcome.conflict { m["conflict"] = conflict.protoJSON }
                if !outcome.refusedClass.isEmpty { m["refused_class"] = outcome.refusedClass }
                return m
            }]
        case .batch(let b):
            var m: [String: Any] = [:]
            if !b.changed.isEmpty { m["changed"] = b.changed.map(\.protoJSON) }
            if !b.deleted.isEmpty { m["deleted"] = b.deleted }
            if b.newSeq != 0 { m["new_seq"] = u64(b.newSeq) }
            if b.more { m["more"] = true }
            if !b.generation.isEmpty { m["generation"] = b.generation }
            d["batch"] = m
        case .done:
            d["done"] = [String: Any]()
        case .account(let status):
            d["account"] = status.isEmpty ? [:] : ["status": status]
        case let .shares(dataURL, relayURL):
            var m: [String: Any] = [:]
            if !dataURL.isEmpty { m["data_url"] = dataURL }
            if !relayURL.isEmpty { m["relay_url"] = relayURL }
            d["shares"] = m
        case .participants(let items):
            d["participants"] = items.isEmpty ? [:] : ["items": items.map { p -> [String: Any] in
                var m: [String: Any] = [:]
                if !p.userRecordName.isEmpty { m["user_record_name"] = p.userRecordName }
                if p.accepted { m["accepted"] = true }
                return m
            }]
        case .failure(let failureClass):
            d["failure"] = failureClass.isEmpty ? [:] : ["class": failureClass]
        case .event(let e):
            var m: [String: Any] = [:]
            if !e.zone.isEmpty { m["zone"] = e.zone }
            if e.pullNow { m["pull_now"] = true }
            if !e.errorClass.isEmpty { m["error_class"] = e.errorClass }
            d["event"] = m
        case nil:
            break
        }
        return d
    }
}

/// The repository root: this file is <root>/WatchtowerDesktop/Tests/CloudBridge/<name>.swift.
func repoRoot(_ file: String = #filePath) -> URL {
    var url = URL(fileURLWithPath: file)
    for _ in 0..<4 { url.deleteLastPathComponent() }
    return url
}
