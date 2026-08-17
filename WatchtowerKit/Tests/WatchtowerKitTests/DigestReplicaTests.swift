import GRDB
import XCTest
@testable import WatchtowerKit

/// Digest slices through the replica path: real RowPayloadCoder payloads for
/// `digest`, `digest_topic`, and `stream_digest` flow through
/// InMemoryCloudTransport into ReplicaStore and come back out as decoded
/// models via fetchAll — including the degenerate shapes the phone must not
/// choke on (empty topics, legacy digests published before `channel_name`).
final class DigestReplicaTests: XCTestCase {

    // MARK: - Fixtures

    /// A realistic digests row, as the publisher's `SELECT d.*, channel_name`
    /// projection ships it. `channelName`/`readAt` nil models the daily and
    /// unread cases; `topics` is the legacy digest-level JSON array of topic
    /// titles, not the digest_topics rows.
    private func digestRow(
        id: Int,
        channelID: String = "1:C042",
        channelName: String? = "launch",
        type: String = "channel",
        summary: String = "Launch prep continued",
        topics: String = #"["Launch checklist"]"#,
        decisions: String = "[]",
        createdAt: String = "2026-07-06T10:00:00Z",
        readAt: String? = nil
    ) -> Row {
        var row: [String: (any DatabaseValueConvertible)?] = [
            "id": id,
            "channel_id": channelID,
            "period_from": 1_720_000_000.0,
            "period_to": 1_720_086_400.0,
            "type": type,
            "summary": summary,
            "topics": topics,
            "decisions": decisions,
            "action_items": "[]",
            "message_count": 12,
            "model": "haiku",
            "created_at": createdAt,
            "read_at": readAt
        ]
        if let channelName { row["channel_name"] = channelName }
        return Row(row)
    }

    private func digestTopicRow(id: Int, digestID: Int, idx: Int, title: String, decisions: String) -> Row {
        Row([
            "id": id,
            "digest_id": digestID,
            "idx": idx,
            "title": title,
            "summary": "What happened in \(title)",
            "decisions": decisions,
            "action_items": "[]",
            "situations": "[]",
            "key_messages": "[]"
        ])
    }

    private func streamDigestRow(
        id: Int,
        source: String = "gmail",
        scope: String = "inbox",
        topicsJSON: String,
        readAt: String? = nil
    ) -> Row {
        Row([
            "id": id,
            "source": source,
            "account_id": 1,
            "scope": scope,
            "period_from": "2026-07-05T00:00:00Z",
            "period_to": "2026-07-06T00:00:00Z",
            "topics_json": topicsJSON,
            "created_at": "2026-07-06T09:00:00Z",
            "read_at": readAt
        ])
    }

    private func dataRecord(kind: SliceKind, id: String, row: Row) throws -> CloudRecord {
        CloudRecord(
            recordName: kind.recordName(id: id),
            zone: .data,
            kind: kind.rawValue,
            modifiedAt: Date(timeIntervalSince1970: 1_720_000_000),
            payload: try RowPayloadCoder.payload(from: row)
        )
    }

    private func hydrated(_ records: [CloudRecord]) async throws -> ReplicaStore {
        let transport = InMemoryCloudTransport()
        try await transport.save(records)
        let store = try ReplicaStore.inMemory()
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()
        return store
    }

    // MARK: - Slack digests + topics

    func testHydrateDecodesDigestWithTopicsAndDecisions() async throws {
        let decisions = #"[{"text":"Ship Friday","by":"U1","message_ts":"1720000000.000100","channel_id":"C042","importance":"high"}]"#
        let store = try await hydrated([
            dataRecord(kind: .digest, id: "5", row: digestRow(id: 5)),
            dataRecord(kind: .digestTopic, id: "21",
                       row: digestTopicRow(id: 21, digestID: 5, idx: 1, title: "Rollout", decisions: "[]")),
            dataRecord(kind: .digestTopic, id: "20",
                       row: digestTopicRow(id: 20, digestID: 5, idx: 0, title: "Launch date", decisions: decisions))
        ])

        let digests = try store.fetchAll(Digest.self, kind: .digest)
        XCTAssertEqual(digests.count, 1)
        XCTAssertEqual(digests[0].id, 5)
        XCTAssertEqual(digests[0].channelName, "launch")
        XCTAssertEqual(digests[0].summary, "Launch prep continued")
        XCTAssertFalse(digests[0].isRead)

        let topics = try store.fetchAll(DigestTopic.self, kind: .digestTopic)
            .filter { $0.digestID == 5 }
            .sorted { $0.idx < $1.idx }
        XCTAssertEqual(topics.map(\.title), ["Launch date", "Rollout"])
        XCTAssertEqual(topics[0].parsedDecisions.map(\.text), ["Ship Friday"])
        XCTAssertEqual(topics[0].parsedDecisions[0].resolvedImportance, "high")
        XCTAssertTrue(topics[1].parsedDecisions.isEmpty)
    }

    /// Valid-but-degenerate: a legacy digest published before `channel_name`
    /// existed and before per-topic rows — no topic slice rows, `[]` topics,
    /// digest-level decisions only. Must decode, not be skipped as corrupt.
    func testLegacyDigestWithoutChannelNameOrTopicsDecodes() async throws {
        let decisions = #"[{"text":"Keep the daily cadence","by":null,"message_ts":null,"channel_id":null}]"#
        let store = try await hydrated([
            dataRecord(kind: .digest, id: "2", row: digestRow(
                id: 2, channelID: "", channelName: nil, type: "daily",
                summary: "Quiet day", topics: "[]", decisions: decisions,
                readAt: "2026-07-06T12:00:00Z"
            ))
        ])

        let digests = try store.fetchAll(Digest.self, kind: .digest)
        XCTAssertEqual(digests.count, 1)
        XCTAssertNil(digests[0].channelName)
        XCTAssertTrue(digests[0].parsedTopics.isEmpty)
        XCTAssertEqual(digests[0].parsedDecisions.map(\.text), ["Keep the daily cadence"])
        XCTAssertEqual(digests[0].parsedDecisions[0].resolvedImportance, "medium")
        XCTAssertTrue(digests[0].isRead)
        XCTAssertEqual(store.corruptCount(), 0)
    }

    // MARK: - Stream digests

    func testHydrateDecodesStreamDigestTopics() async throws {
        let topicsJSON = """
        [{"title":"Refund thread","summary":"Support escalation",\
        "ideas":[{"text":"Automate refunds","author":"alice@x.com","ref":"msg-1"}],\
        "decisions":[{"text":"Refund the June invoices","author":null,"ref":null}]}]
        """
        let store = try await hydrated([
            dataRecord(kind: .streamDigest, id: "7", row: streamDigestRow(id: 7, topicsJSON: topicsJSON)),
            dataRecord(kind: .streamDigest, id: "8",
                       row: streamDigestRow(id: 8, source: "jira", scope: "PROJ", topicsJSON: "[]",
                                            readAt: "2026-07-06T11:00:00Z"))
        ])

        let digests = try store.fetchAll(StreamDigest.self, kind: .streamDigest)
            .sorted { $0.id < $1.id }
        XCTAssertEqual(digests.count, 2)

        let gmail = digests[0]
        XCTAssertEqual(gmail.source, "gmail")
        XCTAssertEqual(gmail.scope, "inbox")
        XCTAssertFalse(gmail.isRead)
        let topics = gmail.parsedTopics
        XCTAssertEqual(topics.count, 1)
        XCTAssertEqual(topics[0].title, "Refund thread")
        XCTAssertEqual(topics[0].decisions?.map(\.text), ["Refund the June invoices"])
        XCTAssertEqual(topics[0].ideas?.first?.author, "alice@x.com")

        // Degenerate: an empty topics_json digest is a real row (the pipeline
        // writes one when a window had traffic but no candidates) — it must
        // list as read with zero topics, never decode-fail.
        let jira = digests[1]
        XCTAssertEqual(jira.source, "jira")
        XCTAssertTrue(jira.parsedTopics.isEmpty)
        XCTAssertTrue(jira.isRead)
        XCTAssertEqual(store.corruptCount(), 0)
    }

    /// Malformed topics_json degrades to zero topics (the desktop model's
    /// contract), never to a corrupt-row skip: the row itself decodes.
    func testStreamDigestWithMalformedTopicsJSONDecodesWithNoTopics() async throws {
        let store = try await hydrated([
            dataRecord(kind: .streamDigest, id: "9", row: streamDigestRow(id: 9, topicsJSON: "not json"))
        ])
        let digests = try store.fetchAll(StreamDigest.self, kind: .streamDigest)
        XCTAssertEqual(digests.count, 1)
        XCTAssertTrue(digests[0].parsedTopics.isEmpty)
        XCTAssertEqual(store.corruptCount(), 0)
    }
}
