import Foundation

/// Canonical CloudRecord.kind strings for RelayZone records.
/// rawValues are wire format — never rename existing cases.
public enum RelayRecordKind: String, CaseIterable {
    case action
    case chatMessage = "chat_message"
    case chatChunk = "chat_chunk"
    case heartbeat
    case recordingUpload = "recording_upload"
}

/// Cross-platform CloudKit constants.
public enum WatchtowerCloud {
    /// Single source of truth for the CloudKit container. Packaging must
    /// provision exactly this identifier in the app's entitlements.
    public static let containerID = "iCloud.com.aiwatchtowers.watchtower"
}
