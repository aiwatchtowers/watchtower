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

    /// Pushes count for (b) only if the Mac write they report happened after this moment.
    private static let bSubscribedAtKey = "b.subscribedAt"
    /// A (b) push must arrive within this long after the Mac's write.
    private static let maxPushLatencyMillis: Int64 = 300_000

    func itemBRegister() async {
        let sw = Stopwatch()
        do {
            let subscription = CKDatabaseSubscription(subscriptionID: Spike.sharedDBSubscriptionID)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            _ = try await container.sharedCloudDatabase.save(subscription)
            UserDefaults.standard.set(epochMillis(), forKey: Self.bSubscribedAtKey)
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

        var writtenAt: Int64?
        var fetchError = ""
        if let zone = sharedZone(Spike.dataZone) {
            do {
                let record = try await container.sharedCloudDatabase.record(for: CKRecord.ID(recordName: Spike.pushProbeRecord, zoneID: zone))
                writtenAt = record["writtenAt"] as? Int64
            } catch {
                fetchError = SpikeLog.describe(error)
                log.error("b", "fetch \(Spike.pushProbeRecord)", error)
            }
        }
        let latency = writtenAt.map { epochMillis(receivedAt) - $0 }
        let latencyText = latency.map { "\($0) ms" } ?? "unknown"
        guard state == .background else {
            log.line("(b) push arrived with the app \(stateName) (latency=\(latencyText)) — not a (b) pass; background the app and retry")
            return
        }
        let subscribedAt = UserDefaults.standard.object(forKey: Self.bSubscribedAtKey) as? Int64
        let reason: String?
        if subscribedAt == nil {
            reason = "no subscription time saved — press \"b: Register\" first"
        } else if writtenAt == nil {
            reason = "could not read \(Spike.pushProbeRecord).writtenAt \(fetchError)"
        } else if let written = writtenAt, let subscribed = subscribedAt, written <= subscribed {
            reason = "\(Spike.pushProbeRecord) was written before the subscription — not caused by `write-data`"
        } else if let latency, latency > Self.maxPushLatencyMillis {
            reason = "latency \(latency) ms is over \(Self.maxPushLatencyMillis) ms — not attributable to the last `write-data`"
        } else {
            reason = nil
        }
        if let reason {
            log.result("b", pass: false, "background push arrived but is not attributable to write-data: \(reason)")
        } else {
            log.result("b", pass: true, "silent shared-DB push arrived in the background; Mac write → push latency=\(latencyText)")
        }
        await postLocal(title: "S0 (b) push received", body: reason == nil ? "PASS, latency \(latencyText)" : "Not attributable — open the log")
    }

    // MARK: (c) Access after publicPermission = .none, and F2

    func itemC(item: String) async {
        guard let dataZone = sharedZone(Spike.dataZone), let relayZone = sharedZone(Spike.relayZone) else {
            log.line("(\(item)) no link — scan the Mac's QR first"); return
        }
        let db = container.sharedCloudDatabase

        // Precondition: the Mac really closed the public link on both shares.
        var linkClosed = true
        for zone in [dataZone, relayZone] {
            let sw = Stopwatch()
            do {
                guard let share = try await db.record(for: Spike.shareID(zone: zone)) as? CKShare else {
                    log.line("(\(item)) \(zone.zoneName): the share record is not a CKShare")
                    linkClosed = false
                    continue
                }
                let me = share.currentUserParticipant
                log.step(item, "fetch \(zone.zoneName) share", ms: sw.ms,
                         "publicPermission=\(share.publicPermission.rawValue) me: role=\(me?.role.rawValue ?? -1) "
                         + "permission=\(me?.permission.rawValue ?? -1) status=\(me?.acceptanceStatus.rawValue ?? -1)")
                if share.publicPermission != .none { linkClosed = false }
            } catch {
                log.step(item, "fetch \(zone.zoneName) share", ms: sw.ms, "FAILED \(SpikeLog.describe(error))")
                linkClosed = false
            }
        }
        if !linkClosed {
            log.result(item, pass: false, "the public link is not closed (publicPermission != .none) or a share could not be read — close the link on the Mac first (`close-link`) and press again")
            return
        }

        func attempt(_ name: String, _ body: () async throws -> Void) async -> Error? {
            let sw = Stopwatch()
            do {
                try await body()
                log.step(item, name, ms: sw.ms, "OK")
                return nil
            } catch {
                log.step(item, name, ms: sw.ms, "FAILED \(SpikeLog.describe(error))")
                return error
            }
        }
        let readData = await attempt("read DataZone/\(Spike.seedDataRecord)") {
            _ = try await db.record(for: CKRecord.ID(recordName: Spike.seedDataRecord, zoneID: dataZone))
        } == nil
        let readRelay = await attempt("read RelayZone/\(Spike.seedRelayRecord)") {
            _ = try await db.record(for: CKRecord.ID(recordName: Spike.seedRelayRecord, zoneID: relayZone))
        } == nil
        let writeRelay = await attempt("write RelayZone record") {
            try await saveRecords([makeRecord("relay-check-\(UUID().uuidString)", zone: relayZone, kind: "probe")], in: db)
        } == nil
        let dataWriteError = await attempt("write DataZone record (expected to FAIL with permissionFailure: read-only share)") {
            try await saveRecords([makeRecord("data-check-\(UUID().uuidString)", zone: dataZone, kind: "probe")], in: db)
        }
        let writeDataRefused = dataWriteError.map(isPermissionFailure) ?? false
        if dataWriteError == nil {
            log.line("(\(item)) WARNING: DataZone accepted a participant write — the read-only permission did not hold")
        } else if !writeDataRefused {
            log.line("(\(item)) DataZone write failed with something other than permissionFailure — not proof of read-only")
        }
        let pass = readData && readRelay && writeRelay && writeDataRefused
        log.result(item, pass: pass, "readDataZone=\(readData) readRelayZone=\(readRelay) writeRelayZone=\(writeRelay) writeDataZoneRefusedByPermission=\(writeDataRefused)")
        if !pass && item == "c" {
            let me = (try? await container.userRecordID().recordName) ?? "<run d first>"
            log.line("(c) F2 next: on the Mac run `f2 \(me)`, then press \"c (F2): Re-accept + check\" here")
        }
    }

    private func isPermissionFailure(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        if ck.code == .permissionFailure { return true }
        if ck.code == .partialFailure, let partial = ck.partialErrorsByItemID, !partial.isEmpty {
            return partial.values.allSatisfy { ($0 as? CKError)?.code == .permissionFailure }
        }
        return false
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

    // MARK: (e) Visible alert in a private custom zone

    /// Alerts count for (e) only if their trigger record was written after this moment.
    private static let eSubscribedAtKey = "e.subscribedAt"
    /// Clock-skew allowance when matching a zone notification to the record that caused it.
    private static let skewMillis: Int64 = 5_000

    /// The spec's production alert settings (§7), shared by both paths.
    private func alertInfo() -> CKSubscription.NotificationInfo {
        let info = CKSubscription.NotificationInfo()
        info.alertLocalizationKey = "ASK_ALERT_GENERIC"
        info.soundName = "default"
        info.shouldSendMutableContent = true
        info.category = "ASK"
        return info
    }

    func itemESubscribe() async {
        await requestNotificationPermission()
        UIApplication.shared.registerForRemoteNotifications()
        if let owner = link?.ownerUser, let me = try? await container.userRecordID().recordName, me != owner {
            log.line("(e) WARNING: this iPhone is not on the Mac's Apple ID; (e) needs the same Apple ID (private database)")
        }
        // Primary path: CKQuerySubscription in DataZone.
        var sw = Stopwatch()
        do {
            let query = CKQuerySubscription(
                recordType: Spike.recordType,
                predicate: NSPredicate(format: "kind == %@", "ask_alert"),
                subscriptionID: Spike.alertSubscriptionID(zone: Spike.dataZone),
                options: [.firesOnRecordCreation])
            query.zoneID = Spike.zoneID(Spike.dataZone)
            query.notificationInfo = alertInfo()
            _ = try await container.privateCloudDatabase.save(query)
            log.step("e", "save CKQuerySubscription (private, DataZone)", ms: sw.ms, query.subscriptionID)
        } catch {
            log.error("e", "save query subscription in DataZone", error)
        }
        // Fallback path: CKRecordZoneSubscription on AlertZone.
        sw = Stopwatch()
        do {
            let zoneSub = CKRecordZoneSubscription(zoneID: Spike.zoneID(Spike.alertZone),
                                                   subscriptionID: Spike.alertSubscriptionID(zone: Spike.alertZone))
            zoneSub.notificationInfo = alertInfo()
            _ = try await container.privateCloudDatabase.save(zoneSub)
            log.step("e", "save CKRecordZoneSubscription (private, AlertZone)", ms: sw.ms, zoneSub.subscriptionID)
        } catch {
            log.error("e", "save record zone subscription on AlertZone", error)
        }
        UserDefaults.standard.set(epochMillis(), forKey: Self.eSubscribedAtKey)
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
                       "\(zone): \(seen.contains(zone) ? "visible alert delivered after the subscribe, latency known (lines above)" : "no attributable alert in Notification Center (none, stale, or latency unknown)")")
        }
    }

    /// Logs one CloudKit alert and its Mac write → delivery latency. Returns its zone only when the
    /// trigger record was written after the subscribe time and the latency is known.
    @discardableResult
    func reportAlert(_ notification: UNNotification, path: String) async -> String? {
        guard let note = CKNotification(fromRemoteNotificationDictionary: notification.request.content.userInfo) else { return nil }
        let subscribedAt = UserDefaults.standard.object(forKey: Self.eSubscribedAtKey) as? Int64 ?? Int64.max
        let deliveredAt = epochMillis(notification.date)
        var zone: String?
        var trigger: CKRecord?
        do {
            if let query = note as? CKQueryNotification, let recordID = query.recordID {
                zone = recordID.zoneID.zoneName
                trigger = try await container.privateCloudDatabase.record(for: recordID)
            } else if let zoneNote = note as? CKRecordZoneNotification, let zoneID = zoneNote.recordZoneID {
                zone = zoneID.zoneName
                trigger = try await newestAlertRecord(in: zoneID, notAfter: deliveredAt + Self.skewMillis)
            } else {
                return nil
            }
        } catch {
            log.error("e", "fetch the trigger record (\(zone ?? "?"))", error)
        }
        guard let zone else { return nil }
        let written = trigger?["writtenAt"] as? Int64
        let latencyText = written.map { "\(deliveredAt - $0) ms" } ?? "unknown"
        let fresh = written.map { $0 > subscribedAt } ?? false
        log.line("(e) alert \(path): zone=\(zone) subscription=\(note.subscriptionID ?? "-") record=\(trigger?.recordID.recordName ?? "-") "
            + "Mac write → delivery latency=\(latencyText)\(fresh ? "" : " — NOT counted (written before the subscribe, or unknown)")")
        return fresh ? zone : nil
    }

    /// A record-zone notification names no record: take the newest ask_alert written up to `notAfter`.
    private func newestAlertRecord(in zoneID: CKRecordZone.ID, notAfter: Int64) async throws -> CKRecord? {
        let changes = try await container.privateCloudDatabase.recordZoneChanges(inZoneWith: zoneID, since: nil)
        let records = changes.modificationResultsByID.values.compactMap { try? $0.get().record }
        return records
            .filter { ($0["kind"] as? String) == "ask_alert" && (($0["writtenAt"] as? Int64) ?? .max) <= notAfter }
            .max { (($0["writtenAt"] as? Int64) ?? 0) < (($1["writtenAt"] as? Int64) ?? 0) }
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
