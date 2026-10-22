import SwiftUI
import WatchtowerCore

/// The Inbox's idea card (spec §6.3): `IdeaDetailPane` over the
/// AppState-owned `IdeasViewModel`, whose writes are today's verdict writes
/// (IDEA-04 resurfacing respects them). After each write the Inbox list
/// re-reads (`onChange`), so an approved idea leaves Needs your decision at
/// once instead of on the next poll. **Make a Task** converts the idea and
/// opens the new target (`onMadeTask`).
struct InboxIdeaPane: View {
    let idea: Idea
    let ideas: IdeasViewModel
    /// The merge row's candidates (it keeps the same kind, open ones only).
    let allIdeas: [Idea]
    /// The Inbox re-reads after a write.
    let onChange: () async -> Void
    /// The target Make a Task created.
    let onMadeTask: (Int) -> Void
    /// The idea was deleted (its Discuss chat goes with it).
    let onDeleted: (Int) -> Void
    /// False while the open New idea row's Create is the screen's prominent action.
    var approveIsPrimary = true

    init(
        idea: Idea,
        ideas: IdeasViewModel,
        allIdeas: [Idea],
        onChange: @escaping () async -> Void = {},
        onMadeTask: @escaping (Int) -> Void = { _ in },
        onDeleted: @escaping (Int) -> Void = { _ in }
    ) {
        self.idea = idea
        self.ideas = ideas
        self.allIdeas = allIdeas
        self.onChange = onChange
        self.onMadeTask = onMadeTask
        self.onDeleted = onDeleted
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = ideas.errorMessage {
                WriteErrorBanner(message: error) { ideas.errorMessage = nil }
            }
            IdeaDetailPane(idea: idea, allIdeas: allIdeas, actions: actions,
                           isWriting: ideas.pendingWrites.isPending(Self.writeKey(idea.id)),
                           approveIsPrimary: approveIsPrimary)
                // Identity at the call site: the pane's own state (rating
                // draft, open merge row, Discuss chat) resets per idea.
                .id(idea.id)
        }
    }

    /// One verdict write per idea at a time: the bar waits while it is pending.
    static func writeKey(_ id: Int) -> String { "verdict:\(id)" }

    /// Each write, then the Inbox's re-read; a press while one is pending does nothing.
    var actions: IdeaActions {
        let idea = idea
        let ideas = ideas
        let onChange = onChange
        let onMadeTask = onMadeTask
        let onDeleted = onDeleted
        let once: (@escaping @MainActor () async -> Void) -> () async -> Void = { write in
            {
                await ideas.pendingWrites.run(Self.writeKey(idea.id)) {
                    await write()
                    await onChange()
                }
            }
        }
        return IdeaActions(
            approve: once { await ideas.approve(idea) },
            reject: once { await ideas.reject(idea) },
            activate: once { await ideas.activate(idea) },
            notNow: { until in await once { await ideas.notNow(idea, until: until) }() },
            drop: once { await ideas.drop(idea) },
            merge: { targetID in await once { await ideas.merge(idea, into: targetID) }() },
            makeTask: once {
                if let targetID = await ideas.convertToTarget(idea) { onMadeTask(targetID) }
            },
            supersede: once { await ideas.supersede(idea) },
            reverse: once { await ideas.reverse(idea) },
            rating: { rating, comment in
                await ideas.setRating(idea, rating: rating, comment: comment)
            },
            delete: once {
                if await ideas.deleteIdea(idea) { onDeleted(idea.id) }
            }
        )
    }
}
