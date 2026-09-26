import GRDB

package enum ProfileQueries {
    /// Reserved `user_profile.slack_user_id` key for a profile written before
    /// any account yields an owner (onboarding never dead-ends without one).
    /// Because `user_profile` is an owner singleton, the first
    /// `fetchOwnerProfile`/`upsertOwnerProfile` for a real owner falls back to
    /// the newest row and re-keys it, so answers parked here survive — as does
    /// Go's `GetOwnerProfile`/`UpsertOwnerProfile`, which apply the same
    /// newest-row fallback and never need to know this key.
    package static let pendingOwnerKey = "pending:owner"

    /// The key a profile write targets while no owner exists: the newest
    /// existing row's key — so the singleton never grows a second row that
    /// could later lose to an exact-key match — else `pendingOwnerKey`.
    package static func noOwnerProfileKey(_ db: Database) throws -> String {
        try latestProfileKey(db) ?? pendingOwnerKey
    }

    package static func fetchProfile(_ db: Database, slackUserID: String) throws -> UserProfile? {
        guard try db.tableExists("user_profile") else { return nil }
        return try UserProfile.fetchOne(
            db,
            sql: """
                SELECT * FROM user_profile WHERE slack_user_id = ?
                """,
            arguments: [slackUserID]
        )
    }

    /// The owner's profile (`fetchOwnerProfile` for the resolved owner).
    package static func fetchCurrentProfile(_ db: Database) throws -> UserProfile? {
        try fetchOwnerProfile(db, owner: OwnerQueries.resolve(db))
    }

    /// Swift mirror of Go's `db.GetOwnerProfile` (internal/db/profile.go) —
    /// change both together. `user_profile` is an owner singleton: the row
    /// keyed `owner.id` wins; without one, the most recently updated row
    /// stands in (the owner switched rungs, e.g. a Google-keyed profile before
    /// Slack was connected). An unknown owner → nil.
    package static func fetchOwnerProfile(_ db: Database, owner: Owner) throws -> UserProfile? {
        guard owner.isKnown, try db.tableExists("user_profile") else { return nil }
        if let exact = try fetchProfile(db, slackUserID: owner.id) { return exact }
        guard let key = try latestProfileKey(db) else { return nil }
        return try fetchProfile(db, slackUserID: key)
    }

    /// Swift mirror of Go's `db.UpsertOwnerProfile` — change both together.
    /// Writes `profile` under `owner.id`. When no row is keyed `owner.id` yet
    /// but a fallback row exists (the owner switched rungs), that row is
    /// re-keyed first, inside the caller's write transaction — the table
    /// keeps exactly one owner row. An unknown owner throws `OwnerError.noOwner`.
    package static func upsertOwnerProfile(_ db: Database, owner: Owner, profile: UserProfile) throws {
        guard owner.isKnown else { throw OwnerError.noOwner }
        try rekeyOwnerProfile(db, ownerID: owner.id)
        let keyed = UserProfile(
            id: profile.id, slackUserID: owner.id, role: profile.role, team: profile.team,
            responsibilities: profile.responsibilities, reports: profile.reports, peers: profile.peers,
            manager: profile.manager, starredChannels: profile.starredChannels,
            starredPeople: profile.starredPeople, painPoints: profile.painPoints,
            trackFocus: profile.trackFocus, onboardingDone: profile.onboardingDone,
            customPromptContext: profile.customPromptContext
        )
        try upsertProfile(db, profile: keyed)
    }

    /// The key a single-field profile write (`updateField`, the starred
    /// lists) targets, called inside the caller's write transaction: the
    /// owner's id after re-keying the fallback row onto it (the
    /// `upsertOwnerProfile` rule), else `noOwnerProfileKey`. The row is
    /// created when missing, so such a write never hits zero rows silently.
    package static func ownerProfileWriteKey(_ db: Database) throws -> String {
        let owner = try OwnerQueries.resolve(db)
        let key: String
        if owner.isKnown {
            try rekeyOwnerProfile(db, ownerID: owner.id)
            key = owner.id
        } else {
            key = try noOwnerProfileKey(db)
        }
        try db.execute(sql: """
            INSERT INTO user_profile (slack_user_id, updated_at)
            VALUES (?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            ON CONFLICT(slack_user_id) DO NOTHING
            """, arguments: [key])
        return key
    }

    /// The slack_user_id of the most recently updated profile row (tie →
    /// greatest id), or nil when the table is empty.
    package static func latestProfileKey(_ db: Database) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT slack_user_id FROM user_profile ORDER BY updated_at DESC, id DESC LIMIT 1
            """)
    }

    /// Moves the fallback profile row onto ownerID when no row is keyed
    /// ownerID yet. A no-op when ownerID already has a row or the table is empty.
    private static func rekeyOwnerProfile(_ db: Database, ownerID: String) throws {
        if try fetchProfile(db, slackUserID: ownerID) != nil { return }
        guard let key = try latestProfileKey(db) else { return }
        try db.execute(
            sql: "UPDATE user_profile SET slack_user_id = ? WHERE slack_user_id = ?",
            arguments: [ownerID, key]
        )
    }

    package static func upsertProfile(_ db: Database, profile: UserProfile) throws {
        try db.execute(sql: """
            INSERT INTO user_profile
                (slack_user_id, role, team, responsibilities, reports, peers, manager,
                 starred_channels, starred_people, pain_points, track_focus,
                 onboarding_done, custom_prompt_context, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            ON CONFLICT(slack_user_id) DO UPDATE SET
                role = excluded.role,
                team = excluded.team,
                responsibilities = excluded.responsibilities,
                reports = excluded.reports,
                peers = excluded.peers,
                manager = excluded.manager,
                starred_channels = excluded.starred_channels,
                starred_people = excluded.starred_people,
                pain_points = excluded.pain_points,
                track_focus = excluded.track_focus,
                onboarding_done = excluded.onboarding_done,
                custom_prompt_context = excluded.custom_prompt_context,
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
            """, arguments: [
                profile.slackUserID, profile.role, profile.team,
                profile.responsibilities, profile.reports, profile.peers, profile.manager,
                profile.starredChannels, profile.starredPeople,
                profile.painPoints, profile.trackFocus,
                profile.onboardingDone, profile.customPromptContext
            ])
    }

    /// Updates a single field on the user profile.
    /// Uses a switch statement mapping field names to explicit SQL to prevent injection.
    package static func updateField(_ db: Database, slackUserID: String, field: String, value: String) throws {
        let column: String
        switch field {
        case "role": column = "role"
        case "team": column = "team"
        case "responsibilities": column = "responsibilities"
        case "reports": column = "reports"
        case "peers": column = "peers"
        case "manager": column = "manager"
        case "starred_channels": column = "starred_channels"
        case "starred_people": column = "starred_people"
        case "pain_points": column = "pain_points"
        case "track_focus": column = "track_focus"
        case "custom_prompt_context": column = "custom_prompt_context"
        default: return
        }
        try db.execute(sql: """
            UPDATE user_profile SET \(column) = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
            WHERE slack_user_id = ?
            """, arguments: [value, slackUserID])
    }
}
