import SwiftUI

/// The shared copy of private recordings (docs/features/private-meetings.md,
/// MEETPRIV-01).
enum PrivateRecordingCopy {
    /// Shown wherever an AI action of a private recording would sit.
    static let notSentToAI = "Private recording — not sent to AI"
}

/// The lock beside a private recording's title (list row, detail header,
/// event section).
struct PrivateRecordingBadge: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(PrivateRecordingCopy.notSentToAI)
            .accessibilityLabel("Private recording")
    }
}

/// Stands in for the AI actions (recap, notes, chapters, follow-up, chat) of
/// a private recording.
struct PrivateRecordingNotice: View {
    var body: some View {
        Label(PrivateRecordingCopy.notSentToAI, systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// The indicator's lock toggle for a capture or a queued recording: locked =
/// saved private, nothing generated.
struct PrivateRecordingToggle: View {
    let isPrivate: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isPrivate ? "lock.fill" : "lock.open")
                .font(.caption2)
                .foregroundStyle(isPrivate ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help(isPrivate
              ? "Private: saved without a recap and never sent to AI. Click to make it a regular recording."
              : "Make this recording private: saved without a recap and never sent to AI")
        .accessibilityLabel(isPrivate ? "Make recording not private" : "Make recording private")
    }
}
