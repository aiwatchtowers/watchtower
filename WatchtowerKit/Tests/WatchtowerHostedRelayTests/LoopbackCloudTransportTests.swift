import Foundation
import os
import WatchtowerHostedRelayTesting
import WatchtowerSync
import XCTest

/// `LoopbackCloudTransport` against a `URLProtocol` stub playing the Go interop run's loopback store
/// (`internal/hub/interop_desktop_test.go`): the token on every request, the request bodies, conditional
/// save and delete outcomes, and change paging.
final class LoopbackCloudTransportTests: XCTestCase {
    private let endpoint = LoopbackCloudEndpoint(
        url: URL(string: "http://127.0.0.1:18080")!, token: String(repeating: "ab", count: 32))
    private var transport: LoopbackCloudTransport!

    override func setUp() {
        super.setUp()
        LoopbackStubProtocol.reset()
        transport = LoopbackCloudTransport(endpoint: endpoint, user: "_phone", session: Self.stubSession())
    }

    override func tearDown() {
        LoopbackStubProtocol.reset()
        super.tearDown()
    }

    private static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LoopbackStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func record(_ name: String, _ payload: String = "env", zone: CloudZoneID = .relay) -> CloudRecord {
        CloudRecord(recordName: name, zone: zone, kind: WireKind.envelope, modifiedAt: Date(), payload: Data(payload.utf8))
    }

    // MARK: - Save

    func testConditionalSaveSendsTheExpectationAndMapsEachOutcome() async throws {
        // A full-range change tag survives the JSON number.
        let bigTag: UInt64 = 10_451_216_379_200_823_123
        LoopbackStubProtocol.answers = [
            (200, #"{"outcome":"saved","seq":10451216379200823123}"#),
            (200, #"{"outcome":"conflict","current":{"name":"a-2","payload":"bm93","seq":7,"creator":"_phone","server_at_ms":1700000000000}}"#),
            (200, #"{"outcome":"conflict"}"#),
            (409, #"{"error":"not_participant"}"#),
            (503, #"{"error":"no_hub"}"#)
        ]
        let outcomes = try await transport.save([
            ConditionalSave(record: record("a-1"), expect: .absent),
            ConditionalSave(record: record("a-2"), expect: .seq(bigTag)),
            ConditionalSave(record: record("a-3"), expect: .seq(5)),
            ConditionalSave(record: record("a-4"), expect: .none),
            ConditionalSave(record: record("a-5"), expect: .none)
        ])

        XCTAssertEqual(outcomes.count, 5)
        XCTAssertEqual(outcomes[0], .saved(recordSeq: bigTag))
        guard case .conflict(let current) = outcomes[1] else { return XCTFail("\(outcomes[1])") }
        XCTAssertEqual(current.recordName, "a-2")
        XCTAssertEqual(current.zone, .relay)
        XCTAssertEqual(current.kind, WireKind.envelope)
        XCTAssertEqual(current.payload, Data("now".utf8))
        XCTAssertEqual(current.recordSeq, 7)
        XCTAssertEqual(current.origin, RecordOrigin(author: "_phone", serverAt: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertEqual(outcomes[2], .refused(.permanent(code: "gone")), "a conflict with no record has none to hand back")
        XCTAssertEqual(outcomes[3], .refused(.permanent(code: "not_participant")))
        XCTAssertEqual(outcomes[4], .refused(.unreachable))

        let seen = LoopbackStubProtocol.seen
        XCTAssertEqual(seen.map(\.path), Array(repeating: "/save", count: 5))
        XCTAssertTrue(seen.allSatisfy { $0.method == "POST" && $0.authorization == "Bearer \(endpoint.token)" })
        let first = try seen[0].json()
        XCTAssertEqual(first["user"] as? String, "_phone")
        XCTAssertEqual(first["zone"] as? String, "RelayZone")
        XCTAssertEqual(first["name"] as? String, "a-1")
        XCTAssertEqual(first["payload"] as? String, Data("env".utf8).base64EncodedString())
        XCTAssertEqual(first["expect"] as? String, "absent")
        XCTAssertNil(first["seq"])
        let second = try seen[1].json()
        XCTAssertEqual(second["expect"] as? String, "seq")
        XCTAssertEqual(String(data: seen[1].body, encoding: .utf8)?.contains("\"seq\":10451216379200823123"), true)
        XCTAssertEqual(try seen[3].json()["expect"] as? String, "none")
    }

    func testARecordWithAnAssetIsRefusedWithoutARequest() async throws {
        let withAsset = CloudRecord(
            recordName: "upload-1", zone: .relay, kind: WireKind.envelope, modifiedAt: Date(), payload: Data("e".utf8),
            assetFileURL: URL(fileURLWithPath: "/dev/null"))
        let outcomes = try await transport.save([ConditionalSave(record: withAsset, expect: .absent)])
        XCTAssertEqual(outcomes, [.refused(.permanent(code: "asset_unsupported"))])
        XCTAssertTrue(LoopbackStubProtocol.seen.isEmpty)
    }

    func testThePrivateScopeUserIsSentEmptyAndAcceptShareSendsNothing() async throws {
        let mac = LoopbackCloudTransport(endpoint: endpoint, user: nil, session: Self.stubSession())
        try await mac.acceptShare()
        XCTAssertTrue(LoopbackStubProtocol.seen.isEmpty, "the Mac's own user joins no share")
        LoopbackStubProtocol.answers = [(200, #"{"outcome":"saved","seq":3}"#)]
        try await mac.save([record("hello-1")])
        XCTAssertEqual(try LoopbackStubProtocol.seen[0].json()["user"] as? String, "")
    }

    func testAcceptShareNamesTheUser() async throws {
        LoopbackStubProtocol.answers = [(200, "{}")]
        try await transport.acceptShare()
        XCTAssertEqual(LoopbackStubProtocol.seen.map(\.path), ["/accept-share"])
        XCTAssertEqual(try LoopbackStubProtocol.seen[0].json() as NSDictionary, ["user": "_phone"])
    }

    // MARK: - Delete

    func testConditionalDeleteMapsEachOutcome() async throws {
        LoopbackStubProtocol.answers = [
            (200, #"{"outcome":"deleted"}"#),
            (200, #"{"outcome":"conflict","current":{"name":"b-2","payload":"eA==","seq":9}}"#),
            (200, #"{"outcome":"conflict"}"#),
            (500, #"{"error":"failed"}"#)
        ]
        let outcomes = try await transport.delete([
            ConditionalDelete(recordName: "b-1", zone: .data, expect: .seq(4)),
            ConditionalDelete(recordName: "b-2", zone: .data, expect: .seq(4)),
            ConditionalDelete(recordName: "b-3", zone: .data, expect: .seq(4)),
            ConditionalDelete(recordName: "b-4", zone: .data, expect: .none)
        ])
        XCTAssertEqual(outcomes.count, 4)
        XCTAssertEqual(outcomes[0], .deleted)
        guard case .conflict(let current) = outcomes[1] else { return XCTFail("\(outcomes[1])") }
        XCTAssertEqual(current.recordName, "b-2")
        XCTAssertEqual(current.zone, .data)
        XCTAssertEqual(current.recordSeq, 9)
        XCTAssertEqual(current.origin, .unknown)
        XCTAssertEqual(outcomes[2], .deleted, "an absent record counts as deleted")
        XCTAssertEqual(outcomes[3], .refused(.transient(code: "failed")))

        XCTAssertEqual(LoopbackStubProtocol.seen.map(\.path), Array(repeating: "/delete", count: 4))
        let first = try LoopbackStubProtocol.seen[0].json()
        XCTAssertEqual(first["zone"] as? String, "DataZone")
        XCTAssertEqual(first["name"] as? String, "b-1")
        XCTAssertEqual(first["expect"] as? String, "seq")
        XCTAssertEqual(first["seq"] as? Int, 4)
        XCTAssertNil(first["payload"])
    }

    func testTheSeamDeleteThrowsARefusal() async throws {
        LoopbackStubProtocol.answers = [(409, #"{"error":"not_participant"}"#)]
        do {
            try await transport.delete(recordNames: ["c-1"], in: .relay)
            XCTFail("a refused delete returned")
        } catch let error as LoopbackCloudError {
            XCTAssertEqual(error, .refused(.permanent(code: "not_participant")))
        }
    }

    // MARK: - Changes

    func testChangesFollowsThePagesFromTheCursor() async throws {
        LoopbackStubProtocol.answers = [
            (200, #"""
            {"changed":[{"name":"r-1","payload":"YQ==","seq":11,"creator":"__defaultOwner__","server_at_ms":1700000000500},
                        {"name":"sig-ask-1","payload":null,"seq":12}],
             "deleted":["r-0"],"new_seq":42,"more":true}
            """#),
            (200, #"""
            {"changed":[{"name":"r-2","payload":"Yg==","seq":13}],"deleted":["r-1"],"new_seq":45,"more":false}
            """#)
        ]
        let batch = try await transport.changes(in: .data, since: CloudChangeToken(value: 40))

        XCTAssertEqual(batch.newToken, CloudChangeToken(value: 45))
        XCTAssertEqual(batch.changed.map(\.recordName), ["sig-ask-1", "r-2"])
        XCTAssertEqual(batch.deletedRecordNames, ["r-1", "r-0"], "a record deleted on a later page is deleted, in first-seen order")
        let signal = batch.changed[0]
        XCTAssertEqual(signal.kind, WireKind.signal)
        XCTAssertEqual(signal.payload, Data())
        XCTAssertEqual(signal.zone, .data)
        XCTAssertEqual(signal.recordSeq, 12)
        XCTAssertEqual(batch.changed[1].kind, WireKind.envelope)
        XCTAssertEqual(batch.changed[1].payload, Data("b".utf8))

        let seen = LoopbackStubProtocol.seen
        XCTAssertEqual(seen.map(\.path), ["/changes", "/changes"])
        XCTAssertEqual(try seen[0].json()["since"] as? Int, 40)
        XCTAssertEqual(try seen[0].json()["zone"] as? String, "DataZone")
        XCTAssertEqual(try seen[1].json()["since"] as? Int, 42, "the next page starts at the page's cursor")
    }

    func testChangesKeepsTheCreatorAndServerTime() async throws {
        LoopbackStubProtocol.answers = [
            (200, #"""
            {"changed":[{"name":"r-1","payload":"YQ==","seq":11,"creator":"_phone","server_at_ms":1700000000500}],
             "deleted":[],"new_seq":1,"more":false}
            """#)
        ]
        let batch = try await transport.changes(in: .relay, since: nil)
        let served = Date(timeIntervalSince1970: 1_700_000_000.5)
        XCTAssertEqual(batch.changed.first?.origin, RecordOrigin(author: "_phone", serverAt: served))
        XCTAssertEqual(batch.changed.first?.modifiedAt, served)
        XCTAssertEqual(try LoopbackStubProtocol.seen[0].json()["since"] as? Int, 0, "no token reads from the start")
    }

    func testChangesErrors() async throws {
        for (status, body, want) in [
            (403, #"{"error":"forbidden"}"#, LoopbackCloudError.forbidden),
            (410, #"{"error":"token_expired"}"#, .tokenExpired),
            (503, #"{"error":"unavailable"}"#, .refused(.unreachable))
        ] {
            LoopbackStubProtocol.reset()
            LoopbackStubProtocol.answers = [(status, body)]
            do {
                _ = try await transport.changes(in: .relay, since: nil)
                XCTFail("\(status) returned a batch")
            } catch let error as LoopbackCloudError {
                XCTAssertEqual(error, want)
            }
        }
    }

    func testAForbiddenSaveThrows() async throws {
        LoopbackStubProtocol.answers = [(403, #"{"error":"forbidden"}"#)]
        do {
            _ = try await transport.save([ConditionalSave(record: record("a-1"), expect: .absent)])
            XCTFail("a 403 is not an item outcome")
        } catch let error as LoopbackCloudError {
            XCTAssertEqual(error, .forbidden)
        }
    }

    // MARK: - Handoff

    func testTheEndpointIsReadFromTheHandoffFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loopback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"url":"http://127.0.0.1:52011","token":"0f0f"}"#.utf8)
            .write(to: dir.appendingPathComponent(LoopbackCloudEndpoint.handoffFile))
        let read = try LoopbackCloudEndpoint.read(fromHandoff: dir)
        XCTAssertEqual(read, LoopbackCloudEndpoint(url: try XCTUnwrap(URL(string: "http://127.0.0.1:52011")), token: "0f0f"))
    }
}

/// Answers each request with the next scripted (status, body) and keeps what it was sent.
final class LoopbackStubProtocol: URLProtocol {
    struct Seen {
        let method: String
        let path: String
        let authorization: String?
        let body: Data

        func json() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
    }

    private struct State {
        var answers: [(Int, String)] = []
        var seen: [Seen] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static var answers: [(Int, String)] {
        get { state.withLock { $0.answers } }
        set { state.withLock { $0.answers = newValue } }
    }

    static var seen: [Seen] { state.withLock { $0.seen } }

    static func reset() { state.withLock { $0 = State() } }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let seen = Seen(
            method: request.httpMethod ?? "", path: request.url?.path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"), body: Self.body(of: request))
        let answer: (Int, String) = Self.state.withLock {
            $0.seen.append(seen)
            return $0.answers.isEmpty ? (500, #"{"error":"unscripted"}"#) : $0.answers.removeFirst()
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: answer.0, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
