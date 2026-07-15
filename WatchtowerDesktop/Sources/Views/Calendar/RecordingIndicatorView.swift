import SwiftUI

/// Global bottom-trailing overlay reflecting `MeetingRecorderCenter` state, so an
/// in-flight recording / transcription / summarization is visible from every
/// screen and survives navigation. Hidden only when idle with no recovered
/// recording pending.
struct RecordingIndicatorView: View {
    @Environment(AppState.self) private var appState
    @State private var expanded = false

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
        switch center.phase {
        case .idle:
            if center.pendingAudioURL != nil {
                recoveredPill(center)
            }
        case let .recording(startedAt):
            recordingView(center, startedAt: startedAt)
        case let .transcribing(done, total):
            capsule {
                ProgressView().controlSize(.small)
                Text(total > 0 ? "Transcribing \(done)/\(total)" : "Transcribing…")
                    .font(.callout)
            }
        case .diarizing:
            capsule {
                ProgressView().controlSize(.small)
                Text("Identifying speakers…").font(.callout)
            }
        case .summarizing:
            capsule {
                ProgressView().controlSize(.small)
                Text("Summarizing…").font(.callout)
            }
        case let .failed(message):
            failedCapsule(center, message: message)
        }
    }

    @ViewBuilder
    private func provisionerContent(_ provisioner: TranscriptionModelProvisioner) -> some View {
        switch provisioner.state {
        case .idle:
            EmptyView()
        case let .downloading(progress):
            capsule {
                ProgressView(value: progress).controlSize(.small).frame(width: 80)
                Text("Downloading model… \(Int(progress * 100))%").font(.callout)
            }
        case let .failed(message):
            modelFailedCapsule(provisioner, message: message)
        }
    }

    private func modelFailedCapsule(_ provisioner: TranscriptionModelProvisioner, message: String) -> some View {
        capsule {
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
        if expanded {
            expandedPanel(center, startedAt: startedAt)
        } else {
            recordingCapsule(center, startedAt: startedAt)
        }
    }

    private func recordingCapsule(_ center: MeetingRecorderCenter, startedAt: Date) -> some View {
        capsule {
            Circle().fill(.red).frame(width: 10, height: 10)
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(Self.elapsed(from: startedAt, to: context.date))
                    .font(.callout.monospacedDigit())
            }
            liveEngineIndicator(center.liveEngineState)
            Button { expanded = true } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain).controlSize(.small)
                .help("Show live transcript")
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
                                    Text(chunk.language).font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
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

    private func failedCapsule(_ center: MeetingRecorderCenter, message: String) -> some View {
        capsule {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Transcription failed").font(.callout.weight(.medium))
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button("Retry") { retry(center) }
                .controlSize(.small)
            Button("Dismiss") { center.dismissFailure() }
                .controlSize(.small)
        }
        .frame(maxWidth: 380)
    }

    private func recoveredPill(_ center: MeetingRecorderCenter) -> some View {
        capsule {
            Image(systemName: "waveform.badge.exclamationmark")
                .foregroundStyle(.blue)
            Text("Transcribe recovered recording").font(.callout)
            Button("Transcribe") { retry(center) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
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

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(radius: 8, y: 2)
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
