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
        .padding(.horizontal, Spacing.page)
        .padding(.vertical, Spacing.medium)
    }
}

/// The live capture.
private struct RecordingCaptureView: View {
    @Environment(AppEnvironment.self) private var env
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize = RecorderMetrics.timer

    var body: some View {
        let recorder = env.recorder
        let chrome = RecorderChrome(phase: recorder.phase)
        VStack(spacing: Spacing.page) {
            HStack {
                Button("Minimize") { recorder.minimize() }
                Spacer()
                if let chrome {
                    markView(chrome)
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
                .font(TypeScale.screenTitle)
                .multilineTextAlignment(.center)

            // A capture for another hub than the one on screen names its Mac.
            if let hubName = env.captureHubName {
                Text("Recording for \(hubName)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PhoneTone.red.color)
            }

            Spacer(minLength: 0)

            Text(recorder.timerText)
                .font(.system(size: timerSize, weight: .light, design: .monospaced))
                .monospacedDigit()
                .accessibilityLabel("Recorded \(recorder.timerText)")

            WaveformBars(levels: recorder.levels)
                .frame(height: RecorderMetrics.waveformHeight)
                .accessibilityHidden(true)

            if let notice = recorder.capNotice {
                Text(notice)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PhoneTone.red.color)
            }

            Text(recorder.statusLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 0)

            if let chrome {
                controls(recorder, chrome)
            }
        }
    }

    @ViewBuilder
    private func markView(_ chrome: RecorderChrome) -> some View {
        switch chrome.mark {
        case .recording:
            Label(chrome.markText, systemImage: "circle.fill")
                .labelStyle(.titleAndIcon)
                .font(TypeScale.kind)
                .foregroundStyle(chrome.markTone.color)
        case .starting:
            HStack(spacing: Spacing.compact) {
                ProgressView().controlSize(.small)
                Text(chrome.markText)
            }
            .font(TypeScale.kind)
            .foregroundStyle(chrome.markTone.color)
        case .paused, .saving:
            Text(chrome.markText)
                .font(TypeScale.kind)
                .foregroundStyle(chrome.markTone.color)
        }
    }

    private func controls(_ recorder: PhoneRecorderController, _ chrome: RecorderChrome) -> some View {
        HStack(alignment: .top, spacing: RecorderMetrics.controlGap) {
            RoundButton(systemImage: chrome.leftSystemImage, label: chrome.leftTitle, size: RecorderMetrics.round) {
                if chrome.resumes {
                    recorder.resume()
                } else {
                    recorder.pause()
                }
            }
            .disabled(!chrome.isLeftEnabled)

            Button {
                Task { await recorder.stop() }
            } label: {
                VStack(spacing: Spacing.compact) {
                    ZStack {
                        Circle().fill(PhoneTone.red.color)
                        RoundedRectangle(cornerRadius: Radius.control)
                            .fill(.white)
                            .frame(width: RecorderMetrics.stopGlyph, height: RecorderMetrics.stopGlyph)
                    }
                    .frame(width: RecorderMetrics.stop, height: RecorderMetrics.stop)
                    Text("Stop").font(TypeScale.meta).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
            .disabled(!chrome.areCaptureControlsEnabled)

            RoundButton(systemImage: "bookmark.fill", label: "Mark moment", size: RecorderMetrics.round) {
                recorder.markMoment()
            }
            .disabled(!chrome.areCaptureControlsEnabled)
        }
        .padding(.bottom, Spacing.regular)
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
            VStack(spacing: Spacing.compact) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Fill.card))
                    .overlay(Circle().strokeBorder(Stroke.hairlineColor, lineWidth: Stroke.hairline))
                Text(label)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The waveform: recent input levels, newest on the right; silence is a grey line (`WaveformStyle`).
private struct WaveformBars: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { proxy in
            let count = PhoneRecorderController.waveformBars
            let spacing = RecorderMetrics.barGap
            let width = max(1, (proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            let padded = Array(repeating: Float(0), count: max(0, count - levels.count)) + levels.suffix(count)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(padded.indices, id: \.self) { index in
                    Capsule()
                        .fill(
                            WaveformStyle.isSilent(padded[index])
                                ? AnyShapeStyle(HierarchicalShapeStyle.quaternary)
                                : AnyShapeStyle(PhoneTone.red.color.opacity(RecorderMetrics.barOpacity))
                        )
                        .frame(width: width, height: WaveformStyle.height(padded[index], in: proxy.size.height))
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
            VStack(alignment: .leading, spacing: Spacing.large) {
                Text("Saved · \(PhoneRecorderController.clockText(saved.durationSec))")
                    .font(TypeScale.pageTitle)
                    .padding(.top, Spacing.wide)

                if let notice = env.recorder.endNotice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(PhoneTone.red.color)
                }
                VStack(alignment: .leading, spacing: 0) {
                    StepRow(state: .done, text: "Saved on the phone")
                    if let recording {
                        let upload = PhoneUploadStage(recording: recording, heartbeat: snapshot.heartbeat, now: context.date)
                        uploadStep(upload)
                        transcriptStep(PhoneTranscriptStage(job: snapshot.jobs[saved.id]))
                    } else {
                        StepRow(state: .current, text: "Sending to your Mac")
                        StepRow(state: .todo, text: "Transcript and recap")
                    }
                }
                .card()

                Text("Mac asleep? The file waits in iCloud; the Mac transcribes it when it wakes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("See recordings") { env.showRecordings() }
                    .buttonStyle(ProminentActionStyle())
            }
        }
    }

    @ViewBuilder
    private func uploadStep(_ stage: PhoneUploadStage) -> some View {
        switch stage {
        case .recording, .sending: StepRow(state: .current, text: stage.label)
        case .waitingForMac: StepRow(state: .waiting, text: stage.label)
        case .delivered: StepRow(state: .done, text: stage.label)
        case .failed:
            VStack(alignment: .leading, spacing: Spacing.regular) {
                StepRow(state: .failed, text: stage.label)
                if stage.offersRetry {
                    Button("Retry") {
                        Task { await env.recorder.retry(id: saved.id) }
                    }
                    .padding(.leading, PhoneMetrics.stepColumn + Spacing.medium)
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptStep(_ stage: PhoneTranscriptStage) -> some View {
        switch stage {
        case .notStarted: StepRow(state: .todo, text: "Transcript and recap")
        case let .inProgress(text): StepRow(state: .current, text: text)
        case .ready: StepRow(state: .done, text: "Transcript and recap ready")
        case let .failed(message): StepRow(state: .failed, text: message)
        }
    }
}

/// A stop that saved nothing (too short), a denied microphone, or a
/// start/save failure.
private struct RecordingEndedView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let recorder = env.recorder
        VStack(spacing: Spacing.large) {
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
            Button("Close") { recorder.close() }
                .buttonStyle(SecondaryActionStyle())
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
            HStack(spacing: Spacing.regular) {
                Image(systemName: "circle.fill").font(.caption2)
                Text(recorder.phase == .recording ? "REC" : "PAUSED").font(.footnote.weight(.bold))
                Text(recorder.timerText).font(.footnote.monospacedDigit())
                if let hubName = env.captureHubName {
                    Text("for \(hubName)").font(.footnote).lineLimit(1)
                }
                Spacer()
                Text("Return").font(.footnote)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.cozy)
            .background(PhoneTone.red.color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            env.captureHubName.map { "Recording for \($0), \(recorder.timerText). Return to the recorder" }
                ?? "Recording \(recorder.timerText). Return to the recorder"
        )
    }
}

/// The recorder's own sizes (mockup 14: calm and big), beside `PhoneMetrics`.
private enum RecorderMetrics {
    /// The timer's base size; scales with Dynamic Type.
    static let timer: CGFloat = 64
    static let waveformHeight: CGFloat = 64
    static let barGap: CGFloat = 3
    static let barOpacity = 0.85
    /// Pause and Mark moment.
    static let round: CGFloat = 64
    /// Stop and its white square.
    static let stop: CGFloat = 88
    static let stopGlyph: CGFloat = 30
    static let controlGap: CGFloat = 36
}
