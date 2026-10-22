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
            IdeaDetailPane(idea: idea, allIdeas: allIdeas, actions: actions)
                // Identity at the call site: the pane's own state (rating
                // draft, open merge row, Discuss chat) resets per idea.
                .id(idea.id)
        }
    }

    /// Each write, then the Inbox's re-read.
    var actions: IdeaActions {
        let idea = idea
        let ideas = ideas
        let onChange = onChange
        let onMadeTask = onMadeTask
        let onDeleted = onDeleted
        return IdeaActions(
            approve: { await ideas.approve(idea); await onChange() },
            reject: { await ideas.reject(idea); await onChange() },
            activate: { await ideas.activate(idea); await onChange() },
            notNow: { until in await ideas.notNow(idea, until: until); await onChange() },
            drop: { await ideas.drop(idea); await onChange() },
            merge: { targetID in await ideas.merge(idea, into: targetID); await onChange() },
            makeTask: {
                let targetID = await ideas.convertToTarget(idea)
                await onChange()
                if let targetID { onMadeTask(targetID) }
            },
            supersede: { await ideas.supersede(idea); await onChange() },
            reverse: { await ideas.reverse(idea); await onChange() },
            rating: { rating, comment in
                await ideas.setRating(idea, rating: rating, comment: comment)
            },
            delete: {
                if await ideas.deleteIdea(idea) { onDeleted(idea.id) }
                await onChange()
            }
        )
    }
}
