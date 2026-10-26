import SwiftUI

/// A side panel's folding group header, "▸ N finished" / "▾ 24 older":
/// a click opens or folds the group. The sessions panel's finished group
/// (board #480, spec 2026-10-12-sessions-panel-design §4.5) and the Chats
/// panel's older chats (spec 2026-10-26 §6) draw the same one.
struct PanelFoldHeader: View {
    let count: Int
    /// The group's word after the count: "finished", "older".
    let label: String
    /// What the group holds, singular: "session", "chat".
    let itemName: String
    let expanded: Bool
    let onFold: () -> Void

    var body: some View {
        Button(action: onFold) {
            HStack(spacing: Spacing.small) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 10)
                Text("\(count) \(label)")
                    .font(.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .help("\(expanded ? "Hide" : "Show") \(label) \(itemName)s")
        .accessibilityLabel("\(count) \(label) \(itemName)\(count == 1 ? "" : "s"), \(expanded ? "expanded" : "collapsed")")
        .accessibilityAddTraits(.isHeader)
    }
}
