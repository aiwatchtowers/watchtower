import Foundation
import GRDB

/// The meeting recorder's record of recordings not yet saved (#604 S3/S4):
/// replaces the `rec_*.meta`/`.txt`/`.json` sidecars. Recording names are the
/// audio files' base names (`rec_<ts>.caf`). Writes await the writer (board
/// #670: no synchronous write on the main thread); reads are synchronous.
package protocol PendingTranscriptStore: Sendable {
    /// `isPrivate` is the recording's private flag (MEETPRIV), kept so a
    /// recording recovered after a crash still saves private.
    func begin(recording: String, eventID: String?, title: String?, isPrivate: Bool, at: Date) async throws
    /// Exclusive: false when another recording already holds the name.
    func reserve(recording: String, eventID: String?, title: String?, isPrivate: Bool, at: Date) async throws -> Bool
    /// The owner flipped the private flag while the recording was capturing
    /// or queued. False (nothing written) when the recording has no row.
    @discardableResult
    func setPrivate(recording: String, _ isPrivate: Bool) async throws -> Bool
    /// `isPrivate` is the job's flag, written on insert and on conflict.
    func saveTranscript(recording: String, text: String, metaJSON: String, isPrivate: Bool, at: Date) async throws
    func clearTranscript(recording: String) async throws
    /// Marks the recording dismissed (a row is written when it had none).
    func dismiss(recording: String, at: Date) async throws
    func pending() throws -> [PendingTranscript]
    func transcript(recording: String) throws -> PendingTranscript?
    func remove(recording: String) async throws
    /// Audio paths of saved transcripts.
    func savedAudioPaths() throws -> Set<String>
}

/// `PendingTranscriptStore` over the Desktop's database writer.
package struct DatabasePendingTranscriptStore: PendingTranscriptStore {
    private let writer: any DatabaseWriter

    package init(writer: any DatabaseWriter) { self.writer = writer }

    package func begin(recording: String, eventID: String?, title: String?, isPrivate: Bool, at: Date) async throws {
        try await writer.write {
            try PendingTranscriptQueries.begin($0, recording: recording, eventID: eventID, title: title,
                                               isPrivate: isPrivate, at: at)
        }
    }

    package func reserve(recording: String, eventID: String?, title: String?, isPrivate: Bool, at: Date)
        async throws -> Bool {
        try await writer.write {
            try PendingTranscriptQueries.reserve($0, recording: recording, eventID: eventID, title: title,
                                                 isPrivate: isPrivate, at: at)
        }
    }

    @discardableResult
    package func setPrivate(recording: String, _ isPrivate: Bool) async throws -> Bool {
        try await writer.write { try PendingTranscriptQueries.setPrivate($0, recording: recording, isPrivate) }
    }

    package func saveTranscript(recording: String, text: String, metaJSON: String, isPrivate: Bool, at: Date)
        async throws {
        try await writer.write {
            try PendingTranscriptQueries.saveTranscript($0, recording: recording, text: text, metaJSON: metaJSON,
                                                        isPrivate: isPrivate, at: at)
        }
    }

    package func clearTranscript(recording: String) async throws {
        try await writer.write { try PendingTranscriptQueries.clearTranscript($0, recording: recording) }
    }

    package func dismiss(recording: String, at: Date) async throws {
        try await writer.write { try PendingTranscriptQueries.dismiss($0, recording: recording, at: at) }
    }

    package func pending() throws -> [PendingTranscript] {
        try writer.read { try PendingTranscriptQueries.all($0) }
    }

    package func transcript(recording: String) throws -> PendingTranscript? {
        try writer.read { try PendingTranscriptQueries.row($0, recording: recording) }
    }

    package func remove(recording: String) async throws {
        try await writer.write { try PendingTranscriptQueries.remove($0, recording: recording) }
    }

    package func savedAudioPaths() throws -> Set<String> {
        try writer.read { try PendingTranscriptQueries.savedAudioPaths($0) }
    }
}
