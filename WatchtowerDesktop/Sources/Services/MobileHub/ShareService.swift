import CloudKit
import Foundation
import WatchtowerSync

/// One non-owner participant of a hub zone share.
struct ShareParticipant: Equatable, Sendable {
    /// The participant's iCloud user record name; nil for an invitation
    /// CloudKit has not resolved to a user.
    let userRecordName: String?
    let accepted: Bool
}

/// The `CKShare.url` strings of the two zone shares (the QR's
/// `data_share` / `relay_share`, spec §2.3).
struct ShareURLs: Equatable, Sendable {
    let data: String
    let relay: String
}

/// The hub's zone-wide shares of DataZone and RelayZone (mobile POC spec
/// §2.3): the seam between `MobileLinkCenter` and CloudKit. Tests use a fake.
protocol ShareService: Sendable {
    /// `CKContainer.accountStatus()`, as the transport reports it.
    func accountStatus() async -> CloudAvailability
    /// Creates whichever of the two shares does not exist yet (public link
    /// closed) and returns both URLs. An existing share is reused.
    func ensureShares() async throws -> ShareURLs
    /// Opens the public link (DataZone `.readOnly`, RelayZone `.readWrite`)
    /// or closes it (`.none`) on both shares. A missing share is skipped.
    func setPublicLink(open: Bool) async throws
    /// The share's non-owner participants; empty when there is no share.
    func participants(in zone: CloudZoneID) async throws -> [ShareParticipant]
    /// Removes every non-owner participant `shouldRemove` picks.
    func removeParticipants(in zone: CloudZoneID, where shouldRemove: @escaping @Sendable (ShareParticipant) -> Bool) async throws
    /// Deletes both shares, which drops every participant (take over).
    func deleteShares() async throws
}

/// The CloudKit implementation over the Mac user's private database.
/// Without the iCloud entitlement (an unsigned dev build) it never touches
/// `CKContainer`, which would crash: the account reads `.unavailable` and
/// every other call throws `ShareServiceError.noEntitlement`. The CloudKit
/// calls themselves are not unit-tested: they need a signed build and a real
/// account (the A14 device smoke).
struct CloudKitShareService: ShareService {
    let containerID: String
    private let entitlementPresent: @Sendable () -> Bool

    init(
        containerID: String = WatchtowerCloud.containerID,
        entitlementPresent: (@Sendable () -> Bool)? = nil
    ) {
        self.containerID = containerID
        self.entitlementPresent = entitlementPresent ?? { CloudKitTransport.entitlementPresent(containerID: containerID) }
    }

    private func requireEntitlement() throws {
        guard entitlementPresent() else { throw ShareServiceError.noEntitlement }
    }

    private var database: CKDatabase { CKContainer(identifier: containerID).privateCloudDatabase }

    private static func shareID(_ zone: CloudZoneID) -> CKRecord.ID {
        CKRecord.ID(
            recordName: CKRecordNameZoneWideShare,
            zoneID: CKRecordZone.ID(zoneName: zone.rawValue, ownerName: CKCurrentUserDefaultName)
        )
    }

    private static func publicPermission(for zone: CloudZoneID) -> CKShare.ParticipantPermission {
        zone == .data ? .readOnly : .readWrite
    }

    func accountStatus() async -> CloudAvailability {
        guard entitlementPresent() else { return .unavailable("missing iCloud entitlement (unsigned dev build?)") }
        do {
            switch try await CKContainer(identifier: containerID).accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .couldNotDetermine: return .unavailable("iCloud account status could not be determined")
            case .temporarilyUnavailable: return .unavailable("iCloud account temporarily unavailable")
            @unknown default: return .unavailable("unknown iCloud account status")
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    func ensureShares() async throws -> ShareURLs {
        try requireEntitlement()
        var urls: [CloudZoneID: String] = [:]
        for zone in [CloudZoneID.data, .relay] {
            let share: CKShare
            if let existing = try await fetchShare(zone) {
                share = existing
            } else {
                let created = CKShare(recordZoneID: Self.shareID(zone).zoneID)
                created[CKShare.SystemFieldKey.title] = "Watchtower"
                created.publicPermission = .none
                share = try await save(created)
            }
            guard let url = share.url?.absoluteString else { throw ShareServiceError.noURL(zone) }
            urls[zone] = url
        }
        return ShareURLs(data: urls[.data] ?? "", relay: urls[.relay] ?? "")
    }

    func setPublicLink(open: Bool) async throws {
        try requireEntitlement()
        for zone in [CloudZoneID.data, .relay] {
            guard let share = try await fetchShare(zone) else { continue }
            share.publicPermission = open ? Self.publicPermission(for: zone) : .none
            _ = try await save(share)
        }
    }

    func participants(in zone: CloudZoneID) async throws -> [ShareParticipant] {
        try requireEntitlement()
        guard let share = try await fetchShare(zone) else { return [] }
        return share.participants.filter { $0.role != .owner }.map(Self.participant)
    }

    func removeParticipants(in zone: CloudZoneID, where shouldRemove: @escaping @Sendable (ShareParticipant) -> Bool) async throws {
        try requireEntitlement()
        guard let share = try await fetchShare(zone) else { return }
        let leaving = share.participants.filter { $0.role != .owner && shouldRemove(Self.participant($0)) }
        guard !leaving.isEmpty else { return }
        leaving.forEach(share.removeParticipant)
        _ = try await save(share)
    }

    func deleteShares() async throws {
        try requireEntitlement()
        let ids = [CloudZoneID.data, .relay].map(Self.shareID)
        let (_, results) = try await database.modifyRecords(saving: [], deleting: ids)
        for (_, result) in results {
            if case .failure(let error) = result, (error as? CKError)?.code != .unknownItem { throw error }
        }
    }

    private static func participant(_ participant: CKShare.Participant) -> ShareParticipant {
        ShareParticipant(
            userRecordName: participant.userIdentity.userRecordID?.recordName,
            accepted: participant.acceptanceStatus == .accepted
        )
    }

    /// nil when the zone has no share (or no zone yet).
    private func fetchShare(_ zone: CloudZoneID) async throws -> CKShare? {
        do {
            return try await database.record(for: Self.shareID(zone)) as? CKShare
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    private func save(_ share: CKShare) async throws -> CKShare {
        let (results, _) = try await database.modifyRecords(saving: [share], deleting: [], savePolicy: .changedKeys)
        guard let result = results[share.recordID] else { throw ShareServiceError.noSaveResult }
        guard let saved = try result.get() as? CKShare else { throw ShareServiceError.noSaveResult }
        return saved
    }
}

enum ShareServiceError: Error, LocalizedError {
    case noURL(CloudZoneID)
    case noSaveResult
    case noEntitlement
    /// A share call outlived `MobileLinkCenter`'s share timeout.
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noEntitlement: return "This build has no iCloud entitlement"
        case .timedOut: return "iCloud didn't answer in time"
        case .noURL(let zone): return "The \(zone.rawValue) share has no URL"
        case .noSaveResult: return "iCloud did not return the saved share"
        }
    }
}
