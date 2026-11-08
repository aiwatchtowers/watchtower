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
    var onNote: () -> Void = {}
    var onMenu: (InboxMenuCommand) -> Void = { _ in }
    var emptyState: EmptyStateContext = .neutral
    @ViewBuilder let cards: () -> Cards

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                HStack {
                    Text(isEmpty ? "Needs approval" : "Needs approval · \(count)")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if !menu.isEmpty {
                        InboxMoreMenu(entries: menu, help: "More for Needs approval", onCommand: onMenu)
                    }
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
