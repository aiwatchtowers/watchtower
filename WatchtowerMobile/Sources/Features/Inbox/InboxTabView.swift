import SwiftUI
import WatchtowerDesign
import WatchtowerInterface
import WatchtowerKit
import WatchtowerSync

/// A screen pushed on the Inbox tab's stack.
enum InboxRoute: Hashable {
    case folder(Int64)
    case card(String)
    /// A ref row's detail: its card and the row's key (`InboxRefRowModel.key`).
    case row(cardID: String, row: String)
}

/// What the Inbox screens read off the hub besides the feed: the `inbox` capability (nil from an older hub), the
/// hub's name, when the Mac was last seen while it is away, this phone's grants, and the time.
struct InboxInputs {
    var capability: String?
    var hubName: String
    var macAway: Date?
    var grants: Grants
    var now: Date
    /// The Mac or a server tower: the approval card's "Retry on the Mac" / "on your tower".
    var host: TowerHost = .mac

    @MainActor
    static func current(_ env: AppEnvironment, now: Date) -> Self {
        let snapshot = env.workbenchReplica.snapshot
        let heartbeat = snapshot.heartbeat
        let grant = snapshot.grant(for: env.linkedDevice?.deviceID)
        return Self(
            // No heartbeat yet is the first fetch, not an older hub.
            capability: heartbeat == nil ? InboxCapability.on : heartbeat?.capabilities?.inbox,
            hubName: env.activeSession.hubName ?? heartbeat?.macName ?? "",
            macAway: env.macReachability(now: now).asOf,
            grants: Grants(permissions: grant?.permissionsAllowed == true, typing: grant?.typingAllowed == true),
            now: now,
            host: TowerHost(heartbeat, device: grant?.deviceID)
        )
    }
}

enum InboxCapability {
    static let on = "on"
}

/// The screenshot tour's Inbox: its own center (a feed and press states) and inputs, and the frame's extras.
struct InboxShot {
    let center: InboxCenter
    var inputs: InboxInputs
    /// Row keys drawn swiped open, and to which side.
    var revealed: [String: HorizontalEdge] = [:]
    /// The card screen opens with its ⋯ menu up.
    var showsCardMenu = false
}

/// One card as a list row (mockup §1): the unread dot, the title (unread keeps its weight), the meta line —
/// "4 waiting · updated 6 min ago" on Waiting for me, "ϟ run #12 · 2 h ago" on an automation's card, "Updated 12 min
/// ago · living" on a living one, else the source and time — the preview in a folder, and the orange count of rows
/// that wait.
struct InboxCardRowModel: Equatable {
    let id: String
    let title: String
    let meta: String
    let preview: String?
    let unread: Bool
    /// Rows that wait on the owner (orange); nil when none.
    let waiting: Int?

    init(_ card: InboxCardModel, now: Date, showsPreview: Bool) {
        id = card.id
        title = card.title
        unread = card.showsUnreadDot
        let raw = card.card
        let waits = raw.refFacts.filter { $0.open && $0.waits }.count
        waiting = raw.pinned && waits > 0 ? waits : nil
        let at = Self.date(raw.stamp)
        if let waiting, let at {
            meta = InboxText.waitingSubtitle(waiting, updated: at, now: now)
        } else if raw.living, let at {
            meta = "\(InboxText.updatedAgo(at, now: now)) · \(InboxText.living)"
        } else if let run = raw.automation?.runID, run > 0, let at {
            meta = InboxText.runLine(run: Int(run), at: at, now: now)
        } else {
            meta = card.sourceLine
        }
        preview = showsPreview && !card.preview.isEmpty ? card.preview : nil
    }

    static func date(_ stamp: String) -> Date? {
        try? Date.ISO8601FormatStyle().parse(stamp)
    }

    /// Drawn as a decision card rather than a row: an approval or a reminder.
    static func isDecision(_ card: InboxCard) -> Bool {
        card.approval != nil || card.cardKind == .approvalNative || card.cardKind == .reminder
    }
}

/// The Inbox tab (mobile Inbox spec §7, mockups §1 and §6): the hub's state, then the root — Needs approval as a
/// waiting card while it holds something, the owner's folders as flat rows, and the root's own entries in the
/// Mac's order.
struct InboxTabView: View {
    @Environment(AppEnvironment.self) private var env
    private let shot: InboxShot?

    init(shot: InboxShot? = nil) {
        self.shot = shot
    }

    private var center: InboxCenter { shot?.center ?? env.inbox }

    var body: some View {
        @Bindable var navigation = env.navigation
        NavigationStack(path: $navigation.inboxPath) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let inputs = shot?.inputs ?? InboxInputs.current(env, now: context.date)
                InboxRootScreen(center: center, inputs: inputs)
            }
            .navigationTitle(InboxPhoneText.tabTitle)
            .hubSwitcher()
            .navigationDestination(for: InboxRoute.self) { route in
                InboxDestination(route: route, center: center, shot: shot)
            }
            .navigationDestination(for: NowRoute.self) { _ in NotDeliveredView() }
            .refreshable { await env.refresh(.pull) }
        }
    }
}

/// A pushed Inbox screen, reading its inputs as the root does.
struct InboxDestination: View {
    @Environment(AppEnvironment.self) private var env
    let route: InboxRoute
    let center: InboxCenter
    let shot: InboxShot?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let inputs = shot?.inputs ?? InboxInputs.current(env, now: context.date)
            switch route {
            case let .folder(id):
                InboxFolderView(center: center, folderID: id, inputs: inputs)
            case let .card(id):
                InboxCardDetailView(center: center, cardID: id, inputs: inputs, shot: shot)
            case let .row(cardID, row):
                InboxRowDetailView(center: center, cardID: cardID, rowKey: row, grants: inputs.grants)
            }
        }
    }
}

/// The root over one state (mockup §6): loading, empty, an older hub, the organization's policy, or the list.
struct InboxRootScreen: View {
    let center: InboxCenter
    let inputs: InboxInputs

    var body: some View {
        let state = InboxTabState.resolve(
            capability: inputs.capability, fetched: center.fetched, feed: center.feed, hubName: TowerText.label(inputs.hubName),
            macAway: inputs.macAway
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HubSwitcherChip(now: inputs.now).padding(.horizontal, Spacing.large)
                if case let .macAway(_, asOf) = state {
                    // The cards stay as of the hub's last publish (mockup §6 Mac away).
                    Text(InboxPhoneText.asOf(LastSeen.phrase(asOf, now: inputs.now)))
                        .font(TypeScale.meta)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.large)
                }
                switch state {
                case .ready, .macAway:
                    if let feed = center.feed {
                        InboxRootList(center: center, feed: feed, inputs: inputs)
                    }
                case .loading:
                    InboxStateMessage(state: state, spinner: true)
                default:
                    InboxStateMessage(state: state, spinner: false)
                }
            }
            .padding(.bottom, Spacing.large)
        }
    }
}

/// A state's centred title and line (mockup §6), from `InboxTabState.copy`.
struct InboxStateMessage: View {
    let state: InboxTabState
    let spinner: Bool

    var body: some View {
        VStack(spacing: Spacing.regular) {
            if spinner {
                ProgressView()
            }
            if case .empty = state {
                Image(systemName: "checkmark").font(.largeTitle).foregroundStyle(.secondary)
            }
            if let copy = state.copy {
                if spinner {
                    Text(copy.title).font(TypeScale.rowTitle).foregroundStyle(.secondary)
                } else {
                    Text(copy.title).font(TypeScale.screenTitle)
                }
                if !copy.body.isEmpty {
                    Text(copy.body).font(TypeScale.rowTitle).foregroundStyle(.secondary)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.wide)
        .padding(.top, Spacing.wide * 3)
        .frame(maxWidth: .infinity)
    }
}

/// The root's list (mockup §1, §6 Mac away): the outbox's Inbox lines, Needs approval, the owner's folders, then
/// "Inbox" over the root's own entries.
struct InboxRootList: View {
    let center: InboxCenter
    let feed: Feed
    let inputs: InboxInputs

    var body: some View {
        let root = InboxRootModel(feed: feed, platform: .phone)
        VStack(alignment: .leading, spacing: 0) {
            InboxOutboxLines(center: center, macAway: inputs.macAway != nil)
            ForEach(root.rows, id: \.folder.id) { row in
                if row.folder.kind == .approvals {
                    NavigationLink(value: InboxRoute.folder(row.folder.id)) {
                        InboxApprovalsRow(row: row, titles: approvalTitles(row.folder.id))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, Spacing.regular)
                } else {
                    InboxFolderLink(row: row)
                }
            }
            if let rootID = root.rootFolderID {
                let folder = InboxFolderModel(
                    feed: feed, folderID: rootID, platform: .phone, hidden: center.hidden, now: inputs.now, grants: inputs.grants,
                    blocksReadable: InboxCardDocument.readable
                )
                if !folder.cards.isEmpty {
                    SectionHeader(InboxPhoneText.rootHeader)
                }
                InboxCardList(center: center, cards: folder.cards, inputs: inputs, showsPreview: false)
                if let older = folder.olderLine {
                    InboxFootnote(text: older)
                }
            }
        }
        .padding(.horizontal, Spacing.small)
    }

    private func approvalTitles(_ folderID: Int64) -> [String] {
        feed.cards.filter { $0.folderID == folderID && !center.hidden.isHidden($0.id) }.map { $0.approval?.title ?? $0.title }
    }
}

/// Needs approval on the root (mockup §1): a waiting card with the first proposals and the orange count.
struct InboxApprovalsRow: View {
    let row: InboxFolderRow
    let titles: [String]

    var body: some View {
        FlatRow(icon: .symbol("checkmark", tone: PhoneTone.waitingForYou), title: InboxPhoneText.needsApproval, insets: EdgeInsets()) {
            Text(InboxPhoneText.approvalsSummary(titles))
        } trailing: {
            InboxCount(number: row.waiting > 0 ? row.waiting : row.count, waits: true)
        }
        .card(.waiting)
    }
}

/// An owner folder as a flat row: its icon, title, own count and a chevron.
struct InboxFolderLink: View {
    let row: InboxFolderRow

    var body: some View {
        NavigationLink(value: InboxRoute.folder(row.folder.id)) {
            FlatRow(icon: .symbol(row.folder.icon.isEmpty ? "folder" : row.folder.icon, tone: .secondary), title: row.folder.title) {
                EmptyView()
            } trailing: {
                InboxCount(number: row.count, waits: row.waiting > 0)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A count and the chevron: orange only for what waits on the owner.
struct InboxCount: View {
    let number: Int
    let waits: Bool

    var body: some View {
        HStack(spacing: Spacing.compact) {
            if number > 0 {
                Text("\(number)")
                    .font(TypeScale.time)
                    .foregroundStyle(waits ? PhoneTone.waitingForYou.color : Color.secondary)
            }
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
    }
}

/// A line under a list: "42 older cards are on your Mac."
struct InboxFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TypeScale.meta)
            .foregroundStyle(.secondary)
            .padding(RowInsets.flat)
    }
}

/// Cards in a list: a decision card for an approval or a reminder, "Didn't confirm" with Refresh for one whose
/// press the hub could not confirm, else a flat row that opens the card.
struct InboxCardList: View {
    let center: InboxCenter
    let cards: [InboxCardModel]
    let inputs: InboxInputs
    let showsPreview: Bool

    var body: some View {
        ForEach(cards, id: \.id) { card in
            if center.rowState(card.id) == .unknown, !InboxCardRowModel.isDecision(card.card) {
                InboxUnconfirmedCard(center: center, card: card)
            } else if InboxCardRowModel.isDecision(card.card) {
                InboxApprovalCard(center: center, card: card, inputs: inputs)
                    .padding(.vertical, Spacing.compact)
            } else {
                NavigationLink(value: InboxRoute.card(card.id)) {
                    InboxCardRow(row: InboxCardRowModel(card, now: inputs.now, showsPreview: showsPreview))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A flat card row (mockup §1).
struct InboxCardRow: View {
    let row: InboxCardRowModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.cozy) {
            Circle()
                .fill(row.unread ? PhoneTone.blue.color : Color.clear)
                .frame(width: IconSize.stateDot, height: IconSize.stateDot)
                .frame(width: PhoneMetrics.iconColumn)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(row.title).font(TypeScale.rowTitle).lineLimit(2)
                Text(row.meta).font(TypeScale.meta).foregroundStyle(.secondary).lineLimit(1)
                if let preview = row.preview {
                    Text(preview).font(TypeScale.meta).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: Spacing.regular)
            InboxCount(number: row.waiting ?? 0, waits: row.waiting != nil)
        }
        .padding(RowInsets.flat)
        .frame(minHeight: PhoneMetrics.minTouch)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A card whose press the hub could not confirm (mockup §6 Didn't confirm): it is never sent again; Refresh
/// reads the Inbox once more.
struct InboxUnconfirmedCard: View {
    let center: InboxCenter
    let card: InboxCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(InboxPhoneText.runNowTitle(card.card.automation?.name ?? card.title)).font(TypeScale.rowEmphasis)
            Text(card.sourceLine).font(TypeScale.meta).foregroundStyle(.secondary)
            Text(InboxText.didntConfirmPhone).font(TypeScale.rowTitle).foregroundStyle(PhoneTone.red.color)
            Button(InboxText.refresh) { Task { await center.refresh() } }
                .buttonStyle(PhoneArtifactButtonStyle(primary: false))
                .padding(.top, Spacing.compact)
        }
        .card()
        .padding(.vertical, Spacing.compact)
    }
}

/// The outbox's Inbox lines (mockup §6 Mac away): the presses waiting to go, which apply when the hub wakes, and
/// the ones it never got, which open the Not delivered list.
struct InboxOutboxLines: View {
    let center: InboxCenter
    /// Waiting to send shows while the hub is away; a press to an awake hub shows on its own row.
    let macAway: Bool

    var body: some View {
        let model = center.outbox
        if macAway, let waiting = model.waitingTitle {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(waiting).font(TypeScale.rowEmphasis)
                Text(model.waitingLine).font(TypeScale.meta).foregroundStyle(.secondary)
            }
            .card()
            .padding(.top, Spacing.regular)
        }
        if let title = model.undeliveredTitle {
            NavigationLink(value: NowRoute.notDelivered) {
                HStack(spacing: Spacing.medium) {
                    Text(title).font(TypeScale.rowTitle).foregroundStyle(PhoneTone.red.color)
                    Spacer(minLength: Spacing.medium)
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                .frame(minHeight: PhoneMetrics.minTouch)
                .contentShape(Rectangle())
                .card(padding: EdgeInsets(top: Spacing.tight, leading: Spacing.medium, bottom: Spacing.tight, trailing: Spacing.medium))
            }
            .buttonStyle(.plain)
            .padding(.top, Spacing.regular)
        }
    }
}

/// The Inbox's outbox lines: "Waiting to send · 2" with what they are ("Done · Approve") and when they apply,
/// and "Not delivered · 1".
struct InboxOutboxModel: Equatable {
    var waitingTitle: String?
    var waitingLine = ""
    var undeliveredTitle: String?
}

extension InboxOutboxModel {
    init(queued: [PendingAction], undelivered: [PendingAction], hubName: String) {
        waitingTitle = queued.isEmpty ? nil : InboxPhoneText.waitingToSend(queued.count)
        let verbs = queued.compactMap { InboxPhoneText.verb(of: $0.action.params) }
        waitingLine = InboxPhoneText.appliesWhenAwake(verbs: verbs, hub: hubName)
        undeliveredTitle = undelivered.isEmpty ? nil : InboxPhoneText.notDeliveredCount(undelivered.count)
    }
}

/// A card's block document as the phone reads it.
enum InboxCardDocument {
    static func decode(_ card: InboxCard) -> ArtifactDecodeResult {
        ArtifactDocument.decode(card.blocks)
    }

    /// The card's blocks draw here: none (a markdown card), or a document this build reads.
    static func readable(_ card: InboxCard) -> Bool {
        switch decode(card) {
        case .none, .document: true
        case .unsupported, .unreadable: false
        }
    }
}
