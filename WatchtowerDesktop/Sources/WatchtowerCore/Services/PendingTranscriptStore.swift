import Foundation
import GRDB

/// The meeting recorder's record of recordings not yet saved (#604 S3/S4):
/// replaces the `rec_*.meta`/`.txt`/`.json` sidecars. Recording names are the
/// audio files' base names (`rec_<ts>.caf`).
package protocol PendingTranscriptStore: Sendable {
    func begin(recording: String, eventID: String?, title: String?, at: Date) throws
    /// Exclusive: false when another recording already holds the name.
    func reserve(recording: String, eventID: String?, title: String?, at: Date) throws -> Bool
    func saveTranscript(recording: String, text: String, metaJSON: String, at: Date) throws
    func clearTranscript(recording: String) throws
    /// Marks the recording dismissed (a row is written when it had none).
    func dismiss(recording: String, at: Date) throws
    func pending() throws -> [PendingTranscript]
    func transcript(recording: String) throws -> PendingTranscript?
    func remove(recording: String) throws
    /// Audio paths of saved transcripts.
    func savedAudioPaths() throws -> Set<String>
}

/// `PendingTranscriptStore` over the Desktop's database writer.
package struct DatabasePendingTranscriptStore: PendingTranscriptStore {
    private let writer: any DatabaseWriter

    package init(writer: any DatabaseWriter) { self.writer = writer }

    package func begin(recording: String, eventID: String?, title: String?, at: Date) throws {
        try writer.write { try PendingTranscriptQueries.begin($0, recording: recording, eventID: eventID, title: title, at: at) }
    }

    package func reserve(recording: String, eventID: String?, title: String?, at: Date) throws -> Bool {
        try writer.write {
            try PendingTranscriptQueries.reserve($0, recording: recording, eventID: eventID, title: title, at: at)
        }
    }

    package func saveTranscript(recording: String, text: String, metaJSON: String, at: Date) throws {
        try writer.write {
            try PendingTranscriptQueries.saveTranscript($0, recording: recording, text: text, metaJSON: metaJSON, at: at)
        }
    }

    package func clearTranscript(recording: String) throws {
        try writer.write { try PendingTranscriptQueries.clearTranscript($0, recording: recording) }
    }

    package func dismiss(recording: String, at: Date) throws {
        try writer.write { try PendingTranscriptQueries.dismiss($0, recording: recording, at: at) }
    }

    package func pending() throws -> [PendingTranscript] {
        try writer.read { try PendingTranscriptQueries.all($0) }
    }

    package func transcript(recording: String) throws -> PendingTranscript? {
        try writer.read { try PendingTranscriptQueries.row($0, recording: recording) }
    }

    package func remove(recording: String) throws {
        try writer.write { try PendingTranscriptQueries.remove($0, recording: recording) }
    }

    package func savedAudioPaths() throws -> Set<String> {
        try writer.read { try PendingTranscriptQueries.savedAudioPaths($0) }
    }
}
