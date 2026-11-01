import CloudBridgeCore
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

/// The hub's zone-wide shares of its own `DataZone-<hub_id>` and
/// `RelayZone-<hub_id>` (mobile POC spec §2.3, multi-hub spec §3.4): the seam between `MobileLinkCenter` and CloudKit. Tests use a fake.
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
}

/// The CloudKit implementation over the Mac user's private database: a wrapper over CloudBridgeCore's
/// `CloudKitZoneShares`, the share code the Go hub's CloudKit bridge serves too (moved there in Go hub phase 3,
/// Task 10; this wrapper goes with the Swift hub). Without the iCloud entitlement (an unsigned dev build) it
/// never touches `CKContainer`, which would crash: the account reads `.unavailable` and every other call
/// throws `ShareServiceError.noEntitlement`. The CloudKit calls themselves are not unit-tested: they need a
/// signed build and a real account (the A14 device smoke).
struct CloudKitShareService: ShareService {
    /// Names the zones whose shares this service manages.
    var hubID: String { zones.hubID }
    var containerID: String { zones.containerID }
    private let zones: CloudKitZoneShares

    init(
        hubID: String,
        containerID: String = WatchtowerCloud.containerID,
        entitlementPresent: (@Sendable () -> Bool)? = nil
    ) {
        zones = CloudKitZoneShares(hubID: hubID, containerID: containerID, entitlementPresent: entitlementPresent)
    }

    /// The zone-wide share of one of this hub's zones (multi-hub spec §3.4).
    func shareID(_ zone: CloudZoneID) -> CKRecord.ID {
        zones.shareID(zone)
    }

    func accountStatus() async -> CloudAvailability {
        switch await zones.accountStatus() {
        case .available: return .available
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .noEntitlement: return .unavailable("missing iCloud entitlement (unsigned dev build?)")
        case .couldNotDetermine: return .unavailable("iCloud account status could not be determined")
        case .temporarilyUnavailable: return .unavailable("iCloud account temporarily unavailable")
        case .unknown: return .unavailable("unknown iCloud account status")
        case .failed(let message): return .unavailable(message)
        }
    }

    func ensureShares() async throws -> ShareURLs {
        let urls = try await mapped { try await zones.ensureShares() }
        return ShareURLs(data: urls.data, relay: urls.relay)
    }

    func setPublicLink(open: Bool) async throws {
        try await mapped { try await zones.setPublicLink(open: open) }
    }

    func participants(in zone: CloudZoneID) async throws -> [ShareParticipant] {
        try await mapped { try await zones.participants(in: zone) }
            .map { ShareParticipant(userRecordName: $0.userRecordName, accepted: $0.accepted) }
    }

    func removeParticipants(in zone: CloudZoneID, where shouldRemove: @escaping @Sendable (ShareParticipant) -> Bool) async throws {
        try await mapped {
            try await zones.removeParticipants(in: zone) {
                shouldRemove(ShareParticipant(userRecordName: $0.userRecordName, accepted: $0.accepted))
            }
        }
    }

    /// The moved code's errors as this service has always thrown them.
    private func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ZoneShareError {
            switch error {
            case .noEntitlement: throw ShareServiceError.noEntitlement
            case .noSaveResult: throw ShareServiceError.noSaveResult
            case .noURL(let zone): throw ShareServiceError.noURL(zone)
            }
        }
    }
}

enum ShareServiceError: Error, LocalizedError {
    case noURL(CloudZoneID)
    case noSaveResult
    case noEntitlement
    /// A share call outlived `MobileLinkCenter`'s share timeout.
    case timedOut
    /// A close asked for the public link while an open waited for it.
    case superseded

    var errorDescription: String? {
        switch self {
        case .noEntitlement: return "This build has no iCloud entitlement"
        case .timedOut: return "iCloud didn't answer in time"
        case .superseded: return "The share link was closed meanwhile"
        case .noURL(let zone): return "The \(zone.rawValue) share has no URL"
        case .noSaveResult: return "iCloud did not return the saved share"
        }
    }
}
