import SwiftUI

/// Presentation-only "Linked to:" line in the recording-detail header, split
/// from `RecordingDetailView` for testability. Rendered only when the
/// transcript carries an `event_id`:
/// - resolvable event + navigation available → tappable deep-link button
///   (the host guarantees the tap lands: it pins the event's day into the
///   Events window before expanding);
/// - resolvable event, no navigation (`onOpenEvent == nil`) → the same text
///   as a plain non-tappable label;
/// - event row pruned by sync retention (`linkedEvent == nil`) → plain
///   "Linked to a past event" label — never an error, never navigation.
struct LinkedEventHeader: View {
    /// Resolved link, nil when the event row no longer exists.
    let linkedEvent: CalendarQueries.EventLink?
    /// Navigate to the Events tab with this event expanded; nil hides the
    /// navigation affordance (the text stays informational).
    let onOpenEvent: ((CalendarQueries.EventLink) -> Void)?

    var body: some View {
        if let linkedEvent {
            if let onOpenEvent {
                Button {
                    onOpenEvent(linkedEvent)
                } label: {
                    label(linkedEvent)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help("Show this event in the Events tab")
            } else {
                label(linkedEvent)
                    .foregroundStyle(.secondary)
            }
        } else {
            Label("Linked to a past event", systemImage: "calendar")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func label(_ link: CalendarQueries.EventLink) -> some View {
        Label(Self.title(for: link), systemImage: "calendar")
            .font(.caption)
            .lineLimit(1)
    }

    /// Header text; a schema-default empty title falls back to a placeholder
    /// so the line never renders "Linked to:  · <date>".
    static func title(for link: CalendarQueries.EventLink) -> String {
        let title = link.title.isEmpty ? "(untitled event)" : link.title
        return "Linked to: \(title) · \(TranscriptFormatting.formattedDate(link.startTime))"
    }
}
