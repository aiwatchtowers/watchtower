import SwiftUI
import GRDB
import WatchtowerCore

/// The window's rendering state, derived from `DictationCenter`'s (shared,
/// app-wide) phase plus this VM's own local outcome — a pure function so the
/// derivation is testable without a real `DictationCenter`/mic/CLI. Kept
/// separate from `DictationPhase` because quick capture also needs states
/// `DictationCenter` has no notion of: it not having won the shared slot at
/// all, and the terminal (result/saved) states this VM alone tracks.
enum QuickCaptureState: Equatable {
    /// `start` was rejected — another target's dictation (or the meeting
    /// recorder) already owns the shared slot. `center.phase` in that case
    /// belongs to whatever DOES own it and must not be read as ours.
    case unavailable
    case loading
    case recording
    case paused
    /// Stop pressed — the buffered audio is being transcribed.
    case stopping
    case cleaning
    /// `raw` is `center.lastRaw` — present whenever something was actually
    /// transcribed before the failure (e.g. a cleanup failure), so the
    /// speech itself is never silently lost.
    case failed(message: String, raw: String?)
    case resultReady(DictationCleanResult)
    case saved(Int64)

    static func derive(
        ownsCapture: Bool,
        phase: DictationPhase,
        lastRaw: String?,
        result: DictationCleanResult?,
        savedIdeaID: Int64?
    ) -> Self {
        // A result or a saved id is this VM's own outcome — it stays true
        // regardless of what the shared center moved on to afterward (e.g.
        // `activeTargetID` already cleared once the dictation finished).
        if let savedIdeaID { return .saved(savedIdeaID) }
        if let result { return .resultReady(result) }
        guard ownsCapture else { return .unavailable }
        switch phase {
        case .idle: return .loading
        case .recording: return .recording
        case .paused: return .paused
        case .stopping: return .stopping
        case .cleaning: return .cleaning
        case .failed(let message): return .failed(message: message, raw: lastRaw)
        }
    }
}

/// Screen-local state for the tray "New Voice Idea" window. Deliberately NOT
/// an AppState center like `DictationCenter` — it owns nothing long-running,
/// only the save-as-idea step after dictation finishes, so it can live and
/// die with the window: closing it cancels the in-flight capture by design
/// (see `QuickCaptureView`'s `onDisappear`).
@MainActor
@Observable
final class QuickCaptureViewModel {
    static let targetID = "quick-capture"

    var liveText: String = ""
    var result: DictationCleanResult?
    var savedIdeaID: Int64?
    var error: String?

    private var center: DictationCenter?

    /// True once `start` actually won the shared dictation slot. False means
    /// another target (or the meeting recorder) already owns it — in which
    /// case `center.phase`/`activeTargetID` describe THAT capture, not this
    /// window's, and must never be acted on from here (the M1 fix-round
    /// bug: closing quick capture while another surface was dictating used
    /// to call `center.cancel()` unconditionally and kill it).
    var ownsCapture: Bool {
        center?.activeTargetID == Self.targetID
    }

    var state: QuickCaptureState {
        QuickCaptureState.derive(
            ownsCapture: ownsCapture,
            phase: center?.phase ?? .idle,
            lastRaw: center?.lastRaw,
            result: result,
            savedIdeaID: savedIdeaID
        )
    }

    /// Starts dictating into a fixed target id — one Quick Capture window can
    /// only ever run one capture, so there's no per-instance id to mint.
    /// `DictationCenter.start` is a no-op while another dictation (or the
    /// meeting recorder) already holds the slot — `ownsCapture` afterward is
    /// how the caller tells the two cases apart.
    func start(center: DictationCenter) {
        self.center = center
        // A reused window scene must not show a previous run's outcome
        // ("Saved ✓", an old result or error) over a hot mic.
        result = nil
        savedIdeaID = nil
        error = nil
        liveText = ""
        center.start(
            targetID: Self.targetID,
            mode: .idea,
            onLiveText: { [weak self] text in self?.liveText = text },
            onResult: { [weak self] result in self?.result = result }
        )
    }

    func stop() {
        guard ownsCapture else { return }
        center?.stop()
    }

    /// Pause/resume ride the same ownership gate as `stop()`/`cancel()` — a
    /// quick capture that never won the shared slot must not touch whichever
    /// capture did.
    func pause() {
        guard ownsCapture else { return }
        center?.pause()
    }

    func resume() {
        guard ownsCapture else { return }
        center?.resume()
    }

    /// Walks away from the capture entirely — the window-close path. Gated
    /// on ownership: a quick capture that never won the slot (or whose
    /// capture already finished and the slot moved to something else) must
    /// never touch another surface's in-flight dictation.
    func cancel() {
        guard ownsCapture else { return }
        center?.cancel()
    }

    /// Leaves a failed dictation and starts a fresh one in its place.
    func retry() {
        guard ownsCapture, let center else { return }
        center.retry()
        start(center: center)
    }

    /// Inserts the cleaned result as a manual, owner-authored idea. A nil or
    /// empty result (nothing dictated, or a cleanup that came back empty)
    /// inserts nothing and surfaces an error instead.
    func save(dbPool: DatabasePool) {
        guard let result else {
            error = "Nothing was dictated."
            return
        }
        insertIdea(text: result.text, title: result.title, dbPool: dbPool)
    }

    /// Saves whatever was transcribed before a cleanup (or later) failure —
    /// the "never lose the speech" fallback for the `.failed` state, using
    /// `center.lastRaw` since no `DictationCleanResult` was ever produced.
    func saveRaw(dbPool: DatabasePool) {
        guard let raw = center?.lastRaw else {
            error = "Nothing was dictated."
            return
        }
        insertIdea(text: raw, title: nil, dbPool: dbPool)
    }

    private func insertIdea(text: String, title: String?, dbPool: DatabasePool) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Nothing was dictated."
            return
        }
        let finalTitle = title ?? String(text.prefix(80))
        do {
            savedIdeaID = try dbPool.write { db in
                try IdeaQueries.createManual(db, kind: "idea", title: finalTitle, essence: text)
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
    /// The window scene id, shared by the `Window` declaration and every
    /// `openWindow` call site in `WatchtowerApp`.
    static let sceneID = "quick-capture"

    @Environment(\.dictationCenter) private var center
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var viewModel = QuickCaptureViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Voice Idea")
                .font(.headline)

            content

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

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .unavailable:
            unavailableState
        case .loading:
            loadingState(text: "Loading…")
        case .recording:
            recordingState
        case .paused:
            pausedState
        case .stopping:
            loadingState(text: "Transcribing…")
        case .cleaning:
            loadingState(text: "Cleaning up…")
        case let .failed(message, raw):
            failedState(message: message, raw: raw)
        case .resultReady(let result):
            resultPreview(result)
        case .saved(let ideaID):
            savedState(ideaID: ideaID)
        }
    }

    private var unavailableState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dictation is busy elsewhere — try again in a moment.")
                .foregroundStyle(.secondary)
            Button("Close") { dismiss() }
        }
    }

    private func loadingState(text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }

    private var recordingState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                if let center {
                    // The mic is already hot and buffering while the engine
                    // loads — loading presents as "already listening", and
                    // Stop still finalizes (buffered speech is delivered).
                    Text(center.isEngineLoading
                         ? "Loading model… speak freely, nothing is lost."
                         : "Listening…")
                        .foregroundStyle(.secondary)
                    MicLevelBars(level: center.micLevel)
                    timerText(center)
                } else {
                    Text("Listening…")
                        .foregroundStyle(.secondary)
                }
            }
            liveTextScroll
            HStack {
                Button("Pause") { viewModel.pause() }
                Button("Stop") { viewModel.stop() }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") {
                    viewModel.cancel()
                    dismiss()
                }
            }
        }
    }

    private var pausedState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pause.fill")
                    .foregroundStyle(.secondary)
                Text("Paused")
                    .foregroundStyle(.secondary)
                if let center {
                    timerText(center)
                }
            }
            liveTextScroll
            HStack {
                Button("Resume") { viewModel.resume() }
                Button("Stop") { viewModel.stop() }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") {
                    viewModel.cancel()
                    dismiss()
                }
            }
        }
    }

    private var liveTextScroll: some View {
        ScrollView {
            Text(viewModel.liveText.isEmpty ? "Say what's on your mind." : viewModel.liveText)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
    }

    /// The elapsed-time readout; paused time never ticks (`elapsed()` freezes
    /// while no recording span is open, so the 1 s tick cadence just
    /// re-renders the same label). The TimelineView only drives the refresh —
    /// the value itself comes from the center's monotonic clock.
    private func timerText(_ center: DictationCenter) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(DictationButton.timerLabel(center.elapsed()))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func failedState(message: String, raw: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .foregroundStyle(.red)
            if let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("What was captured before the failure:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(raw)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                Button("Save as idea") { saveRaw() }
                    .buttonStyle(.borderedProminent)
            }
            HStack {
                Button("Retry") { viewModel.retry() }
                Button("Close") { dismiss() }
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

    private func saveRaw() {
        guard let dbPool = appState.databaseManager?.dbPool else {
            viewModel.error = "No database available."
            return
        }
        viewModel.saveRaw(dbPool: dbPool)
    }
}
