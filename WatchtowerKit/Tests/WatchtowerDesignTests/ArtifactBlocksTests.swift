import SwiftUI
@testable import WatchtowerDesign
import XCTest

/// The block document decoder over the Swift-only samples
/// (`Fixtures/artifact_samples.json`, Inbox builder A plan Task 1). The
/// shared Go fixture's parity checks are Task 13's.
final class ArtifactBlocksTests: XCTestCase {
    private struct Samples: Decodable {
        struct Valid: Decodable {
            let name: String
            let cardActions: JSONText
            let document: JSONText
            let actions: Int
            let refs: [Ref]

            enum CodingKeys: String, CodingKey {
                case name, document, actions, refs
                case cardActions = "card_actions"
            }
        }

        struct Ref: Decodable, Equatable {
            let kind: String
            let id: Int64
        }

        struct Unsupported: Decodable {
            let name: String
            let document: JSONText
            let version: Int
        }

        struct Malformed: Decodable {
            let name: String
            let json: String
        }

        let documents: [Valid]
        let unsupported: [Unsupported]
        let malformed: [Malformed]
    }

    /// A fixture value kept as its JSON text, as `blocks_json` stores it.
    private struct JSONText: Decodable {
        let text: String

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(AnyJSON.self)
            let data = try JSONSerialization.data(withJSONObject: value.object, options: [.fragmentsAllowed])
            text = String(bytes: data, encoding: .utf8) ?? ""
        }
    }

    private struct AnyJSON: Decodable {
        let object: Any

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                object = NSNull()
            } else if let value = try? container.decode(Bool.self) {
                object = value
            } else if let value = try? container.decode(Int64.self) {
                object = value
            } else if let value = try? container.decode(Double.self) {
                object = value
            } else if let value = try? container.decode(String.self) {
                object = value
            } else if let value = try? container.decode([Self].self) {
                object = value.map(\.object)
            } else {
                object = try container.decode([String: Self].self).mapValues(\.object)
            }
        }
    }

    private func samples() throws -> Samples {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = tests.appendingPathComponent("Fixtures/artifact_samples.json")
        return try JSONDecoder().decode(Samples.self, from: Data(contentsOf: url))
    }

    private func document(_ sample: Samples.Valid, file: StaticString = #filePath, line: UInt = #line) throws
        -> ArtifactDocument {
        guard case let .document(document) = ArtifactDocument.decode(sample.document.text) else {
            XCTFail("\(sample.name) does not decode", file: file, line: line)
            throw XCTSkip("undecodable sample")
        }
        return document
    }

    private func cardActions(_ sample: Samples.Valid) throws -> [ArtifactAction] {
        guard case let .actions(actions) = ArtifactDocument.decodeActions(sample.cardActions.text) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return actions
    }

    func testEverySampleDocumentDecodes() throws {
        let samples = try samples()
        XCTAssertFalse(samples.documents.isEmpty)
        for sample in samples.documents {
            XCTAssertEqual(ArtifactDocument.decode(sample.document.text).isDocument, true, sample.name)
            XCTAssertNoThrow(try cardActions(sample), sample.name)
        }
    }

    func testNewerVersionIsUnsupported() throws {
        for sample in try samples().unsupported {
            XCTAssertEqual(ArtifactDocument.decode(sample.document.text), .unsupported(version: sample.version),
                           sample.name)
        }
    }

    func testEmptyStringIsNone() {
        XCTAssertEqual(ArtifactDocument.decode(""), .none)
    }

    func testMalformedIsUnreadableNeverNone() throws {
        let samples = try samples()
        XCTAssertFalse(samples.malformed.isEmpty)
        for sample in samples.malformed {
            XCTAssertEqual(ArtifactDocument.decode(sample.json), .unreadable, sample.name)
        }
    }

    func testFlattenedActionCountMatchesEachSample() throws {
        for sample in try samples().documents {
            let doc = try document(sample)
            XCTAssertEqual(doc.flattenedActions(cardActions: try cardActions(sample)).count, sample.actions, sample.name)
        }
    }

    /// Card actions first, then each block's in document order, a list's row by row.
    func testFlattenedActionOrder() throws {
        let sample = try XCTUnwrap(try samples().documents.first { $0.name == "every-block" })
        let labels = try document(sample).flattenedActions(cardActions: try cardActions(sample)).map(\.label)
        XCTAssertEqual(labels, ["Reply with a summary", "Open", "Reply", "Chat", "Make a task", "Open the board",
                                "Ask the assistant"])
    }

    func testRefsInDocumentOrder() throws {
        for sample in try samples().documents {
            let refs = try document(sample).refs.map { Samples.Ref(kind: $0.kind.rawValue, id: $0.id) }
            XCTAssertEqual(refs, sample.refs, sample.name)
        }
    }

    func testTargetActionWithAndWithoutIntentAndParent() throws {
        let samples = try samples()
        let full = try document(try XCTUnwrap(samples.documents.first { $0.name == "every-block" }))
        let bare = try document(try XCTUnwrap(samples.documents.first { $0.name == "target-row" }))
        let targets = { (doc: ArtifactDocument) in
            doc.flattenedActions(cardActions: []).compactMap { action -> ArtifactTargetAction? in
                guard case let .target(target) = action.payload else { return nil }
                return target
            }
        }
        XCTAssertEqual(targets(full), [ArtifactTargetAction(title: "Write the acme 4.2 release notes",
                                                            intent: "Release can't ship without notes", parent: 12)])
        XCTAssertEqual(targets(bare), [ArtifactTargetAction(title: "Sign off the checklist")])
        XCTAssertEqual(bare.flattenedActions(cardActions: []).first?.kind, .target)
    }

    func testEveryActionKindAndField() throws {
        let sample = try XCTUnwrap(try samples().documents.first { $0.name == "every-tone-and-ref" })
        let payloads = try document(sample).flattenedActions(cardActions: try cardActions(sample)).map(\.payload)
        XCTAssertEqual(payloads, [
            .open("https://example.com/acme"),
            .chat("What changed?"),
            .agent(task: "Tidy the acme board", workbench: .name("acme")),
            .agent(task: "Look around", workbench: nil),
            .reply(value: "ok", dataJSON: #"{"a":"x","b":[1,2]}"#),
            .target(ArtifactTargetAction(title: "Follow up with colleague A", intent: "They asked twice"))
        ])
    }

    /// Present-but-undecodable buttons are never "no buttons": the whole
    /// card reads as unreadable, since block press indices count them.
    func testUndecodableCardActionsMakeTheCardUnreadable() {
        XCTAssertEqual(ArtifactDocument.decodeActions(""), .actions([]))
        XCTAssertEqual(ArtifactDocument.decodeActions("[]"), .actions([]))
        XCTAssertEqual(ArtifactDocument.decodeActions("[{"), .unreadable)
        XCTAssertEqual(ArtifactDocument.decodeActions(#"{"label":"x"}"#), .unreadable)
        XCTAssertEqual(ArtifactDocument.decodeActions(#"[{"label":"x","kind":"shell"}]"#), .unreadable)

        let blocks = #"{"v":1,"blocks":[{"type":"actions","actions":[{"label":"Go","kind":"chat","chat":"hi"}]}]}"#
        let broken = ArtifactDocument.decodeCard(blocksJSON: blocks, actionsJSON: #"[{"label":"x","kind":"shell"}]"#)
        XCTAssertEqual(broken.result, .unreadable)
        XCTAssertEqual(broken.cardActions, [])
        let markdown = ArtifactDocument.decodeCard(blocksJSON: "", actionsJSON: "not json")
        XCTAssertEqual(markdown.result, .unreadable)

        let good = ArtifactDocument.decodeCard(blocksJSON: blocks, actionsJSON: #"[{"label":"Open","kind":"link","open":"https://example.com"}]"#)
        guard case .document = good.result else { return XCTFail("a good card does not decode") }
        XCTAssertEqual(good.cardActions.map(\.label), ["Open"])
    }

    /// The renderer's press indices come from the Kit: block i's offset (and
    /// a list row's) is the index of its first action in `flattenedActions`.
    func testBlockAndRowOffsetsMatchTheFlattenedOrder() throws {
        let samples = try samples()
        XCTAssertTrue(samples.documents.contains { $0.name == "actions-before-list" })
        for sample in samples.documents {
            let doc = try document(sample)
            let card = try cardActions(sample)
            let flat = doc.flattenedActions(cardActions: card)
            let offsets = doc.blockActionOffsets(cardActionCount: card.count)
            XCTAssertEqual(offsets.count, doc.blocks.count, sample.name)
            for (index, block) in doc.blocks.enumerated() {
                let blockActions = block.actions
                XCTAssertEqual(Array(flat[offsets[index]..<offsets[index] + blockActions.count]), blockActions,
                               "\(sample.name) block \(index)")
                guard case let .list(list) = block else { continue }
                for (row, start) in zip(list.rows, list.rowActionOffsets(start: offsets[index])) {
                    XCTAssertEqual(Array(flat[start..<start + row.actions.count]), row.actions,
                                   "\(sample.name) block \(index) row \(row.title)")
                }
            }
        }
    }

    func testZeroRowListAndTableDecode() throws {
        let sample = try XCTUnwrap(try samples().documents.first { $0.name == "empty-list-and-table" })
        XCTAssertEqual(try document(sample).blocks, [
            .list(.init(title: "Open threads", rows: [], empty: "Nothing waits on you")),
            .table(.init(title: nil, columns: [ArtifactTableColumn(title: "Service")], rows: []))
        ])
    }

    /// Absent optionals (missing, null, "") decode as nil; defaults apply.
    func testOptionalFieldsAndDefaults() throws {
        let json = #"""
        {"v":1,"blocks":[
          {"type":"heading","text":"T"},
          {"type":"list","rows":[{"title":"r","subtitle":"","badge":null,"tone":"","link":null}]},
          {"type":"table","columns":[{"title":"a"}],"rows":[[{"text":"1"}]]},
          {"type":"person","name":"Colleague A"},
          {"type":"link","title":"L","url":"https://example.com"}
        ]}
        """#
        guard case let .document(doc) = ArtifactDocument.decode(json) else { return XCTFail("does not decode") }
        XCTAssertEqual(doc.blocks, [
            .heading(text: "T", level: 1),
            .list(.init(title: nil, rows: [ArtifactListRow(title: "r")], empty: "Nothing here")),
            .table(.init(columns: [ArtifactTableColumn(title: "a", align: .leading)], rows: [[ArtifactTableCell(text: "1")]])),
            .person(.init(name: "Colleague A")),
            .link(title: "L", url: "https://example.com", subtitle: nil)
        ])
    }

    func testEveryBlockTypeIsSampled() throws {
        var seen = Set<String>()
        for sample in try samples().documents {
            for block in try document(sample).blocks {
                switch block {
                case .heading: seen.insert("heading")
                case .text: seen.insert("text")
                case .list: seen.insert("list")
                case .table: seen.insert("table")
                case .person: seen.insert("person")
                case .metrics: seen.insert("metrics")
                case .link: seen.insert("link")
                case .actions: seen.insert("actions")
                }
            }
        }
        XCTAssertEqual(seen, ["heading", "text", "list", "table", "person", "metrics", "link", "actions"])
    }

    func testToneArtifactCoversAllSix() {
        XCTAssertEqual(ArtifactTone.allCases.count, 6)
        XCTAssertEqual(Tone.artifact(.neutral), .secondary)
        XCTAssertEqual(Tone.artifact(.info), Tone.status("blue"))
        XCTAssertEqual(Tone.artifact(.success), Tone.success)
        XCTAssertEqual(Tone.artifact(.warning), Tone.warning)
        XCTAssertEqual(Tone.artifact(.danger), Tone.error)
        XCTAssertEqual(Tone.artifact(.accent), .accentColor)
    }
}

// MARK: - Parity with Go's shared fixture

/// The Kit against `internal/automations/blocks/testdata/blocks_cases.json`
/// (Go is its only writer, plan Task 13): every Go-canonical document
/// decodes with the card's stored actions (`card_actions`, as
/// `automation_outputs.actions_json` holds them), every action's hash and
/// press order are Go's, refs come in document order, and newer versions
/// are unsupported.
extension ArtifactBlocksTests {
    private struct GoCase {
        let name: String
        let canonical: String
        /// The card's own actions, decoded from the stored `card_actions`.
        let cardActions: [ArtifactAction]
        let labels: [String]
        let hashes: [String]
        /// Every list row's `ref` in the canonical document, in order.
        let refs: [Samples.Ref]
    }

    private static func goFixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WatchtowerDesignTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerKit
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/automations/blocks/testdata/blocks_cases.json")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private static func goCases() throws -> [GoCase] {
        let valid = try XCTUnwrap(try goFixture()["valid"] as? [[String: Any]])
        return try valid.map { item in
            let canonical = try XCTUnwrap(item["canonical"] as? String)
            let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(canonical.utf8)) as? [String: Any])
            let rows = (document["blocks"] as? [[String: Any]] ?? []).flatMap { $0["rows"] as? [Any] ?? [] }
            let refs = rows.compactMap { ($0 as? [String: Any])?["ref"] as? [String: Any] }.map {
                Samples.Ref(kind: $0["kind"] as? String ?? "", id: ($0["id"] as? NSNumber)?.int64Value ?? 0)
            }
            let name = try XCTUnwrap(item["name"] as? String)
            guard case let .actions(cardActions) = ArtifactDocument.decodeActions(
                try XCTUnwrap(item["card_actions"] as? String)) else {
                XCTFail("\(name): Go's stored card actions do not decode")
                throw XCTSkip("undecodable card actions")
            }
            return GoCase(
                name: name,
                canonical: canonical,
                cardActions: cardActions,
                labels: try XCTUnwrap(item["actions"] as? [String]),
                hashes: try XCTUnwrap(item["action_hashes"] as? [String]),
                refs: refs
            )
        }
    }

    private func decoded(_ goCase: GoCase, file: StaticString = #filePath, line: UInt = #line) throws
        -> ArtifactDocument {
        guard case let .document(document) = ArtifactDocument.decode(goCase.canonical) else {
            XCTFail("\(goCase.name): Go's canonical document does not decode", file: file, line: line)
            throw XCTSkip("undecodable Go case")
        }
        return document
    }

    func testEveryGoCanonicalDocumentDecodes() throws {
        let cases = try Self.goCases()
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for goCase in cases {
            XCTAssertEqual(ArtifactDocument.decode(goCase.canonical).isDocument, true, goCase.name)
        }
    }

    /// Go `FlattenActions`: the card's own actions first, then each block
    /// action in the order the Kit flattens them.
    func testFlattenedOrderMatchesGo() throws {
        let cases = try Self.goCases()
        XCTAssertTrue(cases.contains { !$0.cardActions.isEmpty })
        for goCase in cases {
            let labels = try decoded(goCase).flattenedActions(cardActions: goCase.cardActions).map(\.label)
            XCTAssertEqual(labels, goCase.labels, goCase.name)
        }
    }

    /// `ArtifactAction.hash` is Go `blocks.ActionHash` for every action, the
    /// card's own and the blocks' (escaping — the stored card actions are
    /// HTML-escaped, the hashed form is not —, field order, omitted empties,
    /// `data` bytes and workbench forms).
    func testActionHashMatchesGo() throws {
        var checked = 0
        for goCase in try Self.goCases() {
            let actions = try decoded(goCase).flattenedActions(cardActions: goCase.cardActions)
            XCTAssertEqual(actions.map(\.hash), goCase.hashes, goCase.name)
            checked += actions.count
        }
        XCTAssertGreaterThanOrEqual(checked, 10)
    }

    /// A reply's `data` reads back as the bytes Go stored (`json.Marshal`).
    func testReplyDataKeepsGoBytes() throws {
        let goCase = try XCTUnwrap(try Self.goCases().first { $0.name == "reply data bytes" })
        let action = try XCTUnwrap(try decoded(goCase).flattenedActions(cardActions: []).first)
        XCTAssertEqual(action.payload, .reply(value: "v", dataJSON: #"{"a":"\u003c\u0026\u003e","f":1.5,"n":[1,{"b":null}]}"#))
    }

    func testRefsMatchGo() throws {
        let cases = try Self.goCases()
        XCTAssertTrue(cases.contains { !$0.refs.isEmpty })
        for goCase in cases {
            let refs = try decoded(goCase).refs.map { Samples.Ref(kind: $0.kind.rawValue, id: $0.id) }
            XCTAssertEqual(refs, goCase.refs, goCase.name)
        }
    }

    func testGoUnsupportedDocumentsAreUnsupported() throws {
        let unsupported = try XCTUnwrap(try Self.goFixture()["unsupported"] as? [[String: Any]])
        XCTAssertFalse(unsupported.isEmpty)
        for item in unsupported {
            let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(item["document"]))
            let version = try XCTUnwrap(item["version"] as? Int)
            XCTAssertEqual(ArtifactDocument.decode(try XCTUnwrap(String(bytes: data, encoding: .utf8))),
                           .unsupported(version: version), item["name"] as? String ?? "?")
        }
    }

    /// The twin of Go's fixture-coverage test: every `ArtifactBlock` case and
    /// every action kind appears in a Go-canonical case (the switches are
    /// exhaustive, so a new case does not compile until it is listed here).
    func testGoFixtureCoversEveryBlockAndActionKind() throws {
        var blocks = Set<String>()
        var kinds = Set<String>()
        for goCase in try Self.goCases() {
            let document = try decoded(goCase)
            for block in document.blocks {
                switch block {
                case .heading: blocks.insert("heading")
                case .text: blocks.insert("text")
                case .list: blocks.insert("list")
                case .table: blocks.insert("table")
                case .person: blocks.insert("person")
                case .metrics: blocks.insert("metrics")
                case .link: blocks.insert("link")
                case .actions: blocks.insert("actions")
                }
            }
            kinds.formUnion(document.flattenedActions(cardActions: goCase.cardActions).map(Self.kindName))
        }
        XCTAssertEqual(blocks, ["heading", "text", "list", "table", "person", "metrics", "link", "actions"])
        XCTAssertEqual(kinds, ["open", "chat", "agent", "reply", "target"])
    }

    private static func kindName(_ action: ArtifactAction) -> String {
        switch action.kind {
        case .open: "open"
        case .chat: "chat"
        case .agent: "agent"
        case .reply: "reply"
        case .target: "target"
        }
    }

    /// Go's float64 layout (`json.Marshal`), beyond the fixture's 1.5.
    func testGoFloatLayout() {
        let cases: [(Double, String)] = [
            (1.5, "1.5"), (100, "100"), (0.1, "0.1"), (-2.25, "-2.25"), (0, "0"), (-0.0, "-0"),
            (123_456_789, "123456789"), (1e20, "100000000000000000000"), (1e21, "1e+21"),
            (1.5e300, "1.5e+300"), (0.000001, "0.000001"), (1e-7, "1e-7"), (1.25e-10, "1.25e-10"),
            (5e-324, "5e-324"), (9_007_199_254_740_993, "9007199254740992")
        ]
        for (value, want) in cases {
            XCTAssertEqual(GoJSON.float(value), want, "\(value)")
        }
    }

    /// Go's string escaping: HTML characters only under `json.Marshal`;
    /// `\b \f \n \r \t` as such, other controls `\u00XX`, U+2028/9 always.
    func testGoStringEscaping() {
        let text = "a\u{8}\u{c}\n\r\t\u{1}\u{7f}\"\\/<&>\u{2028}\u{2029}é"
        XCTAssertEqual(GoJSON.string(text), #""a\b\f\n\r\t\u0001\#u{7f}\"\\/<&>\u2028\u2029é""#)
        XCTAssertEqual(GoJSON.string(text, escapeHTML: true),
                       #""a\b\f\n\r\t\u0001\#u{7f}\"\\/\u003c\u0026\u003e\u2028\u2029é""#)
    }

    /// `data` objects sort keys by bytes (Go map order), not by Swift's
    /// string order, and keep booleans, nulls and integers.
    func testGoMarshalSortsKeysByBytes() throws {
        let value: [String: Any] = ["b": true, "Z": NSNull(), "é": 2, "a": [1, "x"]]
        XCTAssertEqual(try GoJSON.marshal(value), #"{"Z":null,"a":[1,"x"],"b":true,"é":2}"#)
    }
}

private extension ArtifactDecodeResult {
    var isDocument: Bool {
        if case .document = self { return true }
        return false
    }
}
