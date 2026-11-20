import Foundation
import WatchtowerInterface
import XCTest

/// The Inbox feed's redesign fields are additive: an unknown ref kind
/// decodes to `.unknown`, the new kinds to their own cases, a card from an
/// older hub (none of the new keys) still decodes, and a new-shape card
/// decodes every new field.
final class TowerTypesForwardCompatTests: XCTestCase {
    private static func refFacts(kind: String, key: String? = nil) -> String {
        let keyMember = key.map { #","key":"\#($0)""# } ?? ""
        return #"""
        {"kind":"\#(kind)","id":0,"open":true,"waits":false,"reply":false,"reply_waiting":false,
        "link":"","trigger_type":"","custom":false,"linked_target_id":0,"idea_kind":"","idea_status":""\#(keyMember)}
        """#
    }

    private static func card(extra: String = "", refFacts: [String] = []) -> String {
        #"""
        {"id":"o1","folder_id":1,"card_kind":"artifact","title":"T","source_line":"","preview":"",
        "stamp":"2026-11-20T09:00:00Z","living":false,"unread":true,"priority":"medium","pinned":false,
        "blocks":"","body":"","body_clipped":false,"link":"","content_hash":"","actions":[],
        "ref_facts":[\#(refFacts.joined(separator: ","))]\#(extra)}
        """#
    }

    func testUnknownRefKindDecodesToUnknown() throws {
        let facts = try JSONDecoder().decode(RefFacts.self, from: Data(Self.refFacts(kind: "future_kind").utf8))
        XCTAssertEqual(facts.kind, .unknown("future_kind"))
        XCTAssertNil(facts.key)
    }

    func testNewRefKindsDecodeToTheirCases() throws {
        let sender = try JSONDecoder().decode(
            RefFacts.self, from: Data(Self.refFacts(kind: "mail_sender", key: "a@example.com").utf8)
        )
        XCTAssertEqual(sender.kind, .mailSender)
        XCTAssertEqual(sender.key, "a@example.com")
        let older = try JSONDecoder().decode(
            RefFacts.self, from: Data(Self.refFacts(kind: "waiting_older", key: "people").utf8)
        )
        XCTAssertEqual(older.kind, .waitingOlder)
        XCTAssertEqual(older.key, "people")
    }

    func testCardWithoutNewKeysDecodes() throws {
        let json = Self.card(refFacts: [Self.refFacts(kind: "track")])
        let card = try JSONDecoder().decode(Card.self, from: Data(json.utf8))
        XCTAssertNil(card.section)
        XCTAssertNil(card.mail)
        XCTAssertNil(card.people)
        XCTAssertNil(card.slackToday)
        XCTAssertEqual(card.refFacts.map(\.kind), [.track])
        XCTAssertNil(card.refFacts.first?.key)
    }

    func testOlderApprovalAndLegacyItemDecodeWithoutNewKeys() throws {
        let approval = try JSONDecoder().decode(Approval.self, from: Data(
            #"""
            {"tool":"t","title":"","summary":"","args_sha256":"","status":"pending","error":"","proposer":"",
            "reason":"","edit_on_mac":false,"target":"","target_note":"","target_until":"","superseded":false,
            "disclosure":"","recipe_text":"","diff":[],"recipe_clipped":false}
            """#.utf8
        ))
        XCTAssertNil(approval.group)
        XCTAssertNil(approval.bulk)
        let item = try JSONDecoder().decode(LegacyItem.self, from: Data(
            #"""
            {"ref_kind":"track","id":4,"title":"R","subtitle":"","preview":"","stamp":"","end":"",
            "unread":true,"high":false,"stopped":false,"done":false,"date":""}
            """#.utf8
        ))
        XCTAssertNil(item.news)
        XCTAssertNil(item.quiet)
        XCTAssertNil(item.createdAt)
    }

    func testNewShapeCardDecodesEveryNewField() throws {
        let extra = #"""
        ,"section":"needs_you",
        "mail":{"open":12,"today":3,"senders":5,"top_ten_share":80,"stale":"last_run_failed"},
        "people":{"today":2,"older":7},"slack_today":{"status":"ok","state":"{}"}
        """#
        let card = try JSONDecoder().decode(Card.self, from: Data(Self.card(extra: extra).utf8))
        XCTAssertEqual(card.section, .needsYou)
        XCTAssertEqual(card.mail, MailFacts(open: 12, today: 3, senders: 5, topTenShare: 80, stale: .lastRunFailed))
        XCTAssertEqual(card.people, PeopleFacts(today: 2, older: 7))
        XCTAssertEqual(card.slackToday, SlackTodayFacts(status: "ok", state: "{}"))

        let current = try JSONDecoder().decode(
            MailFacts.self, from: Data(#"{"open":1,"today":0,"senders":1,"top_ten_share":100}"#.utf8)
        )
        XCTAssertNil(current.stale)
    }
}
