import SwiftUI
import UIKit

/// The full-screen recorder (spec §13 C2): Minimize and the red REC mark,
/// "<Meeting> | No meeting", the label, a monospaced timer, the red
/// waveform, the lock-screen line, and Pause | Stop | Mark moment. After
/// Stop it turns into the Saved screen. Red is the recording colour
/// (spec §14).
struct RecordingView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let recorder = env.recorder
        VStack(spacing: 0) {
            switch recorder.phase {
            case let .saved(saved):
                RecordingSavedView(saved: saved)
            case .tooShort, .denied, .failed:
                RecordingEndedView()
            case .idle, .recording, .paused, .saving:
                RecordingCaptureView()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// The live capture.
private struct RecordingCaptureView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let recorder = env.recorder
        VStack(spacing: 20) {
            HStack {
                Button("Minimize") { recorder.minimize() }
                Spacer()
                if recorder.phase == .recording {
                    Label("REC", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.red)
                } else {
                    Text("PAUSED")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }

            if !recorder.contextOptions.isEmpty {
                Picker("Recording for", selection: Binding(
                    get: { recorder.context != .voiceNote },
                    set: { recorder.selectMeeting($0) }
                )) {
                    Text(recorder.contextOptions[0]).tag(true)
                    Text(recorder.contextOptions[1]).tag(false)
                }
                .pickerStyle(.segmented)
            }

            Text(recorder.contextLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 0)

            Text(recorder.timerText)
                .font(.system(size: 64, weight: .light, design: .monospaced))
                .monospacedDigit()
                .accessibilityLabel("Recorded \(recorder.timerText)")

            WaveformBars(levels: recorder.levels)
                .frame(height: 64)
                .accessibilityHidden(true)

            if let notice = recorder.capNotice {
                Text(notice)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
            }

            Text(recorder.statusLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 0)

            controls(recorder)
        }
    }

    private func controls(_ recorder: PhoneRecorderController) -> some View {
        HStack(alignment: .center, spacing: 36) {
            let paused = recorder.phase != .recording
            RoundButton(
                systemImage: paused ? "play.fill" : "pause.fill",
                label: paused ? "Resume" : "Pause",
                size: 64
            ) {
                if paused {
                    recorder.resume()
                } else {
                    recorder.pause()
                }
            }
            .disabled(!recorder.isCapturing)

            Button {
                Task { await recorder.stop() }
            } label: {
                ZStack {
                    Circle().fill(.red)
                    RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 30, height: 30)
                }
                .frame(width: 88, height: 88)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
            .disabled(!recorder.isCapturing)

            RoundButton(systemImage: "bookmark.fill", label: "Mark moment", size: 64) {
                recorder.markMoment()
            }
            .disabled(!recorder.isCapturing)
        }
        .padding(.bottom, 8)
    }
}

/// A round secondary control with its caption.
private struct RoundButton: View {
    let systemImage: String
    let label: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color(.secondarySystemFill)))
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The waveform: recent input levels as red bars, newest on the right.
private struct WaveformBars: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { proxy in
            let count = PhoneRecorderController.waveformBars
            let spacing: CGFloat = 3
            let width = max(1, (proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            let padded = Array(repeating: Float(0), count: max(0, count - levels.count)) + levels.suffix(count)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(padded.indices, id: \.self) { index in
                    Capsule()
                        .fill(.red.opacity(0.85))
                        .frame(width: width, height: max(3, proxy.size.height * CGFloat(padded[index])))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// After Stop: "Saved · mm:ss" and the recording's way to the Mac. The
/// heartbeat goes stale with time alone, so the steps re-render every
/// 30 s.
private struct RecordingSavedView: View {
    @Environment(AppEnvironment.self) private var env
    let saved: SavedRecording

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let snapshot = env.phoneRecordings.snapshot
            let recording = snapshot.recording(saved.id)
            VStack(alignment: .leading, spacing: 18) {
                Text("Saved · \(PhoneRecorderController.clockText(saved.durationSec))")
                    .font(.title2.weight(.semibold))
                    .padding(.top, 24)

                if let notice = env.recorder.endNotice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                StepRow(state: .done, text: "Saved on the phone")
                if let recording {
                    let upload = PhoneUploadStage(recording: recording, heartbeat: snapshot.heartbeat, now: context.date)
                    uploadStep(upload)
                    transcriptStep(PhoneTranscriptStage(job: snapshot.jobs[saved.id]))
                } else {
                    StepRow(state: .working, text: "Sending to your Mac")
                    StepRow(state: .todo, text: "Transcript and recap")
                }

                Text("Mac asleep? The file waits in iCloud; the Mac transcribes it when it wakes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    env.recorder.close()
                } label: {
                    Text("See recordings").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private func uploadStep(_ stage: PhoneUploadStage) -> some View {
        switch stage {
        case .recording, .sending: StepRow(state: .working, text: stage.label)
        case .waitingForMac: StepRow(state: .waiting, text: stage.label)
        case .delivered: StepRow(state: .done, text: stage.label)
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                StepRow(state: .failed, text: stage.label)
                if stage.offersRetry {
                    Button("Retry") {
                        Task { await env.recorder.retry(id: saved.id) }
                    }
                    .padding(.leading, 34)
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptStep(_ stage: PhoneTranscriptStage) -> some View {
        switch stage {
        case .notStarted: StepRow(state: .todo, text: "Transcript and recap")
        case let .inProgress(text): StepRow(state: .working, text: text)
        case .ready: StepRow(state: .done, text: "Transcript and recap ready")
        case let .failed(message): StepRow(state: .failed, text: message)
        }
    }
}

/// One step of the Saved screen.
private struct StepRow: View {
    enum State {
        case done, working, waiting, todo, failed
    }

    let state: State
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 22)
            Text(text)
                .foregroundStyle(state == .todo ? .secondary : .primary)
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .working: ProgressView()
        case .waiting: Image(systemName: "moon.zzz").foregroundStyle(.secondary)
        case .todo: Image(systemName: "circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }
}

/// A stop that saved nothing (too short), a denied microphone, or a
/// start/save failure.
private struct RecordingEndedView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let recorder = env.recorder
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: recorder.phase == .tooShort ? "waveform.slash" : "mic.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(recorder.statusLine)
                .font(.headline)
                .multilineTextAlignment(.center)
            if recorder.phase == .denied, let settings = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: settings)
            }
            Spacer()
            Button {
                recorder.close()
            } label: {
                Text("Close").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}

/// The bar above the tabs while a minimized capture runs: tap to return.
struct RecordingMiniBar: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let recorder = env.recorder
        Button {
            recorder.reopen()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill").font(.caption2)
                Text(recorder.phase == .recording ? "REC" : "PAUSED").font(.footnote.weight(.bold))
                Text(recorder.timerText).font(.footnote.monospacedDigit())
                Spacer()
                Text("Return").font(.footnote)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.red)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recording \(recorder.timerText). Return to the recorder")
    }
}
