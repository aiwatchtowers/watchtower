// Throwaway S0 spike harness, macOS side (the "owner", the Mac's Apple ID).
// Run the binary inside the signed bundle from a terminal:
//   build/mac/Build/Products/Debug/CKSpikeMac.app/Contents/MacOS/CKSpikeMac <command>
// See spikes/cloudkit-share/README.md for the full run book.

import AppKit
import CloudKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let log = SpikeLog.shared

let supportDir: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CKSpike", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()
log.fileURL = supportDir.appendingPathComponent("spike-mac.log")

let dataZoneID = Spike.zoneID(Spike.dataZone)
let relayZoneID = Spike.zoneID(Spike.relayZone)
let alertZoneID = Spike.zoneID(Spike.alertZone)

let usage = """
CKSpikeMac — S0 spike, owner side (the Mac's Apple ID)

  whoami                 (d) account status + userRecordID().recordName
  setup                  create DataZone/RelayZone/AlertZone, seed records, create both
                         zone-wide shares with the public link open, print the link + QR
  participants           list both shares' participants and the public permission
  open-link              publicPermission = readOnly (DataZone) / readWrite (RelayZone)
  close-link             (c) publicPermission = .none on both shares
  f2 <recordName>        (c) fallback F2, spec order: reopen the link, add <recordName> as a
                         named participant (LookupInfo(userRecordID:)), close the link
  write-data             (b) rewrite DataZone/\(Spike.pushProbeRecord) — triggers the shared-DB push
  fetch-relay [--reset]  (a) CKSyncEngine on .private: fetch RelayZone, download and verify assets
  alert <DataZone|AlertZone>  (e) create an ask_alert record (fires the query subscription)
  teardown               delete the three zones (and with them the shares)
"""

// MARK: - Commands

func whoami() async throws {
    let sw = Stopwatch()
    let status = try await container.accountStatus()
    let id = try await container.userRecordID()
    log.step("d", "accountStatus + userRecordID", ms: sw.ms)
    log.line("(d) container=\(Spike.containerID) accountStatus=\(status.rawValue) (\(status == .available ? "available" : "NOT available"))")
    log.line("(d) userRecordID.recordName=\(id.recordName)")
    log.line("(d) compare this value with the iPhone's (d) line: equal on the same Apple ID, different on another one")
}

func fetchOrCreateShare(zone: CKRecordZone.ID, title: String) async throws -> CKShare {
    do {
        if let share = try await db.record(for: Spike.shareID(zone: zone)) as? CKShare { return share }
    } catch let error as CKError where error.code == .unknownItem {
        // First run: no share yet.
    }
    let share = CKShare(recordZoneID: zone)
    share[CKShare.SystemFieldKey.title] = title
    return share
}

func saveShares(_ shares: [CKShare]) async throws -> [CKShare] {
    let result = try await db.modifyRecords(saving: shares, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
    var saved: [CKShare] = []
    for (_, outcome) in result.saveResults {
        switch outcome {
        case .success(let record): if let share = record as? CKShare { saved.append(share) }
        case .failure(let error): throw error
        }
    }
    return saved.sorted { $0.recordID.zoneID.zoneName < $1.recordID.zoneID.zoneName }
}

func loadShares() async throws -> (data: CKShare, relay: CKShare) {
    let data = try await db.record(for: Spike.shareID(zone: dataZoneID))
    let relay = try await db.record(for: Spike.shareID(zone: relayZoneID))
    guard let d = data as? CKShare, let r = relay as? CKShare else {
        throw NSError(domain: "spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "share records missing — run setup"])
    }
    return (d, r)
}

func describe(_ share: CKShare) -> String {
    let parts = share.participants.map { p -> String in
        let name = p.userIdentity.userRecordID?.recordName ?? "?"
        return "\(name) role=\(p.role.rawValue) status=\(p.acceptanceStatus.rawValue) permission=\(p.permission.rawValue)"
    }
    return "\(share.recordID.zoneID.zoneName): publicPermission=\(share.publicPermission.rawValue) url=\(share.url?.absoluteString ?? "-")\n    "
        + parts.joined(separator: "\n    ")
}

func setup() async throws {
    var sw = Stopwatch()
    let zones = [dataZoneID, relayZoneID, alertZoneID].map(CKRecordZone.init(zoneID:))
    _ = try await db.modifyRecordZones(saving: zones, deleting: [])
    log.step("setup", "save zones", ms: sw.ms, zones.map { $0.zoneID.zoneName }.joined(separator: ","))

    sw = Stopwatch()
    try await saveRecords([
        makeRecord(Spike.seedDataRecord, zone: dataZoneID, kind: "seed"),
        makeRecord(Spike.seedRelayRecord, zone: relayZoneID, kind: "seed"),
        makeRecord(Spike.pushProbeRecord, zone: dataZoneID, kind: "probe"),
    ], in: db)
    log.step("setup", "seed records", ms: sw.ms)

    sw = Stopwatch()
    let data = try await fetchOrCreateShare(zone: dataZoneID, title: "Watchtower spike DataZone")
    let relay = try await fetchOrCreateShare(zone: relayZoneID, title: "Watchtower spike RelayZone")
    data.publicPermission = .readOnly
    relay.publicPermission = .readWrite
    let saved = try await saveShares([data, relay])
    log.step("setup", "save zone-wide shares", ms: sw.ms)
    saved.forEach { log.line("  " + describe($0)) }

    guard let dataURL = saved.first(where: { $0.recordID.zoneID == dataZoneID })?.url,
          let relayURL = saved.first(where: { $0.recordID.zoneID == relayZoneID })?.url
    else { throw NSError(domain: "spike", code: 2, userInfo: [NSLocalizedDescriptionKey: "a share has no URL"]) }

    let owner = try await container.userRecordID().recordName
    let link = SpikeLink(ownerUser: owner, dataShare: dataURL, relayShare: relayURL)
    log.line("(setup) LINK \(link.url.absoluteString)")
    let png = supportDir.appendingPathComponent("link-qr.png")
    try writeQR(link.url.absoluteString, to: png)
    log.line("(setup) QR written to \(png.path) — opening it; scan it with the iPhone Camera")
    NSWorkspace.shared.open(png)
}

func writeQR(_ text: String, to url: URL) throws {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw NSError(domain: "spike", code: 3) }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
          let cg = CIContext().createCGImage(image, from: image.extent),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "spike", code: 4) }
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "spike", code: 5) }
}

func participants() async throws {
    let sw = Stopwatch()
    let shares = try await loadShares()
    log.step("c", "fetch shares", ms: sw.ms)
    log.line("  " + describe(shares.data))
    log.line("  " + describe(shares.relay))
}

func setLink(open: Bool, hint: Bool = true) async throws {
    let sw = Stopwatch()
    let shares = try await loadShares()
    shares.data.publicPermission = open ? .readOnly : .none
    shares.relay.publicPermission = open ? .readWrite : .none
    let saved = try await saveShares([shares.data, shares.relay])
    log.step("c", open ? "open public link" : "close public link (publicPermission = .none)", ms: sw.ms)
    saved.forEach { log.line("  " + describe($0)) }
    if !open && hint {
        log.line("(c) now press \"c: Check access\" on the second-Apple-ID iPhone")
    }
}

/// Fallback F2 in the spec §2.3 production order, as separate timed saves:
/// reopen the public link → add the named participant (LookupInfo(userRecordID:)) → close the link.
func f2(recordName: String) async throws {
    func pair(_ shares: [CKShare]) throws -> (data: CKShare, relay: CKShare) {
        guard let d = shares.first(where: { $0.recordID.zoneID == dataZoneID }),
              let r = shares.first(where: { $0.recordID.zoneID == relayZoneID })
        else { throw NSError(domain: "spike", code: 8, userInfo: [NSLocalizedDescriptionKey: "a share is missing after save"]) }
        return (d, r)
    }

    // 1. Reopen the public link, as the Mac does while a QR is on screen.
    var sw = Stopwatch()
    var shares = try await loadShares()
    shares.data.publicPermission = .readOnly
    shares.relay.publicPermission = .readWrite
    shares = try pair(try await saveShares([shares.data, shares.relay]))
    log.step("c-F2", "1/3 reopen the public link", ms: sw.ms)

    // 2. Add the phone as a named participant with each zone's permission.
    var participants: [(CKShare, CKShare.Participant)] = []
    for (share, permission) in [(shares.data, CKShare.ParticipantPermission.readOnly), (shares.relay, .readWrite)] {
        sw = Stopwatch()
        do {
            let participant = try await lookupParticipant(recordName: recordName)
            log.step("c-F2", "CKFetchShareParticipantsOperation(LookupInfo(userRecordID:)) for \(share.recordID.zoneID.zoneName)", ms: sw.ms)
            participant.permission = permission
            participants.append((share, participant))
        } catch {
            log.step("c-F2", "CKFetchShareParticipantsOperation for \(share.recordID.zoneID.zoneName)", ms: sw.ms,
                     "FAILED \(SpikeLog.describe(error))")
            log.result("c-F2", pass: false, "LookupInfo(userRecordID: \(recordName)) returned no participant (user not discoverable, or a wrong record name) — F2 fails; F3 needs the owner's written OK")
            try await setLink(open: false, hint: false)
            return
        }
    }
    do {
        sw = Stopwatch()
        participants.forEach { share, participant in share.addParticipant(participant) }
        shares = try pair(try await saveShares([shares.data, shares.relay]))
        log.step("c-F2", "2/3 save shares with the named participant (link still open)", ms: sw.ms)

        // 3. Close the link.
        sw = Stopwatch()
        shares.data.publicPermission = .none
        shares.relay.publicPermission = .none
        let saved = try await saveShares([shares.data, shares.relay])
        log.step("c-F2", "3/3 close the public link (publicPermission = .none)", ms: sw.ms)
        saved.forEach { log.line("  " + describe($0)) }
        log.line("(c-F2) now press \"c (F2): Re-accept + check\" on the second-Apple-ID iPhone")
    } catch {
        log.step("c-F2", "save", ms: sw.ms, "FAILED \(SpikeLog.describe(error))")
        log.result("c-F2", pass: false, "a share save failed after the link was reopened — closing the link again")
        // Never leave the bearer link open: refetch the shares and close it.
        try await setLink(open: false, hint: false)
        throw error
    }
}

func lookupParticipant(recordName: String) async throws -> CKShare.Participant {
    let info = CKUserIdentity.LookupInfo(userRecordID: CKRecord.ID(recordName: recordName))
    return try await withCheckedThrowingContinuation { cont in
        let op = CKFetchShareParticipantsOperation(userIdentityLookupInfos: [info])
        var found: Result<CKShare.Participant, Error>?
        op.perShareParticipantResultBlock = { _, result in found = result }
        op.fetchShareParticipantsResultBlock = { result in
            switch (result, found) {
            case (.failure(let error), _): cont.resume(throwing: error)
            case (.success, .some(let r)): cont.resume(with: r)
            case (.success, .none):
                cont.resume(throwing: NSError(domain: "spike", code: 6, userInfo: [NSLocalizedDescriptionKey: "no participant returned"]))
            }
        }
        container.add(op)
    }
}

func writeData() async throws {
    let sw = Stopwatch()
    let record = makeRecord(Spike.pushProbeRecord, zone: dataZoneID, kind: "probe")
    try await saveRecords([record], in: db)
    log.step("b", "write DataZone/\(Spike.pushProbeRecord)", ms: sw.ms, "writtenAt=\(record["writtenAt"] as? Int64 ?? 0)")
    log.line("(b) the iPhone logs the push and its latency against this writtenAt")
}

func fetchRelay(reset: Bool) async throws {
    let stateURL = supportDir.appendingPathComponent("engine-private.json")
    if reset { try? FileManager.default.removeItem(at: stateURL) }
    let state = (try? Data(contentsOf: stateURL)).flatMap {
        try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
    }
    let delegate = SpikeSyncDelegate(item: "a")
    delegate.onState = { serialization in
        if let data = try? JSONEncoder().encode(serialization) { try? data.write(to: stateURL) }
    }
    var verified: [(String, Bool, String)] = []
    delegate.onFetchedRecord = { record in
        guard record.recordID.zoneID.zoneName == Spike.relayZone,
              let asset = record["asset"] as? CKAsset, let file = asset.fileURL else { return }
        let sw = Stopwatch()
        do {
            let (size, digest) = try hashFile(file)
            let expected = record["sha256"] as? String ?? ""
            let ok = digest == expected && size >= 60_000_000
            let upload = latencyMillis(writtenAt: record, until: Date()).map { "\($0) ms since the phone's writtenAt" } ?? "-"
            verified.append((record.recordID.recordName, ok,
                             "size=\(size) sha256 \(ok ? "matches" : "MISMATCH (expected \(expected))") hash=\(sw.ms) ms, \(upload)"))
        } catch {
            verified.append((record.recordID.recordName, false, "read failed: \(error)"))
        }
    }
    let config = CKSyncEngine.Configuration(database: db, stateSerialization: state, delegate: delegate)
    let engine = CKSyncEngine(config)
    let sw = Stopwatch()
    try await engine.fetchChanges()
    log.step("a", "owner CKSyncEngine(.private).fetchChanges (assets downloaded)", ms: sw.ms,
             "zones=\(delegate.fetchedZones.sorted()) relayRecords=\(delegate.fetchedByZone[Spike.relayZone]?.count ?? 0)")
    if verified.isEmpty {
        log.line("(a) no new RelayZone asset records. Re-run with --reset to refetch everything, or run \"a\" on the iPhone first.")
    }
    for (name, ok, detail) in verified {
        log.result("a", pass: ok, "owner downloaded \(name): \(detail)")
    }
}

func alert(zoneName: String) async throws {
    guard zoneName == Spike.dataZone || zoneName == Spike.alertZone else {
        throw NSError(domain: "spike", code: 7, userInfo: [NSLocalizedDescriptionKey: "zone must be DataZone or AlertZone"])
    }
    let sw = Stopwatch()
    let record = makeRecord("ask_alert-\(UUID().uuidString)", zone: Spike.zoneID(zoneName), kind: "ask_alert")
    try await saveRecords([record], in: db)
    log.step("e", "create ask_alert in \(zoneName)", ms: sw.ms, "writtenAt=\(record["writtenAt"] as? Int64 ?? 0)")
}

func teardown() async throws {
    let sw = Stopwatch()
    _ = try await db.modifyRecordZones(saving: [], deleting: [dataZoneID, relayZoneID, alertZoneID])
    try? FileManager.default.removeItem(at: supportDir.appendingPathComponent("engine-private.json"))
    log.step("teardown", "delete zones", ms: sw.ms)
}

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(2)
}
// Created only after argument parsing: CKContainer traps in an unsigned build.
let container = Spike.container
let db = container.privateCloudDatabase
log.line("CKSpikeMac \(args.joined(separator: " "))")
do {
    switch command {
    case "whoami": try await whoami()
    case "setup": try await setup()
    case "participants": try await participants()
    case "open-link": try await setLink(open: true)
    case "close-link": try await setLink(open: false)
    case "f2":
        guard args.count == 2 else { print(usage); exit(2) }
        try await f2(recordName: args[1])
    case "write-data": try await writeData()
    case "fetch-relay": try await fetchRelay(reset: args.contains("--reset"))
    case "alert":
        guard args.count == 2 else { print(usage); exit(2) }
        try await alert(zoneName: args[1])
    case "teardown": try await teardown()
    default:
        print(usage)
        exit(2)
    }
} catch {
    log.line("ERROR \(command): \(SpikeLog.describe(error))")
    exit(1)
}
