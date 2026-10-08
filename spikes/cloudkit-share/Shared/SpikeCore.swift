// Throwaway S0 spike harness (mobile POC A, Task 1). Never merged into main.
// Shared by the macOS CLI target and the iOS app target.

import CloudKit
import CryptoKit
import Foundation

enum Spike {
    static let containerID = "iCloud.com.aiwatchtowers.watchtower"
    static let recordType = "WatchtowerRecord"
    static let dataZone = "DataZone"
    static let relayZone = "RelayZone"
    /// Fallback zone for item (e): a private custom zone that is never shared.
    static let alertZone = "AlertZone"

    static let seedDataRecord = "seed-data"
    static let seedRelayRecord = "seed-relay"
    /// DataZone record the Mac rewrites to trigger the shared-database push (b).
    static let pushProbeRecord = "probe-push"

    static let sharedDBSubscriptionID = "spike-shared-db-v1"
    static func alertSubscriptionID(zone: String) -> String { "spike-ask-alerts-\(zone)" }

    /// The link the Mac prints and renders as a QR. The iPhone Camera opens it in the app.
    static let linkScheme = "ckspike"

    /// 64 MiB, comfortably over the 60 MB the spec asks for.
    static let assetBytes = 64 * 1024 * 1024

    static var container: CKContainer { CKContainer(identifier: containerID) }

    static func zoneID(_ name: String, owner: String = CKCurrentUserDefaultName) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: name, ownerName: owner)
    }

    static func shareID(zone: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone)
    }
}

// MARK: - Link payload

/// What the Mac hands to the phone: the owner's record name and both share URLs.
struct SpikeLink: Codable, Equatable {
    var ownerUser: String
    var dataShare: URL
    var relayShare: URL

    var url: URL {
        var c = URLComponents()
        c.scheme = Spike.linkScheme
        c.host = "link"
        c.queryItems = [
            URLQueryItem(name: "owner", value: ownerUser),
            URLQueryItem(name: "data", value: dataShare.absoluteString),
            URLQueryItem(name: "relay", value: relayShare.absoluteString),
        ]
        return c.url!
    }

    init(ownerUser: String, dataShare: URL, relayShare: URL) {
        self.ownerUser = ownerUser
        self.dataShare = dataShare
        self.relayShare = relayShare
    }

    init?(url: URL) {
        guard url.scheme == Spike.linkScheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let owner = value("owner"),
              let data = value("data").flatMap(URL.init(string:)),
              let relay = value("relay").flatMap(URL.init(string:))
        else { return nil }
        self.init(ownerUser: owner, dataShare: data, relayShare: relay)
    }
}

// MARK: - Log

/// Timestamped log: stdout, a file, and an optional UI sink (iOS).
final class SpikeLog: @unchecked Sendable {
    static let shared = SpikeLog()

    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var fileURL: URL?
    var sink: ((String) -> Void)?

    func line(_ text: String) {
        lock.lock()
        let stamped = "[\(formatter.string(from: Date()))] \(text)"
        print(stamped)
        if let fileURL {
            let data = Data((stamped + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
        let sink = self.sink
        lock.unlock()
        sink?(stamped)
    }

    func result(_ item: String, pass: Bool, _ detail: String) {
        line("RESULT (\(item)): \(pass ? "PASS" : "FAIL") — \(detail)")
    }

    func step(_ item: String, _ name: String, ms: Int, _ detail: String = "") {
        line("(\(item)) \(name): \(ms) ms\(detail.isEmpty ? "" : " — \(detail)")")
    }

    func error(_ item: String, _ context: String, _ error: Error) {
        line("(\(item)) ERROR \(context): \(SpikeLog.describe(error))")
    }

    static func describe(_ error: Error) -> String {
        if let ck = error as? CKError {
            var s = "CKError \(ck.code.rawValue) (\(ck.code)) \(ck.localizedDescription)"
            if let partial = ck.partialErrorsByItemID, !partial.isEmpty {
                s += " partial=" + partial.map { "\($0.key): \(describe($0.value))" }.joined(separator: "; ")
            }
            return s
        }
        return "\(error)"
    }
}

struct Stopwatch {
    private let start = DispatchTime.now()
    var ms: Int { Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000) }
}

func epochMillis(_ date: Date = Date()) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

/// Latency between a record's `writtenAt` (written by the other device) and a local moment.
/// Both clocks are network-synced, so expect up to ~1 s of skew.
func latencyMillis(writtenAt record: CKRecord, until date: Date) -> Int64? {
    guard let written = record["writtenAt"] as? Int64 else { return nil }
    return epochMillis(date) - written
}

// MARK: - Records

func makeRecord(_ name: String, zone: CKRecordZone.ID, kind: String) -> CKRecord {
    let record = CKRecord(recordType: Spike.recordType, recordID: CKRecord.ID(recordName: name, zoneID: zone))
    record["kind"] = kind
    record["writtenAt"] = epochMillis()
    return record
}

/// Saves records with `.allKeys` and throws the first per-record failure.
func saveRecords(_ records: [CKRecord], in db: CKDatabase) async throws {
    let result = try await db.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
    for (_, outcome) in result.saveResults {
        if case .failure(let error) = outcome { throw error }
    }
}

// MARK: - Assets

/// Writes `bytes` of random data to a temp file and returns its URL and SHA-256 (hex).
func makeRandomFile(bytes: Int) throws -> (URL, String) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("spike-asset-\(UUID().uuidString).bin")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    let chunk = 1024 * 1024
    var generator = SystemRandomNumberGenerator()
    var written = 0
    while written < bytes {
        let n = min(chunk, bytes - written)
        var buffer = [UInt8](repeating: 0, count: n)
        for i in stride(from: 0, to: n, by: 8) {
            var word = generator.next()
            withUnsafeBytes(of: &word) { raw in
                for j in 0..<min(8, n - i) { buffer[i + j] = raw[j] }
            }
        }
        let data = Data(buffer)
        hasher.update(data: data)
        try handle.write(contentsOf: data)
        written += n
    }
    return (url, hex(hasher.finalize()))
}

/// Streams a file through SHA-256 and returns (size, hex digest).
func hashFile(_ url: URL) throws -> (Int, String) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    var size = 0
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
        hasher.update(data: data)
        size += data.count
    }
    return (size, hex(hasher.finalize()))
}

private func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
}

// MARK: - CKSyncEngine

/// Minimal CKSyncEngine delegate: records what each fetch/send produced, persists state
/// through a closure, and sends the pending saves it is given.
final class SpikeSyncDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingRecords: [CKRecord.ID: CKRecord] = [:]
    private var _fetchedByZone: [String: [CKRecord]] = [:]
    private var _fetchedZones: Set<String> = []
    private var _savedIDs: [CKRecord.ID] = []
    var fetchedByZone: [String: [CKRecord]] { lock.withLock { _fetchedByZone } }
    var fetchedZones: Set<String> { lock.withLock { _fetchedZones } }
    var savedIDs: [CKRecord.ID] { lock.withLock { _savedIDs } }
    /// Called inside the fetched-records event, while each record's asset file is still valid.
    var onFetchedRecord: ((CKRecord) -> Void)?
    var onState: ((CKSyncEngine.State.Serialization) -> Void)?
    let item: String

    init(item: String) { self.item = item }

    func stage(_ record: CKRecord) {
        lock.withLock { pendingRecords[record.recordID] = record }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            onState?(update.stateSerialization)
        case .accountChange(let change):
            SpikeLog.shared.line("(\(item)) engine account change: \(change.changeType)")
        case .fetchedDatabaseChanges(let changes):
            let names = changes.modifications.map { "\($0.zoneID.zoneName)@\($0.zoneID.ownerName)" }
            SpikeLog.shared.line("(\(item)) engine fetched database changes: zones=\(names) deletions=\(changes.deletions.count)")
            lock.withLock { changes.modifications.forEach { _fetchedZones.insert($0.zoneID.zoneName) } }
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                let record = modification.record
                onFetchedRecord?(record)
                lock.withLock {
                    _fetchedByZone[record.recordID.zoneID.zoneName, default: []].append(record)
                    _fetchedZones.insert(record.recordID.zoneID.zoneName)
                }
            }
            SpikeLog.shared.line("(\(item)) engine fetched record changes: +\(changes.modifications.count) -\(changes.deletions.count)")
        case .sentRecordZoneChanges(let sent):
            lock.withLock {
                for record in sent.savedRecords {
                    _savedIDs.append(record.recordID)
                    pendingRecords[record.recordID] = nil
                }
            }
            SpikeLog.shared.line("(\(item)) engine sent: saved=\(sent.savedRecords.count) failed=\(sent.failedRecordSaves.count)")
            for failure in sent.failedRecordSaves {
                SpikeLog.shared.error(item, "save \(failure.record.recordID.recordName)", failure.error)
            }
        case .willFetchChanges, .didFetchChanges, .willSendChanges, .didSendChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .sentDatabaseChanges:
            break
        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        let snapshot = lock.withLock { pendingRecords }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { snapshot[$0] }
    }
}
