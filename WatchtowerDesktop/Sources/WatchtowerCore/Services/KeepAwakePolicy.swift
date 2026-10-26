import Foundation

/// When the hub keeps the Mac from idling to sleep (mobile workbench remote
/// spec, ask #614): a board session is running, a linked phone has been in
/// touch within `contactWindow`, and the owner left Settings → Mobile →
/// "Keep this Mac awake for the iPhone" on.
package enum KeepAwakePolicy {
    /// How recent the phone's last contact must be.
    package static let contactWindow: TimeInterval = 86_400

    package static func shouldHold(
        enabled: Bool, liveBoardSessions: Int, lastPhoneContact: Date?, now: Date
    ) -> Bool {
        guard enabled, liveBoardSessions > 0, let lastPhoneContact else { return false }
        return now.timeIntervalSince(lastPhoneContact) <= contactWindow
    }
}
