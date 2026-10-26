import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// The `owner_ask` slice (mobile POC spec §4.6), record name
/// `owner_ask-<owner_asks.id>`: every open ask of a published workbench,
/// plus its answered, delivered and withdrawn asks filed in the last 7 days
/// (≤ 50 per workbench, newest first).
///
/// Rows are read raw, not through Core's `OwnerAsk(row:)`: an ask the Mac's
/// card decoder refuses (say a question with 5 options) is still published,
/// and the phone falls back to "Open the ask on the Mac" for what it cannot
/// answer. The Mac re-validates every answer (§5.2).
///
/// Wire shape: the Kit mirror `WatchtowerKit.OwnerAsk`, RelayCoder JSON.
struct OwnerAskSlice: SliceSource {
    let kind = SliceKind.ownerAsk

    static let closedWindow: TimeInterval = 7 * 86_400
    static let maxClosedPerWorkbench = 50
    /// `payload` and `answer`, serialized.
    static let maxJSONBytes = 64 * 1024
    /// `doc_snapshot`, UTF-8.
    static let maxSnapshotBytes = 256 * 1024

    let now: @Sendable () -> Date
    /// The spec reviewer's lines, kept across ticks (F9).
    let specReviewLines = SpecReviewLines()

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    struct Quick: Encodable, Equatable {
        struct Option: Encodable, Equatable {
            let label: String
            let recommended: Bool
        }

        let questionID: String
        let options: [Option]

        enum CodingKeys: String, CodingKey {
            case questionID = "question_id"
            case options
        }
    }

    /// The spec reviewer's state on a review ask; older phones ignore it.
    struct SpecReviewLine: Encodable, Equatable {
        let status: String
        let line: String
    }

    struct Payload: Encodable, Equatable {
        let id: Int64
        let workbenchID: Int64
        let workbenchName: String
        let sessionID: Int64?
        let targetID: Int64?
        let kind: String
        let status: String
        let withdrawnReason: String?
        let previousAskID: Int64?
        let createdAt: Date
        let answeredAt: Date?
        let deliveredAt: Date?
        let title: String
        let titleClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let summary: String
        let summaryClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let changes: String
        let changesClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let payload: JSONValue?
        let payloadClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let docPath: String
        let docPathClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let docSnapshot: String?
        let docClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let docBytes: Int?
        let answer: JSONValue?
        let quick: Quick?
        let specReview: SpecReviewLine?

        enum CodingKeys: String, CodingKey {
            case id
            case workbenchID = "workbench_id"
            case workbenchName
            case sessionID = "session_id"
            case targetID = "target_id"
            case kind, status, withdrawnReason
            case previousAskID = "previous_ask_id"
            case createdAt, answeredAt, deliveredAt, title, titleClipped, summary, summaryClipped, changes, changesClipped
            case payload, payloadClipped, docPath, docPathClipped, docSnapshot, docClipped, docBytes, answer, quick
            case specReview = "spec_review"
        }
    }

    func records(_ db: Database) throws -> [SliceRecord] {
        let workbenches = try WorkbenchSlice.publishedWorkbenchRefs(db)
        guard !workbenches.isEmpty else { return [] }
        let names = Dictionary(uniqueKeysWithValues: workbenches.map { ($0.id, $0.name) })
        let stamp = now()
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM (
                SELECT a.*, ROW_NUMBER() OVER (
                    PARTITION BY a.project_id, a.status = 'open'
                    ORDER BY a.created_at DESC, a.id DESC
                ) AS rank
                FROM owner_asks a
                WHERE (a.status = 'open' OR julianday(a.created_at) >= julianday(?)) AND \(OwnerAskQueries.notInSpecLoop("a"))
            )
            WHERE status = 'open' OR rank <= ?
            ORDER BY id
            """, arguments: [stamp.addingTimeInterval(-Self.closedWindow), Self.maxClosedPerWorkbench])
        let encoder = RelayCoder.makeEncoder()
        let reviewAskIDs = rows.compactMap { row -> Int64? in
            let askKind: String = row["kind"] ?? ""
            return askKind == "review" ? row["id"] : nil
        }
        let reviewLines = try specReviewLines.lines(db, askIDs: reviewAskIDs)
        return try rows.compactMap { row in
            let project: Int64 = row["project_id"]
            guard let name = names[project] else { return nil }
            let payload = makePayload(row, workbenchName: name, specReview: reviewLines[row["id"]])
            return SliceRecord(kind: kind, id: String(payload.id), modifiedAt: stamp, payload: try encoder.encode(payload))
        }
    }

    private func makePayload(_ row: Row, workbenchName: String, specReview: SpecReviewLine?) -> Payload {
        let id: Int64 = row["id"]
        let record = kind.recordName(id: String(id))
        let status: String = row["status"] ?? ""
        let askKind: String = row["kind"] ?? ""
        let isOpen = status == "open"
        let title = SliceClip.text(row["title"] ?? "", limit: 200)
        let summary = SliceClip.text(row["summary"] ?? "", limit: 4000)
        let changes = SliceClip.text(row["changes"] ?? "", limit: 4000)
        let docPath = SliceClip.text(row["doc_path"] ?? "", limit: 300)
        let payload = Self.json(row["payload"] ?? "", record: record, field: "payload")
        let snapshot: (text: String, clipped: Bool?, bytes: Int?)? = // swiftlint:disable:this discouraged_optional_boolean
            isOpen && askKind == "review" ? Self.clipSnapshot(row["doc_snapshot"] ?? "") : nil
        let answer = isOpen ? .absent : Self.json(row["answer"] ?? "", record: record, field: "answer")
        let withdrawnReason: String = row["withdrawn_reason"] ?? ""
        return Payload(
            id: id,
            workbenchID: row["project_id"],
            workbenchName: SliceClip.text(workbenchName, limit: 200).text,
            sessionID: row["session_id"],
            targetID: row["target_id"],
            kind: askKind,
            status: status,
            withdrawnReason: withdrawnReason.isEmpty ? nil : withdrawnReason,
            previousAskID: row["previous_ask_id"],
            createdAt: SliceDate.required(row["created_at"] ?? "", field: "created_at", record: record),
            answeredAt: SliceDate.parse(row["answered_at"] ?? ""),
            deliveredAt: SliceDate.parse(row["delivered_at"] ?? ""),
            title: title.text, titleClipped: title.clipped,
            summary: summary.text, summaryClipped: summary.clipped,
            changes: changes.text, changesClipped: changes.clipped,
            payload: payload.value,
            payloadClipped: payload == .clipped ? true : nil,
            docPath: docPath.text, docPathClipped: docPath.clipped,
            docSnapshot: snapshot?.text, docClipped: snapshot?.clipped, docBytes: snapshot?.bytes,
            answer: answer.value,
            // The phone offers only "Open the ask on the Mac" without the payload.
            quick: payload.value.flatMap { askKind == "question" ? Self.quick($0) : nil },
            specReview: specReview
        )
    }

    // MARK: - Stored JSON

    enum StoredJSON: Equatable {
        case absent
        case value(JSONValue)
        /// Over `maxJSONBytes` serialized: dropped.
        case clipped

        var value: JSONValue? {
            if case .value(let json) = self { return json }
            return nil
        }
    }

    /// A stored JSON column as an object for the wire; "" is absent, and an
    /// unreadable value (never written by Go or the Desktop) is logged and
    /// left out.
    static func json(_ text: String, record: String, field: String) -> StoredJSON {
        guard !text.isEmpty else { return .absent }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        } catch {
            logger.warning("unreadable \(field, privacy: .public) on \(record, privacy: .public) left out")
            return .absent
        }
        let size = (try? RelayCoder.makeEncoder().encode(value).count) ?? Int.max
        return size > maxJSONBytes ? .clipped : .value(value)
    }

    // MARK: - Document snapshot

    /// The snapshot, at most `maxSnapshotBytes` of UTF-8: cut after the last
    /// newline before the cap, or at the cap's grapheme boundary when there
    /// is none. No ellipsis: the phone anchors review comments on the text
    /// as shown, and `doc_clipped` says it is partial. `bytes` is the full
    /// size, set with `clipped` only.
    static func clipSnapshot(_ text: String) -> (text: String, clipped: Bool?, bytes: Int?) { // swiftlint:disable:this discouraged_optional_boolean
        let total = text.utf8.count
        guard total > maxSnapshotBytes else { return (text, nil, nil) }
        let capIndex = text.utf8.index(text.utf8.startIndex, offsetBy: maxSnapshotBytes)
        let head = text.utf8[..<capIndex]
        if let newline = head.lastIndex(of: UInt8(ascii: "\n")) {
            let end = text.utf8.index(after: newline)
            return (String(text[..<end]), true, total)
        }
        return (graphemeFloor(text, capIndex), true, total)
    }

    /// `text` cut at the last grapheme boundary at or before `index`.
    private static func graphemeFloor(_ text: String, _ index: String.Index) -> String {
        // Slicing rounds down to a scalar boundary; the last cluster of the
        // copy may still be a broken one.
        let head = String(text[..<index])
        guard let last = head.last else { return head }
        // The same cluster in the full text, found by its UTF-8 offset: an
        // index from `head` would carry `head`'s cached cluster size.
        let start = text.utf8.index(text.utf8.startIndex, offsetBy: head.utf8.count - last.utf8.count)
        let whole = text[start...].first?.utf8.count == last.utf8.count
        return whole ? head : String(head.dropLast())
    }

    // MARK: - Quick answer

    /// `{question_id, options}` for one single-select question with 2–4
    /// options, at least one recommended; nil otherwise. Labels are trimmed
    /// the way the Mac's card decoder reads them, so a quick answer names a
    /// label the Mac accepts.
    static func quick(_ payload: JSONValue) -> Quick? {
        guard case .object(let object) = payload,
              case .array(let questions)? = object["questions"], questions.count == 1,
              case .object(let question) = questions[0],
              case .array(let rawOptions)? = question["options"], (2...4).contains(rawOptions.count)
        else { return nil }
        if case .bool(true)? = question["multi"] { return nil }
        var options: [Quick.Option] = []
        for raw in rawOptions {
            guard case .object(let option) = raw, case .string(let label)? = option["label"] else { return nil }
            let recommended: Bool
            if case .bool(let value)? = option["recommended"] { recommended = value } else { recommended = false }
            options.append(Quick.Option(label: label.trimmingCharacters(in: .whitespacesAndNewlines), recommended: recommended))
        }
        guard options.contains(where: \.recommended) else { return nil }
        let id: String
        if case .string(let value)? = question["id"], !value.isEmpty { id = value } else { id = "1" }
        return Quick(questionID: id, options: options)
    }

    private static let logger = Logger(subsystem: Constants.bundleID, category: "OwnerAskSlice")
}

/// The spec reviewer's line of each review ask in the `owner_ask` slice
/// (F9): one query for every ask's row, without its result; a done
/// review's counts are decoded from its result once per finish
/// (`finished_at`), the result read only for those not yet seen. Asks that
/// left the slice leave the cache on the next read.
final class SpecReviewLines: Sendable {
    private let doneLines = OSAllocatedUnfairLock(initialState: [Int64: (finishedAt: String, line: String)]())

    func lines(_ db: Database, askIDs: [Int64]) throws -> [Int64: OwnerAskSlice.SpecReviewLine] {
        guard !askIDs.isEmpty else {
            doneLines.withLock { $0 = [:] }
            return [:]
        }
        let marks = Array(repeating: "?", count: askIDs.count).joined(separator: ",")
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT ask_id, status, reason, finished_at FROM spec_reviews WHERE ask_id IN (\(marks))",
            arguments: StatementArguments(askIDs)
        )
        let known = doneLines.withLock { $0 }
        var kept: [Int64: (finishedAt: String, line: String)] = [:]
        var out: [Int64: OwnerAskSlice.SpecReviewLine] = [:]
        var misses: [Int64: String] = [:]
        for row in rows {
            let id: Int64 = row["ask_id"]
            let raw: String = row["status"]
            let status = SpecReviewRow.Status(rawValue: raw) ?? .unknown
            if status == .done {
                let finishedAt: String = row["finished_at"] ?? ""
                if let hit = known[id], hit.finishedAt == finishedAt {
                    kept[id] = hit
                    out[id] = Self.line("done", hit.line)
                } else {
                    misses[id] = finishedAt
                }
            } else if let line = SpecReviewSummary.phoneLine(status: status, reason: row["reason"] ?? "", result: { nil }) {
                out[id] = Self.line(line.status, line.line)
            }
        }
        if !misses.isEmpty {
            let ids = Array(misses.keys)
            let results = try Row.fetchAll(
                db,
                sql: "SELECT ask_id, result FROM spec_reviews WHERE ask_id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))",
                arguments: StatementArguments(ids)
            )
            for row in results {
                let id: Int64 = row["ask_id"]
                let json: String = row["result"] ?? ""
                let result = json.isEmpty ? nil : try? JSONDecoder().decode(SpecReviewResult.self, from: Data(json.utf8))
                guard let line = SpecReviewSummary.phoneLine(status: .done, reason: "", result: { result }) else { continue }
                kept[id] = (misses[id] ?? "", line.line)
                out[id] = Self.line("done", line.line)
            }
        }
        doneLines.withLock { $0 = kept }
        return out
    }

    private static func line(_ status: String, _ text: String) -> OwnerAskSlice.SpecReviewLine {
        OwnerAskSlice.SpecReviewLine(status: status, line: SliceClip.text(text, limit: 300).text)
    }
}
