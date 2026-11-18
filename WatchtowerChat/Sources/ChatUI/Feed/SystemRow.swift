import SwiftUI
import WatchtowerDesign

/// A row that is not a message: "Load earlier messages", a stale or gone line, a notice.
struct SystemRow: View {
    static let earlierLabel = "Load earlier messages"

    enum Kind {
        case earlier(onLoad: () -> Void)
        case line(String)
        case notice(String)
    }

    let kind: Kind
    @Environment(\.chatUIStyle) private var style

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            switch kind {
            case .earlier(let onLoad):
                style.secondaryButton(Self.earlierLabel, action: onLoad)
            case .line(let text):
                Text(text).font(.caption).foregroundStyle(.secondary)
            case .notice(let text):
                Text(text).font(.callout).foregroundStyle(Tone.warning)
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("chat.systemRow")
    }
}
