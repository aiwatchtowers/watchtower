import SwiftUI
import WatchtowerCore

/// Global top-aligned overlay: a countdown banner for the next meeting
/// starting within the reminder window, driven by
/// `MeetingReminderCenter.bannerEvent`. Mounted in `WatchtowerApp` beside
/// `RecordingIndicatorView` with a separate alignment (top vs bottomTrailing)
/// so the two never share a corner. In-app only — needs no notification
/// permission.
struct UpcomingMeetingBannerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let center = appState.meetingReminderCenter,
           let event = center.bannerEvent {
            banner(event: event, center: center)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func banner(event: CalendarEvent, center: MeetingReminderCenter) -> some View {
        let recorder = appState.meetingRecorderCenter
        return HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.countdownText(start: event.startDate, now: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if event.conferenceLink != nil {
                Button("Join") {
                    Task { await JoinMeetingAction.join(event: event, center: recorder) }
                    center.dismissBanner(event)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button {
                Task {
                    await recorder.startRecording(eventID: event.id, title: event.title, config: .fromDefaults())
                }
                center.dismissBanner(event)
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(recorder.isCapturing || !SystemAudioRecorder.isSupported)

            Button {
                center.dismissBanner(event)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    /// Live countdown to the meeting's start: "in m:ss" before it begins,
    /// "started" once it has (the banner lingers 5 minutes past start).
    static func countdownText(start: Date, now: Date) -> String {
        let remaining = Int(start.timeIntervalSince(now).rounded())
        guard remaining > 0 else { return "started" }
        return String(format: "in %d:%02d", remaining / 60, remaining % 60)
    }
}
