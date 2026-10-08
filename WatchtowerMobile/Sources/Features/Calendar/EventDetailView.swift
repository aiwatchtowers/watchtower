import SwiftUI
import WatchtowerKit

/// One event: the time line, attendees, the Prep card, linked targets
/// (read-only), the Recording section, and the bottom bar with Join and the
/// red Record this meeting.
struct EventDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    let eventID: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let model = EventDetailModel(
                eventID: eventID,
                snapshot: env.calendarReplica.snapshot,
                recordings: env.phoneRecordings.snapshot,
                now: context.date,
                calendar: .current
            ) {
                content(model)
            } else {
                ContentUnavailableView(
                    "Event not found",
                    systemImage: "calendar",
                    description: Text("It is no longer in your calendar on the Mac.")
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ model: EventDetailModel) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.title).font(.title3.weight(.semibold))
                    Text(model.whenLine).font(.subheadline).foregroundStyle(.secondary)
                }
                if let line = model.attendeesLine {
                    HStack(spacing: 10) {
                        HStack(spacing: -6) {
                            ForEach(model.attendees) { attendee in
                                Text(attendee.initials)
                                    .font(.caption2.weight(.semibold))
                                    .frame(width: 28, height: 28)
                                    .background(Color.secondary.opacity(0.2), in: Circle())
                                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                            }
                        }
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let description = model.description {
                    Text(description).font(.callout)
                }
            }
            Section("Prep") {
                if let empty = model.prepEmptyText {
                    Text(empty).foregroundStyle(.secondary)
                }
                ForEach(Array(model.prepBullets.enumerated()), id: \.offset) { _, bullet in
                    Label(bullet, systemImage: "circle.fill")
                        .labelStyle(BulletLabelStyle())
                }
                if let more = model.prepMoreText {
                    Text(more).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.linkedTargets.isEmpty {
                Section("Linked targets") {
                    ForEach(model.linkedTargets) { target in
                        HStack {
                            Text(target.text)
                            Spacer()
                            Text(target.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let more = model.linkedTargetsMoreText {
                        Text(more).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Recording") {
                if model.recordingPills.isEmpty {
                    Text(model.recordingText).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(model.recordingPills) { EventPillView(pill: $0) }
                    }
                    if model.recordingText != model.recordingPills.first?.text {
                        Text(model.recordingText).font(.callout)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar(model) }
    }

    @ViewBuilder
    private func bottomBar(_ model: EventDetailModel) -> some View {
        if !model.actionTitles.isEmpty {
            HStack(spacing: 10) {
                if let url = model.joinURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Join", systemImage: "video").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                if let meeting = model.meetingEvent {
                    Button {
                        Task { await env.recorder.recordMeeting(meeting) }
                    } label: {
                        Label("Record this meeting", systemImage: "record.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PhoneTone.red.color)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

/// A small dot before each prep bullet.
private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(.secondary)
            configuration.title
        }
    }
}
