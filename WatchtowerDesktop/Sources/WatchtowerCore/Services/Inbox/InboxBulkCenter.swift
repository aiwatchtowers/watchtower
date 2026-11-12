import Foundation

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
@MainActor
package final class InboxBulkCenter: ObservableObject {
    /// The days an item waits before it is in Older (Go's `db.WaitingOlderAfter`).
    package static let olderDays = 7

    private let cli: @MainActor () -> InboxBulkCLI
    private let onFinished: @MainActor () async -> Void
    private var models: [InboxBulkKey: InboxBulkPressModel] = [:]

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
        models[key] = model
        return model
    }

    /// Starts `key`'s press: its dry run (ignored while one is under way).
    package func begin(_ key: InboxBulkKey) {
        model(for: key).begin()
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
