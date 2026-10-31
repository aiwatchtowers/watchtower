import CloudKit
import Foundation
import WatchtowerSync

/// The live `LinkAccess`: the app's CloudKit container (spec §2.3).
/// Share accept runs `CKFetchShareMetadataOperation` on every URL, then one
/// `CKAcceptSharesOperation`. Not verified on a device yet for a different
/// Apple ID (the `shared` scope).
/// The invitation cannot be joined: a share URL is missing or not a URL.
enum LinkAccessError: Error, Equatable {
    case invalidInvitation
}

struct CloudKitLinkAccess: LinkAccess {
    private let containerID: String

    init(containerID: String = WatchtowerCloud.containerID) {
        self.containerID = containerID
    }

    private var container: CKContainer { CKContainer(identifier: containerID) }

    func availability() async -> CloudAvailability {
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .couldNotDetermine: return .unavailable("iCloud status could not be determined")
            case .temporarilyUnavailable: return .unavailable("iCloud is temporarily unavailable")
            @unknown default: return .unavailable("unknown iCloud status")
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    func identity() async throws -> String {
        try await container.userRecordID().recordName
    }

    func join(_ invitation: LinkInvitation, route: HubRoute, hubID: String) async throws {
        switch route {
        case .hostedRelay: throw UnsupportedRouteError(route: route)
        case .cloudKit(.private): return
        case let .cloudKit(.shared(ownerName)):
            guard let urls = Self.shareURLs(invitation) else { throw LinkAccessError.invalidInvitation }
            try await acceptShares(urls, ownerName: ownerName, hubID: hubID)
        }
    }

    private static func shareURLs(_ invitation: LinkInvitation) -> [URL]? {
        guard let data = invitation.dataShare.flatMap(URL.init(string:)),
              let relay = invitation.relayShare.flatMap(URL.init(string:)) else { return nil }
        return [data, relay]
    }

    private func acceptShares(_ urls: [URL], ownerName: String, hubID: String) async throws {
        let metadatas = try await fetchMetadata(urls)
        try Self.checkShares(
            metadatas.map { (owner: $0.ownerIdentity.userRecordID?.recordName, recordID: $0.share.recordID) },
            ownerName: ownerName, hubID: hubID)
        try await accept(metadatas)
    }

    /// The code's share URLs named something else than the hub's two zones.
    enum ShareCheckError: Error, Equatable {
        case unexpectedShares
    }

    /// Before anything is accepted: the shares are exactly the zone-wide
    /// shares of `hubID`'s two zones, and the code's owner owns each, so a
    /// code carrying other URLs cannot make the phone join another user's
    /// zones (or another hub's).
    static func checkShares(
        _ shares: [(owner: String?, recordID: CKRecord.ID)], ownerName: String, hubID: String
    ) throws {
        let expected = shareRecordIDs(ownerName: ownerName, hubID: hubID)
        guard shares.count == expected.count, shares.allSatisfy({ $0.owner == ownerName }),
              Set(shares.map(\.recordID)) == Set(expected) else {
            throw ShareCheckError.unexpectedShares
        }
    }

    /// A zone-wide share's record lives in its zone under
    /// `CKRecordNameZoneWideShare`; deleting it from the shared database
    /// leaves the share.
    func leave(route: HubRoute, hubID: String) async throws {
        switch route {
        case .hostedRelay: throw UnsupportedRouteError(route: route)
        case .cloudKit(.private): return
        case let .cloudKit(.shared(ownerName)): try await leaveShares(ownerName: ownerName, hubID: hubID)
        }
    }

    private func leaveShares(ownerName: String, hubID: String) async throws {
        let ids = Self.shareRecordIDs(ownerName: ownerName, hubID: hubID)
        let results = try await container.sharedCloudDatabase.modifyRecords(saving: [], deleting: ids)
        for (_, result) in results.deleteResults {
            if case let .failure(error) = result,
               (error as? CKError)?.code != .unknownItem, (error as? CKError)?.code != .zoneNotFound {
                throw error
            }
        }
    }

    /// The zone-wide share records of `hubID`'s two zones (`DataZone-<hubID>`,
    /// `RelayZone-<hubID>`) owned by `ownerName`.
    static func shareRecordIDs(ownerName: String, hubID: String) -> [CKRecord.ID] {
        HubZones(scope: .shared(ownerName: ownerName), hubID: hubID).allZoneIDs.map { zoneID in
            CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        }
    }

    private func fetchMetadata(_ urls: [URL]) async throws -> [CKShare.Metadata] {
        try await withCheckedThrowingContinuation { continuation in
            var fetched: [URL: CKShare.Metadata] = [:]
            var failure: (any Error)?
            let operation = CKFetchShareMetadataOperation(shareURLs: urls)
            operation.perShareMetadataResultBlock = { url, result in
                switch result {
                case let .success(metadata): fetched[url] = metadata
                case let .failure(error): failure = failure ?? error
                }
            }
            operation.fetchShareMetadataResultBlock = { result in
                if case let .failure(error) = result {
                    continuation.resume(throwing: error)
                } else if let failure {
                    continuation.resume(throwing: failure)
                } else {
                    let ordered = urls.compactMap { fetched[$0] }
                    if ordered.count == urls.count {
                        continuation.resume(returning: ordered)
                    } else {
                        continuation.resume(throwing: CKError(.unknownItem))
                    }
                }
            }
            container.add(operation)
        }
    }

    private func accept(_ metadatas: [CKShare.Metadata]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var failure: (any Error)?
            let operation = CKAcceptSharesOperation(shareMetadatas: metadatas)
            operation.perShareResultBlock = { _, result in
                if case let .failure(error) = result { failure = failure ?? error }
            }
            operation.acceptSharesResultBlock = { result in
                if case let .failure(error) = result {
                    continuation.resume(throwing: error)
                } else if let failure {
                    continuation.resume(throwing: failure)
                } else {
                    continuation.resume()
                }
            }
            container.add(operation)
        }
    }
}
