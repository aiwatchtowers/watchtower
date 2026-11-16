import SwiftUI
import WatchtowerDesign
import WatchtowerInterface

/// How a ref row's verbs read and press on the phone (mobile Inbox mockup §2): the swipe and menu titles, the
/// swipe tones (never orange: that is waiting-for-you's), the busy line, whether an `ok` hides the row, and the
/// snooze each one carries.
enum InboxRefVerbs {
    static func title(_ verb: RefVerb, kind: RefKind) -> String {
        switch verb {
        case .resolve, .done, .check: InboxText.done
        case .uncheck: InboxText.notDone
        case .snooze: kind == .reminder ? InboxText.snoozeOneHour : InboxText.snooze
        case .dismiss: InboxText.hide
        case .stop: InboxText.stopWatching
        case .makeTask: InboxText.makeATask
        case .approve: InboxText.approve
        case .reject: InboxText.reject
        case .notNow: InboxText.notNow
        default: ""
        }
    }

    static func tone(_ verb: RefVerb) -> PhoneTone {
        switch verb {
        case .resolve, .done, .check, .approve: .green
        case .snooze, .notNow: .blue
        case .reject: .red
        default: .gray
        }
    }

    /// An `ok` of these takes the row off the screen until the hub's next publishes say otherwise.
    static func hides(_ verb: RefVerb) -> Bool {
        switch verb {
        case .resolve, .dismiss, .snooze, .done, .stop, .approve, .reject, .notNow: true
        default: false
        }
    }

    /// The snooze a swipe or a plain press sends: a reminder's hour, an inbox item's day, an idea's week.
    static func defaultSnooze(_ verb: RefVerb, kind: RefKind) -> InboxSnooze? {
        switch verb {
        case .snooze: kind == .reminder ? .hour : .day
        case .notNow: .week
        default: nil
        }
    }
}

/// A ref row's actions for `PhoneArtifactView` (mockup §2): the swipes the model filters, the full verb set in the
/// context menu (the accessibility path; a Mac-only verb disabled with "On your Mac"), the press on its way, its
/// refusal with Retry, and a plan item's time in the phone's zone.
@MainActor
struct InboxRefRowActions {
    let center: InboxCenter
    let card: InboxCardModel
    let now: Date
    var timeZone: TimeZone = .current
    var revealed: (String) -> HorizontalEdge? = { _ in nil }
    let onReply: (InboxRefRowModel) -> Void
    let openURL: (URL) -> Void

    func callAsFunction(_ ref: ArtifactRef) -> PhoneRefRowActions {
        let known = card.card.refFacts.contains { $0.kind.rawValue == ref.kind.rawValue && $0.id == ref.id }
        guard let row = card.refRows.first(where: { $0.facts.kind.rawValue == ref.kind.rawValue && $0.facts.id == ref.id }) else {
            // Closed, or hidden on ok: gone from the list. A ref the hub has no facts for draws as written.
            return PhoneRefRowActions(hidden: known)
        }
        var actions = PhoneRefRowActions()
        actions.leading = row.leadingSwipe.map { swipe($0, row) }
        actions.trailing = row.trailingSwipe.map { swipe($0, row) }
        actions.menu = menu(row)
        actions.revealed = revealed(row.key)
        actions.trailingText = InboxPlanTime.start(of: ref.id, in: card.card, timeZone: timeZone)
        if row.facts.kind == .idea, row.facts.waits {
            // An idea to judge is a waiting card with its verdicts (mockup §5).
            actions.inline = actions.menu.filter { $0.enabled && $0.children.isEmpty }
        }
        if let pressed = center.rowState(row.key) {
            switch pressed.state {
            case .busy: actions.busyLabel = center.busyLabels[pressed.key] ?? ""
            case let .refused(sentence):
                actions.error = sentence
                actions.retry = (InboxText.retry, { [center] in Task { await center.retry(pressed.key) } })
            case .unknown: actions.error = InboxText.didntConfirmPhone
            }
        }
        return actions
    }

    func press(_ verb: RefVerb, _ row: InboxRefRowModel, snooze: InboxSnooze? = nil) {
        let choice = snooze ?? InboxRefVerbs.defaultSnooze(verb, kind: row.facts.kind)
        let until = choice?.until(from: now)
        let cardID = card.id
        let key = InboxPressKey.ref(cardID: cardID, row: row.key, verb, choice: choice.map { "\($0)" } ?? "")
        let busy = InboxText.busyLabel(for: row.request(verb, cardID: cardID, requestID: ""))
        Task {
            await center.press(key, on: row.key, hides: InboxRefVerbs.hides(verb), busy: busy) { requestID in
                row.request(verb, cardID: cardID, requestID: requestID, until: until)
            }
        }
    }

    private func swipe(_ verb: RefVerb, _ row: InboxRefRowModel) -> SwipeAction {
        SwipeAction(title: InboxRefVerbs.title(verb, kind: row.facts.kind), tone: InboxRefVerbs.tone(verb)) { press(verb, row) }
    }

    private func menu(_ row: InboxRefRowModel) -> [PhoneMenuEntry] {
        row.buttons.map { button in
            if !button.enabled {
                return PhoneMenuEntry(title: InboxPhoneText.macOnlyLabel(button.label, note: button.note), enabled: false)
            }
            switch button.action {
            case .open:
                return PhoneMenuEntry(title: button.label) {
                    if let url = URL(string: row.facts.link) { openURL(url) }
                }
            case .reply:
                return PhoneMenuEntry(title: button.label) { onReply(row) }
            case .snooze:
                return PhoneMenuEntry(title: button.label, children: InboxSnooze.menu.map { choice in
                    PhoneMenuEntry(title: choice.label) { press(.snooze, row, snooze: choice) }
                })
            default:
                guard let verb = button.verb else { return PhoneMenuEntry(title: button.label, enabled: false) }
                return PhoneMenuEntry(title: button.label) { press(verb, row) }
            }
        }
    }
}

/// A plan item's start in the phone's own zone, from the card's typed legacy items (the block rows carry no clock
/// time): "09:00".
enum InboxPlanTime {
    static func start(of id: Int64, in card: InboxCard, timeZone: TimeZone) -> String? {
        guard let item = card.legacy?.items.first(where: { $0.refKind == .planItem && $0.id == id }), !item.stamp.isEmpty,
              let date = try? Date.ISO8601FormatStyle().parse(item.stamp) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// A ref row's detail (mockup §2c): who and where with the age badge, the text, the link out, and the row's
/// verbs in the bottom bar — Snooze ▾, Reply…, Done. From the row as the card's document draws it.
struct InboxRowDetailModel: Equatable {
    let who: String
    let initials: String
    let place: String
    let badge: ArtifactBadge?
    let text: String
    /// "Open in Slack ↗"; nil without a link.
    let openTitle: String?

    init(row: InboxRefRowModel, document: ArtifactDocument?) {
        let drawn = document.flatMap { Self.row(row.facts, in: $0) }
        let subtitle = drawn?.subtitle ?? ""
        let parts = subtitle.components(separatedBy: " · ")
        who = parts.first ?? ""
        place = parts.dropFirst().joined(separator: " · ")
        initials = PhoneArtifactLayout.initials(who)
        badge = drawn?.badge
        text = drawn?.title ?? ""
        openTitle = row.facts.link.isEmpty ? nil : InboxPhoneText.openInDetail(InboxText.openLabel(trigger: row.facts.triggerType))
    }

    /// The document's list row that carries `facts`' ref.
    static func row(_ facts: RefFacts, in document: ArtifactDocument) -> ArtifactListRow? {
        for block in document.blocks {
            guard case let .list(list) = block else { continue }
            if let row = list.rows.first(where: { $0.ref?.kind.rawValue == facts.kind.rawValue && $0.ref?.id == facts.id }) {
                return row
            }
        }
        return nil
    }
}

/// The row detail screen (mockup §2c).
struct InboxRowDetailView: View {
    let center: InboxCenter
    let cardID: String
    let rowKey: String
    let grants: Grants
    var showsReply = false
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var replying: InboxRefRowModel?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $replying) { row in
            InboxReplySheet(center: center, cardID: cardID, row: row, place: place(row))
        }
        .onAppear {
            if showsReply, let row = model(now: Date())?.row { replying = row }
        }
    }

    private func model(now: Date) -> (card: InboxCardModel, row: InboxRefRowModel, detail: InboxRowDetailModel)? {
        guard let feed = center.feed, let card = feed.cards.first(where: { $0.id == cardID }) else { return nil }
        let model = InboxCardModel(card: card, platform: .phone, grants: grants, blocksReadable: true, now: now, hidden: center.hidden)
        guard let row = model.refRows.first(where: { $0.key == rowKey }) else { return nil }
        let document: ArtifactDocument? = if case let .document(document) = ArtifactDocument.decode(card.blocks) { document } else { nil }
        return (model, row, InboxRowDetailModel(row: row, document: document))
    }

    private func place(_ row: InboxRefRowModel) -> String {
        model(now: Date())?.detail.place ?? ""
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let found = model(now: now) {
            let (card, row, detail) = found
            let actions = InboxRefRowActions(center: center, card: card, now: now, onReply: { replying = $0 }, openURL: { openURL($0) })
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    header(detail)
                    Text(detail.text).font(TypeScale.rowTitle).textSelection(.enabled)
                    if let open = detail.openTitle, let url = URL(string: row.facts.link) {
                        Button(open) { openURL(url) }.foregroundStyle(PhoneTone.accent.color)
                    }
                    let state = actions(ArtifactRef(kind: ArtifactRefKind(rawValue: row.facts.kind.rawValue) ?? .inboxItem, id: row.facts.id))
                    if let busy = state.busyLabel {
                        Text(busy).font(TypeScale.meta).foregroundStyle(.secondary)
                    }
                    if let error = state.error {
                        Text(error).font(TypeScale.meta).foregroundStyle(PhoneTone.red.color)
                    }
                }
                .padding(.horizontal, Spacing.large)
                .padding(.top, Spacing.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bar(row, actions) }
        } else {
            // Closed or hidden meanwhile: nothing left to act on.
            Color.clear.onAppear { dismiss() }
        }
    }

    private func header(_ detail: InboxRowDetailModel) -> some View {
        HStack(alignment: .center, spacing: Spacing.cozy) {
            Text(detail.initials)
                .font(TypeScale.badge)
                .foregroundStyle(.secondary)
                .frame(width: IconSize.tile, height: IconSize.tile)
                .background(Fill.rest, in: Circle())
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(detail.who).font(TypeScale.rowEmphasis)
                HStack(spacing: Spacing.compact) {
                    Text(detail.place).font(TypeScale.meta).foregroundStyle(.secondary)
                    if let badge = detail.badge {
                        Pill(text: badge.text, tone: PhoneTone.artifact(badge.tone))
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func bar(_ row: InboxRefRowModel, _ actions: InboxRefRowActions) -> some View {
        let done = row.menu.first { [.resolve, .done, .check].contains($0) }
        let snoozes = row.menu.contains(.snooze)
        return BottomActionBar {
            HStack(spacing: Spacing.regular) {
                if snoozes {
                    Menu {
                        ForEach(row.facts.kind == .reminder ? [InboxSnooze.hour] : InboxSnooze.menu, id: \.self) { choice in
                            Button(choice.label) { actions.press(.snooze, row, snooze: choice) }
                        }
                    } label: {
                        Text(InboxText.snoozePicker).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryActionStyle())
                }
                if row.canReply {
                    Button(InboxText.reply) { replying = row }.buttonStyle(SecondaryActionStyle())
                }
                if let done {
                    Button(InboxText.done) { actions.press(done, row) }.buttonStyle(ProminentActionStyle())
                }
            }
        }
    }
}

extension InboxRefRowModel: @retroactive Identifiable {
    public var id: String { key }
}
