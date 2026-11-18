import SwiftUI
import WatchtowerCore

/// What a FILES root row does. `newSessionHere`, `removeFromBench` and
/// `locate` are nil where the flow is not wired: the item shows disabled.
struct FilesRootActions {
    var toggle: () -> Void = {}
    var showInFinder: () -> Void = {}
    var retryInstall: () -> Void = {}
    var newSessionHere: (() -> Void)?
    var removeFromBench: (() -> Void)?
    var locate: (() -> Void)?
}

/// One bench folder in FILES (#2003, spec §6.2): the chevron, the folder,
/// its name (and parent as a caption when two folders share a name), and on
/// the right its branch line or what is wrong with it. A folder that is gone
/// says so under its row with `Locate…` · `Remove`; a missing install shows
/// the install icon and Retry.
struct FilesRootRow: View {
    typealias Copy = WorkbenchFolderPresentation

    let name: String
    var caption: String?
    let path: String
    let state: WorkbenchFolderPresentation.RootState
    var branchLine: String?
    let isExpanded: Bool
    var isHighlighted = false
    var actions = FilesRootActions()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            row
            if state == .notFound { notFoundDetail }
        }
    }

    private var row: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: IconSize.chevron, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: Spacing.cozy)
            Image(systemName: "folder.fill").foregroundStyle(.secondary)
            Text(name)
                .fontWeight(.semibold)
                .foregroundStyle(state.namesAnError ? Tone.error : .primary)
                .layoutPriority(1)
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.tertiary).truncationMode(.middle)
            }
            Spacer(minLength: Spacing.small)
            if state == .installMissing { installMissing }
            if let trailing = state.trailing ?? branchLine {
                Text(trailing)
                    .font(.caption2)
                    .foregroundStyle(tone(state.trailing == nil ? .secondary : state.emphasis))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, Spacing.small)
        .frame(minHeight: ListLayout.lineMinHeight)
        .background(
            RoundedRectangle(cornerRadius: Radius.mark).fill(isHighlighted ? Fill.selected : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: actions.toggle)
        .help(path)
        .contextMenu {
            Button(Copy.showInFinder, action: actions.showInFinder)
            Button(Copy.newSessionHere) { actions.newSessionHere?() }
                .disabled(actions.newSessionHere == nil || state == .notFound)
            Divider()
            Button(Copy.removeFromBench) { actions.removeFromBench?() }
                .disabled(actions.removeFromBench == nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: isExpanded ? "Collapse" : "Expand", actions.toggle)
    }

    private var installMissing: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Tone.warning)
                .font(.caption)
                .help(Copy.installMissingHelp(name: name))
                .accessibilityLabel(Copy.installMissingHelp(name: name))
            Button(Copy.retry, action: actions.retryInstall)
                .buttonStyle(.kitQuiet)
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
        }
    }

    private var notFoundDetail: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(Copy.notFoundDetail(path: path)).foregroundStyle(.secondary)
            HStack(spacing: Spacing.small) {
                Button(Copy.locate) { actions.locate?() }
                    .disabled(actions.locate == nil)
                Text("·").foregroundStyle(.tertiary)
                Button(Copy.remove) { actions.removeFromBench?() }
                    .disabled(actions.removeFromBench == nil)
            }
            .buttonStyle(.kitQuiet)
            .foregroundStyle(Color.accentColor)
        }
        .font(.caption2)
        .padding(.leading, Spacing.wide)
        .padding(.bottom, Spacing.small)
    }

    private func tone(_ emphasis: WorkbenchFolderPresentation.Emphasis) -> Color {
        switch emphasis {
        case .error: Tone.error
        case .warning: Tone.warning
        case .secondary: .secondary
        }
    }
}
