import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// OWNER-01 on the Swift side: `OwnerQueries.resolve` is the twin of Go's
/// `ResolveOwner` (internal/db/owner.go). The ladder table below is a literal
/// copy of `TestOwner01_ResolveOwnerLadder` (internal/db/owner_test.go) — same
/// inputs, same expected values — so the two sides are pinned to one fixture.
final class OwnerQueriesTests: XCTestCase {

    // MARK: - Fixture

    private struct SlackSeed {
        var teamID: String
        var currentUserID = ""
        var status = "ok"
    }

    private struct UserSeed {
        var id: String
        var name: String
        var displayName = ""
        var realName = ""
        var email = ""
    }

    private struct JiraSeed {
        var cloudID: String
        var enabled: Bool
        var ownerAccountID: String
        var ownerEmail = ""
        var ownerDisplayName = ""
    }

    private struct LinearSeed {
        var enabled = true
        var status = "ok"
        var ownerUserID = ""
        var ownerEmail = ""
        var ownerDisplayName = ""
    }

    private struct UserMapSeed {
        var jiraAccountID: String
        var slackUserID: String
    }

    /// The identity rows one resolve case starts from; the Swift mirror of
    /// Go's `ownerSeed`.
    private struct OwnerSeed {
        var slack: [SlackSeed] = []      // inserted in order as slack_accounts id 1, 2, …
        var slackUser: UserSeed?
        var google: [String] = []        // google_accounts emails, in id order
        var jira: [JiraSeed] = []
        var jiraUserMap: [UserMapSeed] = []
        var linear: [LinearSeed] = []    // linear_accounts, in id order
        var mailboxes: [(provider: String, address: String)] = []  // email_accounts, in id order
    }

    private static func seed(_ db: Database, _ s: OwnerSeed) throws {
        for (i, a) in s.slack.enumerated() {
            let id = try TestDatabase.insertSlackAccount(
                db, teamID: a.teamID, currentUserID: a.currentUserID, status: a.status
            )
            XCTAssertEqual(id, Int64(i + 1), "slack accounts are seeded as ids 1, 2, …")
        }
        if let u = s.slackUser {
            try TestDatabase.insertUser(
                db, id: u.id, name: u.name, displayName: u.displayName,
                realName: u.realName, email: u.email
            )
        }
        for email in s.google {
            _ = try TestDatabase.insertGoogleAccount(db, email: email)
        }
        for j in s.jira {
            let id = try TestDatabase.insertJiraAccount(db, cloudID: j.cloudID, enabled: j.enabled)
            try db.execute(sql: """
                UPDATE jira_accounts SET owner_account_id = ?, owner_email = ?, owner_display_name = ?
                WHERE id = ?
                """, arguments: [j.ownerAccountID, j.ownerEmail, j.ownerDisplayName, id])
        }
        for l in s.linear {
            try db.execute(sql: """
                INSERT INTO linear_accounts (enabled, status, owner_user_id, owner_email, owner_display_name)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [l.enabled, l.status, l.ownerUserID, l.ownerEmail, l.ownerDisplayName])
        }
        for m in s.mailboxes {
            try TestDatabase.insertEmailAccount(db, provider: m.provider, emailAddress: m.address)
        }
        for m in s.jiraUserMap {
            try db.execute(
                sql: "INSERT INTO jira_user_map (jira_account_id, slack_user_id) VALUES (?, ?)",
                arguments: [m.jiraAccountID, m.slackUserID]
            )
        }
    }

    private static func owner(
        id: String = "",
        source: OwnerSource = .none,
        slackUserID: String = "",
        email: String = "",
        jiraAccountID: String = "",
        displayName: String = "",
        linearUserIDs: [String] = []
    ) -> Owner {
        Owner(id: id, source: source, slackUserID: slackUserID, email: email,
              jiraAccountID: jiraAccountID, displayName: displayName,
              linearUserIDs: linearUserIDs)
    }

    // MARK: - Ladder

    /// The Linear rows of the ladder table (Go: the `linear` cases of
    /// `TestOwner01_ResolveOwnerLadder`).
    private static let linearLadderCases: [(name: String, seed: OwnerSeed, want: Owner)] = [
            ("linear only",
             OwnerSeed(linear: [LinearSeed(ownerUserID: "user-1", ownerEmail: "owner@example.com", ownerDisplayName: "Owner")]),
             OwnerQueriesTests.owner(id: "linear:user-1", source: .linear, email: "owner@example.com", displayName: "Owner",
                                     linearUserIDs: ["user-1"])),
            ("jira + linear: jira wins ID and enrichment, linear ids still filled",
             OwnerSeed(jira: [JiraSeed(cloudID: "c1", enabled: true, ownerAccountID: "acc-9",
                                       ownerEmail: "j@x.com", ownerDisplayName: "J Doe")],
                       linear: [LinearSeed(ownerUserID: "user-1", ownerEmail: "owner@example.com", ownerDisplayName: "Owner")]),
             OwnerQueriesTests.owner(id: "jira:acc-9", source: .jira, email: "j@x.com", jiraAccountID: "acc-9", displayName: "J Doe",
                                     linearUserIDs: ["user-1"])),
            ("removed linear is skipped",
             OwnerSeed(linear: [LinearSeed(status: "removed", ownerUserID: "user-1")]),
             Owner.unknown),
            ("disabled linear is skipped",
             OwnerSeed(linear: [LinearSeed(enabled: false, ownerUserID: "user-1")]),
             Owner.unknown),
            ("linear account without an owner id is skipped",
             OwnerSeed(linear: [LinearSeed(), LinearSeed(ownerUserID: "user-2")]),
             OwnerQueriesTests.owner(id: "linear:user-2", source: .linear, linearUserIDs: ["user-2"])),
            ("two linear workspaces: first is the rung, both ids listed by account id",
             OwnerSeed(linear: [LinearSeed(ownerUserID: "user-1", ownerEmail: "owner@example.com"),
                                LinearSeed(ownerUserID: "user-2")]),
             OwnerQueriesTests.owner(id: "linear:user-1", source: .linear, email: "owner@example.com", displayName: "owner",
                                     linearUserIDs: ["user-1", "user-2"]))
    ]

    func testOwner01ResolveOwnerLadder() throws {
        let cases: [(name: String, seed: OwnerSeed, want: Owner)] = [
            ("none", OwnerSeed(), Owner.unknown),
            ("slack only",
             OwnerSeed(slack: [SlackSeed(teamID: "T1", currentUserID: "1:U123")],
                       slackUser: UserSeed(id: "1:U123", name: "owner-a", displayName: "Owner A", email: "owner-a@example.com")),
             Self.owner(id: "1:U123", source: .slack, slackUserID: "1:U123", email: "owner-a@example.com", displayName: "Owner A")),
            ("google only, mixed-case email",
             OwnerSeed(google: ["Me@X.com"]),
             Self.owner(id: "google:me@x.com", source: .google, email: "Me@X.com", displayName: "Me")),
            ("jira only",
             OwnerSeed(jira: [JiraSeed(cloudID: "c1", enabled: true, ownerAccountID: "acc-9",
                                       ownerEmail: "j@x.com", ownerDisplayName: "J Doe")]),
             Self.owner(id: "jira:acc-9", source: .jira, email: "j@x.com", jiraAccountID: "acc-9", displayName: "J Doe")),
            ("google + jira: google wins ID, jira enriches",
             OwnerSeed(google: ["me@x.com"],
                       jira: [JiraSeed(cloudID: "c1", enabled: true, ownerAccountID: "acc-9",
                                       ownerEmail: "j@x.com", ownerDisplayName: "J Doe")]),
             Self.owner(id: "google:me@x.com", source: .google, email: "me@x.com", jiraAccountID: "acc-9", displayName: "J Doe")),
            ("slack without current_user_id falls through to google",
             OwnerSeed(slack: [SlackSeed(teamID: "T1")], google: ["me@x.com"]),
             Self.owner(id: "google:me@x.com", source: .google, email: "me@x.com", displayName: "me")),
            ("removed slack is skipped",
             OwnerSeed(slack: [SlackSeed(teamID: "T1", currentUserID: "1:U123", status: "removed")], google: ["me@x.com"]),
             Self.owner(id: "google:me@x.com", source: .google, email: "me@x.com", displayName: "me")),
            ("slack #2 does not widen: account #1 stays the owner",
             OwnerSeed(slack: [SlackSeed(teamID: "T1", currentUserID: "1:U1"),
                               SlackSeed(teamID: "T2", currentUserID: "2:U2")]),
             Self.owner(id: "1:U1", source: .slack, slackUserID: "1:U1")),
            ("removed #1 + active #2 falls to google, never #2",
             OwnerSeed(slack: [SlackSeed(teamID: "T1", currentUserID: "1:U1", status: "removed"),
                               SlackSeed(teamID: "T2", currentUserID: "2:U2")],
                       google: ["me@x.com"]),
             Self.owner(id: "google:me@x.com", source: .google, email: "me@x.com", displayName: "me")),
            ("disabled jira is skipped",
             OwnerSeed(jira: [JiraSeed(cloudID: "c1", enabled: false, ownerAccountID: "acc-9")]),
             Owner.unknown),
            ("slack + jira_user_map bridge fills JiraAccountID",
             OwnerSeed(slack: [SlackSeed(teamID: "T1", currentUserID: "1:U123")],
                       slackUser: UserSeed(id: "1:U123", name: "owner-a", displayName: "Owner A"),
                       jiraUserMap: [UserMapSeed(jiraAccountID: "acc-map", slackUserID: "1:U123")]),
             Self.owner(id: "1:U123", source: .slack, slackUserID: "1:U123", jiraAccountID: "acc-map", displayName: "Owner A")),
            ("google account without an email is skipped",
             OwnerSeed(google: ["", "b@x.com"]),
             Self.owner(id: "google:b@x.com", source: .google, email: "b@x.com", displayName: "b")),
            ("slack user without display name falls back to real name",
             OwnerSeed(slack: [SlackSeed(teamID: "T1", currentUserID: "1:U123")],
                       slackUser: UserSeed(id: "1:U123", name: "owner-a", realName: "Owner A Real")),
             Self.owner(id: "1:U123", source: .slack, slackUserID: "1:U123", displayName: "Owner A Real")),
            ("bare-form jira_user_map row bridges a namespaced owner",
             OwnerSeed(slack: [SlackSeed(teamID: "T1", currentUserID: "1:U123")],
                       jiraUserMap: [UserMapSeed(jiraAccountID: "acc-bare", slackUserID: "U123")]),
             Self.owner(id: "1:U123", source: .slack, slackUserID: "1:U123", jiraAccountID: "acc-bare"))
        ] + Self.linearLadderCases
        XCTAssertEqual(cases.count, 20, "the Go ladder table has twenty cases; copy every one")

        for c in cases {
            let db = try TestDatabase.create()
            try db.write { try Self.seed($0, c.seed) }
            let got = try db.read { try OwnerQueries.resolve($0) }
            XCTAssertEqual(got.id, c.want.id, "\(c.name): id")
            XCTAssertEqual(got.source, c.want.source, "\(c.name): source")
            XCTAssertEqual(got.slackUserID, c.want.slackUserID, "\(c.name): slackUserID")
            XCTAssertEqual(got.email, c.want.email, "\(c.name): email")
            XCTAssertEqual(got.jiraAccountID, c.want.jiraAccountID, "\(c.name): jiraAccountID")
            XCTAssertEqual(got.displayName, c.want.displayName, "\(c.name): displayName")
            XCTAssertEqual(got.linearUserIDs, c.want.linearUserIDs, "\(c.name): linearUserIDs")
            XCTAssertEqual(got.isKnown, !c.want.id.isEmpty, "\(c.name): isKnown")
        }
    }

    /// The email rung (ask #307): a literal copy of Go's `TestOwner01_EmailRung`.
    func testOwner01EmailRung() throws {
        let jira = JiraSeed(cloudID: "c1", enabled: true, ownerAccountID: "acc-9", ownerEmail: "j@x.com", ownerDisplayName: "J Doe")
        let cases: [(name: String, seed: OwnerSeed, want: Owner)] = [
            ("imap only, mixed-case address",
             OwnerSeed(mailboxes: [("imap", "Me@Example.com")]),
             Self.owner(id: "email:me@example.com", source: .email, email: "Me@Example.com", displayName: "Me")),
            ("outlook only",
             OwnerSeed(mailboxes: [("outlook", "me@example.com")]),
             Self.owner(id: "email:me@example.com", source: .email, email: "me@example.com", displayName: "me")),
            ("mailbox without an address is skipped",
             OwnerSeed(mailboxes: [("imap", ""), ("imap", "b@example.com")]),
             Self.owner(id: "email:b@example.com", source: .email, email: "b@example.com", displayName: "b")),
            ("two mailboxes: the first is the rung",
             OwnerSeed(mailboxes: [("imap", "a@example.com"), ("imap", "b@example.com")]),
             Self.owner(id: "email:a@example.com", source: .email, email: "a@example.com", displayName: "a")),
            ("slack + mailbox: slack keeps the id and its email",
             OwnerSeed(slack: [SlackSeed(teamID: "T1", currentUserID: "1:U123")],
                       slackUser: UserSeed(id: "1:U123", name: "owner-a", displayName: "Owner A", email: "owner-a@example.com"),
                       mailboxes: [("imap", "me@example.com")]),
             Self.owner(id: "1:U123", source: .slack, slackUserID: "1:U123", email: "owner-a@example.com", displayName: "Owner A")),
            ("slack user without email: the mailbox fills Email",
             OwnerSeed(slack: [SlackSeed(teamID: "T1", currentUserID: "1:U123")],
                       slackUser: UserSeed(id: "1:U123", name: "owner-a", displayName: "Owner A"),
                       mailboxes: [("imap", "me@example.com")]),
             Self.owner(id: "1:U123", source: .slack, slackUserID: "1:U123", email: "me@example.com", displayName: "Owner A")),
            ("google + mailbox: google wins",
             OwnerSeed(google: ["g@x.com"], mailboxes: [("imap", "me@example.com")]),
             Self.owner(id: "google:g@x.com", source: .google, email: "g@x.com", displayName: "g")),
            ("jira + mailbox: jira wins ID and email",
             OwnerSeed(jira: [jira], mailboxes: [("imap", "me@example.com")]),
             Self.owner(id: "jira:acc-9", source: .jira, email: "j@x.com", jiraAccountID: "acc-9", displayName: "J Doe")),
            ("linear + mailbox: linear wins, the mailbox fills Email",
             OwnerSeed(linear: [LinearSeed(ownerUserID: "user-1", ownerDisplayName: "Owner")], mailboxes: [("imap", "me@example.com")]),
             Self.owner(id: "linear:user-1", source: .linear, email: "me@example.com", displayName: "Owner", linearUserIDs: ["user-1"]))
        ]
        XCTAssertEqual(cases.count, 9, "the Go email-rung table has nine cases; copy every one")

        for c in cases {
            let db = try TestDatabase.create()
            try db.write { try Self.seed($0, c.seed) }
            let got = try db.read { try OwnerQueries.resolve($0) }
            XCTAssertEqual(got, c.want, c.name)
            XCTAssertTrue(got.isKnown, c.name)
        }
    }

    func testOwner01SlackInstallIDUnchanged() throws {
        // An existing Slack install that ALSO has Google + Jira connected keeps
        // its Slack id as the owner id — the one guarantee for every live install.
        let db = try TestDatabase.create()
        try db.write {
            try Self.seed($0, OwnerSeed(
                slack: [SlackSeed(teamID: "T1", currentUserID: "1:U123")],
                slackUser: UserSeed(id: "1:U123", name: "owner-a", displayName: "Owner A", email: "owner-a@example.com"),
                google: ["me@x.com"],
                jira: [JiraSeed(cloudID: "c1", enabled: true, ownerAccountID: "acc-9",
                                ownerEmail: "j@x.com", ownerDisplayName: "J Doe")],
                linear: [LinearSeed(ownerUserID: "user-1", ownerEmail: "owner@example.com", ownerDisplayName: "Owner")]
            ))
        }
        let got = try db.read { try OwnerQueries.resolve($0) }
        XCTAssertEqual(got, Self.owner(id: "1:U123", source: .slack, slackUserID: "1:U123",
                                       email: "owner-a@example.com", jiraAccountID: "acc-9", displayName: "Owner A",
                                       linearUserIDs: ["user-1"]))
    }

    // MARK: - Profile singleton

    func testOwner01ProfileSurvivesRungSwitch() throws {
        let db = try TestDatabase.create()
        let google = Self.owner(id: "google:me@x.com", source: .google)
        try db.write {
            try ProfileQueries.upsertOwnerProfile(
                $0, owner: google, profile: UserProfile(slackUserID: "", role: "EM", team: "Core")
            )
        }
        let slack = Self.owner(id: "1:U123", source: .slack)
        // No row keyed 1:U123 yet → falls back to the only row.
        let fallback = try XCTUnwrap(db.read { try ProfileQueries.fetchOwnerProfile($0, owner: slack) })
        XCTAssertEqual(fallback.role, "EM")

        try db.write {
            try ProfileQueries.upsertOwnerProfile(
                $0, owner: slack, profile: UserProfile(slackUserID: "", role: "Director", team: "Core")
            )
        }
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM user_profile") }
        XCTAssertEqual(count, 1, "the rung switch re-keys the one row, never adds a second")
        let switched = try XCTUnwrap(db.read { try ProfileQueries.fetchOwnerProfile($0, owner: slack) })
        XCTAssertEqual(switched.slackUserID, "1:U123")
        XCTAssertEqual(switched.role, "Director")
    }

    func testOwner01OwnerKeyedProfileBeatsStaleRow() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try ProfileQueries.upsertProfile(db, profile: UserProfile(slackUserID: "1:U123", role: "Mine"))
            try ProfileQueries.upsertProfile(db, profile: UserProfile(slackUserID: "legacy:x", role: "Stale"))
            // Make the stale row strictly newer: strftime has one-second
            // resolution, so two back-to-back upserts can tie.
            try db.execute(sql: """
                UPDATE user_profile SET updated_at = '2099-01-01T00:00:00Z' WHERE slack_user_id = 'legacy:x'
                """)
        }
        let profile = try XCTUnwrap(db.read {
            try ProfileQueries.fetchOwnerProfile($0, owner: Self.owner(id: "1:U123"))
        })
        XCTAssertEqual(profile.role, "Mine", "an exact-key row always wins over the most-recent fallback")
    }

    func testOwner01UnknownOwnerProfileIsNil() throws {
        let db = try TestDatabase.create()
        try db.write { try ProfileQueries.upsertProfile($0, profile: UserProfile(slackUserID: "legacy:x", role: "Stale")) }
        let profile = try db.read { try ProfileQueries.fetchOwnerProfile($0, owner: .unknown) }
        XCTAssertNil(profile)
    }

    func testOwner01UnknownOwnerUpsertThrowsNoOwner() throws {
        let db = try TestDatabase.create()
        XCTAssertThrowsError(try db.write {
            try ProfileQueries.upsertOwnerProfile($0, owner: .unknown, profile: UserProfile(slackUserID: "", role: "EM"))
        }) { error in
            XCTAssertEqual(error as? OwnerError, .noOwner)
            XCTAssertEqual(error.localizedDescription, "no owner identity: connect Slack, Google, Jira, Linear or an email account first")
        }
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM user_profile") }
        XCTAssertEqual(count, 0)
    }

    // MARK: - Email rung edges (Go: the TestOwner01_EmailRung… / CalDAV / RungSwitch tests)

    func testOwner01EmailRungIgnoresBareLogins() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            for login in ["jdoe", #"DOMAIN\jdoe"#, "@example.com"] {
                try TestDatabase.insertEmailAccount(db, emailAddress: login)
            }
        }
        XCTAssertEqual(try db.read { try OwnerQueries.resolve($0) }, .unknown)
        try db.write { try Self.seed($0, OwnerSeed(linear: [LinearSeed(ownerUserID: "user-1")])) }
        XCTAssertEqual(try db.read { try OwnerQueries.resolve($0) },
                       Self.owner(id: "linear:user-1", source: .linear, linearUserIDs: ["user-1"]),
                       "a bare login never fills email")
    }

    func testOwner01EmailRungOrdersByID() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: "INSERT INTO email_accounts (id, provider, email_address) VALUES (2, 'imap', 'a@example.com')")
            try db.execute(sql: "INSERT INTO email_accounts (id, provider, email_address) VALUES (1, 'imap', 'b@example.com')")
        }
        XCTAssertEqual(try db.read { try OwnerQueries.resolve($0) }.id, "email:b@example.com")
    }

    func testOwner01CalDAVOnlyHasNoOwner() throws {
        let db = try TestDatabase.create()
        try db.write { try TestDatabase.insertCalendarAccount($0, username: "me@example.com") }
        let (owner, pending) = try db.read { try OwnerQueries.resolveWithPending($0) }
        XCTAssertEqual(owner, .unknown)
        XCTAssertNil(pending)
    }

    /// An enabled Jira/Linear account without its owner id yet is what the
    /// unknown owner waits on; once it has one, nothing is pending.
    func testOwner01PendingIdentitySource() throws {
        let db = try TestDatabase.create()
        try db.write { try Self.seed($0, OwnerSeed(linear: [LinearSeed()])) }
        XCTAssertEqual(try db.read { try OwnerQueries.resolveWithPending($0) }.1, "Linear")
        try db.write { try Self.seed($0, OwnerSeed(jira: [JiraSeed(cloudID: "c1", enabled: true, ownerAccountID: "")])) }
        XCTAssertEqual(try db.read { try OwnerQueries.resolveWithPending($0) }.1, "Jira", "Jira first")
        try db.write { try $0.execute(sql: "UPDATE jira_accounts SET enabled = 0") }
        try db.write { try $0.execute(sql: "UPDATE linear_accounts SET status = 'removed'") }
        XCTAssertNil(try db.read { try OwnerQueries.resolveWithPending($0) }.1)
    }

    /// Revoked or failing accounts will not report an owner: Home asks to
    /// (re)connect instead of "Waiting…".
    func testOwner01PendingIdentityIgnoresUnhealthyAccounts() throws {
        for status in ["revoked", "error"] {
            let db = try TestDatabase.create()
            try db.write { try Self.seed($0, OwnerSeed(jira: [JiraSeed(cloudID: "c1", enabled: true, ownerAccountID: "")])) }
            try db.write { try $0.execute(sql: "UPDATE jira_accounts SET status = ?", arguments: [status]) }
            XCTAssertNil(try db.read { try OwnerQueries.resolveWithPending($0) }.1, status)
        }
    }

    /// The Swift twin of Go's `UpsertOwnerProfile` re-key: a profile write
    /// after a rung switch also moves the briefings and day plans written
    /// under the earlier id; a date the owner already has keeps its row.
    func testOwner01ProfileWriteAdoptsBriefingsAndDayPlans() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try TestDatabase.insertBriefing(db, userID: "email:x@example.com", date: "2026-10-16", role: "Old")
            try TestDatabase.insertBriefing(db, userID: "email:x@example.com", date: "2026-10-17", role: "Stale")
            try TestDatabase.insertBriefing(db, userID: "jira:acc-9", date: "2026-10-17", role: "Mine")
            try TestDatabase.insertDayPlan(db, userID: "email:x@example.com", planDate: "2026-10-17")
            let jira = Self.owner(id: "jira:acc-9", source: .jira, jiraAccountID: "acc-9")
            try ProfileQueries.upsertOwnerProfile(db, owner: jira, profile: UserProfile(slackUserID: "", role: "EM"))
        }
        let roles = try db.read {
            try String.fetchAll($0, sql: "SELECT role FROM briefings WHERE user_id = 'jira:acc-9' ORDER BY date")
        }
        XCTAssertEqual(roles, ["Old", "Mine"])
        let plans = try db.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM day_plans WHERE user_id = 'jira:acc-9'")
        }
        XCTAssertEqual(plans, 1)
    }

    // MARK: - Migrated sites (Google-only fixtures)

    func testOwner01FetchCurrentProfileGoogleOnly() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "Me@X.com")
            try TestDatabase.insertProfile(db, slackUserID: "google:me@x.com", role: "EM")
        }
        let profile = try XCTUnwrap(db.read { try ProfileQueries.fetchCurrentProfile($0) })
        XCTAssertEqual(profile.role, "EM")
    }

    /// The ProfileSettings save path: resolve + upsertOwnerProfile inside one
    /// write, on an install with no Slack account.
    func testOwner01ProfileSaveGoogleOnlyWritesOneGoogleKeyedRow() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "Me@X.com")
            try ProfileQueries.upsertOwnerProfile(
                db, owner: OwnerQueries.resolve(db), profile: UserProfile(slackUserID: "", role: "EM")
            )
        }
        let keys = try db.read { try String.fetchAll($0, sql: "SELECT slack_user_id FROM user_profile") }
        XCTAssertEqual(keys, ["google:me@x.com"])
    }

    // MARK: - OWNER-01 scan

    /// Every owner-identity read in the Desktop goes through
    /// `OwnerQueries.resolve`: no Swift source outside the resolver may read
    /// Slack account #1's `current_user_id` directly.
    func testOwner01NoRawOwnerQueriesOutsideResolver() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        // The Go scan's pattern: any spelling (multi-line literal, `id=1`, a
        // different predicate) of a raw current_user_id read from slack_accounts.
        let forbidden = try NSRegularExpression(pattern: #"current_user_id\s+FROM\s+slack_accounts\b"#)
        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            if url.lastPathComponent == "OwnerQueries.swift" { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if forbidden.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                offenders.append(url.path.replacingOccurrences(of: sources.path + "/", with: ""))
            }
        }
        XCTAssertGreaterThanOrEqual(scanned, 200, "the scan must actually walk WatchtowerDesktop/Sources")
        XCTAssertEqual(offenders, [], "raw owner reads outside OwnerQueries.swift — use OwnerQueries.resolve")
    }
}
