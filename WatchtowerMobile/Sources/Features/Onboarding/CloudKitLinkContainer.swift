import CloudKit
import Foundation
import WatchtowerSync

/// The live `LinkContainer`: the app's CloudKit container (spec §2.3).
/// Share accept runs `CKFetchShareMetadataOperation` on every URL, then one
/// `CKAcceptSharesOperation`. Not verified on a device yet for a different
/// Apple ID (the `shared` scope).
struct CloudKitLinkContainer: LinkContainer {
    private let containerID: String

    init(containerID: String = WatchtowerCloud.containerID) {
        self.containerID = containerID
    }

    private var container: CKContainer { CKContainer(identifier: containerID) }

    func accountStatus() async -> CloudAvailability {
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

    func userRecordName() async throws -> String {
        try await container.userRecordID().recordName
    }

    func acceptShares(_ urls: [URL]) async throws {
        let metadatas = try await fetchMetadata(urls)
        try await accept(metadatas)
    }

    /// A zone-wide share's record lives in its zone under
    /// `CKRecordNameZoneWideShare`; deleting it from the shared database
    /// leaves the share.
    func leaveShares(ownerName: String) async throws {
        let ids = CloudZoneID.allCases.map { zone in
            CKRecord.ID(
                recordName: CKRecordNameZoneWideShare,
                zoneID: CKRecordZone.ID(zoneName: zone.rawValue, ownerName: ownerName)
            )
        }
        let results = try await container.sharedCloudDatabase.modifyRecords(saving: [], deleting: ids)
        for (_, result) in results.deleteResults {
            if case let .failure(error) = result,
               (error as? CKError)?.code != .unknownItem, (error as? CKError)?.code != .zoneNotFound {
                throw error
            }
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
