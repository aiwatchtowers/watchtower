import Foundation
import WatchtowerChatText

extension StepsSummary {
    /// First step start → last step end (→ `now` while running).
    package static func elapsed(steps: [ChatStepDisplay], running: Bool, now: Date) -> TimeInterval {
        guard let start = steps.map(\.startedAt).min() else { return 0 }
        let end = running ? now : (steps.compactMap(\.endedAt).max() ?? start)
        return max(0, end.timeIntervalSince(start))
    }
}
