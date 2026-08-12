import GRDB
import WatchtowerCore

package enum GoogleAccountQueries {
    package static func fetchAll(_ db: Database) throws -> [GoogleAccount] {
        try GoogleAccount.fetchAll(
            db,
            sql: "SELECT * FROM google_accounts ORDER BY id ASC"
        )
    }

    /// True when at least one account has granted Calendar access and its
    /// OAuth grant is currently healthy. The DB-derived replacement for the
    /// old file-stat check (`google_token_1.json` existence), which only ever
    /// reflected account #1 and couldn't distinguish Calendar from Gmail.
    package static func hasConnectedCalendarAccount(_ db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM google_accounts WHERE calendar_enabled = 1 AND status = 'ok')"
        ) ?? false
    }

    /// Same as `hasConnectedCalendarAccount` but for Gmail access.
    package static func hasConnectedGmailAccount(_ db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM google_accounts WHERE gmail_enabled = 1 AND status = 'ok')"
        ) ?? false
    }
}
