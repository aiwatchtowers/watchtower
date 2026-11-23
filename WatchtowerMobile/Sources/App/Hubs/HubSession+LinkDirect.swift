import Foundation
import WatchtowerSync

/// The link flow's direct CloudKit calls (#2189): its keybox read by name and its hello saved at once, so neither
/// waits behind the full download of the Mac's zones a fresh replica starts with. Both go through
/// `CloudKitTransport`'s direct calls, which honour its throttle and its unlink.
extension HubSession {
    /// This phone's keybox as the server holds it now: one read of `keybox-<DEVICE_ID>` by its fixed name in the data
    /// zone (`CloudKitTransport.serverRecord`), opened as the replica opens it, with nothing stored. The link flow's
    /// baseline and its grant polls take it; a link still completes from the replica. Off CloudKit: `.unavailable`.
    func serverKeybox(deviceID: UUID) async -> KeyboxRead {
        guard let direct = directCloud else { return .unavailable(reason: "no direct read on this route") }
        direct.energy?.record(.fetchLink)
        return await Self.keyboxRead {
            let name = Keybox.recordName(deviceID: deviceID.uuidString)
            guard let record = try await direct.cloud.serverRecord(named: name, in: .data) else { return nil }
            return try await direct.secure.openKeybox(sealed: record.payload, deviceID: deviceID)
        }
    }

    /// A keybox read's outcome as the link flow takes it: the copy, or nil only when the source holds none. Any throw
    /// is `.unavailable` (a record that does not map or open, locked keys, a throttle, a CloudKit failure, a
    /// cancellation), never an absence. Logged at debug (the link flow logs a wait's first one); a cancellation not.
    static func keyboxRead(_ read: () async throws -> Keybox?) async -> KeyboxRead {
        do {
            return .read(try await read())
        } catch is CancellationError {
            return .unavailable(reason: "cancelled")
        } catch {
            let reason = String(describing: error)
            logger.debug("keybox read unavailable: \(reason, privacy: .public)")
            return .unavailable(reason: reason)
        }
    }

    /// Saves `record` sealed with this session's keys straight to CloudKit (`CloudKitTransport.saveDirectly`, outside
    /// the engine's queue): the link flow's hello, which must not wait behind a fresh replica's launch fetch. false off
    /// CloudKit, or when the seal or the save failed (logged; a cancellation at debug).
    func sendDirectly(_ record: CloudRecord) async -> Bool {
        guard let direct = directCloud else { return false }
        do {
            try await direct.cloud.saveDirectly(try await direct.secure.seal(record))
            return true
        } catch is CancellationError {
            Self.logger.debug("direct save cancelled")
            return false
        } catch {
            Self.logger.error("direct save failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
