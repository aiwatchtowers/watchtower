import Foundation

/// Builds CloudRecords from typed payloads so callers never assemble
/// zone/kind/recordName triples by hand.
public enum CloudRecordFactory {
    public static func record(for action: ActionRequestPayload, modifiedAt: Date) throws -> CloudRecord {
        try relayRecord(name: action.recordName, kind: .action, payload: action, modifiedAt: modifiedAt)
    }

    public static func record(for message: ChatMessagePayload, modifiedAt: Date) throws -> CloudRecord {
        try relayRecord(name: message.recordName, kind: .chatMessage, payload: message, modifiedAt: modifiedAt)
    }

    public static func record(for chunk: ChatChunkPayload, modifiedAt: Date) throws -> CloudRecord {
        try relayRecord(name: chunk.recordName, kind: .chatChunk, payload: chunk, modifiedAt: modifiedAt)
    }

    public static func record(for heartbeat: HeartbeatPayload, modifiedAt: Date) throws -> CloudRecord {
        try relayRecord(name: HeartbeatPayload.recordName, kind: .heartbeat, payload: heartbeat, modifiedAt: modifiedAt)
    }

    /// `assetFileURL` carries the audio as a `CKAsset`: the phone passes its
    /// local `.m4a`; the desktop's status write-back passes nil, which
    /// REMOVES the asset from the record (frees the iCloud storage).
    public static func record(
        for upload: RecordingUploadPayload,
        modifiedAt: Date,
        assetFileURL: URL?
    ) throws -> CloudRecord {
        CloudRecord(
            recordName: upload.recordName,
            zone: .relay,
            kind: RelayRecordKind.recordingUpload.rawValue,
            modifiedAt: modifiedAt,
            payload: try RelayCoder.makeEncoder().encode(upload),
            assetFileURL: assetFileURL
        )
    }

    public static func record(for slice: SliceRecord) -> CloudRecord {
        CloudRecord(
            recordName: slice.recordName,
            zone: .data,
            kind: slice.kind.rawValue,
            modifiedAt: slice.modifiedAt,
            payload: slice.payload,
            notifyLevel: slice.notifyLevel
        )
    }

    private static func relayRecord<P: Encodable>(
        name: String,
        kind: RelayRecordKind,
        payload: P,
        modifiedAt: Date
    ) throws -> CloudRecord {
        CloudRecord(
            recordName: name,
            zone: .relay,
            kind: kind.rawValue,
            modifiedAt: modifiedAt,
            payload: try RelayCoder.makeEncoder().encode(payload)
        )
    }
}
