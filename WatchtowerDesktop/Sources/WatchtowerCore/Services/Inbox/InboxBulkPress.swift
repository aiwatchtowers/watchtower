import Foundation

/// What a bulk press would touch, read just before the owner confirms.
package struct InboxBulkPlan: Equatable, Sendable {
    package let ids: [String]
    package let count: Int

    package init(ids: [String], count: Int) {
        self.ids = ids
        self.count = count
    }
}

/// How a bulk press ended.
package enum InboxBulkResult: Equatable, Sendable {
    /// Everything went; `skipped` were already closed when the apply ran.
    case done(count: Int, skipped: Int)
    /// The apply stopped part-way with `error`.
    case partial(done: Int, of: Int, error: String)
    case failed(String)
}

/// One bulk press of the Inbox (Approve All, Close All…): plan → confirm →
/// apply → one result. Nothing retries by itself; Try Again is the owner's
/// `begin()` running the stored plan again.
@MainActor
package final class InboxBulkPressModel: ObservableObject {
    package enum State: Equatable {
        case idle, planning, confirming(InboxBulkPlan), running, finished(InboxBulkResult)
    }

    @Published package private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    /// Called after every state change (`InboxBulkCenter` keeps its pins with it).
    package var onStateChange: ((State) -> Void)?

    private var plan: (() async throws -> InboxBulkPlan)?
    private var apply: (([String]) async throws -> InboxBulkResult)?

    package init(
        plan: (() async throws -> InboxBulkPlan)? = nil,
        apply: (([String]) async throws -> InboxBulkResult)? = nil
    ) {
        self.plan = plan
        self.apply = apply
    }

    /// Plans with `plan`, which is kept as the Try Again plan. Ignored while
    /// a press is under way.
    package func begin(plan: @escaping () async throws -> InboxBulkPlan) {
        guard canBegin else { return }
        self.plan = plan
        begin()
    }

    /// Plans with the stored plan; a no-op without one or while a press is
    /// under way. An empty plan finishes at once, with nothing to confirm.
    package func begin() {
        guard canBegin, let plan else { return }
        state = .planning
        Task {
            do {
                let planned = try await plan()
                // `count` is the plan's own field (what the dialog names),
                // not a collection's count.
                // swiftlint:disable:next empty_count
                state = planned.count == 0 ? .finished(.done(count: 0, skipped: 0)) : .confirming(planned)
            } catch {
                state = .finished(.failed(error.localizedDescription))
            }
        }
    }

    /// Applies the confirmed plan's ids with `apply`, which is kept for the
    /// next confirm. Ignored unless the plan is waiting for the owner.
    package func confirm(apply: @escaping ([String]) async throws -> InboxBulkResult) {
        guard case .confirming = state else { return }
        self.apply = apply
        confirm()
    }

    /// Applies with the stored apply; a no-op without one or unless the plan
    /// is waiting for the owner.
    package func confirm() {
        guard case .confirming(let planned) = state, let apply else { return }
        state = .running
        Task {
            do {
                state = .finished(try await apply(planned.ids))
            } catch {
                state = .finished(.failed(error.localizedDescription))
            }
        }
    }

    /// A finished press back to idle (its result no longer speaks for the
    /// list); a no-op unless finished.
    package func reset() {
        guard case .finished = state else { return }
        state = .idle
    }

    /// The owner said no: back to idle. Only while confirming.
    package func cancel() {
        guard case .confirming = state else { return }
        state = .idle
    }

    /// The press is under way or waits for the owner: planning, asking or
    /// running. A row keeps its actions shown meanwhile, so the confirmation
    /// stays on screen until the owner answers.
    package static func pinsActions(_ state: State) -> Bool {
        switch state {
        case .planning, .confirming, .running: true
        case .idle, .finished: false
        }
    }

    private var canBegin: Bool {
        switch state {
        case .idle, .finished: true
        case .planning, .confirming, .running: false
        }
    }
}
