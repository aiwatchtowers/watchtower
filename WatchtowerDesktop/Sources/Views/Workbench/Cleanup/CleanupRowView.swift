import AppKit
import SwiftUI
import WatchtowerCore

/// The Clean Up list's column widths (mockup grid): checkbox · Name (the
/// rest) · Owner · Size · Last commit · State.
enum CleanupColumns {
    static let check: CGFloat = 26
    static let owner: CGFloat = 190
    static let size: CGFloat = 84
    /// The sizes stop short of Last commit (mockup `.num`).
    static let sizeInset: CGFloat = Spacing.medium
    static let lastCommit: CGFloat = 104
    static let state: CGFloat = 190
}

/// The column-header row: Name, Size and Last commit sort the list (click
/// again to flip the direction; the sorted one shows ↑/↓), Owner and State
/// do not.
struct CleanupColumnHeader: View {
    @Binding var sort: CleanupSort
    @Binding var ascending: Bool

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Color.clear.frame(width: CleanupColumns.check, height: 1)
            // The buttons' own inset is taken back so the titles line up
            // with the rows' text.
            sortButton("Name", .name)
                .padding(.leading, -Spacing.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
            title("Owner").frame(width: CleanupColumns.owner, alignment: .leading)
            sortButton("Size", .size)
                .padding(.trailing, CleanupColumns.sizeInset - Spacing.regular)
                .frame(width: CleanupColumns.size, alignment: .trailing)
            sortButton("Last commit", .lastCommit)
                .padding(.leading, -Spacing.regular)
                .frame(width: CleanupColumns.lastCommit, alignment: .leading)
            title("State").frame(width: CleanupColumns.state, alignment: .leading)
        }
        .font(.caption)
        .controlSize(.small)
        // The sort buttons' own height is the row's.
        .padding(.horizontal, Spacing.regular)
    }

    private func title(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    private func sortButton(_ text: String, _ column: CleanupSort) -> some View {
        let sorted = sort == column
        return Button {
            if sorted {
                ascending.toggle()
            } else {
                sort = column
                // Names A→Z; sizes and dates biggest and newest first.
                ascending = column == .name
            }
        } label: {
            Text(sorted ? "\(text) \(ascending ? "↑" : "↓")" : text)
                .fontWeight(sorted ? .medium : .regular)
        }
        .buttonStyle(KitQuietButtonStyle(label: sorted ? .primary : .secondary))
        .help("Sort by \(text.lowercased())")
    }
}

/// One row: a worktree with its branch (and its bundles' entries), a branch
/// with no worktree, or a stale LaunchServices entry (spec §4.1–§4.2). A
/// row that can be chosen has the system checkbox; one still being checked
/// an empty dashed box; a kept one none. Clicking the row or its box ticks
/// it; `onClick` gets whether ⇧ was held.
struct CleanupRowView: View {
    let row: CleanupRow
    let ticked: Bool
    let onClick: (_ shift: Bool) -> Void

    var body: some View {
        HStack(spacing: Spacing.regular) {
            // The column stays on rows with no box, so the names line up.
            ZStack { checkbox }.frame(width: CleanupColumns.check)
            name.frame(maxWidth: .infinity, alignment: .leading)
            Text(row.ownerText)
                .font(.caption)
                .foregroundStyle(row.hasOwner ? .secondary : .tertiary)
                .lineLimit(1)
                .help(row.ownerText)
                .frame(width: CleanupColumns.owner, alignment: .leading)
            size
                .padding(.trailing, CleanupColumns.sizeInset)
                .frame(width: CleanupColumns.size, alignment: .trailing)
            Text(row.state == .checking ? "—" : row.lastCommitText)
                .font(.caption)
                .foregroundStyle(row.state == .checking ? .tertiary : .secondary)
                .frame(width: CleanupColumns.lastCommit, alignment: .leading)
            stateCell.frame(width: CleanupColumns.state, alignment: .leading)
        }
        .frame(minHeight: 28)
        .opacity(row.state == .checking ? 0.55 : 1)
        .kitRow(isSelected: ticked && row.canChoose)
        .onTapGesture { click() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(ticked ? [.isSelected] : [])
        .accessibilityValue(row.canChoose ? (ticked ? "Selected" : "Not selected") : "")
        .accessibilityActions {
            if row.canChoose {
                Button(ticked ? "Unselect" : "Select") { onClick(false) }
            }
        }
    }

    private func click() {
        onClick(NSEvent.modifierFlags.contains(.shift))
    }

    @ViewBuilder private var checkbox: some View {
        if row.canChoose {
            // The row's click is the one handler (a click on the box would
            // otherwise reach both); VoiceOver ticks through the row's action.
            Toggle("Select \(row.title)", isOn: .constant(ticked))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else if row.state == .checking {
            RoundedRectangle(cornerRadius: Radius.mark, style: .continuous)
                .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(width: 14, height: 14)
                .help("Still being checked")
        }
    }

    private var name: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(row.title)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: Spacing.small) {
                Text(row.subtitle).foregroundStyle(.secondary)
                if let note = row.branchNote {
                    Text("· \(note)").foregroundStyle(Tone.warning)
                }
            }
            .font(.caption)
            .lineLimit(1)
        }
        .help(row.subtitle)
    }

    @ViewBuilder private var size: some View {
        let pending = row.sizePending
        HStack(spacing: Spacing.small) {
            if pending { ProgressView().controlSize(.mini) }
            Text(row.sizeText)
                .font(pending || row.bytes == nil ? .caption : .body)
                .monospacedDigit()
                .foregroundStyle(pending || row.bytes == nil ? .tertiary : .primary)
        }
    }

    @ViewBuilder private var stateCell: some View {
        switch row.state {
        case .checking:
            Text("—").font(.caption).foregroundStyle(.tertiary)
        case .merged:
            Chip(text: "Merged", color: Tone.success)
        case .pushed:
            Chip(text: "Pushed", color: Tone.status("blue"))
        case let .kept(reason):
            Chip(text: reason, color: Tone.status("gray"))
        case let .changedSinceCheck(reason):
            Chip(text: reason, color: Tone.warning)
        case .removing:
            ProgressView().controlSize(.mini).help("Removing…")
        case let .failed(error):
            Chip(text: error, color: Tone.error).lineLimit(1).help(error)
        }
    }
}
