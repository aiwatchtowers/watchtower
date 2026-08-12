import SwiftUI
import WatchtowerCore

/// Play/pause + scrubber control for a transcript's recorded audio. Takes the
/// shared `AudioPlaybackCenter` explicitly (not via `@Environment`) so it is a
/// self-contained, independently testable unit.
struct AudioPlayerControlView: View {
    let transcriptID: Int64
    let audioURL: URL
    /// The transcript's persisted duration (seconds), shown/used as the scrubber's
    /// range before playback starts — `center.duration` is 0 until this row's
    /// `AVAudioPlayer` has loaded, which would otherwise make the slider
    /// un-draggable (range `0...0.01`) on a row that hasn't been played yet.
    let knownDuration: TimeInterval
    let center: AudioPlaybackCenter

    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    private var isActive: Bool { center.activeTranscriptID == transcriptID }
    private var hasFailed: Bool { center.failedTranscriptID == transcriptID }
    private var displayedDuration: TimeInterval { isActive ? center.duration : knownDuration }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    togglePlay()
                } label: {
                    Image(systemName: isActive && center.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help(isActive && center.isPlaying ? "Pause" : "Play")

                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubTime : (isActive ? center.currentTime : 0) },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(displayedDuration, 0.01),
                    onEditingChanged: handleScrub
                )

                Text(timeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if hasFailed, let message = center.errorMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var timeLabel: String {
        let elapsed = isActive ? center.currentTime : 0
        return "\(formatSeconds(elapsed)) / \(formatSeconds(displayedDuration))"
    }

    private func togglePlay() {
        if isActive {
            if center.isPlaying {
                center.pause()
            } else {
                center.resume()
            }
        } else {
            center.play(url: audioURL, transcriptID: transcriptID)
        }
    }

    private func handleScrub(_ editing: Bool) {
        isScrubbing = editing
        guard !editing else { return }
        if !isActive {
            center.play(url: audioURL, transcriptID: transcriptID)
        }
        center.seek(to: scrubTime)
    }

    private func formatSeconds(_ value: TimeInterval) -> String {
        let total = Int(value.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Audio control for a transcript row, or an explanatory caption when the
/// retention sweep already deleted the source file (`audioPath == nil`).
/// Shared by `TranscriptSectionView` (event-linked) and `CalendarEventsView`
/// (ad-hoc) so the conditional isn't duplicated at each call site.
struct TranscriptAudioControl: View {
    let transcript: MeetingTranscript
    let center: AudioPlaybackCenter

    var body: some View {
        if let id = transcript.id, let audioPath = transcript.audioPath {
            AudioPlayerControlView(
                transcriptID: id,
                audioURL: URL(fileURLWithPath: audioPath),
                knownDuration: TimeInterval(transcript.durationSec),
                center: center
            )
        } else if transcript.audioPath == nil {
            Text("Recording deleted")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
