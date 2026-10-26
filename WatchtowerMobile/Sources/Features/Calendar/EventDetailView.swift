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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(model)
                section("Prep") {
                    if let empty = model.prepEmptyText {
                        Text(empty).foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.prepBullets.enumerated()), id: \.offset) { _, bullet in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: PhoneMetrics.priorityDot, height: PhoneMetrics.priorityDot)
                                .accessibilityHidden(true)
                            Text(bullet).font(TypeScale.rowTitle)
                        }
                    }
                    if let more = model.prepMoreText {
                        Text(more).font(TypeScale.meta).foregroundStyle(.secondary)
                    }
                }
                if !model.linkedTargets.isEmpty {
                    section("Linked targets") {
                        ForEach(Array(model.linkedTargets.enumerated()), id: \.element.id) { index, target in
                            if index > 0 { CardRowDivider() }
                            HStack {
                                Text(target.text).font(TypeScale.rowTitle)
                                Spacer()
                                Text(target.status).font(TypeScale.meta).foregroundStyle(.secondary)
                            }
                        }
                        if let more = model.linkedTargetsMoreText {
                            Text(more).font(TypeScale.meta).foregroundStyle(.secondary)
                        }
                    }
                }
                section("Recording") { recording(model) }
            }
            .padding(.horizontal, Spacing.large)
            .padding(.bottom, Spacing.large)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar(model) }
    }

    private func header(_ model: EventDetailModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(model.title).font(TypeScale.screenTitle)
                Text(model.whenLine).font(.subheadline).foregroundStyle(.secondary)
            }
            if let line = model.attendeesLine {
                HStack(spacing: Spacing.cozy) {
                    // The line next to it says the same for VoiceOver.
                    HStack(spacing: -Spacing.compact) {
                        ForEach(model.attendees) { attendee in
                            Text(attendee.initials)
                                .font(TypeScale.kind)
                                .foregroundStyle(attendee.tone.color)
                                .frame(width: EventDetailMetrics.avatar, height: EventDetailMetrics.avatar)
                                .background(attendee.tone.color.opacity(ChipTint.fillOpacity), in: Circle())
                                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: Stroke.selection))
                        }
                    }
                    .accessibilityHidden(true)
                    Text(line).font(TypeScale.meta).foregroundStyle(.secondary)
                }
            }
            if let description = model.description {
                Text(description).font(TypeScale.rowTitle)
            }
        }
        .padding(.top, Spacing.regular)
        .padding(.horizontal, Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A caps header over one plain card; rows inside are flat.
    private func section<Body: View>(_ title: String, @ViewBuilder _ body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title)
            VStack(alignment: .leading, spacing: Spacing.regular) { body() }.card()
        }
    }

    @ViewBuilder
    private func recording(_ model: EventDetailModel) -> some View {
        if let percent = model.transcribingPercent {
            HStack(spacing: Spacing.regular) {
                Image(systemName: "waveform").foregroundStyle(PhoneTone.purple.color)
                Text(EventDetailModel.transcribingTitle).font(TypeScale.rowTitle)
                Spacer(minLength: Spacing.regular)
                ThinProgressBar(value: Double(percent) / 100, tone: .purple)
                    .frame(width: EventDetailMetrics.progressWidth)
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
                Text(model.recordingText).font(TypeScale.rowTitle)
            }
        }
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
                .buttonStyle(SecondaryActionStyle())
            }
        case .record:
            if let meeting = model.meetingEvent {
                RecordButton(fillsWidth: true) {
                    Task { await env.recorder.recordMeeting(meeting) }
                }
                .disabled(!env.canStartCapture)
            }
        case let .openRecap(id):
            // A link, not a calendarPath append: the event detail is also
            // pushed on Now's stack, and the recap opens on the stack it is on.
            NavigationLink(value: CalendarRoute.recap(id)) {
                Text(action.title)
            }
            .buttonStyle(ProminentActionStyle())
        }
    }
}

/// The event detail's own sizes, beside the parts' `PhoneMetrics`.
private enum EventDetailMetrics {
    static let avatar: CGFloat = 32
    static let progressWidth: CGFloat = 80
}
