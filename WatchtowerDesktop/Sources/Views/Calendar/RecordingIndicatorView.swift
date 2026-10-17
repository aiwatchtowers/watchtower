import SwiftUI
import WatchtowerCore

/// Shared chrome for every pill in the corner indicator stack. A free
/// function rather than a method, so `RecordingJobPill` renders the same capsule
/// without going through `RecordingIndicatorView`. `moveGesture` sits on the
/// capsule's background only: a press that starts on anything drawn over it —
/// Stop, the chevron, Retry — never reaches it, so a button can never lose
/// its click to a drag.
@ViewBuilder
private func indicatorCapsule<Content: View>(
    moveGesture: AnyGesture<Void>? = nil,
    @ViewBuilder _ content: () -> Content
) -> some View {
    HStack(spacing: 10) { content() }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            Capsule().fill(.regularMaterial)
                .contentShape(Capsule())
                .movesIndicator(moveGesture)
        }
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(radius: 8, y: 2)
}

private extension View {
    @ViewBuilder
    func movesIndicator(_ gesture: AnyGesture<Void>?) -> some View {
        if let gesture { self.gesture(gesture) } else { self }
    }
}

/// Global overlay reflecting `MeetingRecorderCenter` state, so an in-flight
/// recording / transcription / summarization is visible from every screen and
/// survives navigation. Hidden only when nothing is capturing, the queue is
/// empty, and nothing is waiting for the user.
///
/// It sits in one of the window's corners (`RecordingIndicatorCorner`, kept
/// across launches): dragging a pill by its capsule background moves the
/// stack, and on release it snaps to the corner nearest the pointer. Only
/// the backgrounds carry the drag, so every button keeps its clicks; the
/// expanded live panel carries none (a drag there selects transcript text).
///
/// Capture and post-processing are decoupled in the Center, so the stack renders
/// `captureState` and the `jobs` queue side by side (a recording capsule plus one
/// pill per queued/running/failed job) instead of the old single-slot `phase`
/// projection — which stays for the surfaces that genuinely show one thing at a
/// time (the "is THIS event recording" check, the stop reminder).
struct RecordingIndicatorView: View {
    @Environment(AppState.self) private var appState
    @State private var expanded = false
    @AppStorage("transcription.provider") private var transcriptionProvider = "whisperkit"
    @AppStorage(RecordingIndicatorCorner.storageKey) private var corner = RecordingIndicatorCorner.default
    /// The window's content size, which the release point is snapped in.
    var windowSize: CGSize = .zero
    /// Receives the space the window must keep free on the corner's edge
    /// while pills show (`RecordingIndicatorInset.reservedHeight`) and the
    /// stack's full extent, both 0 once the stack is empty.
    var onLayoutChange: (RecordingIndicatorLayout) -> Void = { _ in }
    /// The stack's offset while it is being dragged. A gesture state, so it
    /// returns to zero however the drag ends — released, or cancelled when
    /// the pill under the pointer goes away.
    @GestureState(resetTransaction: Transaction(animation: .snappy)) private var dragOffset = CGSize.zero
    @State private var stackHeight: CGFloat = 0
    /// Height of the model-download capsules drawn between the recorder
    /// pills and the window's edge, read only while one shows.
    @State private var provisionerHeight: CGFloat = 0

    private var layout: RecordingIndicatorLayout {
        let provisionerShown = !appState.transcriptionModelProvisioner.downloads.isEmpty
        let reserved = RecordingIndicatorInset.reservedHeight(
            stackHeight: stackHeight, expandedPanelShown: expandedPanelShown,
            belowPanelHeight: provisionerShown ? provisionerHeight : 0)
        return RecordingIndicatorLayout(reservedInset: reserved,
                                        occupiedHeight: RecordingIndicatorInset.occupiedHeight(stackHeight: stackHeight))
    }

    /// The same condition `recordingView` renders the expanded panel under.
    private var expandedPanelShown: Bool {
        let center = appState.meetingRecorderCenter
        guard case .recording = center.captureState else { return false }
        return expanded && showsLiveAffordance(center)
    }

    /// Whether the active capture has a live transcript to offer: the engine
    /// can produce one AND the capture opted in — the Center's start-time
    /// snapshot (`captureLiveEnabled`), never a live Settings read, so a
    /// mid-recording toggle can neither hide a pass that is still running nor
    /// dangle "Listening…" over a pass that was never started. When false,
    /// the recording shows only the plain capsule and the transcript appears
    /// after Stop.
    private func showsLiveAffordance(_ center: MeetingRecorderCenter) -> Bool {
        center.captureLiveEnabled
            && TranscriptionProviderRegistry.resolve(providerID: transcriptionProvider).supportsLive
    }

    var body: some View {
        let center = appState.meetingRecorderCenter
        let provisioner = appState.transcriptionModelProvisioner
        // Top to bottom in the corner's order (`RecordingIndicatorCorner.stackParts`).
        VStack(alignment: corner.horizontalAlignment, spacing: RecordingIndicatorInset.stackSpacing) {
            ForEach(corner.stackParts, id: \.self) { part in
                switch part {
                case .interrupted: interruptedContent(center)
                case .jobs: jobQueue(center)
                case .recording: recordingContent(center)
                case .downloads: provisionerContent(provisioner)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stackHeight = $0 }
        .onChange(of: layout, initial: true) { _, layout in onLayoutChange(layout) }
        .offset(dragOffset)
        .padding(RecordingIndicatorInset.outerPadding)
    }

    /// Moves the stack with the pointer and, on release, snaps it to the
    /// corner nearest the pointer. Carried by the pills' capsule backgrounds
    /// (`indicatorCapsule`); the minimum distance leaves a click on one a
    /// click.
    private var moveGesture: AnyGesture<Void> {
        AnyGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(RecordingIndicatorCorner.coordinateSpace))
                .updating($dragOffset) { value, offset, _ in offset = value.translation }
                .onEnded { value in
                    withAnimation(.snappy) { corner = corner.snapped(releasedAt: value.location, in: windowSize) }
                }
                .map { _ in () }
        )
    }

    /// A capture that failed, then the recordings recovered after a crash.
    @ViewBuilder
    private func interruptedContent(_ center: MeetingRecorderCenter) -> some View {
        if let message = center.captureError {
            captureFailedCapsule(center, message: message)
        }
        if !center.recoverable.isEmpty {
            recoveredPill(center)
        }
    }

    @ViewBuilder
    private func recordingContent(_ center: MeetingRecorderCenter) -> some View {
        if case let .recording(startedAt) = center.captureState {
            recordingView(center, startedAt: startedAt)
        }
    }

    /// The post-processing queue, oldest job first, with the running job always
    /// among the visible pills. Which failure the action buttons may act on is
    /// the Center's own answer (`retriableFailureID`/`dismissableFailureID`), so
    /// an enabled button always does something.
    @ViewBuilder
    private func jobQueue(_ center: MeetingRecorderCenter) -> some View {
        let split = Self.visibleJobs(center.jobs, activeID: center.activeJobID)
        let retriable = center.retriableFailureID
        let dismissable = center.dismissableFailureID
        ForEach(split.visible) { job in
            RecordingJobPill(
                title: job.title ?? "Recording",
                phase: job.phase,
                canRetry: job.id == retriable,
                canDismiss: job.id == dismissable,
                retry: { retry(center) },
                dismiss: { center.dismissFailure() },
                moveGesture: moveGesture)
        }
        if split.overflow > 0 {
            Text("+\(split.overflow) more").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// One pill per model download, running or failed (#744): the model,
    /// its size, the percent and the time left, or the failure with Retry.
    @ViewBuilder
    private func provisionerContent(_ provisioner: TranscriptionModelProvisioner) -> some View {
        if !provisioner.downloads.isEmpty {
            VStack(alignment: corner.horizontalAlignment, spacing: RecordingIndicatorInset.stackSpacing) {
                ForEach(provisioner.downloads) { download in
                    ModelDownloadPill(
                        download: download,
                        retry: { provisioner.retry(download.key) },
                        dismiss: { provisioner.dismiss(download.key) },
                        moveGesture: moveGesture)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { provisionerHeight = $0 }
        }
    }

    // MARK: - Phase content

    @ViewBuilder
    private func recordingView(_ center: MeetingRecorderCenter, startedAt: Date) -> some View {
        if showsLiveAffordance(center) && expanded {
            expandedPanel(center, startedAt: startedAt)
        } else {
            recordingCapsule(center, startedAt: startedAt)
        }
    }

    /// Compact mic + system level meters answering "is my mic alive" and "is
    /// system audio actually being captured" at a glance.
    @ViewBuilder
    private func captureLevelIndicators(_ center: MeetingRecorderCenter) -> some View {
        Image(systemName: "mic.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
        MicLevelBars(level: center.captureLevels.mic, barCount: 3)
            .help("Microphone level")
        Image(systemName: "speaker.wave.2.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
        MicLevelBars(level: center.captureLevels.system, barCount: 3)
            .help("System audio level")
        if center.callAudioSilentSince != nil {
            Label("No call audio", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help("Nothing has come from the call for over \(Int(CallAudioWatch.minGapSec / 60)) minutes. "
                    + "If people are still talking, the call's audio is not being recorded — \(callAudioOutputHint)")
        }
    }

    private func recordingCapsule(_ center: MeetingRecorderCenter, startedAt: Date) -> some View {
        indicatorCapsule(moveGesture: moveGesture) {
            Circle().fill(.red).frame(width: 10, height: 10)
            captureLevelIndicators(center)
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(Self.elapsed(from: startedAt, to: context.date))
                    .font(.callout.monospacedDigit())
            }
            if showsLiveAffordance(center) {
                liveEngineIndicator(center.liveEngineState)
                // The panel opens toward the window's interior.
                Button { expanded = true } label: { Image(systemName: corner.expandChevron) }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .help("Show live transcript")
            }
            Button {
                stop(center)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.destructivePrimary)
            .controlSize(.small)
        }
        // Ideal width, never compressed: a squeezed capsule blanked the Stop
        // label and pushed the button out past the capsule's (and the
        // window's) right edge.
        .fixedSize()
    }

    @ViewBuilder
    private func liveEngineIndicator(_ state: MeetingRecorderCenter.LiveEngineState) -> some View {
        switch state {
        case .off, .running: EmptyView()
        case .loading: ProgressView().controlSize(.small)
        case .waiting:
            ProgressView().controlSize(.small)
                .help("Waiting for the previous recording's transcription to finish — live transcript will catch up.")
        case .unavailable:
            Image(systemName: "text.badge.xmark").foregroundStyle(.secondary)
                .help("Live transcript unavailable — the transcription will appear after you stop.")
        }
    }

    private func expandedPanel(_ center: MeetingRecorderCenter, startedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 10, height: 10)
                captureLevelIndicators(center)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(Self.elapsed(from: startedAt, to: context.date)).font(.callout.monospacedDigit())
                }
                Spacer()
                Button { expanded = false } label: { Image(systemName: corner.collapseChevron) }
                    .buttonStyle(.plain).controlSize(.small)
                Button { stop(center) } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.destructivePrimary).controlSize(.small)
            }
            Divider()
            liveTranscriptBody(center)
        }
        .padding(14)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
        .shadow(radius: 8, y: 2)
    }

    @ViewBuilder
    private func liveTranscriptBody(_ center: MeetingRecorderCenter) -> some View {
        switch center.liveEngineState {
        case .loading:
            // A first recording waits for the model's download: say so, with
            // its progress, rather than a bare "Loading…" (#744).
            if let key = appState.meetingModelKey,
               let download = appState.transcriptionModelProvisioner.download(for: key),
               case .downloading = download.state {
                Text(download.progressLine(now: Date()) + ". The transcript starts once it lands.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Loading transcription model…").font(.callout).foregroundStyle(.secondary)
            }
        case .waiting:
            Text("Waiting for previous transcription… live transcript will catch up.")
                .font(.callout).foregroundStyle(.secondary)
        case .unavailable:
            Text("Live transcript unavailable — the transcription will appear after you stop.")
                .font(.callout).foregroundStyle(.secondary)
        case .off, .running:
            if center.liveChunks.isEmpty {
                Text("Listening…").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(center.liveChunks) { chunk in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(chunk.language)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                    Text(chunk.text).font(.callout).textSelection(.enabled)
                                }
                                .id(chunk.id)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 240)
                    .onChange(of: center.liveChunks.count) {
                        if let last = center.liveChunks.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }
        }
    }

    /// A capture that failed before any audio existed. No file, so no job and
    /// nothing to retry — the only action is dismissing the message.
    private func captureFailedCapsule(_ center: MeetingRecorderCenter, message: String) -> some View {
        indicatorCapsule(moveGesture: moveGesture) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording failed").font(.callout.weight(.medium))
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button("Dismiss") { center.dismissFailure() }
                .controlSize(.small)
                .disabled(!center.captureErrorDismissable)
                .help(center.captureErrorDismissable
                      ? "Clear this message"
                      : "Available once the running transcription finishes")
        }
        .frame(maxWidth: 380)
    }

    private func recoveredPill(_ center: MeetingRecorderCenter) -> some View {
        indicatorCapsule(moveGesture: moveGesture) {
            Image(systemName: "waveform.badge.exclamationmark")
                .foregroundStyle(.blue)
            Text(Self.recoveredLabel(count: center.recoverable.count)).font(.callout)
            // The Center acts on the oldest recovered recording only, so both
            // buttons take one at a time however many are listed.
            Button("Transcribe") { retry(center) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(center.isBusy)
                .help(center.isBusy
                      ? "Available once the current recording and queue settle"
                      : "Transcribe the oldest recovered recording")
            Button("Dismiss") { center.dismissRecovered() }
                .controlSize(.small)
                .disabled(center.isCapturing)
                .help(center.isCapturing
                      ? "Not while a recording is in progress"
                      : "Forget the oldest recovered recording")
        }
    }

    // MARK: - Actions

    // No CLI-runner guards here: stopping capture must never depend on the
    // watchtower binary resolving — the Center fails visibly at the save step
    // instead, with the audio kept.

    private func stop(_ center: MeetingRecorderCenter) {
        Task { await center.stopAndProcess(config: .fromDefaults()) }
    }

    private func retry(_ center: MeetingRecorderCenter) {
        Task { await center.retryTranscription(config: .fromDefaults()) }
    }

    // MARK: - Helpers

    /// How many job pills the stack shows before collapsing the tail into a
    /// "+N more" caption. The queue is normally one or two deep; the cap only
    /// keeps a pathological backlog from covering the window.
    static let maxVisibleJobPills = 3

    /// The job actually being worked comes first, then the queue fills the
    /// remaining slots in order. Plain FIFO order would be enough if failures
    /// left the queue, but they stay for retry — three stale failures at the
    /// head would push the running job out of sight, which is exactly when the
    /// user wants to see it.
    ///
    /// Which job that is comes from the Center (`activeJobID`), not from a
    /// phase: the queue claims a job before its first phase update, and with
    /// diarization off it can stay `.queued`-looking throughout. With nothing
    /// active yet, the job the queue will work next — the first non-failed one —
    /// leads instead. The promotion is unconditional, so crossing the visible
    /// cap never reshuffles the pills already on screen.
    static func visibleJobs(_ jobs: [MeetingRecorderCenter.ProcessingJob],
                            activeID: MeetingRecorderCenter.ProcessingJob.ID?)
        -> (visible: [MeetingRecorderCenter.ProcessingJob], overflow: Int) {
        let promoted = jobs.first { $0.id == activeID } ?? jobs.first { !$0.phase.isFailed }
        var visible = promoted.map { [$0] } ?? []
        for job in jobs where visible.count < maxVisibleJobPills {
            if job.id != promoted?.id { visible.append(job) }
        }
        return (visible, jobs.count - visible.count)
    }

    static func jobPhaseLabel(_ phase: MeetingRecorderCenter.ProcessingJob.Phase) -> String {
        switch phase {
        case .queued: return "Queued"
        case let .transcribing(done, total):
            return total > 0 ? "Transcribing \(done)/\(total)" : "Transcribing…"
        case .diarizing: return "Identifying speakers…"
        case .summarizing: return "Summarizing…"
        case .failed: return "Transcription failed"
        }
    }

    static func recoveredLabel(count: Int) -> String {
        count > 1 ? "Transcribe \(count) recovered recordings" : "Transcribe recovered recording"
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// One post-processing job in the indicator stack. Plain values + closures (no
/// `AppState`, no Center), so the queue rendering is testable on its own.
struct RecordingJobPill: View {
    let title: String
    let phase: MeetingRecorderCenter.ProcessingJob.Phase
    /// Whether the Center's single-slot retry/dismiss would act on *this* job;
    /// the buttons render disabled otherwise rather than silently no-opping.
    let canRetry: Bool
    let canDismiss: Bool
    let retry: () -> Void
    let dismiss: () -> Void
    /// Moves the stack when dragged by the pill's background.
    var moveGesture: AnyGesture<Void>?

    var body: some View {
        indicatorCapsule(moveGesture: moveGesture) {
            switch phase {
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(RecordingIndicatorView.jobPhaseLabel(phase)).font(.callout.weight(.medium))
                    titleText
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Button("Retry") { retry() }
                    .controlSize(.small)
                    .disabled(!canRetry)
                    .help(canRetry
                          ? "Run this recording through transcription again"
                          : "Available once the queue settles; recovered recordings take "
                            + "precedence; newest failure first")
                Button("Dismiss") { dismiss() }
                    .controlSize(.small)
                    .disabled(!canDismiss)
                    .help(canDismiss
                          ? "Keep the audio and stop showing this failure"
                          : "Available once the running transcription finishes; capture "
                            + "errors take precedence; newest failure first")
            case .queued:
                Image(systemName: "clock").foregroundStyle(.secondary)
                titleText
                Text("Queued").font(.callout).foregroundStyle(.secondary)
            case .transcribing, .diarizing, .summarizing:
                ProgressView().controlSize(.small)
                Text(RecordingIndicatorView.jobPhaseLabel(phase)).font(.callout)
                titleText
            }
        }
        .frame(maxWidth: 380)
    }

    private var titleText: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: 160, alignment: .leading)
    }
}

/// One model download in the indicator stack (#744). Plain values + closures,
/// like `RecordingJobPill`, so it renders without `AppState`.
struct ModelDownloadPill: View {
    let download: TranscriptionModelProvisioner.Download
    let retry: () -> Void
    let dismiss: () -> Void
    /// Moves the stack when dragged by the pill's background.
    var moveGesture: AnyGesture<Void>?

    var body: some View {
        indicatorCapsule(moveGesture: moveGesture) {
            switch download.state {
            case let .downloading(progress):
                ProgressView(value: progress).controlSize(.small).frame(width: 80)
                VStack(alignment: .leading, spacing: 2) {
                    Text(download.progressLine(now: Date())).font(.callout)
                    Text(ModelDownloadText.oneTimeNote).font(.caption).foregroundStyle(.secondary)
                }
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(download.label) download failed").font(.callout.weight(.medium))
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Button("Retry", action: retry)
                    .controlSize(.small)
                Button("Dismiss", action: dismiss)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: 420)
    }
}
