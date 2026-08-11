import SwiftUI
import GRDB

/// Screen-local state for the tray "New Voice Idea" window. Deliberately NOT
/// an AppState center like `DictationCenter` — it owns nothing long-running,
/// only the save-as-idea step after dictation finishes, so it can live and
/// die with the window: closing it cancels the in-flight capture by design
/// (see `QuickCaptureView`'s `onDisappear`).
@MainActor
@Observable
final class QuickCaptureViewModel {
    var liveText: String = ""
    var result: DictationCleanResult?
    var savedIdeaID: Int64?
    var error: String?

    private var center: DictationCenter?

    /// Starts dictating into a fixed target id — one Quick Capture window can
    /// only ever run one capture, so there's no per-instance id to mint.
    func start(center: DictationCenter) {
        self.center = center
        center.start(
            targetID: "quick-capture",
            mode: .idea,
            onLiveText: { [weak self] text in self?.liveText = text },
            onResult: { [weak self] result in self?.result = result }
        )
    }

    func stop() {
        center?.stop()
    }

    /// Walks away from the capture entirely — the window-close path.
    func cancel() {
        center?.cancel()
    }

    /// Inserts the cleaned result as a manual, owner-authored idea. A nil or
    /// empty result (nothing dictated, or a cleanup that came back empty)
    /// inserts nothing and surfaces an error instead.
    func save(dbPool: DatabasePool) {
        guard let result, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Nothing was dictated."
            return
        }
        let title = result.title ?? String(result.text.prefix(80))
        do {
            savedIdeaID = try dbPool.write { db in
                try IdeaQueries.createManual(db, kind: "idea", title: title, essence: result.text)
            }
        } catch {
            self.error = "Failed to save idea: \(error.localizedDescription)"
        }
    }
}

/// Compact floating window opened from the tray or the ⌃⌥D global hotkey:
/// dictation starts the instant the window appears, so speaking is the only
/// action quick capture asks for.
struct QuickCaptureView: View {
    @Environment(\.dictationCenter) private var center
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var viewModel = QuickCaptureViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Voice Idea")
                .font(.headline)

            if let savedIdeaID = viewModel.savedIdeaID {
                savedState(ideaID: savedIdeaID)
            } else if let result = viewModel.result {
                resultPreview(result)
            } else {
                recordingState
            }

            if let error = viewModel.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            guard let center else { return }
            viewModel.start(center: center)
        }
        .onDisappear {
            viewModel.cancel()
        }
        .onChange(of: viewModel.savedIdeaID) { _, savedIdeaID in
            // Confirmation is a courtesy, not a decision point — quick capture
            // is meant to be hands-free, so it closes itself a beat after a
            // successful save rather than waiting on the owner to dismiss it.
            guard savedIdeaID != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(2))
                dismiss()
            }
        }
    }

    private var recordingState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                Text("Listening…")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(viewModel.liveText.isEmpty ? "Say what's on your mind." : viewModel.liveText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            HStack {
                Button("Stop") { viewModel.stop() }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") {
                    viewModel.cancel()
                    dismiss()
                }
            }
        }
    }

    private func resultPreview(_ result: DictationCleanResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = result.title {
                Text(title).font(.subheadline.bold())
            }
            ScrollView {
                Text(result.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            HStack {
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                Button("Discard") { dismiss() }
            }
        }
    }

    private func savedState(ideaID: Int64) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved ✓")
                .foregroundStyle(.green)
            Button("Open Ideas") {
                // Same "leave the tray, come back as a normal app" move the
                // tray's own "Open Watchtower" action makes — quick capture
                // may have been triggered while the app had no visible window.
                ActivationPolicyDecision.becomeRegularAndActivate()
                openWindow(id: TrayAppDelegate.mainWindowSceneID)
                appState.selectedDestination = .ideas
                dismiss()
            }
        }
    }

    private func save() {
        guard let dbPool = appState.databaseManager?.dbPool else {
            viewModel.error = "No database available."
            return
        }
        viewModel.save(dbPool: dbPool)
    }
}
