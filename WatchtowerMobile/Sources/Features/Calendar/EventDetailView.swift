import SwiftUI
import WatchtowerKit

/// One event: the time line, attendees, the Prep card, linked targets
/// (read-only), the Recording section, and the bottom bar: Join and the red
/// Record, or Open recap once the event is over and has one.
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
                    Text(model.title).font(TypeScale.screenTitle)
                    Text(model.whenLine).font(.subheadline).foregroundStyle(.secondary)
                }
                if let line = model.attendeesLine {
                    HStack(spacing: 10) {
                        // The line next to it says the same for VoiceOver.
                        HStack(spacing: -6) {
                            ForEach(model.attendees) { attendee in
                                Text(attendee.initials)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(attendee.tone.color)
                                    .frame(width: 32, height: 32)
                                    .background(attendee.tone.color.opacity(0.2), in: Circle())
                                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                            }
                        }
                        .accessibilityHidden(true)
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
                if let percent = model.transcribingPercent {
                    HStack(spacing: Spacing.regular) {
                        Image(systemName: "waveform").foregroundStyle(PhoneTone.purple.color)
                        Text(EventDetailModel.transcribingTitle).font(.callout)
                        Spacer(minLength: Spacing.regular)
                        ThinProgressBar(value: Double(percent) / 100, tone: .purple)
                            .frame(width: 80)
                            .accessibilityHidden(true)
                        Text("\(percent)%").font(TypeScale.time)
                    }
                    .accessibilityElement(children: .combine)
                } else if model.recordingPills.isEmpty {
                    Text(model.recordingText).foregroundStyle(.secondary)
                } else {
                    FlowRow {
                        ForEach(model.recordingPills) { Pill(text: $0.text, tone: $0.tone) }
                    }
                    if model.recordingText != model.recordingPills.first?.text {
                        Text(model.recordingText).font(.callout)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar(model) }
    }

    @ViewBuilder
    private func bottomBar(_ model: EventDetailModel) -> some View {
        if !model.actions.isEmpty {
            BottomActionBar {
                HStack(spacing: Spacing.regular) {
                    ForEach(model.actions, id: \.self) { action in
                        actionButton(action, model)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: EventAction, _ model: EventDetailModel) -> some View {
        switch action {
        case .join:
            if let url = model.joinURL {
                Button {
                    openURL(url)
                } label: {
                    Label(action.title, systemImage: "video").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        case .record:
            if let meeting = model.meetingEvent {
                RecordButton(fillsWidth: true) {
                    Task { await env.recorder.recordMeeting(meeting) }
                }
            }
        case let .openRecap(id):
            Button(action.title) {
                env.navigation.calendarPath.append(.recap(id))
            }
            .buttonStyle(ProminentActionStyle())
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
