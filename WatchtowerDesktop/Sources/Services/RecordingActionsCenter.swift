import AppKit
import Foundation
import WatchtowerCore

/// App-wide owner of the recording detail header's **Private** toggle and
/// **Export** runs (docs/features/private-meetings.md), living on AppState so
/// a run outlives the view that started it: the busy flags, a failure and the
/// short success line stay keyed by recording, and show again when the owner
/// comes back to it (the TranscriptChaptersCenter pattern).
@MainActor
@Observable
final class RecordingActionsCenter {
    private(set) var changingPrivate: Set<Int64> = []
    private(set) var exporting: Set<Int64> = []
    private(set) var lastError: [Int64: String] = [:]
    /// "Copied" / "Saved to <name>", cleared after `noticeLifetime`.
    private(set) var notice: [Int64: String] = [:]

    private let copyToPasteboard: @MainActor (String) -> Void
    private let noticeLifetime: Duration
    private var noticeGeneration: [Int64: Int] = [:]

    init(
        noticeLifetime: Duration = .seconds(4),
        copyToPasteboard: @escaping @MainActor (String) -> Void = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    ) {
        self.noticeLifetime = noticeLifetime
        self.copyToPasteboard = copyToPasteboard
    }

    /// `transcript private <id> on|off`. `onChanged` gets the flag the CLI
    /// reports, whether or not the recording is still on screen.
    func setPrivate(
        transcriptID: Int64,
        _ isPrivate: Bool,
        service: TranscriptSaveService,
        onChanged: @escaping @MainActor (Bool) -> Void
    ) {
        guard !changingPrivate.contains(transcriptID) else { return }
        changingPrivate.insert(transcriptID)
        clearMessages(transcriptID)
        Task {
            defer { changingPrivate.remove(transcriptID) }
            do {
                let result = try await service.setPrivate(transcriptID: transcriptID, isPrivate)
                onChanged(result.isPrivate)
            } catch {
                lastError[transcriptID] = "Couldn't change Private: \(error.localizedDescription)"
            }
        }
    }

    /// The txt rendering, from the CLI's stdout, onto the pasteboard.
    func copyTranscript(transcriptID: Int64, service: TranscriptSaveService) {
        runExport(transcriptID) {
            let data = try await service.export(transcriptID: transcriptID, format: .txt)
            guard let text = String(bytes: data, encoding: .utf8) else {
                throw ExportError.notText
            }
            guard !Self.isBlank(data) else { throw ExportError.empty }
            self.copyToPasteboard(text)
            return "Copied the transcript"
        } failure: { "Couldn't copy the transcript: \($0)" }
    }

    /// The rendering, from the CLI's stdout, written by the app to the URL the
    /// owner picked in the save panel (`writeOwnerOnly`). The app writes it, not
    /// the CLI child, so the save panel's grant covers the destination.
    func save(transcriptID: Int64, format: TranscriptExportFormat, to url: URL, service: TranscriptSaveService) {
        runExport(transcriptID) {
            let data = try await service.export(transcriptID: transcriptID, format: format)
            guard !Self.isBlank(data) else { throw ExportError.empty }
            try await Task.detached(priority: .userInitiated) {
                try Self.writeOwnerOnly(data, to: url)
            }.value
            return "Saved to \(url.lastPathComponent)"
        } failure: { "Export failed: \($0)" }
    }

    /// A transcript is the owner's alone: the file is created 0600 (a temp
    /// file beside the destination, opened `O_EXCL` with that mode), written,
    /// then renamed over the destination — so no reader ever sees it with a
    /// wider mode, a replaced file included (Go's `fsutil.WriteFileAtomic`).
    /// On failure the temp file is removed and the destination is untouched.
    nonisolated static func writeOwnerOnly(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var renamed = false
        defer { if !renamed { unlink(temp.path) } }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        renamed = true
    }

    private enum ExportError: LocalizedError {
        case notText
        case empty
        var errorDescription: String? {
            switch self {
            case .notText: "the export was not text"
            case .empty: "nothing to export — every utterance is deleted"
            }
        }
    }

    /// A txt rendering of a recording whose utterances are all deleted is
    /// empty: reported, never a "Saved"/"Copied" of nothing.
    private nonisolated static func isBlank(_ data: Data) -> Bool {
        String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false
    }

    private func runExport(
        _ transcriptID: Int64,
        _ work: @escaping @MainActor () async throws -> String,
        failure: @escaping (String) -> String
    ) {
        guard !exporting.contains(transcriptID) else { return }
        exporting.insert(transcriptID)
        clearMessages(transcriptID)
        Task {
            defer { exporting.remove(transcriptID) }
            do {
                show(notice: try await work(), for: transcriptID)
            } catch {
                lastError[transcriptID] = failure(error.localizedDescription)
            }
        }
    }

    private func clearMessages(_ transcriptID: Int64) {
        lastError[transcriptID] = nil
        notice[transcriptID] = nil
    }

    private func show(notice text: String, for transcriptID: Int64) {
        let generation = (noticeGeneration[transcriptID] ?? 0) + 1
        noticeGeneration[transcriptID] = generation
        notice[transcriptID] = text
        let lifetime = noticeLifetime
        Task {
            try? await Task.sleep(for: lifetime)
            guard noticeGeneration[transcriptID] == generation else { return }
            notice[transcriptID] = nil
        }
    }
}
