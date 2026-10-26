import SwiftUI
import WatchtowerCore

/// What the Chats panel's header does (spec 2026-10-26 §4); the panel owns
/// the flows (the landing, the project page, the history selection).
struct ChatPanelHeaderActions {
    /// `+`: a new chat, in the level's project when one is selected.
    let newChat: () -> Void
    /// A project picked in the switcher: its level.
    let selectProject: (Int64) -> Void
    /// "New Project…": an untitled project, its page open with the name focused.
    let newProject: () -> Void
    /// `‹` and "All Chats": back to every chat.
    let showAll: () -> Void
}

/// The Chats panel's header: `All chats ⌄` + `+`, or at a project
/// `‹ 📁 <name> ⌄` + `+` (the Workbench sessions panel's header, for chats).
struct ChatPanelHeader: View {
    @Bindable var historyVM: ChatHistoryViewModel
    /// The level's project name; nil at All chats.
    let projectName: String?
    let actions: ChatPanelHeaderActions
    @State private var showsPopover = false

    var body: some View {
        HStack(spacing: Spacing.small) {
            if projectName != nil {
                Button(action: actions.showAll) {
                    Image(systemName: "chevron.backward")
                }
                .buttonStyle(.kitIcon(isOn: false))
                .help("All Chats")
                .accessibilityLabel("Back to All Chats")
            }
            ChatProjectSwitcherButton(projectName: projectName) { showsPopover.toggle() }
                .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                    ChatProjectSwitcherPopover(
                        historyVM: historyVM,
                        currentID: historyVM.level.projectID,
                        onSelect: { id in
                            showsPopover = false
                            actions.selectProject(id)
                        },
                        onNewProject: {
                            showsPopover = false
                            actions.newProject()
                        },
                        onShowAll: {
                            showsPopover = false
                            actions.showAll()
                        }
                    )
                    .popoverSurface()
                }
            Button(action: actions.newChat) {
                Image(systemName: "plus")
            }
            .buttonStyle(.kitIcon(isOn: false))
            .help(projectName.map { "New Chat in \($0) (⌘N)" } ?? "New Chat (⌘N)")
            .accessibilityLabel("New chat")
        }
        // The name lines up with the rows' text below.
        .padding(.leading, Spacing.medium)
        .padding(.trailing, Spacing.regular)
        .padding(.vertical, Spacing.compact)
    }
}

/// The switcher's button: "All chats", or a folder icon and the project's
/// name (long names truncate, the tooltip has it all), then a chevron; the
/// whole width is the click target.
struct ChatProjectSwitcherButton: View {
    let projectName: String?
    let action: () -> Void

    private var title: String { projectName ?? "All chats" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.compact) {
                if projectName != nil {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        // Not a kit button: those size to their label, and the whole width
        // is the target here (as `WorkbenchSwitcherButton`).
        .buttonStyle(.borderless)
        .help("\(title) — Switch Project")
        .accessibilityLabel(projectName.map { "Project \($0)" } ?? "All chats")
        .accessibilityHint("Switch project")
    }
}

/// The project switcher's popover (spec §4, mockup board 2 column 1):
/// find a project by name, most recently active first with its chats'
/// state, the current one checked; New Project…; back to All Chats.
struct ChatProjectSwitcherPopover: View {
    @Bindable var historyVM: ChatHistoryViewModel
    /// The level's project; nil at All chats (nothing checked).
    let currentID: Int64?
    let onSelect: (Int64) -> Void
    let onNewProject: () -> Void
    let onShowAll: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            TextField("Find project", text: $query)
                .textFieldStyle(.kit)
                .focused($searchFocused)
            Text("RECENT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            list
            Divider()
            Button(action: onNewProject) {
                Label("New Project…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(KitQuietButtonStyle(label: .primary))
            Button(action: onShowAll) {
                Label("All Chats", systemImage: "chevron.backward")
            }
            .buttonStyle(KitQuietButtonStyle(label: .primary))
        }
        .padding(Spacing.cozy)
        .frame(width: 320)
        .task {
            searchFocused = true
            await historyVM.loadSwitcherSummaries()
        }
    }

    @ViewBuilder
    private var list: some View {
        if let error = historyVM.switcherError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        let rows = ChatProjectSwitcherPresentation.matching(historyVM.switcherRows, query: query)
        if rows.isEmpty {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No project matches.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            let now = historyVM.now()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    ForEach(rows) { row in
                        SwitcherPopoverRow(
                            name: row.name,
                            isCurrent: row.id == currentID,
                            tooltip: row.name,
                            segments: ChatProjectSwitcherPresentation.segments(summary: row, now: now)
                        ) {
                            onSelect(row.id)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
