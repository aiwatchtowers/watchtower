import Foundation
import GRDB
import WatchtowerCore

@MainActor
@Observable
final class InboxLearnedRulesViewModel {
    var mutes: [InboxLearnedRule] = []   // weight < 0
    var boosts: [InboxLearnedRule] = []  // weight > 0

    private let queries: InboxLearnedRulesQueries

    init(db: DatabasePool) {
        self.queries = InboxLearnedRulesQueries(dbPool: db)
    }

    func load() async {
        let all = (try? queries.listAll()) ?? []
        mutes = all.filter { $0.weight < 0 }
        boosts = all.filter { $0.weight > 0 }
    }

    /// A write that failed, shown over the list (board #670: no more `try?`).
    var errorMessage: String?
    /// One write per rule at a time; its controls wait meanwhile.
    let pendingWrites = PendingWrites()

    /// True once stored; a failure keeps the sheet's input and says why.
    @discardableResult
    func addRule(ruleType: String, scopeKey: String, weight: Double) async -> Bool {
        let queries = queries
        let stored = await pendingWrites.run("add") { () -> Bool in
            do {
                try await queries.upsertManual(ruleType: ruleType, scopeKey: scopeKey, weight: weight)
                errorMessage = nil
                return true
            } catch {
                errorMessage = "Couldn't save the rule: \(error.localizedDescription)"
                return false
            }
        } ?? false
        if stored { await load() }
        return stored
    }

    /// A rule's pending-write key: its type and scope (its row id may be nil).
    static func key(_ rule: InboxLearnedRule) -> String {
        "\(rule.ruleType)|\(rule.scopeKey)"
    }

    func remove(_ rule: InboxLearnedRule) async {
        let queries = queries
        let removed = await pendingWrites.run(Self.key(rule)) { () -> Bool in
            do {
                try await queries.delete(ruleType: rule.ruleType, scopeKey: rule.scopeKey)
                errorMessage = nil
                return true
            } catch {
                errorMessage = "Couldn't remove the rule: \(error.localizedDescription)"
                return false
            }
        } ?? false
        if removed { await load() }
    }
}
