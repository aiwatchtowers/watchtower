import Foundation
import GRDB

/// What onboarding's "About you" step collects. People are namespaced Slack
/// ids (`<acct>:<id>`); `role` is free text (role and team in the owner's
/// own words).
package struct OnboardingAboutYou: Equatable, Sendable {
    package var role: String
    package var manager: String
    package var reports: [String]
    package var peers: [String]

    package init(role: String = "", manager: String = "", reports: [String] = [], peers: [String] = []) {
        self.role = role
        self.manager = manager
        self.reports = reports
        self.peers = peers
    }
}

/// Onboarding's profile writes — no LLM. Both exits set `onboarding_done`:
/// Done also writes the About-you answers, Later writes the flag alone.
/// `custom_prompt_context` and every other column are carried over from the
/// existing row, never touched.
///
/// Owner rules are OWNER-01's (docs/inventory/owner-identity.md): a known
/// owner writes through `ProfileQueries.upsertOwnerProfile` (singleton
/// re-key); with no owner yet the write lands on `noOwnerProfileKey` — the
/// existing row, else `pendingOwnerKey` — which the first owner adopts.
/// Each call is meant to run inside one write transaction, so the read and
/// the upsert cannot interleave with another profile write.
package enum OnboardingProfileWriter {
    /// Done: the answers plus `onboarding_done = 1`. An empty role keeps
    /// the existing one.
    package static func done(_ db: Database, about: OnboardingAboutYou) throws {
        let reports = try encode(about.reports)
        let peers = try encode(about.peers)
        try write(db) { profile in
            let role = about.role.trimmingCharacters(in: .whitespacesAndNewlines)
            if !role.isEmpty { profile.role = role }
            profile.manager = about.manager
            profile.reports = reports
            profile.peers = peers
        }
    }

    /// Later: `onboarding_done = 1` only.
    package static func later(_ db: Database) throws {
        try write(db) { _ in }
    }

    private static func write(_ db: Database, edit: (inout UserProfile) -> Void) throws {
        let owner = try OwnerQueries.resolve(db)
        let key = owner.isKnown ? owner.id : try ProfileQueries.noOwnerProfileKey(db)
        let existing = owner.isKnown
            ? try ProfileQueries.fetchOwnerProfile(db, owner: owner)
            : try ProfileQueries.fetchProfile(db, slackUserID: key)
        var profile = existing ?? UserProfile(slackUserID: key)
        edit(&profile)
        profile.onboardingDone = true
        if owner.isKnown {
            try ProfileQueries.upsertOwnerProfile(db, owner: owner, profile: profile)
        } else {
            try ProfileQueries.upsertProfile(db, profile: profile)
        }
    }

    private static func encode(_ ids: [String]) throws -> String {
        // JSONEncoder always emits UTF-8; the fallback is unreachable.
        String(bytes: try JSONEncoder().encode(ids), encoding: .utf8) ?? "[]"
    }
}
