import AppKit
import DesignKit
import SwiftUI
@testable import WatchtowerCore
@testable import WatchtowerDesktop

/// The multi-folder workbench spec's mockups (board #2003, spec
/// 2026-11-18-multi-folder-workbench-design.md §9): static views on `acme`
/// sample data, drawn from the design kit and plain SwiftUI; the strings are
/// the spec's §6 words. Built parts use the production views: the FILES
/// root rows (`FilesRootRow`), the switcher rows (`SwitcherPopoverRow`),
/// the session rows (`TerminalSessionRow`), the prompt notice bar, the
/// folder label and the from-parent link; the New Session menu's entries
/// come from its model (`SessionNestingPresentation.newSessionMenu`).
@MainActor
enum MultiFolderShotFixtures {
    static var shots: [DesignShot] {
        [
            shot("panel-nested", width: 300) { MultiFolderPanel(nested: true) },
            shot("panel-single", width: 300) { MultiFolderPanel(nested: false) },
            shot("files-root-errors", width: 300) { MultiFolderFilesRootErrors() },
            shot("switcher", width: 400) { MultiFolderSwitcher() },
            shot("switcher-folders", width: 400) { MultiFolderSwitcher(showFolders: true) },
            shot("panel-parent-waiting", width: 300) { MultiFolderPanel(nested: true, parentWaiting: true) },
            shot("new-session-menu", width: 520) { MultiFolderNewSessionMenu() },
            shot("suggest-card", width: 300) { MultiFolderSuggestCard(state: .ready) },
            shot("suggest-card-busy", width: 300) { MultiFolderSuggestCard(state: .busy) },
            shot("suggest-card-error", width: 300) { MultiFolderSuggestCard(state: .error) },
            shot("suggest-card-merge", width: 300) { MultiFolderSuggestCard(state: .merge) },
            shot("remove-confirm", width: 360) { MultiFolderRemoveDialog(kind: .confirm) },
            shot("remove-refused-sessions", width: 360) { MultiFolderRemoveDialog(kind: .sessionsRunning) },
            shot("remove-refused-last", width: 360) { MultiFolderRemoveDialog(kind: .lastFolder) },
            shot("merge-confirm", width: 360) { MultiFolderMergeDialog(refused: false) },
            shot("merge-refused", width: 360) { MultiFolderMergeDialog(refused: true) },
            shot("feed-parent", width: 600) { MultiFolderFeedParent() },
            shot("strip-child", width: 760) { MultiFolderStripChild() },
            shot("board-card-folder", width: 380) { MultiFolderBoardCards() },
            shot("message-in-prompt", width: 760) { MultiFolderMessageInPrompt() }
        ]
    }

    /// One `workbench-multifolder-<name>` shot, as tall as its content.
    private static func shot<V: View>(_ name: String, width: CGFloat, _ make: @escaping @MainActor () -> V) -> DesignShot {
        DesignShot(name: "workbench-multifolder-\(name)", size: NSSize(width: width, height: 0)) {
            AnyView(make().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        }
    }
}

/// The spec's §6 words the mockups show, in one place for the spec's review.
enum MultiFolderMockCopy {
    static let bench = "acme"
    static let otherBench = "tools"
    static let putOnTheBench = "Put on the Bench…"
    static let putOnTheBenchSubtitle = "Add a folder to “acme”"
    static let singleHintLead = "Task touches another repo?"
    static let folderNotFound = "Folder not found"
    static let movedOrDeleted = "~/code/hub was moved or deleted."
    static let gitUnavailable = "Git unavailable"
    static let notARepository = "Not a repository"
    static let suggestTitle = "Put billing on the bench?"
    static let suggestSubtitle = "From “Export reports to PDF” · the agent worked in ~/code/billing 3 times"
    static let putOnBench = "Put on Bench"
    static let notNow = "Not Now"
    static let never = "Never for This Folder"
    static let putting = "Putting on the bench…"
    static let mergeSuggestSubtitle = "billing is on the “tools” bench"
    static let mergeBenches = "Merge Benches…"
    static let suggestFailed = "Couldn’t put billing on the bench: the folder was moved or deleted."
    static let mergeTitle = "Merge “tools” into “acme”?"
    static let mergeMessage = "tools's board (12 targets), asks and sessions move to acme, "
        + "and tools leaves the workbench list. Folders that move: billing."
    static let mergeRefusedTitle = "Can’t merge “tools” yet"
    static let mergeRefused = "2 sessions are running in tools. Finish them first."
    static let removeTitle = "Remove hub from the bench?"
    static let removeMessage = "Watchtower's install in this folder is removed. Your files and git are not touched."
    static let sessionsRunning = "2 sessions are running in hub. Finish them first."
    static let lastFolder = "A workbench needs at least one folder."
    static let benchFolders = "app, hub, site"
}

// MARK: - Shared parts

/// A folder label: the folder glyph and its name, in the accent colour.
private struct FolderLabel: View {
    let name: String

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Image(systemName: "folder")
            Text(name)
        }
        .foregroundStyle(Color.accentColor)
    }
}

/// The FILES header's Put on the Bench… icon button (§6.1).
private struct PutOnBenchIcon: View {
    var body: some View {
        Button {} label: { Image(systemName: WorkbenchFolderPresentation.putOnBenchIcon) }
            .buttonStyle(.kitIcon(isOn: false))
            .help(WorkbenchFolderPresentation.tooltip)
    }
}

/// A sessions-panel row drawn by the production row (`TerminalSessionRow`)
/// with its nesting indent, folder label, sub-session count and prompt flag
/// (spec 2026-11-18 §6.2, §6.5, §6.6).
private struct MockSessionRow: View {
    let title: String
    let state: SessionSwitcherPresentation.State
    var report: (text: String, progress: Double)?
    var folder: String?
    let place: String
    var depth = 0
    var messageInPrompt = false
    var selected = false

    var body: some View {
        TerminalSessionRow(
            row: SessionSwitcherPresentation.Row(
                session: TerminalSession(
                    id: Int64(abs(title.hashValue % 10_000)), projectID: 1, kind: .claude, title: title,
                    titleSource: .auto, targetID: nil, folderPath: "/tmp/acme", claudeSessionID: "uuid",
                    createdAt: "2026-11-18T10:00:00Z", lastActiveAt: "2026-11-18T10:00:00Z"
                ),
                state: state, caption: SessionStatePresentation.caption(for: state), badge: nil, shortcut: nil,
                place: .init(text: place, systemImage: SessionPlacePresentation.mainSymbol, help: place)
            ),
            actions: SessionRowActions(open: { _ in }, rename: { _ in }, delete: { _ in }),
            reportLine: report?.text,
            reportProgress: report?.progress,
            folderLabel: folder,
            messageInPrompt: messageInPrompt
        )
        .padding(.leading, CGFloat(depth) * SessionsPanelSessionRow.nestIndent)
        .overlay(alignment: .leading) {
            if depth > 0 {
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1)
                    .padding(.leading, CGFloat(depth) * SessionsPanelSessionRow.nestIndent - SessionsPanelSessionRow.nestIndent / 2)
            }
        }
        .padding(.vertical, Spacing.small)
        .panelTab(isSelected: selected)
    }
}

/// One FILES row: a root (folder) or an entry under it.
private struct FilesRow: View {
    enum Kind { case root(expanded: Bool), folder, file }
    let kind: Kind
    let name: String
    var trailing: String?
    var trailingTone: Color = .secondary
    var nameTone: Color = .primary

    var body: some View {
        HStack(spacing: Spacing.small) {
            switch kind {
            case let .root(expanded):
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: IconSize.chevron, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(name).fontWeight(.semibold).foregroundStyle(nameTone)
            case .folder:
                Image(systemName: "chevron.right")
                    .font(.system(size: IconSize.chevron, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(name)
            case .file:
                Color.clear.frame(width: 10, height: 1)
                Image(systemName: "doc").foregroundStyle(.secondary)
                Text(name).foregroundStyle(nameTone)
            }
            Spacer(minLength: Spacing.small)
            if let trailing {
                Text(trailing).font(.caption2).foregroundStyle(trailingTone).lineLimit(1)
            }
        }
        .lineLimit(1)
        .padding(.leading, isRoot ? 0 : Spacing.large)
        .frame(minHeight: ListLayout.lineMinHeight)
    }

    private var isRoot: Bool {
        if case .root = kind { return true }
        return false
    }
}

/// The FILES header row: the section label and its icon buttons, the
/// Put on the Bench… icon first.
private struct FilesHeader: View {
    var caption = "FILES"

    var body: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: "chevron.right")
                .font(.system(size: IconSize.chevron, weight: .semibold))
                .rotationEffect(.degrees(90))
            Text(caption).sidebarSectionLabel()
            Spacer(minLength: 0)
            PutOnBenchIcon()
            Button {} label: { Image(systemName: "plus") }.buttonStyle(.kitIcon(isOn: false))
            Button {} label: { Image(systemName: "rectangle.compress.vertical") }.buttonStyle(.kitIcon(isOn: false))
            Button {} label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.kitIcon(isOn: false))
        }
        .font(.caption)
    }
}

/// The workbench's panel header: back, the bench name, the switcher's
/// chevron and New Session (+).
private struct BenchHeader: View {
    var body: some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: "chevron.backward").foregroundStyle(.secondary)
            Text(MultiFolderMockCopy.bench).font(.headline)
            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Image(systemName: "plus").foregroundStyle(.secondary)
        }
    }
}

/// A popover- or menu-like surface for a shot (a real popover does not
/// render in a shot).
private extension View {
    func mockPopover() -> some View {
        background(Surface.window, in: RoundedRectangle(cornerRadius: Radius.row))
            .card(fill: nil)
    }
}

// MARK: - 1, 2. The sessions panel

/// The sessions panel: nested sub-sessions with folder labels and three
/// FILES roots (`panel-nested`), or one folder as today plus the quiet
/// hint (`panel-single`).
private struct MultiFolderPanel: View {
    let nested: Bool
    /// The parent's own turn has ended while its sub-sessions work (§6.5).
    var parentWaiting = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            BenchHeader().padding(.horizontal, Spacing.medium)
            Text("SESSIONS").sidebarSectionLabel().padding(.horizontal, Spacing.medium)
            if nested { nestedSessions } else { singleSession }
            VStack(alignment: .leading, spacing: Spacing.tight) {
                FilesHeader()
                if nested { nestedFiles } else { singleFiles }
            }
            .padding(.horizontal, Spacing.medium)
        }
        .padding(.vertical, Spacing.medium)
        .panelBackground()
    }

    private var nestedSessions: some View {
        VStack(alignment: .leading, spacing: 0) {
            MockSessionRow(title: "Export reports to PDF",
                           state: .live(parentWaiting ? .subSessionsWorking : .working, liveSubSessions: 2),
                           report: ("#2010 · 1/3 · no PR yet", 0.33),
                           folder: "app", place: "⎇ feature/pdf-export", selected: true)
            MockSessionRow(title: "PDF export API", state: .live(.working),
                           folder: "hub", place: "⑂ export-api", depth: 1)
            MockSessionRow(title: "Download PDF button",
                           state: .live(.waitingOnAsk, openAsks: 1, oldestAskID: 2011),
                           folder: "site", place: "⑂ pdf-button", depth: 1)
            MockSessionRow(title: "Update dependencies", state: .init(kind: .stopped, live: false),
                           folder: "hub", place: "main folder · main")
        }
    }

    private var singleSession: some View {
        MockSessionRow(title: "Export reports to PDF", state: .live(.working),
                       report: ("#2010 · 1/3 · no PR yet", 0.33),
                       place: "main folder · main", selected: true)
    }

    private var nestedFiles: some View {
        VStack(alignment: .leading, spacing: 0) {
            rootRow("app", branch: WorkbenchGitStatus(branch: "feature/pdf-export", ahead: 2, dirty: true), expanded: true)
            FilesRow(kind: .folder, name: "cmd")
            FilesRow(kind: .folder, name: "internal")
            FilesRow(kind: .file, name: "export.go", nameTone: Tone.warning)
            rootRow("hub", branch: WorkbenchGitStatus(branch: "main"))
            rootRow("site", branch: WorkbenchGitStatus(branch: "main", behind: 1))
        }
    }

    private func rootRow(_ name: String, branch: WorkbenchGitStatus, expanded: Bool = false) -> some View {
        FilesRootRow(name: name, path: "~/code/\(name)", state: .normal,
                     branchLine: WorkbenchFolderPresentation.branchLine(branch), isExpanded: expanded)
            .padding(.horizontal, -Spacing.small)
    }

    private var singleFiles: some View {
        VStack(alignment: .leading, spacing: 0) {
            FilesRow(kind: .folder, name: "cmd").padding(.leading, -Spacing.large)
            FilesRow(kind: .folder, name: "internal").padding(.leading, -Spacing.large)
            FilesRow(kind: .file, name: "go.mod").padding(.leading, -Spacing.large)
            FilesRow(kind: .file, name: "README.md").padding(.leading, -Spacing.large)
            HStack(spacing: Spacing.small) {
                Text(WorkbenchFolderPresentation.hintLead).foregroundStyle(.tertiary)
                Button(WorkbenchFolderPresentation.putOnBenchTitle) {}.buttonStyle(.kitQuiet).foregroundStyle(Color.accentColor)
            }
            .font(.caption2)
            .padding(.top, Spacing.compact)
        }
    }
}

// MARK: - 3. FILES root states

private struct MultiFolderFilesRootErrors: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            FilesHeader()
            Group {
                row("app", .normal, branch: "⎇ main")
                row("hub", WorkbenchFolderPresentation.rootState(exists: false, gitAvailable: true, isRepository: true,
                                                                 installed: true))
                row("site", WorkbenchFolderPresentation.rootState(exists: true, gitAvailable: false, isRepository: false,
                                                                  installed: true))
                row("notes", WorkbenchFolderPresentation.rootState(exists: true, gitAvailable: true, isRepository: false,
                                                                   installed: true))
            }
            .padding(.horizontal, -Spacing.small)
        }
        .padding(Spacing.medium)
        .panelBackground()
    }

    private func row(_ name: String, _ state: WorkbenchFolderPresentation.RootState, branch: String? = nil) -> some View {
        FilesRootRow(name: name, path: NSHomeDirectory() + "/code/\(name)", state: state, branchLine: branch,
                     isExpanded: false, actions: FilesRootActions(removeFromBench: {}, locate: {}))
    }
}

// MARK: - 4. The workbench switcher

private struct MultiFolderSwitcher: View {
    /// `switcher-folders`: the bench row lists its folders after the name.
    var showFolders = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            TextField("Find workbench", text: .constant("")).textFieldStyle(.kit)
            Text("RECENT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if showFolders {
                SwitcherPopoverRow(name: MultiFolderMockCopy.bench, isCurrent: true,
                                   detail: WorkbenchFolderPresentation.switcherFolders(["app", "hub", "site"]),
                                   tooltip: "~/code/app",
                                   segments: [.init(text: "2 new comments", tone: .badge), .init(text: "1 blocked", tone: .warning),
                                              .init(text: "3 working", tone: .secondary)]) {}
                SwitcherPopoverRow(name: MultiFolderMockCopy.otherBench, isCurrent: false,
                                   detail: WorkbenchFolderPresentation.switcherFolders(["tools"]),
                                   tooltip: "~/code/tools", segments: [.init(text: "6d", tone: .secondary)]) {}
            } else {
                SwitcherPopoverRow(name: MultiFolderMockCopy.bench, isCurrent: true, tooltip: "~/code/app",
                                   segments: [.init(text: "2 new comments", tone: .badge), .init(text: "1 blocked", tone: .warning),
                                              .init(text: "3 working", tone: .secondary)]) {}
                SwitcherPopoverRow(name: MultiFolderMockCopy.otherBench, isCurrent: false, tooltip: "~/code/tools",
                                   segments: [.init(text: "6d", tone: .secondary)]) {}
            }
            Divider()
            Button {} label: { Label("Open Folder…", systemImage: "folder.badge.plus") }.buttonStyle(.kitQuiet)
            Button {} label: {
                Label {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(WorkbenchFolderPresentation.putOnBenchTitle)
                        Text(WorkbenchFolderPresentation.putOnBenchSubtitle(bench: MultiFolderMockCopy.bench))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: WorkbenchFolderPresentation.putOnBenchIcon)
                }
            }
            .buttonStyle(.kitQuiet)
            Button {} label: { Label("All Workbenches", systemImage: "chevron.backward") }.buttonStyle(.kitQuiet)
        }
        .padding(Spacing.cozy)
        .frame(width: 380)
        .mockPopover()
        .padding(Spacing.cozy)
        .detailBackground()
    }
}

// MARK: - 5. The New Session (+) menu

/// The (+) menu with per-folder items, the "in hub" submenu open beside it.
private struct MultiFolderNewSessionMenu: View {
    /// The production menu's model on the acme bench, from app.
    private let model = SessionNestingPresentation.newSessionMenu(
        folders: BenchFolders(folders: ["app", "hub", "site"].enumerated().map { index, name in
            WorkbenchFolder(id: Int64(index + 1), workbenchID: 1, folderPath: "~/code/\(name)", position: index, name: name)
        }, homeID: 1),
        contextFolderID: 1
    )
    private let agents = AgentChoicePresentation.newSessionAgentChoices { _ in true }.map { Entry.item($0.title) }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.tight) {
            menu(agents + [.separator]
                + model.otherFolders.enumerated().map { .submenu($1.title, highlighted: $0 == 0) } + [.separator]
                + [WorktreeChoice.folder, .worktree].map { .submenu(SessionStartPlacementPresentation.menuTitle($0)) })
            menu(agents)
                .padding(.top, Spacing.hero + Spacing.medium)
        }
        .padding(Spacing.cozy)
        .detailBackground()
    }

    enum Entry: Hashable {
        case item(String)
        case submenu(String, highlighted: Bool = false)
        case separator
    }

    private func menu(_ entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                switch entry {
                case let .item(title):
                    row(title, submenu: false, highlighted: false)
                case let .submenu(title, highlighted):
                    row(title, submenu: true, highlighted: highlighted)
                case .separator:
                    Divider().padding(.vertical, Spacing.small)
                }
            }
        }
        .padding(Spacing.small)
        .frame(width: 240)
        .mockPopover()
    }

    private func row(_ title: String, submenu: Bool, highlighted: Bool) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: Spacing.regular)
            if submenu { Image(systemName: "chevron.right").font(.caption2) }
        }
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .padding(.horizontal, Spacing.regular)
        .frame(minHeight: 22)
        .background(highlighted ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: Radius.mark))
    }
}

// MARK: - 6. The agent's folder suggestion

private struct MultiFolderSuggestCard: View {
    enum State { case ready, busy, error, merge }
    let state: State

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("Waiting for you (1)").sidebarSectionLabel()
            if state == .merge {
                mergeCard // §6.13's variant: Task 19 builds it.
            } else {
                // The production card (§6.7), on the presentation model's words.
                FolderSuggestionCard(card: FolderSuggestionPresentation.card(
                    Self.suggestion, sessionTitle: "Export reports to PDF", phase: phase, home: "/Users/owner"
                ))
            }
        }
        .padding(Spacing.medium)
        .panelBackground()
    }

    private static let suggestion = FolderSuggestionPayload(
        path: "/Users/owner/code/billing", repoRoot: "/Users/owner/code/billing", touches: 3, why: "export lives there"
    )

    private var phase: FolderSuggestionPresentation.Phase {
        switch state {
        case .busy: .busy
        case .error: .failed(FolderSuggestionPresentation.failed(name: "billing", reason: "the folder was moved or deleted."))
        case .ready, .merge: .ready
        }
    }

    private var mergeCard: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Image(systemName: "plus.rectangle.on.folder").foregroundStyle(Color.accentColor).frame(width: 16)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(MultiFolderMockCopy.suggestTitle)
                    subtitle.font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            actions.padding(.leading, 16 + Spacing.compact)
        }
        .padding(Spacing.regular)
        .card(fill: Fill.selected)
    }

    @ViewBuilder private var subtitle: some View {
        switch state {
        case .error: Text(MultiFolderMockCopy.suggestFailed)
        case .merge: Text(MultiFolderMockCopy.mergeSuggestSubtitle)
        default: Text(MultiFolderMockCopy.suggestSubtitle)
        }
    }

    @ViewBuilder private var actions: some View {
        switch state {
        case .ready:
            // The panel is 220 pt wide by default: the quiet Never goes under the two buttons.
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack(spacing: Spacing.small) {
                    Button(MultiFolderMockCopy.putOnBench) {}.buttonStyle(.kitPrimary).fixedSize()
                    Button(MultiFolderMockCopy.notNow) {}.buttonStyle(.kitSecondary).fixedSize()
                }
                Button(MultiFolderMockCopy.never) {}.buttonStyle(.kitQuiet).fixedSize()
            }
            .controlSize(.small)
        case .busy:
            HStack(spacing: Spacing.compact) {
                ProgressView().controlSize(.mini)
                Text(MultiFolderMockCopy.putting).font(.caption).foregroundStyle(.secondary)
            }
        case .error:
            Button("OK") {}.buttonStyle(.kitSecondary).controlSize(.small)
        case .merge:
            HStack(spacing: Spacing.small) {
                Button(MultiFolderMockCopy.mergeBenches) {}.buttonStyle(.kitPrimary).fixedSize()
                Button(MultiFolderMockCopy.notNow) {}.buttonStyle(.kitSecondary).fixedSize()
            }
            .controlSize(.small)
        }
    }
}

// MARK: - 7. Remove from Bench

/// The Remove from Bench… confirmation and its two refusals, drawn as the
/// alert sheet's content (a system alert does not render in a shot).
private struct MultiFolderRemoveDialog: View {
    enum Kind { case confirm, sessionsRunning, lastFolder }
    let kind: Kind

    var body: some View {
        VStack(spacing: Spacing.medium) {
            Image(systemName: kind == .confirm ? "folder.badge.minus" : "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(kind == .confirm ? AnyShapeStyle(.secondary) : AnyShapeStyle(Tone.warning))
            VStack(spacing: Spacing.small) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            buttons
        }
        .padding(Spacing.page)
        .frame(width: 300)
        .mockPopover()
        .padding(Spacing.page)
        .frame(maxWidth: .infinity)
        .detailBackground()
    }

    /// The production dialog's words (`WorkbenchFolderPresentation`).
    private var dialog: WorkbenchFolderPresentation.RemoveDialog {
        switch kind {
        case .confirm: WorkbenchFolderPresentation.removeConfirm(name: "hub")
        case .sessionsRunning: WorkbenchFolderPresentation.removeRefusedSessions(name: "hub", count: 2)
        case .lastFolder: WorkbenchFolderPresentation.removeRefusedLast(name: "app")
        }
    }

    private var title: String { dialog.title }
    private var message: String { dialog.message }

    @ViewBuilder private var buttons: some View {
        if dialog.confirms {
            HStack(spacing: Spacing.regular) {
                Button(WorkbenchFolderPresentation.cancel) {}.buttonStyle(.kitSecondary)
                Button(WorkbenchFolderPresentation.remove) {}.buttonStyle(.kitDestructive)
            }
        } else {
            Button(WorkbenchFolderPresentation.ok) {}.buttonStyle(.kitPrimary)
        }
    }
}

/// The Merge Benches confirmation and its refusal (§6.13), drawn like the
/// remove dialog.
private struct MultiFolderMergeDialog: View {
    let refused: Bool

    var body: some View {
        VStack(spacing: Spacing.medium) {
            Image(systemName: refused ? "exclamationmark.triangle" : "arrow.triangle.merge")
                .font(.largeTitle)
                .foregroundStyle(refused ? AnyShapeStyle(Tone.warning) : AnyShapeStyle(.secondary))
            VStack(spacing: Spacing.small) {
                Text(refused ? MultiFolderMockCopy.mergeRefusedTitle : MultiFolderMockCopy.mergeTitle).font(.headline)
                Text(refused ? MultiFolderMockCopy.mergeRefused : MultiFolderMockCopy.mergeMessage)
                    .font(.callout).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            if refused {
                Button("OK") {}.buttonStyle(.kitPrimary)
            } else {
                HStack(spacing: Spacing.regular) {
                    Button("Cancel") {}.buttonStyle(.kitSecondary)
                    Button("Merge") {}.buttonStyle(.kitPrimary)
                }
            }
        }
        .padding(Spacing.page)
        .frame(width: 300)
        .mockPopover()
        .padding(Spacing.page)
        .frame(maxWidth: .infinity)
        .detailBackground()
    }
}

// MARK: - 8. The parent's feed

/// The parent session's Workchat feed: its strip, an agent line, then the
/// peer bubbles — started, to, from, finished and waiting (§6.6).
private struct MultiFolderFeedParent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(spacing: Spacing.small) {
                FolderLabel(name: "app")
                Text("›").foregroundStyle(.tertiary)
                Text("⎇ feature/pdf-export")
                Spacer(minLength: 0)
                Text("2 sub-sessions").foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.bottom, Spacing.small)
            bubble(caption: "Agent", tone: .secondary, text: "The server in hub has to change. Starting a sub-session.")
            bubble(caption: "↗ Sub-session “PDF export API” started · hub · ⑂ export-api", tone: Tone.status("purple"),
                   text: "Brief sent.")
            bubble(caption: "↗ To “PDF export API” · hub", tone: Tone.status("purple"),
                   text: "Return application/pdf and cap a file at 20 MB.")
            bubble(caption: "↘ From “PDF export API” · hub", tone: Tone.status("purple"),
                   text: "Done: branch wt/export-api, returns application/pdf, 20 MB cap.")
            bubble(caption: "✓ Sub-session “PDF export API” finished", tone: Tone.success,
                   text: "The endpoint and its tests are in, PR #41 in hub.")
            waiting
        }
        .padding(Spacing.medium)
        .detailBackground()
    }

    private func bubble(caption: String, tone: Color, text: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(caption).font(.caption.weight(.medium)).foregroundStyle(tone)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.regular)
        .frame(maxWidth: 480, alignment: .leading)
        .card()
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("⏸ Message to “Download PDF button” is waiting").font(.caption.weight(.medium))
                .foregroundStyle(Tone.warning)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
                Text("The session is at a permission prompt; the message goes once it is answered.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open") {}.buttonStyle(.kitQuiet).foregroundStyle(Color.accentColor)
            }
        }
        .padding(Spacing.regular)
        .frame(maxWidth: 480, alignment: .leading)
        .card()
    }
}

// MARK: - 9. A sub-session's strip

private struct MultiFolderStripChild: View {
    var body: some View {
        HStack(spacing: Spacing.compact) {
            SessionLiveDot(state: .init(kind: .working, live: true))
            Text("PDF export API").font(.callout.weight(.semibold))
            Text("›").foregroundStyle(.tertiary)
            SessionFolderLabel(name: "hub", font: .caption)
            Text("›").foregroundStyle(.tertiary)
            Text("⑂ export-api")
            Text("›").foregroundStyle(.tertiary)
            Text("⎇ wt/export-api")
            Image(systemName: "circle.fill").font(.system(size: IconSize.stateDot)).foregroundStyle(Tone.warning)
            Spacer(minLength: Spacing.regular)
            SessionFromParentButton(parentTitle: "Export reports to PDF") {}
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, Spacing.medium)
        .frame(minHeight: 36)
        .padding(.vertical, Spacing.small)
        .detailBackground()
    }
}

// MARK: - 11. A typed message waiting in the prompt (§6.6)

/// The sessions-panel row of a session whose agent message sits typed in its
/// prompt, beside the top of that session's pane with the notice bar.
private struct MultiFolderMessageInPrompt: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            MockSessionRow(title: "PDF export API", state: .live(.stopped), folder: "hub", place: "⑂ export-api",
                           messageInPrompt: true)
                .frame(width: 300)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Spacing.compact) {
                    SessionLiveDot(state: .init(kind: .stopped, live: true))
                    Text("PDF export API").font(.callout.weight(.semibold))
                    Text("›").foregroundStyle(.tertiary)
                    SessionFolderLabel(name: "hub", font: .caption)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, Spacing.medium)
                .frame(minHeight: 36)
                SessionPromptNoticeBar(offersDismiss: false, showInTerminal: {}, dismiss: {})
            }
        }
        .detailBackground()
    }
}

// MARK: - 10. Board cards

/// Board cards on a three-folder bench: the folder chip before the branch,
/// and a target whose folder left the bench (`folder removed`).
private struct MultiFolderBoardCards: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            card("PDF export API", status: ("In progress", "blue"), folder: "hub", branch: "⎇ wt/export-api · PR #41")
            card("Download PDF button", status: ("To do", "gray"), folder: "site", branch: "⎇ wt/pdf-button")
            card("Billing CSV columns", status: ("In progress", "blue"), folder: nil, branch: "⎇ wt/billing-csv",
                 drift: "folder removed")
        }
        .padding(Spacing.medium)
        .detailBackground()
    }

    private func card(
        _ title: String,
        status: (String, String),
        folder: String?,
        branch: String,
        drift: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(title).font(.callout.weight(.medium))
            HStack(spacing: Spacing.compact) {
                Chip(text: status.0, color: Tone.status(status.1))
                if let folder { Chip(text: folder, color: Color.accentColor) }
                Text(branch).foregroundStyle(.secondary)
                if let drift { Text("· \(drift)").foregroundStyle(Tone.warning) }
            }
            .font(.caption2)
            .lineLimit(1)
        }
        .padding(Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
