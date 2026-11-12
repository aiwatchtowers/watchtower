import Foundation
import Observation

/// What a **Mark All Done…** press closes: one Mail waiting sender's open
/// mail, or Waiting for me's people items 7 days or more old.
package enum InboxBulkKey: Hashable, Sendable {
    /// A sender, by any spelling: the center keys it by
    /// `InboxPeopleRule.senderKey`.
    case sender(String)
    case olderPeople
}

/// The **Mark All Done…** presses of the Inbox's sender and Older rows: one
/// `InboxBulkPressModel` per key, kept while the app runs (on the strip,
/// AppState-owned), so a press under way or its result survives leaving the
/// pane. A press plans with a dry run (`InboxBulkCLI.planSender` /
/// `planOlderPeople(days: 7)`) and closes exactly the ids it named; Try
/// Again is a new dry run. `onFinished` (the strip's `refresh()`) runs after
/// every finished press — an apply's result, an empty plan (the pressed row
/// was stale), a failed dry run — so the rows redraw with its result line.
/// The bulk presses under way or waiting for the owner
/// (`InboxBulkPressModel.pinsActions`), by canonical key. Observable, so a
/// row that reads it while drawing redraws when its press starts or ends.
@MainActor
@Observable
package final class InboxBulkPins {
    package private(set) var keys: Set<InboxBulkKey> = []

    fileprivate func set(_ key: InboxBulkKey, pinned: Bool) {
        guard keys.contains(key) != pinned else { return }
        if pinned { keys.insert(key) } else { keys.remove(key) }
    }
}

@MainActor
package final class InboxBulkCenter: ObservableObject {
    /// The days an item waits before it is in Older (Go's `db.WaitingOlderAfter`).
    package static let olderDays = 7

    private let cli: @MainActor () -> InboxBulkCLI
    private let onFinished: @MainActor () async -> Void
    private var models: [InboxBulkKey: InboxBulkPressModel] = [:]
    private let pins = InboxBulkPins()

    /// `cli` is called at each press, so a CLI installed meanwhile is found.
    package init(
        cli: @escaping @MainActor () -> InboxBulkCLI,
        onFinished: @escaping @MainActor () async -> Void
    ) {
        self.cli = cli
        self.onFinished = onFinished
    }

    /// `key`'s press, the same instance on every call.
    package func model(for key: InboxBulkKey) -> InboxBulkPressModel {
        let key = Self.canonical(key)
        if let model = models[key] { return model }
        let model = InboxBulkPressModel(
            plan: { [weak self] in
                guard let self else { throw InboxBulkCLIError.unexpectedAnswer }
                let plan: InboxBulkPlan
                do {
                    plan = try await self.plan(key)
                } catch {
                    await onFinished()
                    throw error
                }
                // swiftlint:disable:next empty_count
                if plan.count == 0 { await onFinished() }
                return plan
            },
            apply: { [weak self] ids in
                guard let self else { return .failed(InboxBulkCLIError.unexpectedAnswer.localizedDescription) }
                let result = await cli().resolve(ids: ids)
                await onFinished()
                return result
            })
        model.onStateChange = { [pins] state in
            pins.set(key, pinned: InboxBulkPressModel.pinsActions(state))
        }
        models[key] = model
        return model
    }

    /// `key`'s press is planning, asking or running (any spelling): its row
    /// keeps its actions shown until the owner answers. Observation-tracked.
    package func isPinned(_ key: InboxBulkKey) -> Bool {
        pins.keys.contains(Self.canonical(key))
    }

    /// Starts `key`'s press: its dry run (ignored while one is under way).
    package func begin(_ key: InboxBulkKey) {
        model(for: key).begin()
    }

    /// Puts back to idle every finished press whose row the last read no
    /// longer shows (`shown`, any spelling), so an old result line never
    /// comes back with a later row (Approve All's `resetStaleApproveAll`).
    /// A press under way is left alone.
    package func resetFinished(shown: Set<InboxBulkKey>) {
        let shown = Set(shown.map(Self.canonical))
        for (key, model) in models where !shown.contains(key) {
            model.reset()
        }
    }

    private func plan(_ key: InboxBulkKey) async throws -> InboxBulkPlan {
        switch key {
        case let .sender(address): try await cli().planSender(address)
        case .olderPeople: try await cli().planOlderPeople(days: Self.olderDays)
        }
    }

    private static func canonical(_ key: InboxBulkKey) -> InboxBulkKey {
        guard case let .sender(address) = key else { return key }
        return .sender(InboxPeopleRule.senderKey(address))
    }
}
