import Foundation
import GRDB
import WatchtowerCore

@MainActor
@Observable
final class PeopleViewModel {
    var cards: [PeopleCard] = []
    var cardSummary: PeopleCardSummary?
    var searchText = ""
    var isLoading = false
    var errorMessage: String?
    var selectedWindow: Int = 0  // index into availableWindows
    var availableWindows: [(from: Double, to: Double)] = []

    private(set) var userNameCache: [String: String] = [:]
    private(set) var starredPeopleIDs: Set<String> = []
    private(set) var currentUserID: String?
    private(set) var currentProfile: UserProfile?
    /// Stays empty in practice: nothing writes `user_interactions` any more
    /// (#1769, A15) and People → Connections shows only the org links. Kept
    /// because the OWNER-01 guards pin which id the graph is keyed by.
    private(set) var interactions: [UserInteraction] = []
    /// People whose cards the owner stopped (#1769, A14).
    private(set) var stoppedPeopleIDs: Set<String> = []
    /// The last Stop card / Make cards again failure, shown on that
    /// person's view.
    /// Stop card / Make cards again failures by user id, each shown on
    /// that person's view until it succeeds or is dismissed.
    private(set) var cardActionErrors: [String: String] = [:]
    /// The last `load()` failed: the list offers Retry.
    private(set) var loadFailed = false
    private let dbManager: DatabaseManager
    @ObservationIgnored private let cliRunner: (any CLIRunnerProtocol)?
    private var observationTask: Task<Void, Never>?
    /// One pending star write per person (board #670).
    let pendingWrites = PendingWrites()
    /// Every write of this view model, in order (board #670).
    @ObservationIgnored let writes = SerialWrites()

    init(dbManager: DatabaseManager, cliRunner: (any CLIRunnerProtocol)? = ProcessCLIRunner.makeDefault()) {
        self.dbManager = dbManager
        self.cliRunner = cliRunner
    }

    /// Start observing the people_cards table for live updates.
    func startObserving() {
        guard observationTask == nil else { return }
        load()
        let dbPool = dbManager.dbPool
        observationTask = Task { [weak self] in
            let observation = ValueObservation.tracking { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM people_cards") ?? 0
            }
            do {
                for try await _ in observation.values(in: dbPool).dropFirst() {
                    guard !Task.isCancelled else { break }
                    self?.load()
                }
            } catch {}
        }
    }

    /// The current user's card from the loaded cards list.
    var myCard: PeopleCard? {
        guard let uid = currentUserID else { return nil }
        return cards.first { $0.userID == uid }
    }

    func load() {
        isLoading = true
        // Keep the window the owner is looking at when it still exists.
        let wanted = availableWindows.indices.contains(selectedWindow) ? availableWindows[selectedWindow] : nil
        do {
            let result = try dbManager.dbPool.read { db in
                let windows = try PeopleCardQueries.fetchAvailableWindows(db)
                let index = wanted.flatMap { want in
                    windows.firstIndex { $0.from == want.from && $0.to == want.to }
                } ?? 0
                let selected = windows.indices.contains(index) ? windows[index] : nil
                let users = try UserQueries.fetchAll(db, activeOnly: false)

                var nameMap: [String: String] = [:]
                for user in users {
                    let name = user.displayName.isEmpty ? user.name : user.displayName
                    nameMap[user.id] = name
                }

                let cards: [PeopleCard]
                let cs: PeopleCardSummary?
                if let window = selected {
                    cards = try PeopleCardQueries.fetchForWindow(
                        db, from: window.from, to: window.to
                    )
                    cs = try PeopleCardQueries.fetchSummary(
                        db, from: window.from, to: window.to
                    )
                } else {
                    cards = []
                    cs = nil
                }
                let owner = try OwnerQueries.resolve(db)
                let profile = try ProfileQueries.fetchOwnerProfile(db, owner: owner)
                let starred = Set(profile?.decodedStarredPeople ?? [])
                // People cards and interactions are keyed by Slack user id —
                // never the profile row's key, which may be a Google/Jira
                // owner id or a row parked under an earlier key. No Slack
                // identity → no "me" card and no social graph.
                let uid: String? = owner.slackUserID.isEmpty ? nil : owner.slackUserID

                // Load interactions for social graph
                var ints: [UserInteraction] = []
                if let uid, let window = selected {
                    ints = try InteractionQueries.fetchForUser(
                        db, userID: uid, periodFrom: window.from, periodTo: window.to
                    )
                }

                let stopped = try PeopleCardQueries.fetchExcludedIDs(db)
                return (cards, windows, nameMap, cs, starred, uid, profile, ints, stopped, index)
            }
            cards = result.0
            availableWindows = result.1
            userNameCache = result.2
            cardSummary = result.3
            starredPeopleIDs = result.4
            currentUserID = result.5
            currentProfile = result.6
            interactions = result.7
            stoppedPeopleIDs = result.8
            selectedWindow = result.9
            errorMessage = nil
            loadFailed = false
        } catch {
            cards = []
            errorMessage = error.localizedDescription
            loadFailed = true
        }
        isLoading = false
    }

    func loadWindow(at index: Int) {
        guard index >= 0, index < availableWindows.count else { return }
        selectedWindow = index
        let window = availableWindows[index]
        do {
            let result = try dbManager.dbPool.read { db in
                let cards = try PeopleCardQueries.fetchForWindow(
                    db, from: window.from, to: window.to
                )
                let cs = try PeopleCardQueries.fetchSummary(
                    db, from: window.from, to: window.to
                )
                var ints: [UserInteraction] = []
                if let uid = currentUserID {
                    ints = try InteractionQueries.fetchForUser(
                        db, userID: uid, periodFrom: window.from, periodTo: window.to
                    )
                }
                return (cards, cs, ints)
            }
            cards = result.0
            cardSummary = result.1
            interactions = result.2
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func userName(for userID: String) -> String {
        userNameCache[userID] ?? userID
    }

    func cardHistory(userID: String) -> [PeopleCard] {
        do {
            return try dbManager.dbPool.read { db in
                try PeopleCardQueries.fetchByUser(db, userID: userID)
            }
        } catch {
            return []
        }
    }

    var currentWindowLabel: String {
        guard !availableWindows.isEmpty, selectedWindow < availableWindows.count else {
            return "No data"
        }
        let w = availableWindows[selectedWindow]
        return PeopleCardCopy.period(from: Date(timeIntervalSince1970: w.from), to: Date(timeIntervalSince1970: w.to))
    }

    // MARK: - Stop card for this person (#1769, A14)

    /// The owner stopped this person's card: no card is made for them.
    func isCardStopped(_ userID: String) -> Bool {
        stoppedPeopleIDs.contains(userID)
    }

    /// The stopped people by name, for the list's Stopped cards section.
    var stoppedPeople: [String] {
        stoppedPeopleIDs.sorted {
            userName(for: $0).localizedCaseInsensitiveCompare(userName(for: $1)) == .orderedAscending
        }
    }

    /// The failure of this person's last Stop card / Make cards again.
    func cardActionError(for userID: String) -> String? {
        cardActionErrors[userID]
    }

    func dismissCardActionError(for userID: String) {
        cardActionErrors[userID] = nil
    }

    /// Stop card or Make cards again for this person is running: its button waits.
    func isStopPending(_ userID: String) -> Bool {
        pendingWrites.isPending("stop:\(userID)")
    }

    /// Runs `watchtower people exclude`: the CLI deletes the person's cards
    /// and records the exclusion in one transaction.
    func stopCard(userID: String) async {
        await pendingWrites.run("stop:\(userID)") { await setCardStopped(userID: userID, stopped: true) }
    }

    /// Runs `watchtower people include`: the next people run may make a card.
    func makeCardsAgain(userID: String) async {
        await pendingWrites.run("stop:\(userID)") { await setCardStopped(userID: userID, stopped: false) }
    }

    /// The CLI's `--json` answer.
    private struct ExcludeAnswer: Decodable {
        let ok: Bool
    }

    /// No optimistic flip: a failure says why and leaves the card as the
    /// database has it.
    private func setCardStopped(userID: String, stopped: Bool) async {
        do {
            guard let runner = cliRunner else { throw CLIRunnerError.binaryNotFound }
            let args = ["people", stopped ? "exclude" : "include", "--user", userID, "--json"]
            let data = try await writes.runThrowing { try await runner.run(args: args) }
            // The CLI answers ok or exits non-zero; an answer that does not
            // decode is a failure too.
            _ = try JSONDecoder().decode(ExcludeAnswer.self, from: data)
            cardActionErrors[userID] = nil
            load()
        } catch {
            cardActionErrors[userID] = PeopleCardCopy.actionFailed(stopping: stopped, error.localizedDescription)
        }
    }

    // MARK: - Starred People Management

    func isPersonStarred(_ userID: String) -> Bool {
        starredPeopleIDs.contains(userID)
    }

    /// Look up the card for a specific user in the current window.
    func cardFor(userID: String) -> PeopleCard? {
        cards.first { $0.userID == userID }
    }

    /// Update profile connections (reports, peers, manager).
    /// Profile writes go by the owner's profile key
    /// (`ProfileQueries.ownerProfileWriteKey`), never `currentUserID` — that
    /// is the Slack id the cards and the graph are keyed by.
    /// Saves run one after another (board #670), so an older pick never
    /// lands after a newer one.
    func updateConnections(reports: [String], peers: [String], manager: String) async {
        await writes.run { await self.writeConnections(reports: reports, peers: peers, manager: manager) }
    }

    private func writeConnections(reports: [String], peers: [String], manager: String) async {
        do {
            let encoder = JSONEncoder()
            let reportsJSON = String(data: try encoder.encode(reports), encoding: .utf8) ?? "[]"
            let peersJSON = String(data: try encoder.encode(peers), encoding: .utf8) ?? "[]"
            try await dbManager.dbPool.write { db in
                let userID = try ProfileQueries.ownerProfileWriteKey(db)
                try ProfileQueries.updateField(db, slackUserID: userID, field: "reports", value: reportsJSON)
                try ProfileQueries.updateField(db, slackUserID: userID, field: "peers", value: peersJSON)
                try ProfileQueries.updateField(db, slackUserID: userID, field: "manager", value: manager)
            }
            // Reload profile
            currentProfile = try await dbManager.dbPool.read { db in
                try ProfileQueries.fetchCurrentProfile(db)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Failed to update connections: \(error.localizedDescription)"
        }
    }

    /// The star changes only once the write landed; a second press while it
    /// waits does nothing (board #670).
    func toggleStarredPerson(_ personUserID: String) async {
        await pendingWrites.run("star:\(personUserID)") {
            await writeStar(personUserID)
        }
    }

    /// The star of `personUserID` is being written: its button waits.
    func isStarPending(_ personUserID: String) -> Bool {
        pendingWrites.isPending("star:\(personUserID)")
    }

    private func writeStar(_ personUserID: String) async {
        let wasStarred = starredPeopleIDs.contains(personUserID)
        do {
            if wasStarred {
                try await writes.runThrowing { try await self.dbManager.removeStarredPerson(personUserID) }
                starredPeopleIDs.remove(personUserID)
            } else {
                try await writes.runThrowing { try await self.dbManager.addStarredPerson(personUserID) }
                starredPeopleIDs.insert(personUserID)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Failed to update starred person: \(error.localizedDescription)"
        }
    }
}
