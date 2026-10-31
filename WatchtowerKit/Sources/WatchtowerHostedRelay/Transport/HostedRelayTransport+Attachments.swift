import Foundation
import WatchtowerRelayProto
import WatchtowerSync

/// A queued record's asset file cannot be read (a local error: the record is not sent).
struct AssetMissing: Error {}

/// Attachments: `create_upload` → PUT of the file → the save names `attachment_id`; a pulled
/// record's attachment is `get_download` → GET capped at `maxAttachmentBytes` into the stash,
/// before its page is buffered. Blob URLs are signed: never logged, never in an error.
extension HostedRelayTransport {
    /// Uploads `file` for a record of `zone`; returns the attachment id. The upload URL must be
    /// HTTPS (or loopback), and any non-2xx answer, a redirect included, fails it.
    func upload(_ file: URL, zone: CloudZoneID) async throws -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = (attributes?[.size] as? NSNumber)?.uint64Value else { throw AssetMissing() }
        var create = Relay_V1_CreateUpload()
        create.zone = zoneName(zone)
        create.size = size
        let upload = try await call(zone) { try await self.client.createUpload(create) }
        guard let url = URL(string: upload.url), Self.secureBlobURL(url) else {
            Self.logger.error("relay upload: the URL leaves HTTPS, \(Self.kind(zone), privacy: .public)")
            throw HostedRelayError.undecodable(status: 200)
        }
        let status: Int
        do {
            status = try await client.http.put(url, file: file, headers: upload.headers)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            Self.logger.error("relay upload: no answer, \(Self.kind(zone), privacy: .public)")
            await note(HostedRelayError.unreachable, zone: zone)
            throw HostedRelayError.unreachable
        }
        guard (200..<300).contains(status) else {
            Self.logger.error("relay upload: HTTP \(status), \(Self.kind(zone), privacy: .public)")
            if status == 413 { throw HostedRelayError.server(code: .attachmentTooLarge, retryAfter: nil) }
            throw HostedRelayError.undecodable(status: status)
        }
        return upload.attachmentID
    }

    /// Downloads `record`'s attachment into the store's stash (a temporary file for a store
    /// without one). A URL that leaves HTTPS, a non-2xx answer (a redirect included) or a body
    /// past `maxAttachmentBytes` fails the page; nothing is left on disk then.
    func download(_ record: Relay_V1_Record, zone: CloudZoneID) async throws -> URL {
        var request = Relay_V1_GetDownload()
        request.zone = zoneName(zone)
        request.attachmentID = record.attachmentID
        let answer = try await call(zone) { try await self.client.getDownload(request) }
        guard let url = URL(string: answer.url), Self.secureBlobURL(url) else {
            Self.logger.error("relay download: the URL leaves HTTPS, \(Self.kind(zone), privacy: .public)")
            throw HostedRelayError.undecodable(status: 200)
        }
        let directory = store.stashDirectory ?? FileManager.default.temporaryDirectory
        let file = directory.appendingPathComponent(".download-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let status = try await client.http.get(url, to: file, maxBytes: maxAttachmentBytes, headers: [:])
            guard (200..<300).contains(status) else {
                Self.logger.error("relay download: HTTP \(status), \(Self.kind(zone), privacy: .public)")
                throw HostedRelayError.undecodable(status: status)
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw Self.downloadError(error, zone: zone)
        }
        guard let stashed = store.stashAsset(from: file, recordName: record.name, zone: zone, maxBytes: maxAttachmentBytes) else {
            return file
        }
        try? FileManager.default.removeItem(at: file)
        return stashed
    }

    private static func downloadError(_ error: any Error, zone: CloudZoneID) -> any Error {
        if error is HostedRelayError || error is CancellationError { return error }
        if (error as? URLError)?.code == .cancelled { return CancellationError() }
        if (error as? URLError)?.code == .dataLengthExceedsMaximum {
            logger.error("relay download: over the attachment cap, \(kind(zone), privacy: .public)")
            return HostedRelayError.server(code: .attachmentTooLarge, retryAfter: nil)
        }
        logger.error("relay download: no answer, \(kind(zone), privacy: .public)")
        return HostedRelayError.unreachable
    }

    /// HTTPS, or plain HTTP to this machine only (the local stand).
    static func secureBlobURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
        default: return false
        }
    }
}
