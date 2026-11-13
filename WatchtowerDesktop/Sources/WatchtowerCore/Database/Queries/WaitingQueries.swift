import Foundation
import GRDB

/// The open people items by section (Waiting for me).
package struct PeopleWaitingCounts: Equatable, Sendable {
    package var open, today, week, older: Int

    package init(open: Int, today: Int, week: Int, older: Int) {
        self.open = open
        self.today = today
        self.week = week
        self.older = older
    }

    package static let zero = Self(open: 0, today: 0, week: 0, older: 0)
}

/// One sender of open, unmuted mail (a Mail waiting row).
package struct MailSenderRow: Equatable, Sendable {
    /// The sender's `InboxPeopleRule.senderKey`; "" for mail with no address.
    package let address: String
    package let open, today: Int
    /// The newest item's snippet before " — ".
    package let subject: String

    package init(address: String, open: Int, today: Int, subject: String) {
        self.address = address
        self.open = open
        self.today = today
        self.subject = subject
    }
}

/// The sender view of the open, unmuted mail.
package struct MailWaitingSummary: Equatable, Sendable {
    /// Over every sender; `topTenShare` is the top ten senders' share of
    /// `open` in whole percent, rounded half up (0 with no mail).
    package let open, today, senderCount, topTenShare: Int
    /// The busiest senders first, at most the limit asked.
    package let senders: [MailSenderRow]

    package init(open: Int, today: Int, senderCount: Int, topTenShare: Int, senders: [MailSenderRow]) {
        self.open = open
        self.today = today
        self.senderCount = senderCount
        self.topTenShare = topTenShare
        self.senders = senders
    }

    package static let empty = Self(open: 0, today: 0, senderCount: 0, topTenShare: 0, senders: [])
}

/// The reads of Waiting for me and Mail waiting, Go twins of
/// `db.OpenPeopleCounts` and `db.OpenMailSenders` (`WaitingSplitParityTests`).
/// Open = `HomeFeedQueries.openMessageClause`; stamp = MAX(created_at,
/// mentioned_at); today = stamp at or after `startOfTodayUTC`; older = stamp
/// at or before now − 7 × 24 h and not today; week = the rest. Times are RFC
/// 3339 UTC strings; an unparsable `nowUTC` reads as the current time, as
/// `InboxRefState` and `InboxFolderMenuSnapshot` read it. A missing items
/// table reads as no items; a missing rules table as no mutes.
package enum WaitingQueries {
    /// Go's `db.WaitingOlderAfter`.
    package static let olderAfter: TimeInterval = 7 * 24 * 3600

    /// The open, unmuted mail. The mute clause only while its table is
    /// there: without it nothing is muted, and the mail still reads.
    private static func mailFilter(_ db: Database) throws -> String {
        let open = "\(HomeFeedQueries.openMessageClause) AND \(InboxPeopleRule.mailClause)"
        return try db.tableExists("inbox_learned_rules") ? open + " AND \(InboxPeopleRule.mutedMailClause)" : open
    }

    /// Every open people item (no cap) by section, in one read.
    package static func peopleCounts(_ db: Database, nowUTC: String, startOfTodayUTC: String) throws -> PeopleWaitingCounts {
        let now = AutomationDates.parse(nowUTC) ?? Date()
        let cutoff = AutomationDates.format(now.addingTimeInterval(-olderAfter))
        return try missingTableAsEmpty(.zero) {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS open, COALESCE(SUM(stamp >= ?), 0) AS today,
                  COALESCE(SUM(stamp < ? AND stamp <= ?), 0) AS older
                FROM (SELECT MAX(created_at, mentioned_at) AS stamp FROM inbox_items
                  WHERE \(HomeFeedQueries.openMessageClause) AND \(InboxPeopleRule.peopleClause))
                """, arguments: [startOfTodayUTC, startOfTodayUTC, cutoff, nowUTC]) else { return .zero }
            let open: Int = row["open"], today: Int = row["today"], older: Int = row["older"]
            return PeopleWaitingCounts(open: open, today: today, week: open - today - older, older: older)
        }
    }

    /// The open, unmuted mail grouped by sender key, ordered open DESC,
    /// newest item DESC, address ASC; `senders` is capped at `limit`, the
    /// totals are not.
    package static func mailSenders(
        _ db: Database, nowUTC: String, startOfTodayUTC: String, limit: Int
    ) throws -> MailWaitingSummary {
        try missingTableAsEmpty(.empty) {
            let rows = try Row.fetchAll(db, sql: """
                SELECT lower(trim(sender_user_id)) AS address, MAX(created_at, mentioned_at) AS stamp, snippet
                FROM inbox_items WHERE \(try mailFilter(db))
                ORDER BY stamp DESC, id DESC
                """, arguments: [nowUTC])
            var senders: [(row: MailSenderRow, newest: String)] = []
            var index: [String: Int] = [:]
            var open = 0, today = 0
            for row in rows {
                let address: String = row["address"] ?? ""
                let stamp: String = row["stamp"] ?? ""
                let fromToday = stamp >= startOfTodayUTC
                open += 1
                today += fromToday ? 1 : 0
                // Rows come newest first: a sender's first row is its newest.
                guard let i = index[address] else {
                    index[address] = senders.count
                    senders.append((MailSenderRow(address: address, open: 1, today: fromToday ? 1 : 0,
                                                  subject: subject(row["snippet"] ?? "")), stamp))
                    continue
                }
                let s = senders[i].row
                senders[i].row = MailSenderRow(address: s.address, open: s.open + 1,
                                               today: s.today + (fromToday ? 1 : 0), subject: s.subject)
            }
            senders.sort { a, b in
                if a.row.open != b.row.open { return a.row.open > b.row.open }
                if a.newest != b.newest { return a.newest > b.newest }
                return a.row.address < b.row.address
            }
            let top = senders.prefix(10).reduce(0) { $0 + $1.row.open }
            return MailWaitingSummary(
                open: open, today: today, senderCount: senders.count,
                topTenShare: open > 0 ? (100 * top + open / 2) / open : 0,
                senders: senders.prefix(max(limit, 0)).map(\.row))
        }
    }

    /// The `keys` that still have open, unmuted mail (Mail waiting's rows
    /// drawn: a `mail_sender` ref is shown), each with its newest such
    /// mail's link ("" when that item has none), in one read.
    package static func newestOpenMail(_ db: Database, keys: [String], nowUTC: String) throws -> [String: String] {
        guard !keys.isEmpty else { return [:] }
        return try missingTableAsEmpty([:]) {
            let rows = try Row.fetchAll(db, sql: """
                SELECT address, permalink FROM (
                  SELECT lower(trim(sender_user_id)) AS address, permalink, ROW_NUMBER() OVER (
                    PARTITION BY lower(trim(sender_user_id)) ORDER BY MAX(created_at, mentioned_at) DESC, id DESC) AS n
                  FROM inbox_items
                  WHERE \(try mailFilter(db)) AND lower(trim(sender_user_id)) IN (\(databaseQuestionMarks(count: keys.count))))
                WHERE n = 1
                """, arguments: StatementArguments([nowUTC] + keys))
            var out: [String: String] = [:]
            for row in rows {
                out[row["address"] ?? ""] = row["permalink"] ?? ""
            }
            return out
        }
    }

    /// Go's `db.MailSubject`: the snippet before " — " (all of it without one).
    private static func subject(_ snippet: String) -> String {
        snippet.range(of: " — ").map { String(snippet[..<$0.lowerBound]) } ?? snippet
    }

    /// `empty` when a table the open clause reads (`inbox_items`, and
    /// `jira_issues` in its Jira check) is missing; any other error throws.
    private static func missingTableAsEmpty<T>(_ empty: T, _ read: () throws -> T) throws -> T {
        do {
            return try read()
        } catch let error as DatabaseError where ActionStripViewModel.isMissingTable(error)
                    && ["no such table: inbox_items", "no such table: jira_issues"].contains(error.message ?? "") {
            return empty
        }
    }
}
