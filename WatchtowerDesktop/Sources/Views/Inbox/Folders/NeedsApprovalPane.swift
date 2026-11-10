import SwiftUI
import WatchtowerCore

/// Needs approval (spec "Needs approval" → What the Desktop shows; b-02):
/// one column of cards under its title and count — the note when it falls
/// back to the native cards for a cause (off, stopped, last run failed),
/// then `cards` (the built-in upgrade notices and every open approval,
/// native cards above the recipe's), or "Nothing waits for your approval".
struct NeedsApprovalPane<Cards: View>: View {
    /// How many cards `cards` draws; none shows the empty state.
    let count: Int
    private var isEmpty: Bool { count < 1 }
    let note: NeedsApprovalNoteContent?
    /// Its ⋯ (Edit the Look…, Turn Off / Turn On, Run History); empty draws none.
    var menu: [InboxMenuEntry] = []
    /// Its last failed (or busy) press's text, under the title.
    var menuError: String?
    /// A Turn On / Turn Off from its ⋯ runs: the ⋯ waits.
    var menuWorking = false
    var onNote: () -> Void = {}
    var onMenu: (InboxMenuCommand) -> Void = { _ in }
    var emptyState: EmptyStateContext = .neutral
    /// The card a route opened (a waiting target button's click): the
    /// stack scrolls to the card with this `.id`.
    var scrollTarget: String?
    @ViewBuilder let cards: () -> Cards

    var body: some View {
        ScrollViewReader { proxy in
            stack
                .onAppear { scroll(proxy) }
                .onChange(of: scrollTarget) { scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let scrollTarget else { return }
        withAnimation { proxy.scrollTo(scrollTarget, anchor: .top) }
    }

    private var stack: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                HStack {
                    Text(isEmpty ? "Needs approval" : "Needs approval · \(count)")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if menuWorking { ProgressView().controlSize(.small) }
                    if !menu.isEmpty {
                        InboxMoreMenu(entries: menu, help: "More for Needs approval", onCommand: onMenu)
                            .disabled(menuWorking)
                    }
                }
                if let menuError {
                    Text(menuError)
                        .font(.caption)
                        .foregroundStyle(Tone.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let note {
                    NeedsApprovalNote(content: note, onPress: onNote)
                }
                if isEmpty {
                    TabEmptyState(copyKey: "inboxApprovals", context: emptyState)
                        .padding(.top, Spacing.wide)
                } else {
                    cards()
                }
            }
            .padding(Spacing.page)
            .frame(maxWidth: InboxCardColumn<EmptyView>.readableWidth + 2 * Spacing.page, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
