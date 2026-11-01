import CloudBridgeCore
import Foundation

/// CloudKit as the bridge sees it, in memory: random change tags, a change feed per zone with opaque tokens
/// (the archived feed position), deletes that win, conditional writes on change tags.
actor FakeBridgeCloud: BridgeCloud {
    private struct Entry {
        var item: CloudItem?
        var change: Int
    }

    private var zones: [String: [String: Entry]] = [:]
    private var counter = 0
    private var assets: [String: Data] = [:]
    var pageLimit = 100
    /// Every envelope handed to save, as received.
    private(set) var savedEnvelopes: [Data] = []

    func setPageLimit(_ n: Int) { pageLimit = n }

    private func tag() -> String { UUID().uuidString }

    private func current(_ zone: String, _ name: String) -> CloudItem? { zones[zone]?[name]?.item }

    private func put(_ zone: String, _ item: CloudItem?, name: String) {
        counter += 1
        zones[zone, default: [:]][name] = Entry(item: item, change: counter)
    }

    private func holds(_ precondition: CloudPrecondition, _ cur: CloudItem?) -> Bool {
        switch precondition {
        case .none: return true
        case .absent: return cur == nil
        case .unchanged(let tag, _): return cur?.changeTag == tag
        }
    }

    /// A phone's (or anyone's) write straight into the store.
    @discardableResult
    func write(zone: String, name: String, envelope: Data, asset: Data? = nil) -> CloudItem {
        let t = tag()
        let item = CloudItem(
            name: name, envelope: envelope, changeTag: t, systemFields: Data(t.utf8),
            serverAt: Date(timeIntervalSince1970: 1_800_000_000.123), hasAsset: asset != nil)
        if let asset { assets[zone + "/" + name] = asset }
        put(zone, item, name: name)
        return item
    }

    func save(zone: String, _ writes: [CloudWrite]) async throws -> [CloudWriteResult] {
        writes.map { w in
            savedEnvelopes.append(w.envelope)
            let cur = current(zone, w.name)
            guard holds(w.precondition, cur) else { return .conflict(cur) }
            let asset = w.assetURL.flatMap { try? Data(contentsOf: $0) }
            return .done(write(zone: zone, name: w.name, envelope: w.envelope, asset: asset))
        }
    }

    func delete(zone: String, _ deletions: [CloudDeletion]) async throws -> [CloudWriteResult] {
        deletions.map { d in
            let cur = current(zone, d.name)
            guard holds(d.precondition, cur) else { return .conflict(cur) }
            if cur != nil { put(zone, nil, name: d.name) }
            return .done(nil)
        }
    }

    func fetch(zone: String, name: String) async throws -> CloudItem? { current(zone, name) }

    func changes(zone: String, since token: Data?) async throws -> CloudPage {
        let floor = token.flatMap { String(bytes: $0, encoding: .utf8) }.flatMap { Int($0) } ?? 0
        let entries = (zones[zone] ?? [:]).filter { $0.value.change > floor && (token != nil || $0.value.item != nil) }
            .sorted { $0.value.change < $1.value.change }
        let page = entries.prefix(pageLimit)
        let last = page.last?.value.change ?? max(floor, 0)
        return CloudPage(
            changed: page.compactMap(\.value.item), deleted: page.filter { $0.value.item == nil }.map(\.key),
            token: Data(String(last).utf8), more: entries.count > page.count)
    }

    func downloadAsset(zone: String, name: String, to dst: URL) async throws {
        guard let data = assets[zone + "/" + name] else { throw BridgeCloudFailure.badRequest }
        try data.write(to: dst)
    }
}

final class FakeShares: BridgeShareProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var people: [String: [ZoneShareParticipant]] = [:]
    private var open = false

    var publicLink: Bool { lock.withLock { open } }

    func set(_ zone: String, _ list: [ZoneShareParticipant]) { lock.withLock { people[zone] = list } }

    func accountStatus() async -> ZoneShareAccount { .temporarilyUnavailable }

    func ensureShares() async throws -> (data: String, relay: String) {
        ("https://www.icloud.com/share/0data", "https://www.icloud.com/share/0relay")
    }

    func setPublicLink(open: Bool) async throws { lock.withLock { self.open = open } }

    func participants(inZoneNamed zone: String) async throws -> [ZoneShareParticipant] {
        lock.withLock { people[zone] ?? [] }
    }

    func removeParticipants(inZoneNamed zone: String, userRecordNames: [String]) async throws {
        lock.withLock { people[zone]?.removeAll { $0.userRecordName.map(userRecordNames.contains) ?? false } }
    }
}

/// A fresh hub dir (0700) with `assets/` and `downloads/`, short enough for a socket path.
func makeHubDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bt-\(UUID().uuidString.prefix(8))")
    let fm = FileManager.default
    for sub in ["", "assets", "downloads"] {
        try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    return dir
}
