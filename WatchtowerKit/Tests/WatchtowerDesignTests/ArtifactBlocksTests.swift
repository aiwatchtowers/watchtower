import SwiftUI
import WatchtowerDesign
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

private extension ArtifactDecodeResult {
    var isDocument: Bool {
        if case .document = self { return true }
        return false
    }
}
