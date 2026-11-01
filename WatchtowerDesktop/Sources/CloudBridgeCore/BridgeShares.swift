import CloudKit
import Foundation
import WatchtowerSync

/// The iCloud account as `CKContainer.accountStatus()` reports it, plus the build without the entitlement.
public enum ZoneShareAccount: Equatable, Sendable {
    case available
    case noAccount
    case restricted
    case couldNotDetermine
    case temporarilyUnavailable
    case unknown
    /// The process is not signed with the container (an unsigned dev build): CloudKit was never touched.
    case noEntitlement
    /// The status call itself failed.
    case failed(String)

    /// The bridge protocol's `Account.status` word.
    public var wireStatus: String {
        switch self {
        case .available: return "available"
        case .noAccount: return "no_account"
        case .restricted: return "restricted"
        case .noEntitlement: return "no_entitlement"
        case .couldNotDetermine, .temporarilyUnavailable, .unknown, .failed: return "temporarily_unavailable"
        }
    }
}

/// One non-owner participant of a hub zone share.
public struct ZoneShareParticipant: Equatable, Sendable {
    /// The participant's iCloud user record name; nil for an invitation CloudKit has not resolved to a user.
    public let userRecordName: String?
    public let accepted: Bool

    public init(userRecordName: String?, accepted: Bool) {
        self.userRecordName = userRecordName
        self.accepted = accepted
    }
}

public enum ZoneShareError: Error, Equatable {
    case noURL(CloudZoneID)
    case noSaveResult
    case noEntitlement
}

/// The hub's zone-wide shares of its own `DataZone-<hub_id>` and `RelayZone-<hub_id>` in the Mac user's
/// private database (mobile POC spec §2.3, multi-hub spec §3.4): moved here from the Swift hub's
/// `ShareService.swift`, whose `CloudKitShareService` now wraps it, so the bridge (Go hub spec §6.2) and the
/// Swift hub run the same share code until the Swift hub goes. Without the iCloud entitlement it never touches
/// `CKContainer`, which would crash: the account reads `.noEntitlement` and every other call throws
/// `ZoneShareError.noEntitlement`. The CloudKit calls themselves need a signed build and a real account.
public struct CloudKitZoneShares: Sendable {
    public let hubID: String
    public let containerID: String
    private let entitlementPresent: @Sendable () -> Bool

    public init(
        hubID: String,
        containerID: String = WatchtowerCloud.containerID,
        entitlementPresent: (@Sendable () -> Bool)? = nil
    ) {
        self.hubID = hubID
        self.containerID = containerID
        self.entitlementPresent = entitlementPresent ?? { CloudKitTransport.entitlementPresent(containerID: containerID) }
    }

    public var hasEntitlement: Bool { entitlementPresent() }

    private func requireEntitlement() throws {
        guard entitlementPresent() else { throw ZoneShareError.noEntitlement }
    }

    private var database: CKDatabase { CKContainer(identifier: containerID).privateCloudDatabase }

    /// The zone-wide share of one of this hub's zones (multi-hub spec §3.4).
    public func shareID(_ zone: CloudZoneID) -> CKRecord.ID {
        CKRecord.ID(
            recordName: CKRecordNameZoneWideShare,
            zoneID: HubZones(scope: .private, hubID: hubID).zoneID(for: zone)
        )
    }

    private static func publicPermission(for zone: CloudZoneID) -> CKShare.ParticipantPermission {
        zone == .data ? .readOnly : .readWrite
    }

    public func accountStatus() async -> ZoneShareAccount {
        guard entitlementPresent() else { return .noEntitlement }
        do {
            switch try await CKContainer(identifier: containerID).accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .couldNotDetermine: return .couldNotDetermine
            case .temporarilyUnavailable: return .temporarilyUnavailable
            @unknown default: return .unknown
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Creates whichever of the two shares does not exist yet (public link closed) and returns both URLs. An
    /// existing share is reused.
    public func ensureShares() async throws -> (data: String, relay: String) {
        try requireEntitlement()
        var urls: [CloudZoneID: String] = [:]
        for zone in [CloudZoneID.data, .relay] {
            let share: CKShare
            if let existing = try await fetchShare(zone) {
                share = existing
            } else {
                let created = CKShare(recordZoneID: shareID(zone).zoneID)
                created[CKShare.SystemFieldKey.title] = "Watchtower"
                created.publicPermission = .none
                share = try await save(created)
            }
            guard let url = share.url?.absoluteString else { throw ZoneShareError.noURL(zone) }
            urls[zone] = url
        }
        return (urls[.data] ?? "", urls[.relay] ?? "")
    }

    /// Opens the public link (DataZone `.readOnly`, RelayZone `.readWrite`) or closes it (`.none`) on both
    /// shares. A missing share is skipped.
    public func setPublicLink(open: Bool) async throws {
        try requireEntitlement()
        for zone in [CloudZoneID.data, .relay] {
            guard let share = try await fetchShare(zone) else { continue }
            share.publicPermission = open ? Self.publicPermission(for: zone) : .none
            _ = try await save(share)
        }
    }

    /// The share's non-owner participants; empty when there is no share.
    public func participants(in zone: CloudZoneID) async throws -> [ZoneShareParticipant] {
        try requireEntitlement()
        guard let share = try await fetchShare(zone) else { return [] }
        return share.participants.filter { $0.role != .owner }.map(Self.participant)
    }

    /// Removes every non-owner participant `shouldRemove` picks.
    public func removeParticipants(
        in zone: CloudZoneID, where shouldRemove: @escaping @Sendable (ZoneShareParticipant) -> Bool
    ) async throws {
        try requireEntitlement()
        guard let share = try await fetchShare(zone) else { return }
        let leaving = share.participants.filter { $0.role != .owner && shouldRemove(Self.participant($0)) }
        guard !leaving.isEmpty else { return }
        leaving.forEach(share.removeParticipant)
        _ = try await save(share)
    }

    private static func participant(_ participant: CKShare.Participant) -> ZoneShareParticipant {
        ZoneShareParticipant(
            userRecordName: participant.userIdentity.userRecordID?.recordName,
            accepted: participant.acceptanceStatus == .accepted
        )
    }

    /// nil when the zone has no share (or no zone yet).
    private func fetchShare(_ zone: CloudZoneID) async throws -> CKShare? {
        do {
            return try await database.record(for: shareID(zone)) as? CKShare
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    private func save(_ share: CKShare) async throws -> CKShare {
        let (results, _) = try await database.modifyRecords(saving: [share], deleting: [], savePolicy: .changedKeys)
        guard let result = results[share.recordID] else { throw ZoneShareError.noSaveResult }
        guard let saved = try result.get() as? CKShare else { throw ZoneShareError.noSaveResult }
        return saved
    }
}

// MARK: - The bridge's share operations

/// The share operations the bridge serves (`AccountStatus`, `EnsureShares`, `SetPublicLink`, `Participants`,
/// `RemoveParticipants`); `CloudKitZoneShares` in the app, a fake in tests. A zone is named by its CloudKit
/// name, one of the hub's two zones (the caller checked it).
public protocol BridgeShareProviding: Sendable {
    func accountStatus() async -> ZoneShareAccount
    func ensureShares() async throws -> (data: String, relay: String)
    func setPublicLink(open: Bool) async throws
    func participants(inZoneNamed zone: String) async throws -> [ZoneShareParticipant]
    /// Removes the participants whose user record names are listed.
    func removeParticipants(inZoneNamed zone: String, userRecordNames: [String]) async throws
}

extension CloudKitZoneShares: BridgeShareProviding {
    private func cloudZone(_ name: String) throws -> CloudZoneID {
        let zones = HubZones(scope: .private, hubID: hubID)
        guard let zone = CloudZoneID.allCases.first(where: { zones.zoneID(for: $0).zoneName == name }) else {
            throw BridgeCloudFailure.unsupportedZone
        }
        return zone
    }

    public func participants(inZoneNamed zone: String) async throws -> [ZoneShareParticipant] {
        try await participants(in: cloudZone(zone))
    }

    public func removeParticipants(inZoneNamed zone: String, userRecordNames: [String]) async throws {
        let names = Set(userRecordNames)
        try await removeParticipants(in: cloudZone(zone)) { participant in
            participant.userRecordName.map(names.contains) ?? false
        }
    }
}
