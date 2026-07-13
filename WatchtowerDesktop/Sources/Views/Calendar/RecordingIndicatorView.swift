import SwiftUI

/// Global bottom-trailing overlay reflecting `MeetingRecorderCenter` state, so an
/// in-flight recording / transcription / summarization is visible from every
/// screen and survives navigation. Hidden only when idle with no recovered
/// recording pending.
struct RecordingIndicatorView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let center = appState.meetingRecorderCenter
        Group {
            switch center.phase {
            case .idle:
                if center.pendingAudioURL != nil {
                    recoveredPill(center)
                }
            case let .recording(startedAt):
                recordingCapsule(center, startedAt: startedAt)
            case let .transcribing(done, total):
                capsule {
                    ProgressView().controlSize(.small)
                    Text(total > 0 ? "Transcribing \(done)/\(total)" : "Transcribing…")
                        .font(.callout)
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
        .padding(16)
    }

    // MARK: - Phase content

    private func recordingCapsule(_ center: MeetingRecorderCenter, startedAt: Date) -> some View {
        capsule {
            Circle().fill(.red).frame(width: 10, height: 10)
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(Self.elapsed(from: startedAt, to: context.date))
                    .font(.callout.monospacedDigit())
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

    private func stop(_ center: MeetingRecorderCenter) {
        guard let runner = ProcessCLIRunner.makeDefault() else { return }
        Task { await center.stopAndProcess(runner: runner, config: .fromDefaults()) }
    }

    private func retry(_ center: MeetingRecorderCenter) {
        guard let runner = ProcessCLIRunner.makeDefault() else { return }
        Task { await center.retryTranscription(runner: runner, config: .fromDefaults()) }
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
