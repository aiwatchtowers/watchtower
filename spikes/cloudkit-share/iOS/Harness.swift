// Throwaway S0 spike harness, iOS side. Each item (a)–(e) is one button that logs
// timed steps and a final "RESULT (x): PASS|FAIL" line.

import CloudKit
import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class Harness: ObservableObject {
    static let shared = Harness()

    @Published var lines: [String] = []
    @Published var link: SpikeLink?
    @Published var busy = false

    let container = Spike.container
    private let log = SpikeLog.shared
    /// Kept alive so CKSyncEngine is not torn down mid-operation.
    private var engine: CKSyncEngine?

    let logURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ckspike.log")

    private init() {
        log.fileURL = logURL
        if let text = try? String(contentsOf: logURL, encoding: .utf8) {
            lines = text.split(separator: "\n").suffix(500).map(String.init)
        }
        log.sink = { line in
            Task { @MainActor in Harness.shared.lines.append(line) }
        }
        if let data = UserDefaults.standard.data(forKey: "link"),
           let saved = try? JSONDecoder().decode(SpikeLink.self, from: data) {
            link = saved
        }
    }

    // MARK: Link

    func open(_ url: URL) {
        guard let parsed = SpikeLink(url: url) else {
            log.line("link: not a spike link: \(url.absoluteString)")
            return
        }
        link = parsed
        if let data = try? JSONEncoder().encode(parsed) { UserDefaults.standard.set(data, forKey: "link") }
        log.line("link: saved owner_user=\(parsed.ownerUser)")
        log.line("link: data_share=\(parsed.dataShare.absoluteString)")
        log.line("link: relay_share=\(parsed.relayShare.absoluteString)")
    }

    func pasteLink() {
        let pasted = UIPasteboard.general.url ?? UIPasteboard.general.string.flatMap(URL.init(string:))
        if let pasted { open(pasted) } else { log.line("link: the clipboard holds no URL") }
    }

    private var ownerZoneOwner: String? { link?.ownerUser }
    private func sharedZone(_ name: String) -> CKRecordZone.ID? {
        ownerZoneOwner.map { Spike.zoneID(name, owner: $0) }
    }

    func run(_ body: @escaping () async -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            await body()
            busy = false
        }
    }

    // MARK: Accept (used by a, c, c-F2)

    @discardableResult
    func acceptShares(item: String) async -> Bool {
        guard let link else { log.line("(\(item)) no link — scan the Mac's QR first"); return false }
        do {
            var sw = Stopwatch()
            let metadatas = try await fetchMetadata([link.dataShare, link.relayShare])
            log.step(item, "CKFetchShareMetadataOperation (2 URLs)", ms: sw.ms)
            for m in metadatas {
                log.line("(\(item))   \(m.share.recordID.zoneID.zoneName)@\(m.share.recordID.zoneID.ownerName) "
                    + "participantStatus=\(m.participantStatus.rawValue) permission=\(m.participantPermission.rawValue) role=\(m.participantRole.rawValue)")
            }
            sw = Stopwatch()
            let accepted = try await accept(metadatas)
            log.step(item, "CKAcceptSharesOperation", ms: sw.ms, accepted.map { $0.recordID.zoneID.zoneName }.joined(separator: ","))
            return accepted.count == 2
        } catch {
            log.error(item, "accept", error)
            return false
        }
    }

    private func fetchMetadata(_ urls: [URL]) async throws -> [CKShare.Metadata] {
        try await withCheckedThrowingContinuation { cont in
            var found: [CKShare.Metadata] = []
            var firstError: Error?
            let op = CKFetchShareMetadataOperation(shareURLs: urls)
            op.shouldFetchRootRecord = false
            op.perShareMetadataResultBlock = { url, result in
                switch result {
                case .success(let m): found.append(m)
                case .failure(let e): firstError = firstError ?? e
                    SpikeLog.shared.line("  metadata failed for \(url.absoluteString): \(SpikeLog.describe(e))")
                }
            }
            op.fetchShareMetadataResultBlock = { result in
                if case .failure(let e) = result { cont.resume(throwing: e); return }
                if let firstError { cont.resume(throwing: firstError); return }
                cont.resume(returning: found)
            }
            container.add(op)
        }
    }

    private func accept(_ metadatas: [CKShare.Metadata]) async throws -> [CKShare] {
        try await withCheckedThrowingContinuation { cont in
            var accepted: [CKShare] = []
            var firstError: Error?
            let op = CKAcceptSharesOperation(shareMetadatas: metadatas)
            op.perShareResultBlock = { _, result in
                switch result {
                case .success(let share): accepted.append(share)
                case .failure(let e): firstError = firstError ?? e
                }
            }
            op.acceptSharesResultBlock = { result in
                if case .failure(let e) = result { cont.resume(throwing: e); return }
                if let firstError { cont.resume(throwing: firstError); return }
                cont.resume(returning: accepted)
            }
            container.add(op)
        }
    }

    // MARK: (a) CKSyncEngine on .shared, 60+ MB asset

    func itemA() async {
        guard let relayZone = sharedZone(Spike.relayZone) else {
            log.line("(a) no link — scan the Mac's QR first"); return
        }
        let total = Stopwatch()
        let delegate = SpikeSyncDelegate(item: "a")
        let engine = CKSyncEngine(CKSyncEngine.Configuration(
            database: container.sharedCloudDatabase, stateSerialization: nil, delegate: delegate))
        self.engine = engine
        do {
            var sw = Stopwatch()
            try await engine.fetchChanges()
            let dataCount = delegate.fetchedByZone[Spike.dataZone]?.count ?? 0
            let relayCount = delegate.fetchedByZone[Spike.relayZone]?.count ?? 0
            log.step("a", "CKSyncEngine(.shared).fetchChanges", ms: sw.ms, "DataZone=\(dataCount) RelayZone=\(relayCount) records")
            let fetchedBoth = dataCount > 0 && relayCount > 0

            sw = Stopwatch()
            let message = makeRecord("relay-msg-\(UUID().uuidString)", zone: relayZone, kind: "probe")
            let messageSent = try await send(message, via: engine, delegate: delegate)
            log.step("a", "send small RelayZone record", ms: sw.ms, messageSent ? "saved" : "NOT saved")

            sw = Stopwatch()
            let (file, digest) = try makeRandomFile(bytes: Spike.assetBytes)
            log.step("a", "generate \(Spike.assetBytes) byte file", ms: sw.ms, "sha256=\(digest)")
            let assetRecord = makeRecord("relay-asset-\(UUID().uuidString)", zone: relayZone, kind: "relay_asset")
            assetRecord["asset"] = CKAsset(fileURL: file)
            assetRecord["sha256"] = digest
            assetRecord["sizeBytes"] = Int64(Spike.assetBytes)
            sw = Stopwatch()
            let assetSent = try await send(assetRecord, via: engine, delegate: delegate)
            log.step("a", "upload CKAsset record via sendChanges", ms: sw.ms, assetSent ? "saved \(assetRecord.recordID.recordName)" : "NOT saved")
            try? FileManager.default.removeItem(at: file)

            let pass = fetchedBoth && messageSent && assetSent
            log.result("a", pass: pass,
                       "participant side: fetchedBothZones=\(fetchedBoth) relayRecordSent=\(messageSent) assetSent=\(assetSent) total=\(total.ms) ms. "
                       + "Now run `fetch-relay` on the Mac for the owner download half.")
        } catch {
            log.error("a", "sync engine", error)
            log.result("a", pass: false, "participant side threw after \(total.ms) ms")
        }
    }

    private func send(_ record: CKRecord, via engine: CKSyncEngine, delegate: SpikeSyncDelegate) async throws -> Bool {
        delegate.stage(record)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        try await engine.sendChanges()
        return delegate.savedIDs.contains(record.recordID)
    }

    // MARK: (b) Silent CKDatabaseSubscription on the shared database

    func itemBRegister() async {
        let sw = Stopwatch()
        do {
            let subscription = CKDatabaseSubscription(subscriptionID: Spike.sharedDBSubscriptionID)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            _ = try await container.sharedCloudDatabase.save(subscription)
            await requestNotificationPermission()
            UIApplication.shared.registerForRemoteNotifications()
            log.step("b", "save silent CKDatabaseSubscription on .shared", ms: sw.ms, Spike.sharedDBSubscriptionID)
            log.line("(b) now lock the iPhone or switch to another app (do NOT force-quit), then run `write-data` on the Mac")
        } catch {
            log.error("b", "save subscription", error)
        }
    }

    /// Called by the app delegate for every remote notification with content-available.
    func handlePush(_ userInfo: [AnyHashable: Any], state: UIApplication.State, receivedAt: Date) async {
        let stateName = state == .background ? "background" : (state == .inactive ? "inactive" : "active")
        guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            log.line("push: not a CloudKit notification (state=\(stateName))")
            return
        }
        log.line("push: received subscriptionID=\(note.subscriptionID ?? "-") type=\(note.notificationType.rawValue) state=\(stateName)")
        guard note.subscriptionID == Spike.sharedDBSubscriptionID else { return }
        var latency = "unknown"
        if let zone = sharedZone(Spike.dataZone) {
            do {
                let record = try await container.sharedCloudDatabase.record(for: CKRecord.ID(recordName: Spike.pushProbeRecord, zoneID: zone))
                if let ms = latencyMillis(writtenAt: record, until: receivedAt) { latency = "\(ms) ms" }
            } catch {
                log.error("b", "fetch \(Spike.pushProbeRecord)", error)
            }
        }
        if state == .background {
            log.result("b", pass: true, "silent shared-DB push arrived in the background; Mac write → push latency=\(latency)")
            await postLocal(title: "S0 (b) push received", body: "Background, latency \(latency)")
        } else {
            log.line("(b) push arrived with the app \(stateName) (latency=\(latency)) — not a (b) pass; background the app and retry")
        }
    }

    // MARK: (c) Access after publicPermission = .none, and F2

    func itemC(item: String) async {
        guard let dataZone = sharedZone(Spike.dataZone), let relayZone = sharedZone(Spike.relayZone) else {
            log.line("(\(item)) no link — scan the Mac's QR first"); return
        }
        let db = container.sharedCloudDatabase
        func attempt(_ name: String, _ body: () async throws -> Void) async -> Bool {
            let sw = Stopwatch()
            do {
                try await body()
                log.step(item, name, ms: sw.ms, "OK")
                return true
            } catch {
                log.step(item, name, ms: sw.ms, "FAILED \(SpikeLog.describe(error))")
                return false
            }
        }
        let readData = await attempt("read DataZone/\(Spike.seedDataRecord)") {
            _ = try await db.record(for: CKRecord.ID(recordName: Spike.seedDataRecord, zoneID: dataZone))
        }
        let readRelay = await attempt("read RelayZone/\(Spike.seedRelayRecord)") {
            _ = try await db.record(for: CKRecord.ID(recordName: Spike.seedRelayRecord, zoneID: relayZone))
        }
        let writeRelay = await attempt("write RelayZone record") {
            try await saveRecords([makeRecord("relay-check-\(UUID().uuidString)", zone: relayZone, kind: "probe")], in: db)
        }
        let writeData = await attempt("write DataZone record (expected to FAIL: read-only share)") {
            try await saveRecords([makeRecord("data-check-\(UUID().uuidString)", zone: dataZone, kind: "probe")], in: db)
        }
        if writeData { log.line("(\(item)) WARNING: DataZone accepted a participant write — the read-only permission did not hold") }
        let pass = readData && readRelay && writeRelay && !writeData
        log.result(item, pass: pass, "readDataZone=\(readData) readRelayZone=\(readRelay) writeRelayZone=\(writeRelay) writeDataZoneRefused=\(!writeData)")
        if !pass && item == "c" {
            let me = (try? await container.userRecordID().recordName) ?? "<run d first>"
            log.line("(c) F2 next: on the Mac run `f2 \(me)`, then press \"c (F2): Re-accept + check\" here")
        }
    }

    func itemCF2() async {
        let accepted = await acceptShares(item: "c-F2")
        log.line("(c-F2) re-accept from the saved URLs: \(accepted ? "accepted both" : "FAILED")")
        await itemC(item: "c-F2")
    }

    // MARK: (d) userRecordID across platforms / Apple IDs

    func itemD(sameAppleIDAsMac: Bool) async {
        let sw = Stopwatch()
        do {
            let status = try await container.accountStatus()
            let me = try await container.userRecordID().recordName
            log.step("d", "accountStatus + userRecordID", ms: sw.ms, "status=\(status.rawValue)")
            log.line("(d) this iPhone userRecordID.recordName=\(me)")
            guard let owner = link?.ownerUser else {
                log.line("(d) no link — scan the Mac's QR (it carries the Mac's recordName) and press again")
                return
            }
            let equal = me == owner
            log.line("(d) Mac owner_user=\(owner) → \(equal ? "EQUAL" : "DIFFERENT")")
            log.result("d", pass: equal == sameAppleIDAsMac,
                       "\(sameAppleIDAsMac ? "same" : "different") Apple ID expected, values are \(equal ? "equal" : "different")")
        } catch {
            log.error("d", "userRecordID", error)
            log.result("d", pass: false, "threw after \(sw.ms) ms")
        }
    }

    // MARK: (e) Visible alert from a CKQuerySubscription in a private custom zone

    func itemESubscribe() async {
        await requestNotificationPermission()
        UIApplication.shared.registerForRemoteNotifications()
        if let owner = link?.ownerUser, let me = try? await container.userRecordID().recordName, me != owner {
            log.line("(e) WARNING: this iPhone is not on the Mac's Apple ID; (e) needs the same Apple ID (private database)")
        }
        for zone in [Spike.dataZone, Spike.alertZone] {
            let sw = Stopwatch()
            do {
                let subscription = CKQuerySubscription(
                    recordType: Spike.recordType,
                    predicate: NSPredicate(format: "kind == %@", "ask_alert"),
                    subscriptionID: Spike.alertSubscriptionID(zone: zone),
                    options: [.firesOnRecordCreation])
                subscription.zoneID = Spike.zoneID(zone)
                let info = CKSubscription.NotificationInfo()
                info.title = "S0 (e) alert"
                info.alertBody = "Query subscription in \(zone)"
                info.soundName = "default"
                subscription.notificationInfo = info
                _ = try await container.privateCloudDatabase.save(subscription)
                log.step("e", "save CKQuerySubscription (private, \(zone))", ms: sw.ms, subscription.subscriptionID)
            } catch {
                log.error("e", "save query subscription in \(zone)", error)
            }
        }
        log.line("(e) now lock the iPhone and run `alert DataZone` and `alert AlertZone` on the Mac")
    }

    func itemEReadDelivered() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        var seen: Set<String> = []
        for notification in delivered {
            if let zone = await reportAlert(notification, path: "delivered") { seen.insert(zone) }
        }
        for zone in [Spike.dataZone, Spike.alertZone] {
            log.result("e", pass: seen.contains(zone),
                       "\(zone): \(seen.contains(zone) ? "visible alert delivered (latencies above)" : "no delivered alert found in Notification Center")")
        }
    }

    /// Logs one CloudKit query-subscription alert and its Mac write → delivery latency; returns its zone.
    @discardableResult
    func reportAlert(_ notification: UNNotification, path: String) async -> String? {
        guard let note = CKNotification(fromRemoteNotificationDictionary: notification.request.content.userInfo) as? CKQueryNotification,
              let recordID = note.recordID
        else { return nil }
        let zone = recordID.zoneID.zoneName
        var latency = "unknown"
        do {
            let record = try await container.privateCloudDatabase.record(for: recordID)
            if let ms = latencyMillis(writtenAt: record, until: notification.date) { latency = "\(ms) ms" }
        } catch {
            log.error("e", "fetch \(recordID.recordName)", error)
        }
        log.line("(e) alert \(path): zone=\(zone) subscription=\(note.subscriptionID ?? "-") record=\(recordID.recordName) Mac write → delivery latency=\(latency)")
        return zone
    }

    // MARK: Helpers

    func requestNotificationPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            log.line("notifications: authorization granted=\(granted)")
        } catch {
            log.line("notifications: authorization failed: \(error)")
        }
    }

    private func postLocal(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func clearLog() {
        try? FileManager.default.removeItem(at: logURL)
        lines = []
    }
}
