import Foundation
import WatchtowerCore

extension IdeasViewModel {
    /// The Idea finder card's verdict (spec "Idea finder (phase 3)"): Keep →
    /// `active`, Drop → `rejected` (never `dropped`, which is Clear Old
    /// Ideas'), Later → `not_now` with no date, Make a Target… → the idea
    /// converted into a new target. Each clears the review flag (IDEA-04).
    ///
    /// Runs under the idea's verdict key (`InboxIdeaPane.writeKey`), the one
    /// the Inbox's idea card uses too: a press while a verdict on that idea is
    /// pending does nothing and returns nil, so K K or K then D writes one
    /// verdict. Returns the new target's id for Make a Target…, the idea's id
    /// for the other presses once the write landed, and nil when it failed
    /// (the reason is in `errorMessage`) or did not run.
    @discardableResult
    func press(_ press: IdeaBatchPress, on idea: Idea) async -> Int? {
        let result = await pendingWrites.run(InboxIdeaPane.writeKey(idea.id)) { () -> Int? in
            switch press {
            case .keep:
                return await approve(idea) ? idea.id : nil
            case .drop:
                return await reject(idea) ? idea.id : nil
            case .later:
                return await notNow(idea) ? idea.id : nil
            case .makeTarget:
                return await convertToTarget(idea)
            }
        }
        return result.flatMap { $0 }
    }
}
