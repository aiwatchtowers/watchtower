import AppKit
import SwiftUI
import WatchtowerCore

/// The top of the session panel (spec 2026-10-03 Part 8): "Waiting for you
/// (N)", every open ask of the workbench oldest first — kind, title,
/// next step, session and age. A click puts the ask's session on screen and opens the
/// drawer on it (`WorkbenchesViewModel.showAsk`). The closed asks filed
/// from outside the app have no session row: their "N closed" sits here.
/// A or ⌃⌘A on the page (board #412) gives the oldest card the keyboard; a
/// card holding it — its title part, never its Reply field — takes
/// `OwnerAskCardKeys`. A click never gives a card the keyboard (the
/// terminal keeps it); Tab reaches one with keyboard navigation on.
struct OwnerAskStackSection: View {
    /// Past this the rows scroll, so a long stack never pushes the
    /// session list off the panel.
    static let maxRowsHeight: CGFloat = 220

    let vm: WorkbenchesViewModel
    let project: Workbench
    @State private var rowsHeight: CGFloat = 0
    @FocusState private var focusedAsk: Int64?

    var body: some View {
        let asks = vm.asks
        let stack = asks.stack(projectID: project.id)
        let outsideClosed = asks.closedCounts[project.id]?[nil] ?? 0
        let notices = asks.quickNotices(projectID: project.id)
        if !stack.asks.isEmpty || !notices.isEmpty || outsideClosed > 0 || asks.loadErrors[project.id] != nil {
            VStack(alignment: .leading, spacing: 2) {
                if !stack.asks.isEmpty {
                    Text("Waiting for you (\(stack.count))")
                        .sidebarSectionLabel()
                        .padding(.horizontal, 12)
                        .accessibilityAddTraits(.isHeader)
                        .help(Self.keysHint)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(stack.asks) { ask in
                                OwnerAskStackRow(
                                    vm: vm,
                                    ask: ask,
                                    sessionTitle: sessionTitle(ask),
                                    isSelected: asks.drawerAskIDs[project.id] == ask.id,
                                    cardFocus: OwnerAskCardFocus(focus: $focusedAsk, value: ask.id, keys: cardKeys(ask, stack: stack))
                                ) {
                                    Task { await vm.showAsk(ask.id, projectID: project.id) }
                                }
                            }
                        }
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { rowsHeight = $0 })
                    }
                    .frame(height: min(rowsHeight, Self.maxRowsHeight))
                }
                // Quick answers' notices, where the owner tapped.
                ForEach(notices) { notice in
                    OwnerAskQuickNoticeRow(vm: vm, notice: notice).padding(.horizontal, 12)
                }
                if outsideClosed > 0 {
                    HStack(spacing: 4) {
                        Text(OwnerAskStack.outsideTheAppTitle).font(.caption2).foregroundStyle(.secondary)
                        OwnerAskClosedButton(vm: vm, projectID: project.id, sessionID: nil, count: outsideClosed)
                    }
                    .padding(.horizontal, 12)
                }
                if let error = asks.loadErrors[project.id] {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 6)
            .onChange(of: asks.stackKeyboardRequest, initial: true) { _, _ in
                guard asks.takeStackKeyboardRequest(projectID: project.id) else { return }
                // On the next turn: a section shown by the same key (the
                // panel was hidden) takes no focus in its first update.
                let first = stack.asks.first?.id
                DispatchQueue.main.async { focusedAsk = first }
            }
        }
    }

    static let keysHint = "⌃⌘A, or A with no field focused, comes here; then J / K or ↓ / ↑ move, 1–3 answer a Quick ask, Return opens"

    private func cardKeys(_ ask: OwnerAsk, stack: OwnerAskStack) -> OwnerAskCardKeys {
        let projectID = project.id
        return OwnerAskCardKeys(vm: vm, ask: ask) {
            focusedAsk == ask.id
        } open: { [vm] in
            Task { await vm.showAskFromKeyboard(ask.id, projectID: projectID) }
        } release: {
            focusedAsk = nil
            OwnerAskCardKeys.releaseKeyboard()
        } move: { forward in
            guard let other = forward ? stack.next(after: ask.id) : stack.previous(before: ask.id) else { return false }
            focusedAsk = other.id
            return true
        }
    }

    private func sessionTitle(_ ask: OwnerAsk) -> String {
        guard let id = ask.sessionID else { return OwnerAskStack.outsideTheAppTitle }
        return vm.session(id, projectID: project.id)?.title ?? "Session"
    }
}

/// One waiting ask: its kind's icon, title, then its number (board #500,
/// so "ask #145" in a terminal finds its row) · next step (board #366,
/// "Answer 2 questions") · session · age. A Quick ask (spec 2026-10-10
/// Part 9.2) adds the banner's one-tap row under it; one raised from the
/// terminal's question says "From chat · N min".
private struct OwnerAskStackRow: View {
    let vm: WorkbenchesViewModel
    let ask: OwnerAsk
    let sessionTitle: String
    let isSelected: Bool
    let cardFocus: OwnerAskCardFocus<Int64?>
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            openButton.modifier(cardFocus)
            if let row = OwnerAskQuickRow(ask: ask) {
                OwnerAskQuickActions(vm: vm, ask: ask, row: row)
                    .padding(.leading, 34)
                    .padding(.trailing, 8)
                    .padding(.bottom, 3)
            }
        }
    }

    private var openButton: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: OwnerAskPresentation.askKindIcon(ask.kind))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                    .accessibilityLabel(OwnerAskPresentation.askKindLabel(ask.kind))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(ask.title).lineLimit(1).truncationMode(.tail)
                        if ask.origin == .chat { OwnerAskChatMark(askedAt: ask.chatAskedAt) }
                    }
                    Text("\(Text.askNumber(ask.id)) \(Text(OwnerAskPresentation.nextStep(for: ask)).foregroundStyle(Color.accentColor)) · \(caption)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .help(ask.title)
    }

    private var caption: String {
        let age = TimeFormatting.shortAge(from: ask.createdAt, now: Date())
        return [sessionTitle, age].compactMap(\.self).joined(separator: " · ")
    }
}

/// The part of a banner or stack card that takes the keyboard (board #412):
/// its title, never its Reply field. Only from Tab with keyboard
/// navigation on or from A / ⌃⌘A (`.activate`): a click leaves the
/// keyboard where it was, the terminal included.
struct OwnerAskCardFocus<Value: Hashable>: ViewModifier {
    let focus: FocusState<Value>.Binding
    let value: Value
    let keys: OwnerAskCardKeys

    func body(content: Content) -> some View {
        content
            .focusable(interactions: .activate)
            .focused(focus, equals: value)
            .onKeyPress(phases: .down) { press in
                keys.press(OwnerAskKeyMap.Press(press)) ? .handled : .ignored
            }
    }
}
