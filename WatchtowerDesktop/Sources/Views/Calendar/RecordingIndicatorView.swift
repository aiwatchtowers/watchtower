import SwiftUI

/// Shared chrome for every pill in the bottom-trailing indicator stack. A free
/// function rather than a method, so `RecordingJobPill` renders the same capsule
/// without going through `RecordingIndicatorView`.
@ViewBuilder
private func indicatorCapsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    HStack(spacing: 10) { content() }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(radius: 8, y: 2)
}

/// Global bottom-trailing overlay reflecting `MeetingRecorderCenter` state, so an
/// in-flight recording / transcription / summarization is visible from every
/// screen and survives navigation. Hidden only when nothing is capturing, the
/// queue is empty, and nothing is waiting for the user.
///
/// Capture and post-processing are decoupled in the Center, so the stack renders
/// `captureState` and the `jobs` queue side by side (a recording capsule plus one
/// pill per queued/running/failed job) instead of the old single-slot `phase`
/// projection — which stays for the `onChange` consumers elsewhere.
struct RecordingIndicatorView: View {
    @Environment(AppState.self) private var appState
    @State private var expanded = false
    @AppStorage("transcription.provider") private var transcriptionProvider = "whisperkit"

    /// Whether the currently-selected engine can produce a live transcript at
    /// all. When it cannot, the live-chunks panel/chevron affordance never
    /// makes sense (there is nothing to expand into) — the recording shows
    /// only the plain capsule, and the transcript appears after Stop.
    private var activeProviderSupportsLive: Bool {
        TranscriptionProviderRegistry.resolve(providerID: transcriptionProvider).supportsLive
    }

    var body: some View {
        let center = appState.meetingRecorderCenter
        let provisioner = appState.transcriptionModelProvisioner
        VStack(alignment: .trailing, spacing: 10) {
            recorderContent(center)
            provisionerContent(provisioner)
        }
        .padding(16)
    }

    @ViewBuilder
    private func recorderContent(_ center: MeetingRecorderCenter) -> some View {
        if let message = center.captureError {
            captureFailedCapsule(center, message: message)
        }
        if !center.recoverable.isEmpty {
            recoveredPill(center)
        }
        jobQueue(center)
        if case let .recording(startedAt) = center.captureState {
            recordingView(center, startedAt: startedAt)
        }
    }

    /// The post-processing queue, oldest job first — so the running head is
    /// always among the visible pills.
    @ViewBuilder
    private func jobQueue(_ center: MeetingRecorderCenter) -> some View {
        let split = Self.visibleJobs(center.jobs)
        let actionable = Self.actionableFailureID(center.jobs, isBusy: center.isBusy)
        ForEach(split.visible) { job in
            RecordingJobPill(
                title: job.title ?? "Recording",
                phase: job.phase,
                // `retryTranscription` takes a recovered recording ahead of any
                // job, and `dismissFailure` clears a capture error first — so
                // neither reaches the job while those stand.
                canRetry: job.id == actionable && center.recoverable.isEmpty,
                canDismiss: job.id == actionable && center.captureError == nil,
                retry: { retry(center) },
                dismiss: { center.dismissFailure() })
        }
        if split.overflow > 0 {
            Text("+\(split.overflow) more").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func provisionerContent(_ provisioner: TranscriptionModelProvisioner) -> some View {
        switch provisioner.state {
        case .idle:
            EmptyView()
        case let .downloading(progress):
            indicatorCapsule {
                ProgressView(value: progress).controlSize(.small).frame(width: 80)
                Text("Downloading model… \(Int(progress * 100))%").font(.callout)
            }
        case let .failed(message):
            modelFailedCapsule(provisioner, message: message)
        }
    }

    private func modelFailedCapsule(_ provisioner: TranscriptionModelProvisioner, message: String) -> some View {
        indicatorCapsule {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Model download failed").font(.callout.weight(.medium))
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button("Retry") { provisioner.retry() }
                .controlSize(.small)
            Button("Dismiss") { provisioner.dismiss() }
                .controlSize(.small)
        }
        .frame(maxWidth: 380)
    }

    // MARK: - Phase content

    @ViewBuilder
    private func recordingView(_ center: MeetingRecorderCenter, startedAt: Date) -> some View {
        if activeProviderSupportsLive && expanded {
            expandedPanel(center, startedAt: startedAt)
        } else {
            recordingCapsule(center, startedAt: startedAt)
        }
    }

    private func recordingCapsule(_ center: MeetingRecorderCenter, startedAt: Date) -> some View {
        indicatorCapsule {
            Circle().fill(.red).frame(width: 10, height: 10)
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(Self.elapsed(from: startedAt, to: context.date))
                    .font(.callout.monospacedDigit())
            }
            if activeProviderSupportsLive {
                liveEngineIndicator(center.liveEngineState)
                Button { expanded = true } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .help("Show live transcript")
            }
            Button {
                stop(center)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.red)
        }
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
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(Self.elapsed(from: startedAt, to: context.date)).font(.callout.monospacedDigit())
                }
                Spacer()
                Button { expanded = false } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain).controlSize(.small)
                Button { stop(center) } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.red)
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
            Text("Loading transcription model…").font(.callout).foregroundStyle(.secondary)
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
        indicatorCapsule {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording failed").font(.callout.weight(.medium))
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button("Dismiss") { center.dismissFailure() }
                .controlSize(.small)
                .disabled(center.isBusy)
                .help(center.isBusy
                      ? "Dismissable once the current recording and queue settle"
                      : "Clear this message")
        }
        .frame(maxWidth: 380)
    }

    private func recoveredPill(_ center: MeetingRecorderCenter) -> some View {
        indicatorCapsule {
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

    static func visibleJobs(_ jobs: [MeetingRecorderCenter.ProcessingJob])
        -> (visible: [MeetingRecorderCenter.ProcessingJob], overflow: Int) {
        (Array(jobs.prefix(maxVisibleJobPills)), max(0, jobs.count - maxVisibleJobPills))
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

    /// Job the Center's single-slot `retryTranscription`/`dismissFailure` pair
    /// would act on: the newest failure, and only while nothing is in flight
    /// (both no-op otherwise). Every other failed pill renders its buttons
    /// disabled rather than silently doing nothing — dismiss the newest failure
    /// and the one behind it becomes actionable in turn.
    static func actionableFailureID(_ jobs: [MeetingRecorderCenter.ProcessingJob],
                                    isBusy: Bool) -> MeetingRecorderCenter.ProcessingJob.ID? {
        guard !isBusy else { return nil }
        return jobs.last { $0.phase.isFailed }?.id
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

    var body: some View {
        indicatorCapsule {
            switch phase {
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcription failed").font(.callout.weight(.medium))
                    titleText
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Button("Retry") { retry() }
                    .controlSize(.small)
                    .disabled(!canRetry)
                    .help(canRetry
                          ? "Run this recording through transcription again"
                          : "Retry takes the newest failure first, and only while nothing is in flight")
                Button("Dismiss") { dismiss() }
                    .controlSize(.small)
                    .disabled(!canDismiss)
                    .help(canDismiss
                          ? "Keep the audio and stop showing this failure"
                          : "Dismiss takes the newest failure first, and only while nothing is in flight")
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
