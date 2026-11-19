import Foundation
import os
import WatchtowerSync

/// Whether the recording uploader may re-send (the app is active). Read by
/// the uploader's actor, written on the main actor.
final class UploadRetryGate: Sendable {
    private let state: OSAllocatedUnfairLock<Bool>

    init(_ open: Bool) {
        state = OSAllocatedUnfairLock(initialState: open)
    }

    var isOpen: Bool { state.withLock { $0 } }

    /// Sets the gate; true when that changed it.
    func set(_ open: Bool) -> Bool {
        state.withLock { current in
            defer { current = open }
            return current != open
        }
    }
}

extension PhoneRecording {
    /// On its way to the Mac and not yet acknowledged: waiting, or saved
    /// and waiting for the Mac's receipt, while it still retries by itself.
    var needsUpload: Bool {
        (state == .waiting || state == .uploading) && !isUploadStuck
    }
}
