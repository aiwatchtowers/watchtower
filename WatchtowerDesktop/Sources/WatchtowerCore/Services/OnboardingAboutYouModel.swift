import Foundation
import GRDB
import Observation

/// Onboarding's About you step: role and team, manager, reports and peers,
/// picked from the synced Slack users. Held by `AppState` so the answers
/// survive Back to Connect and return.
@MainActor
@Observable
package final class OnboardingAboutYouModel {
    package var role = ""
    /// A namespaced Slack user id; empty for none.
    package var manager = ""
    package var reports: [String] = []
    package var peers: [String] = []
    /// The pickable people: active humans other than the owner.
    package private(set) var people: [User] = []
    /// Slack account id → workspace name, filled only when more than one
    /// Slack account is connected (one workspace needs no label).
    package private(set) var workspaceNames: [Int: String] = [:]
    /// The profile could not be read: Done stays off (it would write empty
    /// fields over the real ones) until a Retry reads it.
    package private(set) var profileError: String?
    package private(set) var peopleError: String?

    /// The form holds the profile Done writes over
    /// (`OnboardingProfileWriter.current`), read once per onboarding run.
    /// Done overwrites the people fields with exactly what the form holds,
    /// so it is allowed only once this is true.
    package private(set) var isPrefilled = false

    package init() {}

    /// What Done writes: the manager trimmed, empty ids dropped.
    package var answers: OnboardingAboutYou {
        OnboardingAboutYou(
            role: role,
            manager: manager.trimmingCharacters(in: .whitespacesAndNewlines),
            reports: Self.cleaned(reports),
            peers: Self.cleaned(peers)
        )
    }

    /// Every picked id, across the three fields — one person fills one role.
    package var allPicked: [String] {
        (manager.isEmpty ? [] : [manager]) + reports + peers
    }

    /// Prefills (first time per run, again after a failure) and reads the
    /// people.
    package func load(from pool: DatabasePool) async {
        if !isPrefilled {
            do {
                let current = try await pool.read { db in try OnboardingProfileWriter.currentAnswers(db) }
                role = current.role
                manager = current.manager
                reports = Self.cleaned(current.reports)
                peers = Self.cleaned(current.peers)
                isPrefilled = true
                profileError = nil
            } catch {
                profileError = "Could not read your profile: \(error.localizedDescription)"
            }
        }
        await reloadPeople(from: pool)
    }

    /// The step has no database to read from.
    package func databaseUnavailable() {
        profileError = "Could not read your profile: the database is not open."
    }

    /// Re-reads the people (while the roster load is still saving them).
    /// Never touches `profileError`.
    package func reloadPeople(from pool: DatabasePool) async {
        do {
            let (users, names) = try await pool.read { db in
                (try Self.pickablePeople(db), try Self.workspaceNames(db))
            }
            people = users
            workspaceNames = names
            peopleError = nil
        } catch {
            peopleError = "Could not read people: \(error.localizedDescription)"
        }
    }

    /// The workspace label for a user, nil with one workspace.
    package func workspaceName(for userID: String) -> String? {
        SlackAccountID.split(userID).flatMap { workspaceNames[$0.accountID] }
    }

    /// "Run setup again": prefill from the profile again.
    package func prepareForRerun() {
        isPrefilled = false
        profileError = nil
    }

    /// Active, non-bot users other than Slackbot and the owner (any Slack
    /// account's current user, and the resolved owner).
    package nonisolated static func pickablePeople(_ db: Database) throws -> [User] {
        var owners = try String.fetchAll(db, sql: "SELECT current_user_id FROM slack_accounts WHERE current_user_id != ''")
        let owner = try OwnerQueries.resolve(db)
        if owner.isKnown { owners.append(owner.id) }
        return try UserQueries.fetchAll(db, activeOnly: true).filter { user in
            !user.isBot
                && SlackAccountID.raw(user.id) != "USLACKBOT"
                && !owners.contains { SlackAccountID.matches($0, user.id) }
        }
    }

    nonisolated static func workspaceNames(_ db: Database) throws -> [Int: String] {
        let accounts = try SlackAccountQueries.fetchAll(db).filter { $0.status != "removed" }
        guard accounts.count > 1 else { return [:] }
        return Dictionary(accounts.map { ($0.id, $0.displayName) }) { first, _ in first }
    }

    /// `people` matching `query` by display name, real name or @handle
    /// (case and diacritics ignored), minus `excluded` ids; at most `limit`.
    /// A blank query matches nothing.
    package nonisolated static func search(
        _ query: String,
        in people: [User],
        excluding excluded: [String],
        limit: Int = 8
    ) -> [User] {
        var needle = query.trimmingCharacters(in: .whitespaces)
        if needle.hasPrefix("@") { needle.removeFirst() }
        guard !needle.isEmpty else { return [] }
        let matches = people.lazy.filter { user in
            !excluded.contains { SlackAccountID.matches($0, user.id) }
                && [user.displayName, user.realName, user.name].contains {
                    $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
        }
        return Array(matches.prefix(limit))
    }

    nonisolated private static func cleaned(_ ids: [String]) -> [String] {
        ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
