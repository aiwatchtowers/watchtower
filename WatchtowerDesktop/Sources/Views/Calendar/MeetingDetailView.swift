import SwiftUI

/// Right-hand detail pane for one resolved `MeetingListEntry` in the unified
/// Meetings screen: an `.event` entry renders its header (prep/join/record/
/// calendar-link affordances) plus a recordings selector with the chosen
/// recording embedded below; a `.recording` entry renders `RecordingDetailView`
/// directly, full pane. "Prepare" pane-swaps to `MeetingPrepDetailView`
/// (unchanged, owns its own scrolling — never nested inside another
/// ScrollView, the `SituationDiscussInputBar` house gotcha).
struct MeetingDetailView: View {
    let entry: MeetingListEntry
    @Bindable var prepVM: MeetingPrepViewModel
    @Binding var userNotes: String
    let onDeleted: () -> Void
    let onChanged: () -> Void
    let onOpenEvent: (CalendarQueries.EventLink) -> Void

    @Environment(AppState.self) private var appState
    @State private var showPrep = false
    @State private var selectedRecordingID: Int64?
    /// Full-agenda expansion of the header's description preview. Resets on
    /// entry switch via the host's `.id(entry.id)` wrapper (view recreated).
    @State private var descriptionExpanded = false

    var body: some View {
        switch entry.kind {
        case let .event(event, recordings):
            if showPrep {
                MeetingPrepDetailView(
                    eventID: event.id,
                    viewModel: prepVM,
                    userNotes: $userNotes
                ) { showPrep = false }
            } else {
                eventPane(event, recordings: recordings)
            }
        case .recording(let item):
            RecordingDetailView(
                transcriptID: item.id, onDeleted: onDeleted, onChanged: onChanged, onOpenEvent: onOpenEvent)
        }
    }

    // MARK: - Pure helpers (testable without mounting a view)

    /// Record affordance must not render for a meeting that has already ended.
    static func showsRecordButton(for event: CalendarEvent, now: Date) -> Bool {
        event.endDate > now
    }

    /// Whether the collapsed 3-line description preview hides content, i.e.
    /// a "Show more" toggle is warranted. Exact truncation depends on pane
    /// width, so this is a deliberate heuristic: estimate rendered lines at a
    /// conservative ~70 characters per wrapped line (caption font at the
    /// pane's 400pt minWidth) — every source line consumes at least one clamp
    /// line, a long one its wrapped count — and toggle once the estimate
    /// exceeds the 3-line clamp. The inputs compose (rather than a source-line
    /// count OR a flat length threshold) so that short lines plus one long
    /// paragraph still get their toggle.
    static func descriptionNeedsToggle(_ plain: String) -> Bool {
        let estimatedLines = plain.components(separatedBy: "\n")
            .reduce(0) { $0 + max(1, ($1.count + 69) / 70) }
        return estimatedLines > 3
    }

    /// The transcript id `MeetingDetailView` would embed for `entry` given the
    /// current `selectedRecordingID` state: an explicit selection wins, an
    /// unset selection falls back to `MeetingListBuilder.defaultRecordingID`
    /// for an `.event` entry, and a `.recording` entry always resolves to its
    /// own id regardless of `selectedRecordingID`.
    static func embeddedTranscriptID(entry: MeetingListEntry, selectedRecordingID: Int64?) -> Int64? {
        switch entry.kind {
        case .event(_, let recordings):
            return selectedRecordingID ?? MeetingListBuilder.defaultRecordingID(recordings)
        case .recording(let item):
            return item.id
        }
    }

    // MARK: - Event pane

    private func eventPane(_ event: CalendarEvent, recordings: [RecordingListItem]) -> some View {
        VStack(spacing: 0) {
            header(event)
            recordingsSelector(recordings)

            if let id = Self.embeddedTranscriptID(entry: entry, selectedRecordingID: selectedRecordingID) {
                RecordingDetailView(
                    transcriptID: id, onDeleted: onDeleted, onChanged: onChanged, onOpenEvent: onOpenEvent)
            } else {
                Spacer()
            }
        }
        // The host wraps this view in `.id(entry.id)` (`CalendarEventsView`),
        // so switching entries recreates the view and re-runs `.onAppear` —
        // no `.onChange(of: entry.id)` reseed is needed alongside it.
        .onAppear { selectedRecordingID = MeetingListBuilder.defaultRecordingID(recordings) }
    }

    // MARK: - Header

    private func header(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(event.title)
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(event.formattedTimeRange)
                Text(event.durationText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            attendeesDisclosure(event)

            let plain = event.plainDescription
            if !plain.isEmpty {
                Text(plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(descriptionExpanded ? nil : 3)
                    .textSelection(.enabled)
                if Self.descriptionNeedsToggle(plain) {
                    Button(descriptionExpanded ? "Show less" : "Show more") {
                        descriptionExpanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.blue)
                }
            }

            HStack(spacing: 8) {
                Button {
                    showPrep = true
                    prepVM.generate(eventID: event.id)
                } label: {
                    Label("Prepare", systemImage: "doc.text.magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if event.conferenceLink != nil {
                    joinButton(event)
                }

                if Self.showsRecordButton(for: event, now: Date()) {
                    MeetingRecordButton(eventID: event.id, title: event.title)
                }

                if let eventURL = URL(string: event.htmlLink), !event.htmlLink.isEmpty {
                    Link(destination: eventURL) {
                        Label("Open in Google Calendar", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func attendeesDisclosure(_ event: CalendarEvent) -> some View {
        let attendees = event.parsedAttendees
        if !attendees.isEmpty {
            DisclosureGroup("\(attendees.count) attendees") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(attendees) { a in
                        HStack(spacing: 4) {
                            Image(systemName: responseIcon(a.responseStatus))
                                .font(.caption2)
                                .foregroundStyle(responseColor(a.responseStatus))
                            Text(a.displayName.isEmpty ? a.email : a.displayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 2)
            }
            .font(.caption)
        }
    }

    private func responseIcon(_ status: String) -> String {
        switch status {
        case "accepted": return "checkmark.circle.fill"
        case "tentative": return "questionmark.circle"
        case "declined": return "xmark.circle"
        default: return "circle"
        }
    }

    private func responseColor(_ status: String) -> Color {
        switch status {
        case "accepted": return .green
        case "tentative": return .orange
        case "declined": return .red
        default: return .secondary
        }
    }

    // MARK: - Join Button

    /// Opens the event's conference link and (per the "Auto-record on join"
    /// setting) starts an event-linked recording via the shared
    /// `JoinMeetingAction`. Prominent while the meeting is imminent/ongoing.
    @ViewBuilder
    private func joinButton(_ event: CalendarEvent) -> some View {
        JoinButton(event: event,
                   center: appState.meetingRecorderCenter,
                   prominent: event.isUpcoming || event.isHappeningNow)
    }

    // MARK: - Recordings selector

    @ViewBuilder
    private func recordingsSelector(_ recordings: [RecordingListItem]) -> some View {
        if recordings.isEmpty {
            Text("No recordings")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        } else if recordings.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(recordings) { item in
                        recordingChip(item)
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 8)
        }
    }

    private func recordingChip(_ item: RecordingListItem) -> some View {
        let isSelected = selectedRecordingID == item.id
        return Button {
            selectedRecordingID = item.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(TranscriptFormatting.formattedDate(item.createdAt))
                    .font(.caption2)
                HStack(spacing: 4) {
                    Text(TranscriptFormatting.formatDuration(item.durationSec))
                    TranscriptLangBadges(langStatsJSON: item.langStats)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
