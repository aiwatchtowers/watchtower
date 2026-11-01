import Foundation

// The bridge protocol's frames (internal/hub/transport/cloudkit/bridge.proto, version 1), hand-coded: the
// package has no swift-protobuf, and the messages use only varint and length-delimited fields. Encoding follows
// the Go side's deterministic marshal — fields in field-number order, proto3 defaults omitted, a present
// sub-message always written (even empty) — so the bytes equal internal/hub/transport/cloudkit/testdata/frames.json
// (BridgeFramesFixtureTests). Decoding skips unknown fields.

/// The bridge protocol version this bridge speaks.
public let bridgeProtocolVersion: UInt32 = 1

/// The largest protobuf message one frame carries (4 MiB).
public let bridgeMaxFrame = 4 << 20

public enum BridgeFrameError: Error, Equatable {
    case truncated
    case badWireType(field: UInt64, wireType: UInt64)
    case badUTF8(field: UInt64)
    case frameTooLarge(Int)
    case overlongVarint
}

// MARK: - Requests

public enum BridgeExpectMode: UInt64, Sendable {
    case none = 0
    case absent = 1
    case seq = 2
}

/// A precondition; `tagSeq` (with the generation it was issued in) is read only with `.seq`.
public struct BridgeExpect: Equatable, Sendable {
    public var mode: BridgeExpectMode
    public var tagSeq: UInt64
    public var generation: String

    public init(mode: BridgeExpectMode = .none, tagSeq: UInt64 = 0, generation: String = "") {
        self.mode = mode
        self.tagSeq = tagSeq
        self.generation = generation
    }
}

public struct BridgeSaveItem: Equatable, Sendable {
    public var zone: String
    public var name: String
    public var envelope: Data
    public var assetPath: String
    public var expect: BridgeExpect?

    public init(zone: String, name: String, envelope: Data = Data(), assetPath: String = "", expect: BridgeExpect? = nil) {
        self.zone = zone
        self.name = name
        self.envelope = envelope
        self.assetPath = assetPath
        self.expect = expect
    }
}

public struct BridgeDeleteItem: Equatable, Sendable {
    public var name: String
    public var expect: BridgeExpect?

    public init(name: String, expect: BridgeExpect? = nil) {
        self.name = name
        self.expect = expect
    }
}

/// The request's `op` oneof.
public enum BridgeOp: Equatable, Sendable {
    case hello(version: UInt32, hubID: String)
    case save([BridgeSaveItem])
    case delete(zone: String, items: [BridgeDeleteItem])
    case changes(zone: String, since: UInt64, generation: String)
    case download(zone: String, assetID: String, dst: String)
    case accountStatus
    case ensureShares
    case setPublicLink(open: Bool)
    case participants(zone: String)
    case removeParticipants(zone: String, userRecordNames: [String])
}

/// Every frame the Go hub writes.
public struct BridgeRequest: Equatable, Sendable {
    public var id: UInt64
    public var op: BridgeOp?

    public init(id: UInt64, op: BridgeOp?) {
        self.id = id
        self.op = op
    }
}

// MARK: - Responses

/// A stored record: its name, envelope, the bridge's number for its change tag, the server's modification
/// time and its asset's id, if any.
public struct BridgeRecord: Equatable, Sendable {
    public var name: String
    public var envelope: Data
    public var tagSeq: UInt64
    public var serverAtMs: Int64
    public var assetID: String

    public init(name: String, envelope: Data = Data(), tagSeq: UInt64 = 0, serverAtMs: Int64 = 0, assetID: String = "") {
        self.name = name
        self.envelope = envelope
        self.tagSeq = tagSeq
        self.serverAtMs = serverAtMs
        self.assetID = assetID
    }
}

/// Saved with the new `tagSeq`; or not saved, with `refusedClass` set (a per-item refusal) or with `conflict`
/// = the current record (nil when there is none).
public struct BridgeOutcome: Equatable, Sendable {
    public var saved: Bool
    public var tagSeq: UInt64
    public var conflict: BridgeRecord?
    public var refusedClass: String

    public init(saved: Bool = false, tagSeq: UInt64 = 0, conflict: BridgeRecord? = nil, refusedClass: String = "") {
        self.saved = saved
        self.tagSeq = tagSeq
        self.conflict = conflict
        self.refusedClass = refusedClass
    }
}

/// One page of changes; `newSeq` is the next cursor, `generation` the one its numbers belong to.
public struct BridgeBatch: Equatable, Sendable {
    public var changed: [BridgeRecord]
    public var deleted: [String]
    public var newSeq: UInt64
    public var more: Bool
    public var generation: String

    public init(changed: [BridgeRecord] = [], deleted: [String] = [], newSeq: UInt64 = 0, more: Bool = false, generation: String = "") {
        self.changed = changed
        self.deleted = deleted
        self.newSeq = newSeq
        self.more = more
        self.generation = generation
    }
}

public struct BridgeParticipant: Equatable, Sendable {
    public var userRecordName: String
    public var accepted: Bool

    public init(userRecordName: String, accepted: Bool = false) {
        self.userRecordName = userRecordName
        self.accepted = accepted
    }
}

/// A server-sent event: a zone that may have changed, a silent push, or a transport-level error class.
public struct BridgeEvent: Equatable, Sendable {
    public var zone: String
    public var pullNow: Bool
    public var errorClass: String

    public init(zone: String = "", pullNow: Bool = false, errorClass: String = "") {
        self.zone = zone
        self.pullNow = pullNow
        self.errorClass = errorClass
    }
}

/// The response's `result` oneof.
public enum BridgeResult: Equatable, Sendable {
    case hello(version: UInt32, generation: String)
    case outcomes([BridgeOutcome])
    case batch(BridgeBatch)
    case done
    case account(status: String)
    case shares(dataURL: String, relayURL: String)
    case participants([BridgeParticipant])
    case failure(class: String)
    case event(BridgeEvent)
}

/// Every frame the bridge writes; id 0 with an event is server-sent.
public struct BridgeResponse: Equatable, Sendable {
    public var id: UInt64
    public var result: BridgeResult?

    public init(id: UInt64, result: BridgeResult?) {
        self.id = id
        self.result = result
    }
}

// MARK: - Writer

/// Appends protobuf fields; every `put` skips a proto3 default, `message` always writes.
struct ProtoWriter {
    private(set) var bytes = Data()

    private mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    private mutating func key(_ field: UInt64, _ wireType: UInt64) {
        varint(field << 3 | wireType)
    }

    mutating func put(_ field: UInt64, _ value: UInt64) {
        guard value != 0 else { return }
        key(field, 0)
        varint(value)
    }

    mutating func put(_ field: UInt64, _ value: Int64) {
        put(field, UInt64(bitPattern: value))
    }

    mutating func put(_ field: UInt64, _ value: Bool) {
        put(field, value ? UInt64(1) : 0)
    }

    mutating func put(_ field: UInt64, _ value: Data) {
        guard !value.isEmpty else { return }
        bytesField(field, value)
    }

    mutating func put(_ field: UInt64, _ value: String) {
        put(field, Data(value.utf8))
    }

    /// A repeated string: every element, empty ones too.
    mutating func putEach(_ field: UInt64, _ values: [String]) {
        for value in values { bytesField(field, Data(value.utf8)) }
    }

    mutating func message(_ field: UInt64, _ build: (inout Self) -> Void) {
        var inner = Self()
        build(&inner)
        bytesField(field, inner.bytes)
    }

    private mutating func bytesField(_ field: UInt64, _ value: Data) {
        key(field, 2)
        varint(UInt64(value.count))
        bytes.append(value)
    }
}

// MARK: - Reader

/// Reads protobuf fields in order; `fields` hands each known field to `body` and skips the rest.
struct ProtoReader {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
    }

    private let data: Data
    private var index: Data.Index

    init(_ data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    private mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < data.endIndex else { throw BridgeFrameError.truncated }
            guard shift < 64 else { throw BridgeFrameError.overlongVarint }
            let byte = data[index]
            index = data.index(after: index)
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    private mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, data.distance(from: index, to: data.endIndex) >= count else { throw BridgeFrameError.truncated }
        let end = data.index(index, offsetBy: count)
        defer { index = end }
        return Data(data[index..<end])
    }

    static func fields(_ data: Data, _ body: (UInt64, Value) throws -> Void) throws {
        var reader = Self(data)
        while reader.index < reader.data.endIndex {
            let key = try reader.varint()
            let field = key >> 3, wireType = key & 7
            switch wireType {
            case 0:
                try body(field, .varint(try reader.varint()))
            case 1:
                _ = try reader.take(8)
            case 2:
                let length = try reader.varint()
                guard length <= UInt64(Int.max) else { throw BridgeFrameError.truncated }
                try body(field, .bytes(try reader.take(Int(length))))
            case 5:
                _ = try reader.take(4)
            default:
                throw BridgeFrameError.badWireType(field: field, wireType: wireType)
            }
        }
    }
}

extension ProtoReader.Value {
    func uint64(_ field: UInt64) throws -> UInt64 {
        guard case .varint(let v) = self else { throw BridgeFrameError.badWireType(field: field, wireType: 2) }
        return v
    }

    func uint32(_ field: UInt64) throws -> UInt32 { UInt32(truncatingIfNeeded: try uint64(field)) }
    func int64(_ field: UInt64) throws -> Int64 { Int64(bitPattern: try uint64(field)) }
    func bool(_ field: UInt64) throws -> Bool { try uint64(field) != 0 }

    func data(_ field: UInt64) throws -> Data {
        guard case .bytes(let d) = self else { throw BridgeFrameError.badWireType(field: field, wireType: 0) }
        return d
    }

    func string(_ field: UInt64) throws -> String {
        guard let s = String(data: try data(field), encoding: .utf8) else { throw BridgeFrameError.badUTF8(field: field) }
        return s
    }
}

// MARK: - Request coding

extension BridgeExpect {
    func encode(_ w: inout ProtoWriter) {
        w.put(1, mode.rawValue)
        w.put(2, tagSeq)
        w.put(3, generation)
    }

    static func decode(_ data: Data) throws -> Self {
        var e = Self()
        try ProtoReader.fields(data) { field, value in
            switch field {
            case 1: e.mode = BridgeExpectMode(rawValue: try value.uint64(field)) ?? .none
            case 2: e.tagSeq = try value.uint64(field)
            case 3: e.generation = try value.string(field)
            default: break
            }
        }
        return e
    }
}

extension BridgeSaveItem {
    func encode(_ w: inout ProtoWriter) {
        w.put(1, zone)
        w.put(2, name)
        w.put(3, envelope)
        w.put(4, assetPath)
        if let expect { w.message(5) { expect.encode(&$0) } }
    }

    static func decode(_ data: Data) throws -> Self {
        var item = Self(zone: "", name: "")
        try ProtoReader.fields(data) { field, value in
            switch field {
            case 1: item.zone = try value.string(field)
            case 2: item.name = try value.string(field)
            case 3: item.envelope = try value.data(field)
            case 4: item.assetPath = try value.string(field)
            case 5: item.expect = try BridgeExpect.decode(try value.data(field))
            default: break
            }
        }
        return item
    }
}

extension BridgeDeleteItem {
    func encode(_ w: inout ProtoWriter) {
        w.put(1, name)
        if let expect { w.message(2) { expect.encode(&$0) } }
    }

    static func decode(_ data: Data) throws -> Self {
        var item = Self(name: "")
        try ProtoReader.fields(data) { field, value in
            switch field {
            case 1: item.name = try value.string(field)
            case 2: item.expect = try BridgeExpect.decode(try value.data(field))
            default: break
            }
        }
        return item
    }
}

extension BridgeRequest {
    public func encoded() -> Data {
        var w = ProtoWriter()
        w.put(1, id)
        switch op {
        case let .hello(version, hubID):
            w.message(2) { $0.put(1, UInt64(version)); $0.put(2, hubID) }
        case .save(let items):
            w.message(3) { m in items.forEach { item in m.message(1) { item.encode(&$0) } } }
        case let .delete(zone, items):
            w.message(4) { m in
                m.put(1, zone)
                items.forEach { item in m.message(2) { item.encode(&$0) } }
            }
        case let .changes(zone, since, generation):
            w.message(5) { $0.put(1, zone); $0.put(2, since); $0.put(3, generation) }
        case let .download(zone, assetID, dst):
            w.message(6) { $0.put(1, zone); $0.put(2, assetID); $0.put(3, dst) }
        case .accountStatus:
            w.message(7) { _ in }
        case .ensureShares:
            w.message(8) { _ in }
        case .setPublicLink(let open):
            w.message(9) { $0.put(1, open) }
        case .participants(let zone):
            w.message(10) { $0.put(1, zone) }
        case let .removeParticipants(zone, names):
            w.message(11) { $0.put(1, zone); $0.putEach(2, names) }
        case nil:
            break
        }
        return w.bytes
    }

    public static func decode(_ data: Data) throws -> Self {
        var request = Self(id: 0, op: nil)
        try ProtoReader.fields(data) { field, value in
            switch field {
            case 1: request.id = try value.uint64(field)
            case 2...11: request.op = try decodeOp(field, try value.data(field))
            default: break
            }
        }
        return request
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func decodeOp(_ field: UInt64, _ body: Data) throws -> BridgeOp {
        switch field {
        case 2:
            var version: UInt32 = 0, hubID = ""
            try ProtoReader.fields(body) { f, v in
                if f == 1 { version = try v.uint32(f) } else if f == 2 { hubID = try v.string(f) }
            }
            return .hello(version: version, hubID: hubID)
        case 3:
            var items: [BridgeSaveItem] = []
            try ProtoReader.fields(body) { f, v in
                if f == 1 { items.append(try BridgeSaveItem.decode(try v.data(f))) }
            }
            return .save(items)
        case 4:
            var zone = "", items: [BridgeDeleteItem] = []
            try ProtoReader.fields(body) { f, v in
                if f == 1 { zone = try v.string(f) } else if f == 2 { items.append(try BridgeDeleteItem.decode(try v.data(f))) }
            }
            return .delete(zone: zone, items: items)
        case 5:
            var zone = "", since: UInt64 = 0, generation = ""
            try ProtoReader.fields(body) { f, v in
                switch f {
                case 1: zone = try v.string(f)
                case 2: since = try v.uint64(f)
                case 3: generation = try v.string(f)
                default: break
                }
            }
            return .changes(zone: zone, since: since, generation: generation)
        case 6:
            var zone = "", assetID = "", dst = ""
            try ProtoReader.fields(body) { f, v in
                switch f {
                case 1: zone = try v.string(f)
                case 2: assetID = try v.string(f)
                case 3: dst = try v.string(f)
                default: break
                }
            }
            return .download(zone: zone, assetID: assetID, dst: dst)
        case 7:
            return .accountStatus
        case 8:
            return .ensureShares
        case 9:
            var open = false
            try ProtoReader.fields(body) { f, v in if f == 1 { open = try v.bool(f) } }
            return .setPublicLink(open: open)
        case 10:
            var zone = ""
            try ProtoReader.fields(body) { f, v in if f == 1 { zone = try v.string(f) } }
            return .participants(zone: zone)
        default:
            var zone = "", names: [String] = []
            try ProtoReader.fields(body) { f, v in
                if f == 1 { zone = try v.string(f) } else if f == 2 { names.append(try v.string(f)) }
            }
            return .removeParticipants(zone: zone, userRecordNames: names)
        }
    }
}

// MARK: - Response coding

extension BridgeRecord {
    func encode(_ w: inout ProtoWriter) {
        w.put(1, name)
        w.put(2, envelope)
        w.put(3, tagSeq)
        w.put(4, serverAtMs)
        w.put(5, assetID)
    }

    static func decode(_ data: Data) throws -> Self {
        var r = Self(name: "")
        try ProtoReader.fields(data) { field, value in
            switch field {
            case 1: r.name = try value.string(field)
            case 2: r.envelope = try value.data(field)
            case 3: r.tagSeq = try value.uint64(field)
            case 4: r.serverAtMs = try value.int64(field)
            case 5: r.assetID = try value.string(field)
            default: break
            }
        }
        return r
    }
}

extension BridgeOutcome {
    func encode(_ w: inout ProtoWriter) {
        w.put(1, saved)
        w.put(2, tagSeq)
        if let conflict { w.message(3) { conflict.encode(&$0) } }
        w.put(4, refusedClass)
    }

    static func decode(_ data: Data) throws -> Self {
        var outcome = Self()
        try ProtoReader.fields(data) { field, value in
            switch field {
            case 1: outcome.saved = try value.bool(field)
            case 2: outcome.tagSeq = try value.uint64(field)
            case 3: outcome.conflict = try BridgeRecord.decode(try value.data(field))
            case 4: outcome.refusedClass = try value.string(field)
            default: break
            }
        }
        return outcome
    }
}

extension BridgeBatch {
    func encode(_ w: inout ProtoWriter) {
        changed.forEach { record in w.message(1) { record.encode(&$0) } }
        w.putEach(2, deleted)
        w.put(3, newSeq)
        w.put(4, more)
        w.put(5, generation)
    }

    static func decode(_ data: Data) throws -> Self {
        var b = Self()
        try ProtoReader.fields(data) { field, value in
            switch field {
            case 1: b.changed.append(try BridgeRecord.decode(try value.data(field)))
            case 2: b.deleted.append(try value.string(field))
            case 3: b.newSeq = try value.uint64(field)
            case 4: b.more = try value.bool(field)
            case 5: b.generation = try value.string(field)
            default: break
            }
        }
        return b
    }
}

extension BridgeEvent {
    func encode(_ w: inout ProtoWriter) {
        w.put(1, zone)
        w.put(2, pullNow)
        w.put(3, errorClass)
    }

    static func decode(_ data: Data) throws -> Self {
        var e = Self()
        try ProtoReader.fields(data) { field, value in
            switch field {
            case 1: e.zone = try value.string(field)
            case 2: e.pullNow = try value.bool(field)
            case 3: e.errorClass = try value.string(field)
            default: break
            }
        }
        return e
    }
}

extension BridgeResponse {
    public func encoded() -> Data {
        var w = ProtoWriter()
        w.put(1, id)
        switch result {
        case let .hello(version, generation):
            w.message(2) { $0.put(1, UInt64(version)); $0.put(2, generation) }
        case .outcomes(let items):
            w.message(3) { m in items.forEach { item in m.message(1) { item.encode(&$0) } } }
        case .batch(let batch):
            w.message(4) { batch.encode(&$0) }
        case .done:
            w.message(5) { _ in }
        case .account(let status):
            w.message(6) { $0.put(1, status) }
        case let .shares(dataURL, relayURL):
            w.message(7) { $0.put(1, dataURL); $0.put(2, relayURL) }
        case .participants(let items):
            w.message(8) { m in
                items.forEach { p in m.message(1) { $0.put(1, p.userRecordName); $0.put(2, p.accepted) } }
            }
        case .failure(let failureClass):
            w.message(9) { $0.put(1, failureClass) }
        case .event(let event):
            w.message(10) { event.encode(&$0) }
        case nil:
            break
        }
        return w.bytes
    }

    public static func decode(_ data: Data) throws -> Self {
        var response = Self(id: 0, result: nil)
        try ProtoReader.fields(data) { field, value in
            switch field {
            case 1: response.id = try value.uint64(field)
            case 2...10: response.result = try decodeResult(field, try value.data(field))
            default: break
            }
        }
        return response
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func decodeResult(_ field: UInt64, _ body: Data) throws -> BridgeResult {
        switch field {
        case 2:
            var version: UInt32 = 0, generation = ""
            try ProtoReader.fields(body) { f, v in
                if f == 1 { version = try v.uint32(f) } else if f == 2 { generation = try v.string(f) }
            }
            return .hello(version: version, generation: generation)
        case 3:
            var items: [BridgeOutcome] = []
            try ProtoReader.fields(body) { f, v in if f == 1 { items.append(try BridgeOutcome.decode(try v.data(f))) } }
            return .outcomes(items)
        case 4:
            return .batch(try BridgeBatch.decode(body))
        case 5:
            return .done
        case 6:
            var status = ""
            try ProtoReader.fields(body) { f, v in if f == 1 { status = try v.string(f) } }
            return .account(status: status)
        case 7:
            var dataURL = "", relayURL = ""
            try ProtoReader.fields(body) { f, v in
                if f == 1 { dataURL = try v.string(f) } else if f == 2 { relayURL = try v.string(f) }
            }
            return .shares(dataURL: dataURL, relayURL: relayURL)
        case 8:
            var items: [BridgeParticipant] = []
            try ProtoReader.fields(body) { f, v in
                guard f == 1 else { return }
                var p = BridgeParticipant(userRecordName: "")
                try ProtoReader.fields(try v.data(f)) { pf, pv in
                    if pf == 1 { p.userRecordName = try pv.string(pf) } else if pf == 2 { p.accepted = try pv.bool(pf) }
                }
                items.append(p)
            }
            return .participants(items)
        case 9:
            var failureClass = ""
            try ProtoReader.fields(body) { f, v in if f == 1 { failureClass = try v.string(f) } }
            return .failure(class: failureClass)
        default:
            return .event(try BridgeEvent.decode(body))
        }
    }
}

// MARK: - Framing

/// A frame: a u32 big-endian length, then the message bytes.
public enum BridgeFraming {
    public static func frame(_ message: Data) throws -> Data {
        guard message.count <= bridgeMaxFrame else { throw BridgeFrameError.frameTooLarge(message.count) }
        var out = Data(capacity: 4 + message.count)
        let n = UInt32(message.count)
        out.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
        out.append(message)
        return out
    }

    /// The length a frame header announces; past `bridgeMaxFrame` is an error.
    public static func length(ofHeader header: Data) throws -> Int {
        guard header.count == 4 else { throw BridgeFrameError.truncated }
        let b = [UInt8](header)
        let n = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
        guard n <= bridgeMaxFrame else { throw BridgeFrameError.frameTooLarge(n) }
        return n
    }
}
