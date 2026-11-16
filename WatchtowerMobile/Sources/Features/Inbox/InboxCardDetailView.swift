import SwiftUI
import WatchtowerDesign
import WatchtowerInterface

/// A card's screen (mockups §2, §4, §5): the header line, the blocks through `PhoneArtifactView` with each button's
/// state and each ref row's native actions, or the text when there are no blocks (with the newer-version banner
/// when the blocks do not read here); Dismiss and Done at the bottom of an artifact, which mark only the drawn
/// version; the ⋯ menu with Run Now. Opening an unread card marks it read, by its hash too.
struct InboxCardDetailView: View {
    let center: InboxCenter
    let cardID: String
    let inputs: InboxInputs
    var shot: InboxShot?
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @State private var showsMenu = false
    @State private var replying: InboxRefRowModel?
    @State private var markedRead = false

    var body: some View {
        if let card = center.feed?.cards.first(where: { $0.id == cardID }), !center.hidden.isHidden(cardID) {
            let model = InboxCardModel(
                card: card, platform: .phone, grants: inputs.grants, blocksReadable: InboxCardDocument.readable(card), now: inputs.now,
                hidden: center.hidden
            )
            screen(model)
                .onAppear {
                    showsMenu = shot?.showsCardMenu ?? false
                    markRead(model)
                }
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }

    private func screen(_ model: InboxCardModel) -> some View {
        let header = InboxCardHeader(model, now: inputs.now)
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(header.line).font(TypeScale.meta).foregroundStyle(.secondary).padding(.horizontal, Spacing.large)
                if center.rowState(model.id) == .unknown {
                    InboxUnconfirmedCard(center: center, card: model).padding(.horizontal, Spacing.small)
                }
                content(model)
            }
            .padding(.top, Spacing.compact)
            .padding(.bottom, Spacing.large)
            .opacity(showsMenu ? PhoneOpacity.disabled : 1)
        }
        .navigationTitle(header.showsTitle ? model.title : "")
        .navigationBarTitleDisplayMode(header.showsTitle ? .large : .inline)
        .toolbar {
            if model.card.automation != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsMenu.toggle() } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel(InboxPhoneText.more)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsMenu {
                ZStack(alignment: .topTrailing) {
                    // A tap anywhere else closes it.
                    Color.clear.contentShape(Rectangle()).onTapGesture { showsMenu = false }
                    menu(model)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Waiting for me lists rows that are done one by one (mockup §2): no Done for the whole card.
            if model.card.cardKind == .artifact, !header.showsTitle {
                bar(model)
            }
        }
        .sheet(item: $replying) { row in
            InboxReplySheet(center: center, cardID: model.id, row: row, place: InboxRowDetailModel(row: row, document: document(model)).place)
        }
    }

    @ViewBuilder
    private func content(_ model: InboxCardModel) -> some View {
        if let banner = model.unsupportedBanner {
            Text(banner)
                .font(TypeScale.meta)
                .card()
                .padding(.horizontal, Spacing.small)
            text(model)
        } else if let document = document(model) {
            let own = ownButtons(model, document: document)
            PhoneArtifactView(document: document, cardActionCount: own.count, onRef: { open($0, model) }, onAction: { press($0, model, document) })
                .environment(\.phoneArtifactInputs, inputs(model))
            if model.card.legacy?.kind == .tracks {
                InboxFootnote(text: InboxText.trackHint)
            }
            if !own.isEmpty {
                // The card's own buttons press first but draw under its blocks, as the Mac's card does.
                PhoneArtifactButtons(buttons: own) { press($0, model, document) }
                    .environment(\.phoneArtifactInputs, inputs(model))
                    .padding(.horizontal, Spacing.large)
            }
        } else {
            text(model)
        }
    }

    private func text(_ model: InboxCardModel) -> some View {
        PhoneArtifactText(markdown: model.card.body.isEmpty ? model.preview : model.card.body)
    }

    private func document(_ model: InboxCardModel) -> ArtifactDocument? {
        if case let .document(document) = InboxCardDocument.decode(model.card) { return document }
        return nil
    }

    /// The card's own buttons (before its blocks' in press order).
    private func ownButtons(_ model: InboxCardModel, document: ArtifactDocument) -> [PhoneArtifactButton] {
        let blockCount = document.blocks.reduce(0) { $0 + $1.actions.count }
        let ownCount = max(0, model.actions.count - blockCount)
        return model.actions.filter { $0.index < ownCount }.map {
            PhoneArtifactButton(
                label: $0.label, kind: ArtifactActionKind(rawValue: $0.kind == "link" ? "open" : $0.kind) ?? .open, primary: false, index: $0.index
            )
        }
    }

    // MARK: - Presses

    private func markRead(_ model: InboxCardModel) {
        guard !markedRead, model.card.unread, model.card.cardKind == .artifact, shot == nil else { return }
        markedRead = true
        Task {
            await center.press { model.request(.read, requestID: $0) }
        }
    }

    private func cardVerb(_ verb: ActVerb, _ model: InboxCardModel) {
        Task { await center.press { model.request(verb, requestID: $0) } }
    }

    private func press(_ index: Int, _ model: InboxCardModel, _ document: ArtifactDocument) {
        guard let action = model.actions.first(where: { $0.index == index }), action.enabled else { return }
        if action.kind == "link" {
            let flattened = document.flattenedActions(cardActions: [])
            let offset = index - (model.actions.count - flattened.count)
            if flattened.indices.contains(offset), case let .open(text) = flattened[offset].payload, let url = PhoneArtifactLayout.webURL(text) {
                openURL(url)
            } else if let url = PhoneArtifactLayout.webURL(model.card.link) {
                openURL(url)
            }
            return
        }
        Task {
            await center.press { model.press(action, requestID: $0) }
        }
    }

    static func buttonRow(_ cardID: String, _ index: Int) -> String {
        InboxPress.buttonRow(cardID, index)
    }

    private func isBusy(_ model: InboxCardModel) -> Bool {
        if case .busy? = center.rowState(model.id) { return true }
        return false
    }

    private func open(_ ref: ArtifactRef, _ model: InboxCardModel) {
        guard let row = model.refRows.first(where: { $0.facts.kind.rawValue == ref.kind.rawValue && $0.facts.id == ref.id }) else { return }
        env.navigation.inboxPath.append(InboxRoute.row(cardID: model.id, row: row.key))
    }

    // MARK: - Parts

    private func bar(_ model: InboxCardModel) -> some View {
        PrimaryActionBar(
            primary: BarAction(title: InboxText.done, isEnabled: !isBusy(model)) {
                cardVerb(.done, model)
            },
            secondary: BarAction(title: InboxText.dismiss, isEnabled: !isBusy(model)) {
                cardVerb(.dismiss, model)
            }
        )
    }

    private func menu(_ model: InboxCardModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            if model.card.automation != nil {
                Button(InboxText.runNow) {
                    showsMenu = false
                    cardVerb(.runNow, model)
                }
                .font(TypeScale.rowTitle)
                .disabled(center.rowState(model.id) == .unknown || isBusy(model))
            }
            Text(InboxText.macOnlyMenuNote).font(TypeScale.meta).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 240, alignment: .leading)
        .padding(Card.padding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Card.radius, style: .continuous))
        .shadow(radius: 12)
        .padding(.trailing, Spacing.large)
        .padding(.top, Spacing.compact)
    }
}

/// Each button's state for the renderer (mockup §4): the card model's rules — a Mac-only kind or a missing grant
/// disabled as "Chat — on your Mac" —, then the press on its way, refused, or unconfirmed.
enum InboxCardButtons {
    @MainActor
    static func state(_ index: Int, _ model: InboxCardModel, center: InboxCenter) -> PhoneArtifactButtonState {
        guard let action = model.actions.first(where: { $0.index == index }) else { return PhoneArtifactButtonState() }
        var state = PhoneArtifactButtonState(enabled: action.enabled)
        if !action.enabled, action.note == InboxText.onYourMac {
            state.label = InboxPhoneText.macOnlyLabel(action.label, note: action.note)
        } else {
            state.note = action.note
        }
        switch center.rowState(InboxPress.buttonRow(model.id, index)) {
        case .busy?: state.busyLabel = action.label
        case let .refused(sentence, _)?: state.note = sentence
        case .unknown?: state.note = InboxText.didntConfirmPhone
        case nil: break
        }
        return state
    }
}

extension InboxCardDetailView {
    /// The renderer's inputs for `model`.
    func inputs(_ model: InboxCardModel) -> PhoneArtifactInputs {
        let actions = InboxRefRowActions(
            center: center, card: model, now: inputs.now, revealed: { shot?.revealed[$0] }, onReply: { replying = $0 }, openURL: { openURL($0) }
        )
        return PhoneArtifactInputs(buttonState: { InboxCardButtons.state($0, model, center: center) }, refRow: { actions($0) })
    }
}

/// A card screen's header (mockup §4): "ϟ Weekly mail roundup · run #12 · 2 h ago", "ϟ Release checklist · Updated
/// 12 min ago", else the card's source line. Waiting for me and the Track my threads and Idea finder entries take
/// their title as the screen's title (mockup §2, §5).
struct InboxCardHeader: Equatable {
    let line: String
    let showsTitle: Bool

    init(_ model: InboxCardModel, now: Date) {
        let card = model.card
        let at = InboxCardRowModel.date(card.stamp)
        let waits = card.refFacts.contains { $0.open && $0.waits }
        showsTitle = (card.pinned && waits) || card.legacy?.kind == .tracks || card.legacy?.kind == .ideas
        if showsTitle {
            line = InboxCardRowModel(model, now: now, showsPreview: false).meta
        } else if let automation = card.automation, let at {
            line = InboxPhoneText.cardHeader(automation: automation.name, run: automation.runID, at: at, living: card.living, now: now)
        } else {
            line = model.sourceLine
        }
    }
}
