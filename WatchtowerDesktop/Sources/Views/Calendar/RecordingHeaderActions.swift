import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WatchtowerCore

/// The recording detail header's **Private** toggle and **Export** menu
/// (docs/features/private-meetings.md). Both go through the CLI: `transcript
/// private <id> on|off` and `transcript export` to stdout — the renderers live
/// in Go only; the app writes a saved file itself. The runs, their failures
/// and the success line live in `RecordingActionsCenter`, so they survive
/// navigation; the host shows them.
struct RecordingHeaderActions: View {
    let transcript: MeetingTranscript
    /// Whether the row has timed segments; SRT needs them.
    let hasSegments: Bool
    /// False once every utterance is deleted: there is nothing to export.
    let hasContent: Bool
    let center: RecordingActionsCenter
    /// The row's flag as stored now (nil: no row), read back after a failed
    /// change.
    let readPrivate: @Sendable () async throws -> Bool?
    /// The flag landed (the CLI answered), even after the owner moved on.
    let onPrivateChanged: (Bool) -> Void
    /// No CLI to run.
    let onError: (String) -> Void

    @State private var confirmPrivate = false

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
            .disabled(transcriptID.map { center.changingPrivate.contains($0) } ?? true)
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
            .disabled(!hasContent || (transcriptID.map { center.exporting.contains($0) } ?? true))
            .help(!hasContent ? "Nothing to export: every utterance is deleted"
                  : hasSegments ? "Copy or save the transcript" : "Copy or save the transcript (subtitles need timings)")
        }
    }

    // MARK: - Actions

    /// nil (after telling the owner) when the CLI is missing.
    private func cliService() -> TranscriptSaveService? {
        guard let runner = ProcessCLIRunner.makeDefault() else {
            onError("watchtower CLI not found")
            return nil
        }
        return TranscriptSaveService(runner: runner)
    }

    private func setPrivate(_ on: Bool) {
        guard let transcriptID, let service = cliService() else { return }
        center.setPrivate(transcriptID: transcriptID, on, service: service, readPrivate: readPrivate) {
            onPrivateChanged($0)
        }
    }

    private func copyTranscript() {
        guard let transcriptID, let service = cliService() else { return }
        center.copyTranscript(transcriptID: transcriptID, service: service)
    }

    /// The owner picks the destination; the center writes the CLI's rendering
    /// there from the app process.
    private func save(_ format: TranscriptExportFormat) {
        guard let transcriptID, let service = cliService() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = format.suggestedFileName(title: transcript.title)
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            center.save(transcriptID: transcriptID, format: format, to: url, service: service)
        }
    }
}
