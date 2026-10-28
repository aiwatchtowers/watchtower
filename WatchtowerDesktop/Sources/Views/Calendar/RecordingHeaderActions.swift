import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WatchtowerCore

/// The recording detail header's **Private** toggle and **Export** menu
/// (docs/features/private-meetings.md). Both go through the CLI: `transcript
/// private <id> on|off` and `transcript export` — the renderers live in Go
/// only. Failures reach the owner through `onError`, never swallowed.
struct RecordingHeaderActions: View {
    let transcript: MeetingTranscript
    /// Whether the row has timed segments; SRT needs them.
    let hasSegments: Bool
    /// The flag landed (the CLI answered); the host reloads.
    let onPrivateChanged: (Bool) -> Void
    let onError: (String) -> Void

    @State private var confirmPrivate = false
    @State private var isChangingPrivate = false
    @State private var isExporting = false

    private var transcriptID: Int64? { transcript.id }

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Toggle(isOn: Binding(
                get: { transcript.isPrivate },
                set: { on in
                    // Turning private ON is confirmed (what stays is said
                    // there); OFF only re-enables the AI actions.
                    if on { confirmPrivate = true } else { setPrivate(false) }
                }
            )) {
                Label("Private", systemImage: transcript.isPrivate ? "lock.fill" : "lock.open")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .buttonStyle(.kitSecondary)
            .controlSize(.small)
            .disabled(isChangingPrivate || transcriptID == nil)
            .help(transcript.isPrivate
                  ? "Private: never sent to AI. Turn off to allow recap, notes, chapters and chat again."
                  : "Make this recording private: never sent to AI")
            .confirmationDialog("Make this recording private?", isPresented: $confirmPrivate,
                                titleVisibility: .visible) {
                Button("Make Private") { setPrivate(true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("From now on it is never sent to AI: recap, notes, chapters, follow-up drafts and the "
                    + "chat are turned off, and the assistant no longer finds it. A recap or notes already made "
                    + "stay visible here. Ideas and memory already taken from this recording stay.")
            }

            Menu {
                Button("Copy Transcript") { copyTranscript() }
                Divider()
                ForEach(TranscriptExportFormat.allCases, id: \.self) { format in
                    Button(format.menuTitle) { save(format) }
                        .disabled(format.needsSegments && !hasSegments)
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
            .menuStyle(.button)
            .buttonStyle(.kitSecondary)
            .controlSize(.small)
            .fixedSize()
            .disabled(isExporting || transcriptID == nil)
            .help(hasSegments ? "Copy or save the transcript" : "Copy or save the transcript (subtitles need timings)")
        }
    }

    // MARK: - Actions

    private var service: TranscriptSaveService? {
        ProcessCLIRunner.makeDefault().map { TranscriptSaveService(runner: $0) }
    }

    private func setPrivate(_ on: Bool) {
        guard let transcriptID else { return }
        guard let service else {
            onError("watchtower CLI not found")
            return
        }
        isChangingPrivate = true
        Task {
            defer { isChangingPrivate = false }
            do {
                let result = try await service.setPrivate(transcriptID: transcriptID, on)
                onPrivateChanged(result.isPrivate)
            } catch {
                onError("Couldn't change Private: \(error.localizedDescription)")
            }
        }
    }

    /// The txt rendering, from the CLI's stdout, onto the pasteboard.
    private func copyTranscript() {
        guard let transcriptID else { return }
        guard let service else {
            onError("watchtower CLI not found")
            return
        }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let data = try await service.export(transcriptID: transcriptID, format: .txt)
                guard let text = String(bytes: data, encoding: .utf8) else {
                    onError("Couldn't copy the transcript: the export was not text")
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } catch {
                onError("Couldn't copy the transcript: \(error.localizedDescription)")
            }
        }
    }

    /// The owner picks the destination (the consent, no TCC prompt); the CLI
    /// writes the file there (0600).
    private func save(_ format: TranscriptExportFormat) {
        guard let transcriptID else { return }
        guard let service else {
            onError("watchtower CLI not found")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = format.suggestedFileName(title: transcript.title)
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            isExporting = true
            Task {
                defer { isExporting = false }
                do {
                    try await service.export(transcriptID: transcriptID, format: format, outputPath: url.path)
                } catch {
                    onError("Export failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
