import Foundation
import WatchtowerSync

/// Where the loopback CloudKit store of the Go hub's interop run listens (relay client Phase 3b Task 24,
/// Ruling R24): `http://127.0.0.1:<port>` and the run's token. The Go test writes it to `ck.url` in the
/// handoff folder as `{"url": …, "token": …}`, mode 0600.
public struct LoopbackCloudEndpoint: Codable, Equatable, Sendable {
    /// The handoff file's name.
    public static let handoffFile = "ck.url"

    public let url: URL
    public let token: String

    public init(url: URL, token: String) {
        self.url = url
        self.token = token
    }

    /// The endpoint the Go side handed over in `dir`.
    public static func read(fromHandoff dir: URL) throws -> Self {
        let data = try Data(contentsOf: dir.appendingPathComponent(handoffFile))
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

/// Why a loopback call failed outside an item's outcome.
public enum LoopbackCloudError: Error, Equatable, Sendable {
    /// 403: the request did not carry the run's token.
    case forbidden
    /// 410: the change cursor is no longer valid; read the zone again from nil.
    case tokenExpired
    /// The store refused an unconditional write or a read.
    case refused(TransportRefusal)
    /// An answer that is not the store's protocol.
    case badAnswer(status: Int)
}

/// The Kit phone's iCloud leg in the Go hub's interop run: `CloudSyncTransport` + `ConditionalTransport`
/// over the loopback store that `internal/hub/interop_desktop_test.go` serves on the hub's bridgefake (the
/// store the Go hub's CloudKit tests trust). Records are the phone's view of the hub's zones: `payload` is the
/// sealed envelope, `kind` is `sig` for a payload-free `sig-` record (as the bridge maps it) and `wt` otherwise,
/// `origin` carries the store's creator and server time, and `recordSeq` is the record's change tag. Assets are
/// not carried: a record with an `assetFileURL` is refused.
///
/// `user` is the phone's iCloud user record name: nil is the Mac's own user (a private-scope phone); a
/// shared-scope phone calls `acceptShare()` first, and the hub's removal from the share refuses it again
/// (`.permanent(code: "not_participant")`).
///
/// Test-only: it lives in WatchtowerHostedRelayTesting, which no app or extension target links, and it
/// talks to 127.0.0.1 only through the URL the Go test handed over.
public struct LoopbackCloudTransport: ConditionalTransport, Sendable {
    /// Upper bound on change pages per `changes` call (a runaway cursor ends in `.badAnswer`).
    static let maxPages = 1000

    public let endpoint: LoopbackCloudEndpoint
    public let user: String?
    private let session: URLSession

    public init(endpoint: LoopbackCloudEndpoint, user: String?, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.endpoint = endpoint
        self.user = user
        self.session = session
    }

    /// Joins both of the hub's shares as `user`, as accepting the share links does on a real phone.
    public func acceptShare() async throws {
        guard let user else { return }
        let answer = try await post("accept-share", Body(user: user))
        guard answer.status == 200 else { throw failure(answer) }
    }

    // MARK: - CloudSyncTransport

    public func save(_ records: [CloudRecord]) async throws {
        for outcome in try await save(records.map { ConditionalSave(record: $0, expect: .none) }) {
            if case .refused(let refusal) = outcome { throw LoopbackCloudError.refused(refusal) }
        }
    }

    public func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        let items = recordNames.map { ConditionalDelete(recordName: $0, zone: zone, expect: .none) }
        for outcome in try await delete(items) {
            if case .refused(let refusal) = outcome { throw LoopbackCloudError.refused(refusal) }
        }
    }

    /// Every page after `token`, in one batch: a later page's version of a record replaces an earlier one.
    public func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        var since = UInt64(max(token?.value ?? 0, 0))
        var pages = Pages()
        for _ in 0..<Self.maxPages {
            let answer = try await post("changes", Body(user: user, zone: zone.rawValue, since: since))
            guard answer.status == 200 else { throw failure(answer) }
            let page = try JSONDecoder().decode(Page.self, from: answer.body)
            for wire in page.changed ?? [] {
                pages.note(wire.name, wire.record(in: zone))
            }
            for name in page.deleted ?? [] {
                pages.note(name, nil)
            }
            since = page.newSeq
            if !page.more {
                return CloudChangeBatch(
                    changed: pages.order.compactMap { pages.changed[$0] },
                    deletedRecordNames: pages.order.filter { pages.deleted.contains($0) },
                    newToken: CloudChangeToken(value: Int(clamping: since)))
            }
        }
        throw LoopbackCloudError.badAnswer(status: 200)
    }

    // MARK: - ConditionalTransport

    public func save(_ items: [ConditionalSave]) async throws -> [SaveOutcome] {
        var out: [SaveOutcome] = []
        for item in items {
            let record = item.record
            guard record.assetFileURL == nil else {
                out.append(.refused(.permanent(code: "asset_unsupported")))
                continue
            }
            let (expect, seq) = Self.wire(item.expect)
            let body = Body(user: user, zone: record.zone.rawValue, name: record.recordName, payload: record.payload,
                            expect: expect, seq: seq)
            switch try await outcome("save", body) {
            case .done(let tag):
                out.append(.saved(recordSeq: tag))
            case .conflict(let current?):
                out.append(.conflict(current: current.record(in: record.zone)))
            case .conflict(nil):
                // There is no current record to hand back.
                out.append(.refused(.permanent(code: "gone")))
            case .refused(let refusal):
                out.append(.refused(refusal))
            }
        }
        return out
    }

    public func delete(_ items: [ConditionalDelete]) async throws -> [DeleteOutcome] {
        var out: [DeleteOutcome] = []
        for item in items {
            let (expect, seq) = Self.wire(item.expect)
            let body = Body(user: user, zone: item.zone.rawValue, name: item.recordName, expect: expect, seq: seq)
            switch try await outcome("delete", body) {
            case .done:
                out.append(.deleted)
            case .conflict(let current?):
                out.append(.conflict(current: current.record(in: item.zone)))
            case .conflict(nil):
                // The seam's idempotent delete: an absent record is already deleted.
                out.append(.deleted)
            case .refused(let refusal):
                out.append(.refused(refusal))
            }
        }
        return out
    }

    // MARK: - Wire

    private struct Body: Encodable {
        var user: String?
        var zone: String?
        var name: String?
        var payload: Data?
        var expect: String?
        var seq: UInt64?
        var since: UInt64?

        init(
            user: String?,
            zone: String? = nil,
            name: String? = nil,
            payload: Data? = nil,
            expect: String? = nil,
            seq: UInt64? = nil,
            since: UInt64? = nil
        ) {
            self.user = user ?? ""
            self.zone = zone
            self.name = name
            self.payload = payload
            self.expect = expect
            self.seq = seq
            self.since = since
        }
    }

    private struct WireRecord: Decodable {
        let name: String
        let payload: Data?
        let seq: UInt64
        let creator: String?
        let serverAtMs: Int64?

        enum CodingKeys: String, CodingKey {
            case name, payload, seq, creator
            case serverAtMs = "server_at_ms"
        }

        func record(in zone: CloudZoneID) -> CloudRecord {
            let payload = payload ?? Data()
            let serverAt = serverAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            let signal = payload.isEmpty && name.hasPrefix("\(WireKind.signal)-")
            return CloudRecord(
                recordName: name, zone: zone, kind: signal ? WireKind.signal : WireKind.envelope,
                modifiedAt: serverAt ?? Date(timeIntervalSince1970: 0), payload: payload,
                origin: RecordOrigin(author: creator.flatMap { $0.isEmpty ? nil : $0 }, serverAt: serverAt),
                recordSeq: seq)
        }
    }

    private struct Page: Decodable {
        let changed: [WireRecord]?
        let deleted: [String]?
        let newSeq: UInt64
        let more: Bool

        enum CodingKeys: String, CodingKey {
            case changed, deleted, more
            case newSeq = "new_seq"
        }
    }

    private struct WireOutcome: Decodable {
        let outcome: String
        let seq: UInt64?
        let current: WireRecord?
    }

    private struct WireError: Decodable {
        let error: String
    }

    private enum ItemOutcome {
        case done(UInt64)
        case conflict(WireRecord?)
        case refused(TransportRefusal)
    }

    private static func wire(_ expect: WriteExpectation) -> (String, UInt64?) {
        switch expect {
        case .none: return ("none", nil)
        case .absent: return ("absent", nil)
        case .seq(let seq): return ("seq", seq)
        }
    }

    /// The pages read so far: each name once, in first-seen order, at its latest state.
    private struct Pages {
        var order: [String] = []
        var changed: [String: CloudRecord] = [:]
        var deleted: Set<String> = []

        /// `record` nil = deleted.
        mutating func note(_ name: String, _ record: CloudRecord?) {
            if changed[name] == nil, !deleted.contains(name) { order.append(name) }
            if let record {
                changed[name] = record
                deleted.remove(name)
            } else {
                changed[name] = nil
                deleted.insert(name)
            }
        }
    }

    /// One item's answer: a store refusal is the item's outcome; 403 and a broken answer throw.
    private func outcome(_ op: String, _ body: Body) async throws -> ItemOutcome {
        let answer: (status: Int, body: Data)
        do {
            answer = try await post(op, body)
        } catch LoopbackCloudError.refused(let refusal) {
            return .refused(refusal)
        }
        guard answer.status == 200 else {
            if case LoopbackCloudError.refused(let refusal) = failure(answer) { return .refused(refusal) }
            throw failure(answer)
        }
        let wire = try JSONDecoder().decode(WireOutcome.self, from: answer.body)
        switch wire.outcome {
        case "saved", "deleted": return .done(wire.seq ?? 0)
        case "conflict": return .conflict(wire.current)
        default: throw LoopbackCloudError.badAnswer(status: answer.status)
        }
    }

    /// The error of a non-200 answer.
    private func failure(_ answer: (status: Int, body: Data)) -> LoopbackCloudError {
        let code = (try? JSONDecoder().decode(WireError.self, from: answer.body))?.error ?? "http_\(answer.status)"
        switch answer.status {
        case 403: return .forbidden
        case 410: return .tokenExpired
        case 503: return .refused(.unreachable)
        case 400, 404, 405, 409: return .refused(.permanent(code: code))
        case 500...: return .refused(.transient(code: code))
        default: return .badAnswer(status: answer.status)
        }
    }

    /// POSTs `body` to `/<op>` with the run's token; a connection that never answered is `.unreachable`.
    private func post(_ op: String, _ body: Body) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: endpoint.url.appendingPathComponent(op))
        request.httpMethod = "POST"
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch is URLError {
            throw LoopbackCloudError.refused(.unreachable)
        }
        guard let http = response as? HTTPURLResponse else { throw LoopbackCloudError.badAnswer(status: 0) }
        return (http.statusCode, data)
    }
}
