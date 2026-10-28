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
            self.copyToPasteboard(text)
            return "Copied the transcript"
        } failure: { "Couldn't copy the transcript: \($0)" }
    }

    /// The rendering, from the CLI's stdout, written by the app to the URL the
    /// owner picked in the save panel (atomically, 0600). The app writes it, not
    /// the CLI child, so the save panel's grant covers the destination.
    func save(transcriptID: Int64, format: TranscriptExportFormat, to url: URL, service: TranscriptSaveService) {
        runExport(transcriptID) {
            let data = try await service.export(transcriptID: transcriptID, format: format)
            try await Task.detached(priority: .userInitiated) {
                try data.write(to: url, options: .atomic)
                // A transcript is the owner's alone: readable by this user only.
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }.value
            return "Saved to \(url.lastPathComponent)"
        } failure: { "Export failed: \($0)" }
    }

    private enum ExportError: LocalizedError {
        case notText
        var errorDescription: String? { "the export was not text" }
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
