import SwiftUI
import WatchtowerCore

/// Needs approval (spec "Needs approval" → What the Desktop shows; b-02):
/// one column of cards under its title and count — the note when it falls
/// back to the native cards for a cause (off, stopped, last run failed),
/// then the stack (`NeedsApprovalGroups.stack`: the built-in upgrade
/// notices, each group under its header with **Approve All N…** where the
/// group offers it, the in-flight rows), or "Nothing waits for your approval".
struct NeedsApprovalPane<Card: View>: View {
    /// The stack, in the list's order.
    let sections: [NeedsApprovalStackSection]
    /// How many cards the stack draws; none shows the empty state.
    private var count: Int { sections.reduce(0) { $0 + $1.entries.count } }
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
    /// The card or group a route or the list opened (a waiting target
    /// button's click, a group row `group:<raw>`): the stack scrolls to the
    /// card or the group header with this `.id`.
    var scrollTarget: String?
    /// A group's **Approve All** press (`ActionStripViewModel.approveAllModel`).
    let approveAllModel: (NeedsApprovalGroup) -> InboxBulkPressModel
    /// One entry's card.
    @ViewBuilder let card: (InboxFolderEntry) -> Card

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
                    ForEach(sections) { section in
                        NeedsApprovalGroupHeader(
                            title: section.title, count: section.entries.count,
                            approveAll: approveAll(section))
                            .id(section.id)
                        ForEach(section.entries) { entry in
                            card(entry).id(entry.id)
                        }
                    }
                }
            }
            .padding(Spacing.page)
            .frame(maxWidth: InboxCardColumn<EmptyView>.readableWidth + 2 * Spacing.page, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// `section`'s **Approve All**: its count and press, when it offers one.
    private func approveAll(_ section: NeedsApprovalStackSection) -> (count: Int, model: InboxBulkPressModel)? {
        guard let group = section.group, let ids = section.approveAllIDs, !ids.isEmpty else { return nil }
        return (ids.count, approveAllModel(group))
    }
}

/// A block's header in Needs approval's stack: the group's title and count,
/// with **Approve All N…** when the group offers it
/// (`NeedsApprovalGroups.approveAllIDs`).
struct NeedsApprovalGroupHeader: View {
    let title: String
    let count: Int
    var approveAll: (count: Int, model: InboxBulkPressModel)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            InboxListSectionHeading(title: title, count: count)
            if let approveAll {
                InboxBulkPressButton(
                    title: "Approve All \(approveAll.count)…", confirmTitle: { "Approve All \($0)" },
                    model: approveAll.model)
                    .controlSize(.small)
            }
        }
    }
}
