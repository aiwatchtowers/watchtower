import AVFoundation
import Foundation
import WatchtowerCore

/// Phone recording ingest (mobile hub): reserving the recording's name and
/// row, copying the phone's audio in, and the audio check that gates it.
/// `ingestPhoneRecording` itself lives with the queue it enqueues into.
extension MeetingRecorderCenter {
    /// Reserves a unique `rec_<ts>[-N].m4a` name in `directory` by inserting
    /// its `pending_transcripts` row EXCLUSIVELY (`PendingTranscriptStore.reserve`):
    /// when a concurrent reserver took the name first, the insert does
    /// nothing and the next `-N` is tried, so no other recording's row is ever
    /// overwritten. The row is what recovery keys on, so a quit before the job
    /// runs leaves the recording recoverable, event-linked. Unlike a live
    /// capture's best-effort row, a failure here throws. Returns the reserved
    /// audio URL; nothing exists there yet.
    ///
    /// Call it on the main actor (as `ingestPhoneRecording` does); the
    /// exclusive insert makes it safe against other reservers on any thread.
    /// Internal (and `nonisolated`) only so the reservers' race is testable
    /// off the main actor.
    nonisolated static func reservePhoneRecording(
        eventID: String?,
        title: String?,
        in directory: URL,
        store: PendingTranscriptStore,
        date: Date = Date()
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var lost: Set<String> = []
        while true {
            let audioURL = uniqueRecordingURL(in: directory, date: date, fileExtension: "m4a") {
                lost.contains($0) || isReserved($0, in: store)
            }
            if try await store.reserve(recording: audioURL.lastPathComponent, eventID: eventID, title: title, at: date) {
                return audioURL
            }
            // Lost the race for this name; the next `uniqueRecordingURL` moves past it.
            lost.insert(audioURL.deletingPathExtension().lastPathComponent)
        }
    }

    /// Copies the phone's audio into a name `reservePhoneRecording` reserved.
    /// On failure only what this call created is removed — the partial audio
    /// (never a file that already sat there) and the reserved row — and the
    /// error is thrown, so a disk-full ingest leaves nothing half-written.
    /// Copies rather than moves: the source belongs to the transport, which
    /// deletes it only once the ingest succeeded. `nonisolated`: the copy of a
    /// long recording runs off the main actor.
    nonisolated static func copyPhoneRecording(
        from sourceURL: URL,
        to audioURL: URL,
        store: PendingTranscriptStore
    ) async throws {
        do {
            try FileManager.default.copyItem(at: sourceURL, to: audioURL)
        } catch {
            if (error as? CocoaError)?.code != .fileWriteFileExists {
                try? FileManager.default.removeItem(at: audioURL)
            }
            do {
                try await store.remove(recording: audioURL.lastPathComponent)
            } catch let removal {
                print("[MeetingRecorder] could not release the reserved row of \(audioURL.lastPathComponent): "
                      + removal.localizedDescription)
            }
            throw error
        }
    }

    /// Why a phone recording was refused before anything was written.
    enum PhoneIngestError: LocalizedError {
        /// Readable, but no audio recording.
        case notAudio
        /// The file could not be read (an I/O error), so whether it is audio
        /// is unknown.
        case unreadable(String)
        /// The database is not open yet: the recording could not be recorded
        /// as pending, so it was not taken (the phone keeps it and retries).
        case databaseUnavailable

        var errorDescription: String? {
            switch self {
            case .databaseUnavailable: "Watchtower's database is not open yet."
            case .notAudio: "The file is not an audio recording."
            case let .unreadable(detail): "The file could not be read: \(detail)"
            }
        }
    }

    /// A phone recording: an ISO base media file (its first box is `ftyp`,
    /// whose type sits at offset 4) that AVFoundation reads with at least one
    /// audio track — so a video, a HEIF image or a bare header is refused, and
    /// whatever else a linked phone sends never reaches the recordings
    /// directory or the decoder. False means readable but not audio; an I/O
    /// error throws `PhoneIngestError.unreadable` instead.
    nonisolated static func isAudioRecording(_ url: URL) async throws -> Bool {
        guard try isISOMediaFile(url) else { return false }
        do {
            return try await !AVURLAsset(url: url).loadTracks(withMediaType: .audio).isEmpty
        } catch let error as NSError where error.domain == AVFoundationErrorDomain {
            return false // AVFoundation read the bytes and found no media it can open
        } catch {
            throw PhoneIngestError.unreadable(error.localizedDescription)
        }
    }

    /// The cheap first gate of `isAudioRecording`: the `ftyp` box head. A
    /// file shorter than the head is no media file; one that cannot be opened
    /// or read throws `PhoneIngestError.unreadable`.
    nonisolated static func isISOMediaFile(_ url: URL) throws -> Bool {
        let head: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            head = try handle.read(upToCount: 8) ?? Data()
        } catch {
            throw PhoneIngestError.unreadable(error.localizedDescription)
        }
        guard head.count == 8 else { return false }
        return head.suffix(4) == Data("ftyp".utf8)
    }
}
