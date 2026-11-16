import SwiftUI
import WatchtowerDesign
import XCTest
@testable import WatchtowerMobile

/// The phone's block renderer (mobile Inbox spec §7, mockups §4–§5) over the
/// Kit's sample documents (`WatchtowerKit/Tests/Fixtures/artifact_samples.json`,
/// the ones `ArtifactBlocksTests` decodes): every sample draws in both
/// schemes, the draw items keep the document's order and press addresses,
/// and every tone goes through `PhoneTone.artifact(_:)`.
@MainActor
final class PhoneArtifactViewTests: XCTestCase {
    private struct Sample {
        let name: String
        let document: ArtifactDocument
    }

    private func samples() throws -> [Sample] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerMobile
            .deletingLastPathComponent()
            .appendingPathComponent("WatchtowerKit/Tests/Fixtures/artifact_samples.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let documents = try XCTUnwrap(root["documents"] as? [[String: Any]])
        return try documents.map { entry in
            let name = try XCTUnwrap(entry["name"] as? String)
            let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(entry["document"]))
            guard case let .document(document) = ArtifactDocument.decode(String(bytes: data, encoding: .utf8) ?? "") else {
                throw XCTSkip("sample \(name) does not decode")
            }
            return Sample(name: name, document: document)
        }
    }

    private func sample(_ name: String) throws -> ArtifactDocument {
        try XCTUnwrap(try samples().first { $0.name == name }, "no sample \(name)").document
    }

    func testEverySampleRendersInLightAndDark() throws {
        let all = try samples()
        XCTAssertGreaterThan(all.count, 5)
        for sample in all {
            guard !PhoneArtifactLayout.items(sample.document).isEmpty else {
                // A document without blocks draws nothing; the card shows its text.
                XCTAssertTrue(sample.document.blocks.isEmpty, sample.name)
                continue
            }
            for scheme in [ColorScheme.light, .dark] {
                let view = PhoneArtifactView(document: sample.document, onRef: { _ in }, onAction: { _ in })
                    .frame(width: 393)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.uiImage, "\(sample.name) in \(scheme)")
                XCTAssertGreaterThan(image.size.height, 0, "\(sample.name) in \(scheme)")
                XCTAssertEqual(image.size.width, 393, "\(sample.name) in \(scheme)")
            }
        }
    }

    /// The draw items are the blocks in document order, every string of a
    /// block in its own order, and every button carries its press address
    /// in the Kit's flattened order (`ArtifactDocument.flattenedActions`).
    func testLayoutKeepsDocumentOrder() throws {
        for sample in try samples() {
            let items = PhoneArtifactLayout.items(sample.document)
            XCTAssertEqual(items.count, sample.document.blocks.count, sample.name)
            XCTAssertEqual(items.flatMap(\.texts), sample.document.blocks.flatMap(Self.texts), sample.name)
            let buttons = items.flatMap(\.buttons)
            XCTAssertEqual(buttons.map(\.label), sample.document.flattenedActions(cardActions: []).map(\.label), sample.name)
            XCTAssertEqual(buttons.map(\.index), Array(buttons.indices), sample.name)
        }
    }

    /// A card's own buttons come first in its press addresses, so the
    /// blocks' buttons start after them.
    func testButtonIndicesStartAfterTheCardsOwnActions() throws {
        let document = try sample("actions-before-list")
        let indices = PhoneArtifactLayout.items(document, cardActionCount: 1).flatMap(\.buttons).map(\.index)
        XCTAssertEqual(indices, [1, 2, 3, 4, 5])
    }

    /// The Mac's colours, except `accent`: the mockup's purple (§4
    /// `.t-accent`), since the phone's accent is the system blue of `info`.
    func testEveryToneMapsThroughPhoneTone() {
        let expected: [ArtifactTone: PhoneTone] = [
            .neutral: .secondary, .info: .blue, .success: .green, .warning: .orange, .danger: .red, .accent: .purple
        ]
        for tone in ArtifactTone.allCases {
            XCTAssertEqual(PhoneTone.artifact(tone), expected[tone], tone.rawValue)
            if tone != .accent {
                XCTAssertEqual(PhoneTone.artifact(tone).color, Tone.artifact(tone), "the Mac's colour for \(tone.rawValue)")
            }
        }
        XCTAssertEqual(PhoneTone.artifact(.accent).color, Tone.status("purple"))
        XCTAssertNotEqual(PhoneTone.artifact(.accent), PhoneTone.artifact(.info), "accent stays apart from info")
    }

    func testTableScrollsSideways() throws {
        let wide = ArtifactBlock.Table(
            title: "Release",
            columns: ["Item", "Owner", "State", "Since"].map { ArtifactTableColumn(title: $0) },
            rows: [["QA pass", "Colleague C", "green", "Mon"].map { ArtifactTableCell(text: $0) }]
        )
        let narrow = ArtifactBlock.Table(columns: [ArtifactTableColumn(title: "Service")], rows: [[ArtifactTableCell(text: "api")]])
        let items = PhoneArtifactLayout.items(ArtifactDocument(blocks: [.table(wide), .table(narrow)]))
        guard case .table(_, scrolls: true) = items[0] else { return XCTFail("a wide table scrolls: \(items[0])") }
        // Long text in a few columns scrolls too, instead of truncating.
        let long = ArtifactBlock.Table(
            columns: [ArtifactTableColumn(title: "Item"), ArtifactTableColumn(title: "Note")],
            rows: [[ArtifactTableCell(text: "Docs link"),
                    ArtifactTableCell(text: "Waiting on the acme release page to move to the new wiki space")]]
        )
        guard case .table(_, scrolls: true) = PhoneArtifactLayout.items(ArtifactDocument(blocks: [.table(long)]))[0] else {
            return XCTFail("a table with long text scrolls")
        }
        guard case .table(_, scrolls: false) = items[1] else { return XCTFail("a narrow table fits: \(items[1])") }
        // The sample's three-column table fits a phone.
        let table = try XCTUnwrap(PhoneArtifactLayout.items(try sample("every-block")).first {
            if case .table = $0 { true } else { false }
        })
        guard case .table(_, scrolls: false) = table else { return XCTFail("three columns fit: \(table)") }
    }

    /// Only web links open from a row, a cell or a link block; the Mac's
    /// own `watchtower-nav://` and anything else draw as plain text.
    func testOnlyWebLinksOpen() {
        XCTAssertEqual(PhoneArtifactLayout.webURL("https://example.com/acme")?.host, "example.com")
        XCTAssertNotNil(PhoneArtifactLayout.webURL("http://example.com"))
        XCTAssertNil(PhoneArtifactLayout.webURL("watchtower-nav://projects"))
        XCTAssertNil(PhoneArtifactLayout.webURL("javascript:alert(1)"))
        XCTAssertNil(PhoneArtifactLayout.webURL(nil))
        XCTAssertNil(PhoneArtifactLayout.webURL("https://"))
    }

    func testPeopleDrawAsInitials() {
        XCTAssertEqual(PhoneArtifactLayout.initials("Colleague A"), "CA")
        XCTAssertEqual(PhoneArtifactLayout.initials("acme bot two"), "AB")
        XCTAssertEqual(PhoneArtifactLayout.initials("Ünal"), "Ü")
    }

    /// Metrics draw 2- or 3-up (mockup §4): four go 2 by 2.
    func testMetricsColumns() {
        XCTAssertEqual([1, 2, 3, 4, 5, 6].map(PhoneArtifactLayout.metricColumns), [1, 2, 3, 2, 3, 3])
    }

    /// A ref row (a legacy plan item included) is the host's to open; a
    /// row without one opens its web link.
    func testRefRowsGoToTheHost() throws {
        let items = PhoneArtifactLayout.items(try sample("plan-items"))
        guard case let .list(list) = items[1] else { return XCTFail("a list: \(items[1])") }
        XCTAssertEqual(list.rows.map(\.press), [
            .ref(ArtifactRef(kind: .planItem, id: 21)), .ref(ArtifactRef(kind: .planItem, id: 22))
        ])
        let tones = try XCTUnwrap(PhoneArtifactLayout.items(try sample("every-tone-and-ref")).first)
        guard case let .list(toned) = tones else { return XCTFail("a list: \(tones)") }
        XCTAssertEqual(toned.rows[4].press, .link(try XCTUnwrap(URL(string: "https://example.com/acme/danger"))))
    }

    /// Every string a block draws, in its own order (the test's flattening of the Kit document).
    private static func texts(_ block: ArtifactBlock) -> [String] {
        switch block {
        case let .heading(text, _): [text]
        case let .text(markdown): [markdown]
        case let .metrics(items): items.flatMap { [$0.value, $0.label] + [$0.hint].compactMap { $0 } }
        case let .list(list):
            [list.title].compactMap { $0 } + (list.rows.isEmpty ? [list.empty] : list.rows.flatMap { row in
                [row.title] + [row.subtitle, row.badge?.text].compactMap { $0 } + row.actions.map(\.label)
            })
        case let .table(table): [table.title].compactMap { $0 } + table.columns.map(\.title) + table.rows.flatMap { $0.map(\.text) }
        case let .person(person): [person.name] + [person.role].compactMap { $0 } + person.lines.map(\.text)
        case let .link(title, url, subtitle): [title, subtitle ?? url]
        case let .actions(actions): actions.map(\.label)
        }
    }
}
