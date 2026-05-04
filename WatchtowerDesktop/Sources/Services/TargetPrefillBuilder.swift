import Foundation
import GRDB

/// Builds `TargetPrefill` values from in-app source records. Async methods
/// open a single short read transaction; the sub-item method is sync because
/// the parent is already loaded in memory.
///
/// On a missing related entity (channel renamed, user not synced yet, etc.)
/// builders fall back to a softer label (channel id, raw user id) instead of
/// throwing. They only throw on hard DB errors.
enum TargetPrefillBuilder {

    // MARK: - fromSubItem

    /// Synchronous — the `parent` target is already loaded by the caller.
    static func fromSubItem(parent: Target, subItem: TargetSubItem, index: Int) -> TargetPrefill {
        var lines: [String] = []
        lines.append("Sub-target of #\(parent.id) «\(parent.text)».")

        let parentIntent = parent.intent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !parentIntent.isEmpty {
            lines.append("Parent context: \(parentIntent)")
        }

        let siblings = parent.decodedSubItems.enumerated().compactMap { (i, item) -> String? in
            guard i != index, !item.done else { return nil }
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if !siblings.isEmpty {
            let bulleted = siblings.prefix(5).map { "  • \($0)" }.joined(separator: "\n")
            lines.append("Sibling sub-items:\n\(bulleted)")
        }

        return TargetPrefill(
            text: subItem.text,
            intent: lines.joined(separator: "\n"),
            sourceType: "promoted_subitem",
            sourceID: "\(parent.id):\(index)",
            secondaryLinks: [],
            parentID: parent.id
        )
    }

    // MARK: - fromTrack

    static func fromTrack(_ track: Track, db: DatabaseManager) async throws -> TargetPrefill {
        let channelIDs = Array(track.decodedChannelIDs.prefix(3))
        let names = try await db.dbPool.read { dbConn -> [String] in
            try channelIDs.map { id in
                if let ch = try ChannelQueries.fetchByID(dbConn, id: id) {
                    return ch.name
                }
                return id
            }
        }

        var lines: [String] = []
        let context = track.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty { lines.append(context) }

        let decision = track.decisionSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !decision.isEmpty { lines.append("Decision: \(decision)") }

        let blocking = track.blocking.trimmingCharacters(in: .whitespacesAndNewlines)
        if !blocking.isEmpty { lines.append("Blocking: \(blocking)") }

        if !names.isEmpty {
            let pretty = names.map { "#\($0)" }.joined(separator: ", ")
            lines.append("In channels: \(pretty)")
        }

        let links = channelIDs.map {
            TargetPrefillLink(externalRef: "slack:\($0)", relation: "related")
        }

        return TargetPrefill(
            text: track.text,
            intent: lines.joined(separator: "\n"),
            sourceType: "track",
            sourceID: String(track.id),
            secondaryLinks: links,
            parentID: nil
        )
    }

    // MARK: - fromDigest

    static func fromDigest(_ digest: Digest, topic: DigestTopic?, db: DatabaseManager) async throws -> TargetPrefill {
        let channelName = try await db.dbPool.read { dbConn -> String in
            if let ch = try ChannelQueries.fetchByID(dbConn, id: digest.channelID) {
                return ch.name
            }
            return digest.channelID
        }

        let title: String
        if let t = topic {
            title = t.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.firstLine(digest.summary)
                : t.title
        } else {
            title = Self.firstLine(digest.summary)
        }

        var lines: [String] = []
        lines.append("From digest in #\(channelName):")

        let body = (topic?.summary).flatMap { s -> String? in
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? digest.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { lines.append(body) }

        if let topic, !topic.parsedKeyMessages.isEmpty {
            let bulleted = topic.parsedKeyMessages.prefix(5).map { "  • \($0)" }.joined(separator: "\n")
            lines.append("Key messages:\n\(bulleted)")
        }

        let links: [TargetPrefillLink] = digest.channelID.isEmpty
            ? []
            : [TargetPrefillLink(externalRef: "slack:\(digest.channelID)", relation: "related")]

        return TargetPrefill(
            text: title.isEmpty ? digest.summary : title,
            intent: lines.joined(separator: "\n"),
            sourceType: "digest",
            sourceID: String(digest.id),
            secondaryLinks: links,
            parentID: nil
        )
    }

    // MARK: - fromInbox

    static func fromInbox(_ item: InboxItem, db: DatabaseManager) async throws -> TargetPrefill {
        let (senderName, channelName) = try await db.dbPool.read { dbConn -> (String, String) in
            let display = try UserQueries.fetchDisplayName(dbConn, forID: item.senderUserID)
            let chName = try ChannelQueries.fetchByID(dbConn, id: item.channelID)?.name ?? item.channelID
            return (display, chName)
        }

        var lines: [String] = []
        lines.append("From @\(senderName) in #\(channelName) (\(item.triggerType)):")
        let snippetTrimmed = item.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if !snippetTrimmed.isEmpty {
            lines.append("\"\(snippetTrimmed)\"")
        }
        let aiReason = item.aiReason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !aiReason.isEmpty {
            lines.append("Why it matters: \(aiReason)")
        }

        let links: [TargetPrefillLink] = item.permalink.isEmpty
            ? []
            : [TargetPrefillLink(externalRef: "slack:\(item.permalink)", relation: "related")]

        return TargetPrefill(
            text: item.snippet,
            intent: lines.joined(separator: "\n"),
            sourceType: "inbox",
            sourceID: String(item.id),
            secondaryLinks: links,
            parentID: nil
        )
    }

    // MARK: - fromBriefingItem

    static func fromBriefingItem(_ item: AttentionItem,
                                 briefing: Briefing,
                                 db dbMgr: DatabaseManager) async throws -> TargetPrefill {
        let prefix = briefingPrefix(item: item, briefing: briefing)

        // Delegate path: upstream entity present.
        if let sourceType = item.sourceType, let sourceID = item.sourceID,
           let id = Int(sourceID), !sourceType.isEmpty {
            switch sourceType {
            case "track":
                if let track = try await dbMgr.dbPool.read({ db in
                    try Track.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = ?", arguments: [id])
                }) {
                    var pf = try await fromTrack(track, db: dbMgr)
                    pf.text = item.text
                    pf.intent = prefix + "\n\n" + pf.intent
                    return pf
                }
            case "digest":
                if let digest = try await dbMgr.dbPool.read({ db in
                    try Digest.fetchOne(db, sql: "SELECT * FROM digests WHERE id = ?", arguments: [id])
                }) {
                    var pf = try await fromDigest(digest, topic: nil, db: dbMgr)
                    pf.text = item.text
                    pf.intent = prefix + "\n\n" + pf.intent
                    return pf
                }
            case "inbox":
                if let inbox = try await dbMgr.dbPool.read({ db in
                    try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [id])
                }) {
                    var pf = try await fromInbox(inbox, db: dbMgr)
                    pf.text = item.text
                    pf.intent = prefix + "\n\n" + pf.intent
                    return pf
                }
            default:
                break
            }
        }

        // Fallback path.
        let reason = item.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return TargetPrefill(
            text: item.text,
            intent: reason.isEmpty ? prefix : "\(prefix)\n\nReason: \(reason)",
            sourceType: "briefing",
            sourceID: String(briefing.id),
            secondaryLinks: [],
            parentID: nil
        )
    }

    private static func briefingPrefix(item: AttentionItem, briefing: Briefing) -> String {
        var lines: [String] = ["Surfaced in briefing on \(briefing.date)."]
        if let r = item.reason, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Reason: \(r.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let p = item.priority, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Briefing flag: \(p.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func firstLine(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? s
    }
}
