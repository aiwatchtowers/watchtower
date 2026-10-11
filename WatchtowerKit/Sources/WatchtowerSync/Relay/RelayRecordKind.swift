import Foundation

/// Canonical CloudRecord.kind strings for RelayZone records.
/// rawValues are wire format — never rename existing cases.
public enum RelayRecordKind: String, CaseIterable {
    case action
    /// Wire compatibility only: the heartbeat moved to DataZone (mobile POC
    /// spec §4.1), so no current writer emits a relay-zone heartbeat.
    case heartbeat
    case recordingUpload = "recording_upload"
    /// The phone's link record (`device-<device_id>`, spec §5.1). Only the
    /// phone writes it; the Mac answers through the `device_grant` slice.
    case device
}

/// Cross-platform CloudKit constants.
public enum WatchtowerCloud {
    /// Single source of truth for the CloudKit container. Packaging must
    /// provision exactly this identifier in the app's entitlements.
    public static let containerID = "iCloud.com.aiwatchtowers.watchtower"
}
