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
    /// The pickable people: active, non-bot users.
    package private(set) var people: [User] = []
    package private(set) var loadError: String?

    /// Prefilled once per onboarding run. Always from the profile Done
    /// writes over (`OnboardingProfileWriter.current`): Done overwrites the
    /// people fields with exactly what the form holds, so an untouched field
    /// must hold what is there.
    @ObservationIgnored private var prefilled = false

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

    /// Prefills (first time per run) and reads the people.
    package func load(from pool: DatabasePool) async {
        if !prefilled {
            do {
                let current = try await pool.read { db in try OnboardingProfileWriter.currentAnswers(db) }
                role = current.role
                manager = current.manager
                reports = Self.cleaned(current.reports)
                peers = Self.cleaned(current.peers)
                prefilled = true
            } catch {
                loadError = "Could not read your profile: \(error.localizedDescription)"
                return
            }
        }
        await reloadPeople(from: pool)
    }

    /// Re-reads the people (while the roster load is still saving them).
    package func reloadPeople(from pool: DatabasePool) async {
        do {
            people = try await pool.read { db in try Self.pickablePeople(db) }
            loadError = nil
        } catch {
            loadError = "Could not read people: \(error.localizedDescription)"
        }
    }

    /// "Run setup again": prefill from the profile again.
    package func prepareForRerun() {
        prefilled = false
    }

    package nonisolated static func pickablePeople(_ db: Database) throws -> [User] {
        try UserQueries.fetchAll(db, activeOnly: true).filter { !$0.isBot }
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
