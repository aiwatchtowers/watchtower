import SwiftUI
import WatchtowerCore

/// Whose work a Branch review shows (board #712, spec §4.2): the session's
/// panel row, where its agent works and the main folder's git status, as
/// `WorkspacePaneView` reads them; `openSession` puts its terminal on screen.
struct ReviewSessionIdentity {
    /// nil = the session is gone: the session line is left out.
    var row: SessionSwitcherPresentation.Row?
    var place: SessionPlace
    /// The place's last read failed or is pending (`isPlaceStale`).
    var stale: Bool
    var mainStatus: WorkbenchGitStatus?
    var agentName: String
    var openSession: () -> Void
}

/// The top of the Branch review pane (spec §4.2): the caption and round,
/// the session line (dot, agent, title, state, age), the branch line and
/// the For line. Needs no round, so it shows while the round opens too.
struct ReviewIdentityBar: View {
    let identity: ReviewSessionIdentity
    let model: ReviewChangesModel
    @State private var forExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(spacing: Spacing.regular) {
                Text("Branch review")
                    .textCase(.uppercase)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: Spacing.small)
                if let roundText {
                    Text(roundText).font(.caption).foregroundStyle(.tertiary)
                }
            }
            if let row = identity.row { sessionLine(row) }
            branchLine
            // Deep's Meaning shows the targets unfolded: its intent card is this list (spec §6).
            ReviewForLine(items: model.context, alwaysOpen: model.mode == .deep && model.phase == .meaning,
                          expanded: $forExpanded)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.detail)
    }

    /// `Round 2 · open`; nothing on an open round with nothing to review.
    private var roundText: String? {
        guard let round = model.round, model.load == .ready else { return nil }
        let open = round.status == "open"
        guard model.hasChanges || !open else { return nil }
        return "Round \(round.id) · \(open ? "open" : "sent")"
    }

    private func sessionLine(_ row: SessionSwitcherPresentation.Row) -> some View {
        HStack(spacing: Spacing.regular) {
            SessionLiveDot(state: row.state)
            OutlineTag(text: identity.agentName)
            Button(row.session.title, action: identity.openSession)
                .buttonStyle(.kitQuiet)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Show the session's terminal")
            SessionStateLabel(state: row.state, caption: row.caption)
                .layoutPriority(1)
            if let age = TimeFormatting.shortAge(from: row.session.lastActiveAt, now: Date()) {
                Text("· " + (age == "just now" ? age : age + " ago"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder private var branchLine: some View {
        let status = ReviewIdentityPresentation.status(place: identity.place, mainStatus: identity.mainStatus)
        let line = ReviewIdentityPresentation.branchLine(
            place: identity.place, status: status, round: model.round, files: model.files, stale: identity.stale
        )
        HStack(spacing: Spacing.compact) {
            if !line.branch.isEmpty {
                Label(line.branch, systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let base = line.base {
                Text("→").foregroundStyle(.tertiary)
                Text(base).font(.caption.monospaced()).lineLimit(1).help(line.baseHelp)
            }
            ForEach([line.size, line.uncommitted, line.place].compactMap { $0 }, id: \.self) { part in
                Text("·").foregroundStyle(.tertiary)
                Text(part).lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// `For #128 <title>  +2 more ▾`: the session's first linked target; the
/// chevron unfolds every target's card in place. `alwaysOpen` shows the
/// cards without the chevron (Deep's Meaning). Nothing without targets.
struct ReviewForLine: View {
    let items: [ReviewContextItem]
    let alwaysOpen: Bool
    @Binding var expanded: Bool

    var body: some View {
        if let line = ReviewIdentityPresentation.forLine(items) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                HStack(spacing: Spacing.compact) {
                    Text("For").foregroundStyle(.secondary)
                    // Unfolded, the cards name every target, the first too.
                    if !alwaysOpen {
                        Text("#\(line.first.targetId)").fontWeight(.semibold)
                        Text(line.first.text).lineLimit(1).truncationMode(.tail)
                        toggle(more: line.more)
                    }
                }
                .font(.caption)
                if alwaysOpen || expanded {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        ReviewIntentCard(item: item)
                            .padding(Spacing.regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card()
                    }
                }
            }
        }
    }

    /// `+N more ▾` with more targets; a bare chevron folds the one card.
    private func toggle(more: Int) -> some View {
        Button {
            withAnimation(Motion.panel) { expanded.toggle() }
        } label: {
            HStack(spacing: Spacing.tight) {
                if more > 0 { Text("+\(more) more") }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: IconSize.chevron, weight: .semibold))
            }
        }
        .buttonStyle(.kitQuiet)
        .controlSize(.small)
        .accessibilityLabel(expanded ? "Hide the targets" : "Show the targets")
    }
}

/// One task the session works on: its text, intent, and the plan task's
/// text folded to three lines.
struct ReviewIntentCard: View {
    let item: ReviewContextItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Text("#\(item.targetId)").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                Text(item.text).font(.callout.weight(.medium))
            }
            if !item.intent.isEmpty {
                Text(item.intent).font(.caption).foregroundStyle(.secondary)
            }
            if let missing = item.missing {
                Label(missing == "plan" ? "plan file missing" : "task not found", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Tone.warning)
            }
            if let plan = item.planText, !plan.isEmpty {
                Text(plan)
                    .font(.caption)
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
                Button(expanded ? "less" : "more") { expanded.toggle() }
                    .buttonStyle(.kitQuiet)
                    .controlSize(.small)
            }
        }
    }
}
