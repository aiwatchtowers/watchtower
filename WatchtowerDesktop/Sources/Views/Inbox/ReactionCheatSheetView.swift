import SwiftUI
import WatchtowerCore

/// "React in Slack to act": the reaction dictionary as a table of emoji →
/// what happens, whether it asks first, and where the result lands. Shown
/// inline when the Inbox strip is empty and in the strip's `?` popover
/// otherwise. Static help, never a strip card (STRIP-01) — every input comes
/// in from the caller, and it reads or writes nothing itself.
struct ReactionCheatSheetView: View {
    /// Whether the `reaction-commands` feature is on, per the last
    /// `features list` load. `.unknown` (not loaded yet, or the popover,
    /// which has no enable affordance) renders no status row at all.
    enum FeatureState: Equatable {
        case unknown
        case off
        case on(lastCheck: String?)

        /// The feature's row in the loaded Feature Manager list; missing =
        /// not loaded (or the CLI predates the feature).
        static func from(features: [FeatureInfo], lastCheck: String?) -> Self {
            guard let feature = features.first(where: { $0.id == reactionCommandsFeatureID }) else {
                return .unknown
            }
            return feature.state == "disabled" ? .off : .on(lastCheck: lastCheck)
        }
    }

    static let reactionCommandsFeatureID = "reaction-commands"

    let rows: [ReactionCheatSheet.Row]
    var feature: FeatureState = .unknown
    var isEnabling = false
    var error: String?
    var onEnable: () -> Void = {}
    var onOpenSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("React in Slack to act")
                    .font(.headline)
                Text("React to any Slack message with one of these emoji and Watchtower acts on it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            featureStatus

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if rows.isEmpty {
                Text("No reaction commands are enabled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        CheatSheetRow(row: row)
                    }
                }
            }

            if let onOpenSettings {
                Button("Edit reaction commands in Settings…", action: onOpenSettings)
                    .buttonStyle(.link)
            }
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
    }

    @ViewBuilder
    private var featureStatus: some View {
        switch feature {
        case .unknown:
            EmptyView()
        case .off:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button("Enable Reaction Commands", action: onEnable)
                        .buttonStyle(.borderedProminent)
                        .disabled(isEnabling)
                    if isEnabling {
                        ProgressView().controlSize(.small)
                    }
                }
                Text("Reactions you've already placed are not replayed; re-adding one won't run it — react on a different message.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .on(let lastCheck):
            Label(ReactionCheatSheet.statusLine(lastCheck: lastCheck), systemImage: "eye")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// One emoji → action line of the cheat sheet.
private struct CheatSheetRow: View {
    let row: ReactionCheatSheet.Row

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(SlackEmoji.glyph(forShortcode: row.emoji) ?? "")
                .font(.title2)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(.callout.weight(.semibold))
                    Text(":\(row.emoji):")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if !row.summary.isEmpty {
                    Text(row.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Text(row.needsApproval ? "Asks for your Approve" : "Runs immediately")
                        .foregroundStyle(row.needsApproval ? Color.orange : Color.green)
                    if !row.destination.isEmpty {
                        Text("→ \(row.destination)")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
    }
}
