import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Inbox builder B (plan Task 1): every state of the folder menu, the
/// folder list, Needs approval, Waiting for me, the native row actions, the
/// ⋯ menus and the editor's folder line, drawn on plain values before any
/// wiring. Compared with the mockups `docs/design/mockups/inbox-builder/b-01
/// … b-04`. Rows with a `ref` are list rows drawn by A's `ArtifactView`
/// with the Desktop's native actions through `InboxRefHooks` (Task 13); the
/// Changed row is a stand-in over A's row model (Task 15 re-renders it from
/// `AutomationSaveConfirmation`). Sample data only.
@MainActor
enum InboxBuilderBShotFixtures {
    static var shots: [DesignShot] {
        menuShots + listShots + approvalShots + rowShots + menusShots + editorShots
    }

    // MARK: - Folder menu

    /// Drawn from `InboxFolderMenuModel` since Task 11
    /// (`InboxFolderMenuShotFixtures`); the menu's other uses below stay on
    /// plain rows.
    private static var menuShots: [DesignShot] {
        let names = ["inbox-b-menu-hidden-shown", "inbox-b-menu-new-folder", "inbox-b-menu-drag",
                     "inbox-b-menu-changed", "inbox-b-menu-cli-unavailable", "inbox-b-menu-write-refused",
                     "inbox-b-menu-move-pending", "inbox-b-folder-delete-confirm"]
        return [
            DesignShot(name: "inbox-b-menu-root", size: NSSize(width: 1180, height: 640)) {
                InboxFoldersShotFixtures.root()
            }
        ] + names.map { name in
            DesignShot(name: name, size: NSSize(width: 260, height: 300)) {
                do {
                    return menuColumn(try InboxFolderMenuShotFixtures.content(name))
                } catch {
                    return DesignShotFixtures.failure(error)
                }
            }
        }
    }

    private static let root = InboxFolderRow(id: 1, kind: .root, title: "Inbox", icon: "", depth: 0, count: 9)
    private static let approvals = InboxFolderRow(id: 2, kind: .approvals, title: "Needs approval", icon: "",
                                                  depth: 1, count: 3)
    private static let team = InboxFolderRow(id: 5, kind: .owner, title: "Team", icon: "person.2", depth: 1, count: 0)
    private static let blockers = InboxFolderRow(id: 4, kind: .owner, title: "Blockers", icon: "shippingbox",
                                                 depth: 2, count: 1)
    private static func release(depth: Int, count: Int) -> InboxFolderRow {
        InboxFolderRow(id: 3, kind: .owner, title: "Release acme 2.0", icon: "flag", depth: depth, count: count)
    }

    private static var fullTree: [InboxFolderRow] { [root, approvals, release(depth: 1, count: 2), blockers, team] }

    private static func menuColumn(_ content: InboxFolderMenuContent) -> AnyView {
        AnyView(InboxFolderMenu(content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailBackground())
    }

    // MARK: - Folder lists

    private static func rootList(selection: String?, readError: String? = nil) -> InboxFolderListContent {
        InboxFolderListContent(folderKind: .root, folderTitle: "Inbox", rows: [
            InboxFolderListRow(id: "waiting", kind: .artifact, title: "Waiting for me", summary: "4 waiting",
                               detail: "updated 6 min ago · after every sync", unread: true),
            InboxFolderListRow(id: "day", kind: .legacy, title: "Morning brief", summary: "today",
                               detail: "Your day · Fri 6 Nov", unread: true),
            InboxFolderListRow(id: "tracks", kind: .legacy, title: "Track my threads", summary: "2 unread",
                               detail: "updated 1 h ago"),
            InboxFolderListRow(id: "ideas", kind: .legacy, title: "Idea finder", summary: "1 to judge",
                               detail: "updated 3 h ago"),
            InboxFolderListRow(id: "weekly", kind: .artifact, title: "Weekly mail roundup", detail: "run #12 · 2 h ago",
                               unread: true)
        ], selection: selection, readError: readError)
    }

    private static var listShots: [DesignShot] {
        [
            DesignShot(name: "inbox-b-read-failed", size: NSSize(width: 320, height: 340)) {
                listColumn(rootList(selection: "waiting", readError: "database is locked"))
            },
            DesignShot(name: "inbox-b-root-empty", size: NSSize(width: 420, height: 300)) {
                listColumn(InboxFolderListContent(folderKind: .root, folderTitle: "Inbox"))
            },
            DesignShot(name: "inbox-b-folder-empty", size: NSSize(width: 420, height: 300)) {
                listColumn(InboxFolderListContent(folderKind: .owner, folderTitle: "Release acme 2.0"))
            }
        ]
    }

    private static func listColumn(_ content: InboxFolderListContent) -> AnyView {
        AnyView(InboxFolderContentList(content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailBackground())
    }

    // MARK: - Needs approval

    /// Drawn from the wired Inbox since Task 12 (`InboxApprovalsShotFixtures`),
    /// plus the Automations tab's built-in card under the same banner.
    private static var approvalShots: [DesignShot] {
        InboxApprovalsShotFixtures.shots + [
            DesignShot(name: "inbox-b-builtin-restart-failed", size: NSSize(width: 760, height: 0)) {
                AnyView(VStack(spacing: 0) {
                    DaemonBannerView(banner: .failed(InboxApprovalsShotFixtures.restartFailure),
                                     onStart: {}, onOpenLogs: {}, onDismiss: {})
                    BuiltinShotFixtures.card(.shipped)
                }
                .detailBackground())
            }
        ]
    }

    // MARK: - Rows with a ref

    /// A row of a recipe's list block with a `ref`; its native actions come
    /// through `InboxRefHooks` like the Inbox's.
    private struct StandInRow {
        let title: String
        var subtitle: String?
        var badge: String?
        var tone: ArtifactTone?
        let actions: InboxRowActionsContent

        /// The ref of the kind the native actions are for.
        func ref(_ id: Int64) -> ArtifactRef {
            let kind: ArtifactRefKind = switch actions.kind {
            case .inboxItem: .inboxItem
            case .track: .track
            case .idea: .idea
            case .reminder: .reminder
            case .action: .action
            }
            return ArtifactRef(kind: kind, id: id)
        }
    }

    private static func jiraRow() -> StandInRow {
        StandInRow(title: "Create a Jira issue",
                   subtitle: "ACME · “Checklist link broken on the release page” · from your :ticket: reaction",
                   actions: InboxRowActionsContent(kind: .action(
                       summary: "Project: ACME · Task · Summary: Checklist link broken",
                       buttons: [.approve, .reject, .edit])))
    }

    private static func linearFailedRow() -> StandInRow {
        StandInRow(title: "Create a Linear issue", subtitle: "failed: the team was archived", tone: .danger,
                   actions: InboxRowActionsContent(kind: .action(
                       summary: "Team: ACME · Title: Release notes", buttons: [.retry])))
    }

    private static func reminderRow() -> StandInRow {
        StandInRow(title: "Reminder · 14:00", subtitle: "“Answer colleague A about the budget” · Slack message ↗",
                   actions: InboxRowActionsContent(kind: .reminder))
    }

    private static func ping(
        _ who: String, _ place: String, _ text: String, age: String, late: Bool, _ actions: InboxRowActionsContent
    ) -> StandInRow {
        StandInRow(title: "\(who) in \(place)", subtitle: text, badge: age, tone: late ? .warning : nil,
                   actions: actions)
    }

    private static func pingActions(
        _ state: InboxRowActionsContent.State = .idle, reply: InboxRowActionsContent.Reply? = nil
    ) -> InboxRowActionsContent {
        InboxRowActionsContent(kind: .inboxItem(openLabel: "Open in Slack", openEnabled: true, canReply: true,
                                                showsHandToAgent: true), state: state, reply: reply)
    }

    private static var rowShots: [DesignShot] {
        let waiting: [(String, [StandInRow])] = [
            ("inbox-b-rows-inbox-item", [
                ping("Colleague A", "#acme-release", "Can you check the checklist?", age: "2 days", late: true,
                     pingActions()),
                ping("Colleague G", "a DM", "Mail me the invoice when you can", age: "1 h", late: false,
                     InboxRowActionsContent(kind: .inboxItem(
                         openLabel: "Open in Mail", openEnabled: true, canReply: false, showsHandToAgent: true)))
            ]),
            ("inbox-b-row-busy", [ping("Colleague B", "a DM", "Will you approve the budget?", age: "26 h", late: true,
                                       pingActions(.busy))]),
            ("inbox-b-row-failed", [ping("Colleague C", "#acme-infra", "Who reviews the migration?", age: "3 h",
                                         late: false, pingActions(.failed(
                                             message: "Couldn't mark it done: the watchtower CLI timed out.")))]),
            ("inbox-b-row-reply-composer", [ping("Colleague D", "#acme-release", "Is the tag out?", age: "1 h",
                                                 late: false, pingActions(reply: .composing(
                                                     text: "Yes, tagged an hour ago.", error: nil)))]),
            ("inbox-b-row-reply-refused", [ping("Colleague F", "#acme-gone", "Ping?", age: "4 h", late: false,
                                                pingActions(reply: .composing(text: "On it.", error:
                                                    "Reply refused: channel not found or archived — nothing was proposed.")))]),
            ("inbox-b-row-reply-pending", [ping("Colleague E", "#acme-infra", "Rollback plan?", age: "5 h",
                                                late: false, pingActions(reply: .waiting))])
        ]
        let other: [(String, String, [StandInRow])] = [
            ("inbox-b-rows-track", "Release watch", [
                StandInRow(title: "Release acme 2.0 checklist", subtitle: "2 new replies", tone: .accent,
                           actions: InboxRowActionsContent(kind: .track(custom: false, linkedTargetID: nil))),
                StandInRow(title: "Tell me when finance decides on the acme refund", subtitle: "1 new reply",
                           tone: .accent, actions: InboxRowActionsContent(kind: .track(custom: true, linkedTargetID: 12)))
            ]),
            ("inbox-b-rows-idea", "Release ideas", [
                StandInRow(title: "Move the release checklist into the repo", subtitle: "Idea · proposed",
                           tone: .accent, actions: InboxRowActionsContent(kind: .idea(
                               kind: .idea, status: .proposed, awaitsVerdict: true))),
                StandInRow(title: "Ship release notes as a page", subtitle: "Idea · active",
                           actions: InboxRowActionsContent(kind: .idea(kind: .idea, status: .active,
                                                                       awaitsVerdict: false))),
                StandInRow(title: "Keep the old changelog format", subtitle: "Idea · rejected",
                           actions: InboxRowActionsContent(kind: .idea(kind: .idea, status: .rejected,
                                                                       awaitsVerdict: false)))
            ]),
            ("inbox-b-rows-reminder", "Needs approval", [reminderRow()]),
            ("inbox-b-rows-action", "Needs approval", [jiraRow(), linearFailedRow()])
        ]
        return waiting.map { name, rows in
            DesignShot(name: name, size: NSSize(width: 860, height: 0)) {
                AnyView(standInCard(title: "Waiting for me · \(rows.count)",
                                    caption: "updated 6 min ago · after every sync", rows: rows)
                    .padding(Spacing.page)
                    .detailBackground())
            }
        } + other.map { name, title, rows in
            DesignShot(name: name, size: NSSize(width: 760, height: 0)) {
                AnyView(standInCard(title: title, caption: nil, rows: rows)
                    .padding(Spacing.page)
                    .detailBackground())
            }
        } + [
            DesignShot(name: "inbox-b-waiting-not-run", size: NSSize(width: 980, height: 360)) { waitingNotRun() },
            DesignShot(name: "inbox-b-waiting-empty", size: NSSize(width: 660, height: 0)) { waitingEmpty() }
        ]
    }

    private static func standInCard(title: String?, caption: String?, rows: [StandInRow]) -> some View {
        let listRows = rows.enumerated().map { index, row in
            ArtifactListRow(title: row.title, subtitle: row.subtitle,
                            badge: row.badge.map { ArtifactBadge(text: $0, tone: row.tone ?? .neutral) },
                            tone: row.tone, ref: row.ref(Int64(index + 1)))
        }
        let byRef = Dictionary(uniqueKeysWithValues: rows.enumerated().map { index, row in
            (InboxRefHooks.inboxRef(row.ref(Int64(index + 1))), row.actions)
        })
        let hooks = InboxRefHooks.make(isShown: { byRef[$0] != nil }, content: { ref, _ in byRef[ref] })
        return VStack(alignment: .leading, spacing: Spacing.small) {
            if let title {
                Text(title).font(.title3.weight(.semibold))
            }
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            ArtifactView(document: ArtifactDocument(blocks: [.list(ArtifactBlock.List(rows: listRows))]), mode: .inbox)
                .environment(\.artifactEnvironment, ArtifactEnvironment(refHooks: hooks))
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// Before Waiting for me's first run: the root lists the Messages legacy
    /// entry in its place, and its message card has Reply… like a row.
    private static func waitingNotRun() -> AnyView {
        let list = InboxFolderListContent(folderKind: .root, folderTitle: "Inbox", rows: [
            InboxFolderListRow(id: "messages", kind: .legacy, title: "Messages", summary: "4 waiting",
                               detail: "Mentions, DMs and replies", unread: true),
            InboxFolderListRow(id: "day", kind: .legacy, title: "Morning brief", summary: "today",
                               detail: "Your day · Fri 6 Nov", unread: true)
        ], selection: "messages")
        let actions = pingActions()
        return AnyView(HStack(spacing: 0) {
            InboxFolderContentList(content: list).frame(width: 300)
            Divider()
            InboxCardColumn {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    Text("Colleague A · #acme-release · 2 days ago").font(.caption).foregroundStyle(.secondary)
                    Text("Can you check the checklist?").font(.title3.weight(.semibold))
                    HStack {
                        InboxRowActionsView(content: actions)
                        Spacer()
                    }
                    InboxRowActionsFooter(content: actions)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground())
    }

    /// Waiting for me with nothing open: its list block's own empty line.
    private static func waitingEmpty() -> AnyView {
        let json = #"{"v":1,"blocks":[{"type":"list","rows":[],"empty":"Nobody is waiting on you"}]}"#
        guard case let .document(document) = ArtifactDocument.decode(json) else {
            XCTFail("the empty Waiting for me sample does not decode")
            return AnyView(Text("fixture failed"))
        }
        return AnyView(VStack(alignment: .leading, spacing: Spacing.medium) {
            InboxArtifactHeader(title: "Waiting for me", source: "Updated 6 min ago · after every sync",
                                menu: InboxArtifactMenuContent(isBuiltin: true, folders: fullTree))
            ArtifactView(document: document, mode: .inbox)
        }
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground())
    }

    // MARK: - The ⋯ menus

    private static var menusShots: [DesignShot] {
        let artifact = InboxArtifactMenuContent(folders: fullTree, currentFolderID: nil)
        return [
            DesignShot(name: "inbox-b-menus", size: NSSize(width: 960, height: 0)) {
                AnyView(HStack(alignment: .top, spacing: Spacing.large) {
                    menuPanel("Artifact ⋯", artifact.entries)
                    menuPanel("Owner folder ⋯ (Release acme 2.0)", InboxArtifactMenuContent.folderEntries(
                        release(depth: 1, count: 2), icons: icons))
                    menuPanel("Root ⋯", InboxArtifactMenuContent.rootEntries(showingHidden: false))
                    menuPanel("Needs approval ⋯", InboxArtifactMenuContent.approvalsEntries(isEnabled: true))
                }
                .padding(Spacing.page)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .detailBackground())
            },
            DesignShot(name: "inbox-b-idea-finder-menu", size: NSSize(width: 620, height: 0)) {
                AnyView(HStack(alignment: .top, spacing: Spacing.large) {
                    InboxFolderListRowView(row: InboxFolderListRow(
                        id: "ideas", kind: .legacy, title: "Idea finder", summary: "1 to judge",
                        detail: "updated 3 h ago", menu: InboxFolderEntry.legacyIdeas.menuEntries))
                        .kitRow(isSelected: true)
                        .frame(width: 280)
                    menuPanel("Idea finder ⋯", InboxFolderEntry.legacyIdeas.menuEntries)
                }
                .padding(Spacing.page)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .detailBackground())
            },
            DesignShot(name: "inbox-b-move-to-folder", size: NSSize(width: 620, height: 0)) {
                let move = artifact.entries.first { !$0.children.isEmpty }?.children ?? []
                return AnyView(HStack(alignment: .top, spacing: Spacing.small) {
                    menuPanel("Artifact ⋯", artifact.entries)
                    menuPanel("Move to Folder", move)
                }
                .padding(Spacing.page)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .detailBackground())
            },
            DesignShot(name: "inbox-b-artifact-menu-error", size: NSSize(width: 660, height: 0)) {
                AnyView(InboxArtifactHeader(
                    title: "Weekly mail roundup", source: "Weekly mail roundup · Run #12 · 2 h ago", menu: artifact,
                    error: "Couldn't move it: the Inbox menu changed — reload it and try again.")
                    .padding(Spacing.page)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .detailBackground())
            }
        ]
    }

    private static let icons = [
        ("folder", "Folder"), ("tray", "Tray"), ("flag", "Flag"), ("bolt", "Bolt"), ("person.2", "People"),
        ("doc.text", "Document"), ("calendar", "Calendar"), ("shippingbox", "Box"), ("lightbulb", "Idea"),
        ("bell", "Bell")
    ].map { InboxFolderIcon(symbol: $0.0, label: $0.1) }

    /// A ⋯ menu drawn open: a native `Menu` never renders in a snapshot, so
    /// its entries are laid out as the open menu shows them.
    private static func menuPanel(_ title: String, _ entries: [InboxMenuEntry]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: Spacing.compact) {
                        Image(systemName: entry.checked ? "checkmark" : (entry.systemImage ?? "checkmark"))
                            .font(.caption)
                            .opacity(entry.checked || entry.systemImage != nil ? 1 : 0)
                            .frame(width: IconSize.header)
                        Text(entry.title)
                            .foregroundStyle(entry.destructive ? Tone.error : .primary)
                            .padding(.leading, Spacing.medium * CGFloat(entry.indent))
                        Spacer(minLength: Spacing.large)
                        if !entry.children.isEmpty {
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .padding(.vertical, Spacing.small)
                    .padding(.horizontal, Spacing.regular)
                }
            }
            .padding(.vertical, Spacing.small)
            .frame(width: 210, alignment: .leading)
            .card(fill: Surface.window)
        }
    }

    // MARK: - The editor's folder line

    private static var editorShots: [DesignShot] {
        [
            DesignShot(name: "inbox-b-changed-row-new-folder", size: NSSize(width: 480, height: 0)) {
                changedRow(column: changedColumn(), isNew: false, placement: .newFolder(title: "Release", parent: "Inbox"))
            },
            DesignShot(name: "inbox-b-changed-row-folder-only", size: NSSize(width: 480, height: 0)) {
                changedRow(column: newRecipeColumn(), isNew: true, placement: .existing(title: "Release"))
            },
            DesignShot(name: "inbox-b-save-folder-failed", size: NSSize(width: 480, height: 0)) {
                AnyView(VStack(alignment: .leading, spacing: Spacing.regular) {
                    footerBar(column: changedColumn(), isNew: false)
                    InboxFolderSaveFailureLine(reason: "the Inbox menu changed — reload it and try again.")
                }
                .padding(Spacing.large)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .detailBackground())
            }
        ]
    }

    /// The pinned Changed row (A's row model, drawn as
    /// `AutomationSaveConfirmation` draws it) ending with the folder line,
    /// above the footer.
    private static func changedRow(
        column: AutomationDraftColumnModel, isNew: Bool, placement: InboxFolderPlacement
    ) -> AnyView {
        let row = column.confirmationRow(on: .look)
        return AnyView(VStack(alignment: .leading, spacing: Spacing.regular) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                SectionHeader(title: row?.title ?? AutomationSaveConfirmationRow.changedTitle,
                              systemImage: "arrow.left.arrow.right")
                if let note = row?.note {
                    Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array((row?.items ?? []).enumerated()), id: \.offset) { _, item in
                    Text(item.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                InboxFolderPlacementLine(placement: placement)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.medium)
            .card()
            footerBar(column: column, isNew: isNew)
        }
        .padding(Spacing.large)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground())
    }

    private static func footerBar(column: AutomationDraftColumnModel, isNew: Bool) -> some View {
        AutomationDraftFooterBar(
            verdict: AutomationDraftFooter.make(isNew: isNew, bytesChanged: true, enabled: !isNew,
                                                needsConfirmation: false),
            step: .look, ready: true, checking: false, isSaving: false,
            warnings: AutomationDraftFooter.Warnings(column: column, dryRunTokens: nil)
        ) { _ in }
    }

    /// An edit of "Weekly mail roundup" that moved its hour.
    private static func changedColumn() -> AutomationDraftColumnModel {
        column(isNew: false, changes: #"[{"field":"trigger","old":"{\"schedule\":\"0 8 * * 1-5\"}","#
            + #""new":"{\"schedule\":\"0 9 * * 1-5\"}"}]"#)
    }

    /// A new recipe from + New Artifact… in Release.
    private static func newRecipeColumn() -> AutomationDraftColumnModel {
        column(isNew: true, changes: "[]")
    }

    private static func column(isNew: Bool, changes: String) -> AutomationDraftColumnModel {
        let text = "---\nname: Weekly mail roundup\n---\n"
        let json = #"{"ok":true,"errors":[],"slug":"weekly-mail","name":"Weekly mail roundup","scope":"personal","#
            + #""approval_hash":"h2","content_hash":"\#(AutomationDraftColumnModel.contentHash(text))","#
            + #""permissions":["gmail:read@work"],"outputs":["inbox"],"widening":[],"#
            + #""changes":\#(changes),"changes_known":\#(!isNew),"adds_llm":false,"#
            + #""fields":{"trigger":"schedule: 0 9 * * 1-5","missed":"skip","concurrency":"1","#
            + #""artifacts":"living","budget":{"tokens":20000,"minutes":5}}}"#
        let validated = try? JSONDecoder().decode(AutomationsCLI.ValidateResult.self, from: Data(json.utf8))
        return AutomationDraftColumnModel(text: text, validated: validated, isChecking: false, newestChatEntry: nil,
                                          confirmedText: isNew ? nil : text, isNew: isNew, plan: nil) { _ in nil }
    }
}
