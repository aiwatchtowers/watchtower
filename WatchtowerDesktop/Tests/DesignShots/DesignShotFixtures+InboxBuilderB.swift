import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Inbox builder B (plan Task 1): every state of the folder menu, the
/// folder list, Needs approval, Waiting for me, the native row actions, the
/// ⋯ menus and the editor's folder line, drawn on plain values before any
/// wiring. Compared with the mockups `docs/design/mockups/inbox-builder/b-01
/// … b-04`. Rows with a `ref` are drawn as `InboxRowActionsView` beside a
/// plain row stand-in (Task 13 draws them through A's `ArtifactView`); the
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
            DesignShot(name: "inbox-b-menu-root", size: NSSize(width: 1180, height: 640)) { inboxRoot() }
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

    /// The root's menu from the model; a fixture failure fails the shot.
    private static var rootMenu: InboxFolderMenuContent {
        do {
            return try InboxFolderMenuShotFixtures.content("inbox-b-menu-root")
        } catch {
            XCTFail("design shot fixture failed: \(error)")
            return InboxFolderMenuContent(rows: fullTree, selection: 1)
        }
    }

    /// The whole Inbox: the menu, the root's list, the selected artifact
    /// under its header (b-01's main panel).
    private static func inboxRoot() -> AnyView {
        AnyView(VStack(spacing: 0) {
            inboxHeader
            Divider()
            HStack(spacing: 0) {
                InboxFolderMenu(content: rootMenu)
                    .frame(width: PaneWidth.sideListIdeal)
                Divider()
                InboxFolderContentList(content: rootList(selection: "weekly"))
                    .frame(width: 300)
                Divider()
                InboxCardColumn {
                    VStack(alignment: .leading, spacing: Spacing.medium) {
                        InboxArtifactHeader(title: "Weekly mail roundup", source: "Weekly mail roundup · Run #12 · 2 h ago",
                                            menu: InboxArtifactMenuContent(folders: fullTree))
                        Text("Three threads from example.com need an answer this week: the acme invoice, "
                            + "the venue for the offsite and the contract renewal.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground())
    }

    /// The header today's Inbox keeps: its title and the `?`.
    private static var inboxHeader: some View {
        HStack {
            Text("Inbox").font(.headline)
            Spacer()
            Button {} label: { Image(systemName: "questionmark.circle") }
                .buttonStyle(.kitIcon(isOn: false))
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
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
            },
            DesignShot(name: "inbox-b-approvals-empty", size: NSSize(width: 420, height: 240)) {
                listColumn(InboxFolderListContent(folderKind: .approvals, folderTitle: "Needs approval"))
            }
        ]
    }

    private static func listColumn(_ content: InboxFolderListContent) -> AnyView {
        AnyView(InboxFolderContentList(content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailBackground())
    }

    // MARK: - Needs approval

    /// What Needs approval shows above its cards, and the cards.
    private struct Approvals {
        var banner: String?
        var note: NeedsApprovalNoteContent?
        var notice = false
        var cards: [ApprovalCard]
    }

    private enum ApprovalCard {
        case native(AgentAction)
        case nativeReminder
        case recipe([StandInRow])
    }

    private static var approvalShots: [DesignShot] {
        let native: [ApprovalCard] = [.native(slackSend()), .native(jiraIssue())]
        let restart = "The background sync did not restart: the daemon did not stop in time"
        let states: [(String, Approvals)] = [
            ("inbox-b-approvals-native", Approvals(cards: native)),
            ("inbox-b-approvals-recipe", Approvals(cards: [.recipe([jiraRow(), reminderRow()])])),
            ("inbox-b-approvals-mixed", Approvals(cards: [
                .native(slackSend()), .recipe([jiraRow(), linearFailedRow(), reminderRow()])
            ])),
            ("inbox-b-approvals-notice", Approvals(notice: true, cards: [.recipe([jiraRow(), reminderRow()])])),
            ("inbox-b-approvals-off", Approvals(note: NeedsApprovalNoteContent(state: .off), cards: native)),
            ("inbox-b-approvals-stopped", Approvals(note: NeedsApprovalNoteContent(state: .stopped), cards: native)),
            ("inbox-b-approvals-run-failed", Approvals(note: NeedsApprovalNoteContent(state: .lastRunFailed),
                                                       cards: native)),
            ("inbox-b-approvals-off-turn-on-failed", Approvals(note: NeedsApprovalNoteContent(
                state: .off, failure: "Feature changes are being applied in Settings — try again"), cards: native)),
            ("inbox-b-approvals-stopped-turn-on-failed", Approvals(note: NeedsApprovalNoteContent(
                state: .stopped, failure: "watchtower exited with error: database is locked"), cards: native)),
            ("inbox-b-approvals-restart-failed", Approvals(banner: restart, cards: native)),
            ("inbox-b-approvals-failed-action", Approvals(cards: [.native(linearFailed())])),
            ("inbox-b-approvals-reminder", Approvals(cards: [.nativeReminder]))
        ]
        return states.map { name, approvals in
            DesignShot(name: name, size: NSSize(width: 760, height: 0)) { approvalsPane(approvals) }
        } + [
            DesignShot(name: "inbox-b-builtin-restart-failed", size: NSSize(width: 760, height: 0)) {
                AnyView(VStack(spacing: 0) {
                    DaemonBannerView(banner: .failed(restart), onStart: {}, onOpenLogs: {}, onDismiss: {})
                    BuiltinShotFixtures.card(.shipped)
                }
                .detailBackground())
            }
        ]
    }

    private static func approvalsPane(_ approvals: Approvals) -> AnyView {
        let count = approvals.cards.reduce(0) { total, card in
            if case let .recipe(rows) = card { return total + rows.count }
            return total + 1
        } + (approvals.notice ? 1 : 0)
        return AnyView(VStack(spacing: 0) {
            if let banner = approvals.banner {
                DaemonBannerView(banner: .failed(banner), onStart: {}, onOpenLogs: {}, onDismiss: {})
            }
            VStack(alignment: .leading, spacing: Spacing.medium) {
                HStack {
                    Text("Needs approval · \(count)").font(.title3.weight(.semibold))
                    Spacer()
                    InboxMoreMenu(entries: InboxArtifactMenuContent.approvalsEntries(isEnabled: true)) { _ in }
                }
                if let note = approvals.note {
                    NeedsApprovalNote(content: note)
                }
                if approvals.notice {
                    nativeCard(.builtinNotice(BuiltinUpgradeNotice(
                        builtinID: "morning-brief", error: "your customised prompt was kept; the move stopped at "
                            + "the confirm step", updatedAt: now)))
                }
                ForEach(Array(approvals.cards.enumerated()), id: \.offset) { _, card in
                    approvalCard(card)
                }
            }
            .padding(Spacing.page)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground())
    }

    @ViewBuilder
    private static func approvalCard(_ card: ApprovalCard) -> some View {
        switch card {
        case let .native(action):
            nativeProposal(action)
        case .nativeReminder:
            nativeCard(.reminder(reminder))
        case let .recipe(rows):
            standInCard(title: nil, caption: nil, rows: rows)
        }
    }

    /// Today's card for a proposal (the reading pane's `AgentActionCardView`).
    private static func nativeProposal(_ action: AgentAction) -> some View {
        var card = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        // Only the run-made proposal names its automation; a reaction's does not.
        card.contextLabel = action.tool == "send_slack_message" ? "⚙ Release notes · run #4" : nil
        card.onDismiss = {}
        return card
    }

    /// Today's reading-pane card for a reminder or a built-in notice, on a
    /// card fill.
    private static func nativeCard(_ item: InboxListItem) -> some View {
        InboxReadingPane(item: item, navScreens: [], now: now, onCommand: { _ in }, onRetryBuiltin: { _ in })
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
    }

    private static let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

    private static var reminder: Reminder {
        Reminder(row: Row([
            "id": 7, "account_id": 1, "message_ref": "", "note": "Answer colleague A about the budget",
            "remind_at": AutomationDates.format(now.addingTimeInterval(-600)), "status": "pending"
        ]))
    }

    private static func slackSend() -> AgentAction {
        action(id: 41, tool: "send_slack_message",
               args: ##"{"text":"Release 2.0 is tagged; checklist in the thread.","target":{"account_id":1,"##
                   + ##""workspace":"acme","channel_id":"C1","label":"#acme-release"}}"##,
               status: "pending", reason: "Release notes run #4: tell the channel the tag is out")
    }

    private static func jiraIssue() -> AgentAction {
        action(id: 42, tool: "create_jira_issue",
               args: #"{"project_key":"ACME","issue_type":"Bug","summary":"Checklist link broken on the release page"}"#,
               status: "pending", reason: "From your :ticket: reaction")
    }

    private static func linearFailed() -> AgentAction {
        action(id: 43, tool: "create_linear_issue",
               args: #"{"team":"ACME","title":"Rollback plan for 2.0"}"#,
               status: "failed", reason: "From your :ticket: reaction", error: "the team was archived")
    }

    private static func action(
        id: Int64, tool: String, args: String, status: String, reason: String, error: String = ""
    ) -> AgentAction {
        AgentAction(row: Row([
            "id": id, "tool": tool, "args_json": args, "status": status, "surface": "automation",
            "context_type": "automation_run", "context_id": "4", "reason": reason, "error": error,
            "created_at": AutomationDates.format(now.addingTimeInterval(-1800))
        ]))
    }

    // MARK: - Rows with a ref

    /// A row of a recipe's list block (A's `ArtifactListRowView` shape) with
    /// the Desktop's native actions at its trailing edge.
    private struct StandInRow {
        let title: String
        var subtitle: String?
        var badge: String?
        var tone: Color?
        let actions: InboxRowActionsContent
    }

    private static func jiraRow() -> StandInRow {
        StandInRow(title: "Create a Jira issue",
                   subtitle: "ACME · “Checklist link broken on the release page” · from your :ticket: reaction",
                   actions: InboxRowActionsContent(kind: .action(failed: false)))
    }

    private static func linearFailedRow() -> StandInRow {
        StandInRow(title: "Create a Linear issue", subtitle: "failed: the team was archived", tone: Tone.error,
                   actions: InboxRowActionsContent(kind: .action(failed: true)))
    }

    private static func reminderRow() -> StandInRow {
        StandInRow(title: "Reminder · 14:00", subtitle: "“Answer colleague A about the budget” · Slack message ↗",
                   actions: InboxRowActionsContent(kind: .reminder))
    }

    private static func ping(
        _ who: String, _ place: String, _ text: String, age: String, late: Bool, _ actions: InboxRowActionsContent
    ) -> StandInRow {
        StandInRow(title: "\(who) in \(place)", subtitle: text, badge: age, tone: late ? Tone.warning : nil,
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
                StandInRow(title: "Release acme 2.0 checklist", subtitle: "2 new replies", tone: .accentColor,
                           actions: InboxRowActionsContent(kind: .track(custom: false, linkedTargetID: nil))),
                StandInRow(title: "Tell me when finance decides on the acme refund", subtitle: "1 new reply",
                           tone: .accentColor, actions: InboxRowActionsContent(kind: .track(custom: true, linkedTargetID: 12)))
            ]),
            ("inbox-b-rows-idea", "Release ideas", [
                StandInRow(title: "Move the release checklist into the repo", subtitle: "Idea · proposed",
                           tone: .accentColor, actions: InboxRowActionsContent(kind: .idea(
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
        VStack(alignment: .leading, spacing: Spacing.small) {
            if let title {
                Text(title).font(.title3.weight(.semibold))
            }
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                standInRow(row)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private static func standInRow(_ row: StandInRow) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(alignment: .center, spacing: Spacing.regular) {
                Circle()
                    .fill(row.tone ?? .clear)
                    .frame(width: IconSize.stateDot, height: IconSize.stateDot)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                        Text(row.title).font(.callout.weight(.medium))
                        if let badge = row.badge {
                            Chip(text: badge, color: row.tone ?? .secondary)
                        }
                    }
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Spacing.regular)
                InboxRowActionsView(content: row.actions)
            }
            .opacity(row.actions.isBusy ? 0.6 : 1)
            InboxRowActionsFooter(content: row.actions)
                .padding(.leading, IconSize.stateDot + Spacing.regular)
        }
        .controlSize(.small)
        .kitRow(isSelected: false)
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
                    InboxFolderListRowView(row: InboxFolderListRow(id: "ideas", kind: .legacy, title: "Idea finder",
                                                                   summary: "1 to judge", detail: "updated 3 h ago"))
                        .kitRow(isSelected: true)
                        .frame(width: 280)
                    menuPanel("Idea finder ⋯", InboxArtifactMenuContent.ideaFinderEntries)
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
