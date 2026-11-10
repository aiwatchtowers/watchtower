import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerCore

/// Core's Kit-free ref reader (`InboxRef.refs(blocksJSON:)`, the badge's)
/// against the Kit's decoder (`ArtifactDocument.decode(_:).refs`, what the
/// Inbox draws): whenever the Kit reads a document, both give the same refs;
/// for the unreadable cases Core checks, both give none.
final class InboxRefParityTests: XCTestCase {
    private func kitRefs(_ json: String) -> [InboxRef]? {
        guard case let .document(document) = ArtifactDocument.decode(json) else { return nil }
        return document.refs.map { ref in
            guard let kind = InboxRef.Kind(rawValue: ref.kind.rawValue) else {
                XCTFail("Kit kind \(ref.kind.rawValue) has no Core twin")
                return InboxRef(kind: .action, id: 0)
            }
            return InboxRef(kind: kind, id: ref.id)
        }
    }

    private let readable = [
        #"{"v":1,"blocks":[{"type":"list","rows":[{"title":"a","ref":{"kind":"action","id":3}},"#
            + #"{"title":"b","ref":{"kind":"inbox_item","id":1}},{"title":"c","ref":{"kind":"track","id":4}},"#
            + #"{"title":"d","ref":{"kind":"idea","id":5}},{"title":"e","ref":{"kind":"reminder","id":6}}]}]}"#,
        #"{"v":1,"blocks":[{"type":"heading","text":"Today"},{"type":"list","rows":[{"title":"a"},"#
            + #"{"title":"b","ref":null},{"title":"c","ref":{"kind":"idea","id":2}}]},"#
            + #"{"type":"text","markdown":"x"},{"type":"list","title":"More","rows":[]}]}"#,
        #"{"v":1,"blocks":[]}"#,
        #"{"v":1,"blocks":[{"type":"link","title":"Docs","url":"https://example.com"}]}"#
    ]

    private let unreadable = [
        "not json",
        #"{"v":2,"blocks":[]}"#,
        #"{"v":1}"#,
        #"{"v":1,"blocks":[{"type":"chart"},{"type":"list","rows":[{"title":"a","ref":{"kind":"track","id":1}}]}]}"#,
        #"{"v":1,"blocks":["text",{"type":"list","rows":[{"title":"a","ref":{"kind":"track","id":1}}]}]}"#,
        #"{"v":1,"blocks":[{"type":"list"}]}"#,
        #"{"v":1,"blocks":[{"type":"list","rows":[{"ref":{"kind":"track","id":1}}]}]}"#,
        #"{"v":1,"blocks":[{"type":"list","rows":[{"title":"","ref":{"kind":"track","id":1}}]}]}"#,
        #"{"v":1,"blocks":[{"type":"list","rows":[{"title":"a","ref":{"kind":"user","id":1}}]}]}"#,
        #"{"v":1,"blocks":[{"type":"list","rows":[{"title":"a","ref":{"kind":"track","id":0}}]}]}"#,
        #"{"v":1,"blocks":[{"type":"list","rows":[{"title":"a","ref":{"kind":"track","id":true}}]}]}"#
    ]

    func testCoreAgreesWithTheKitOnEveryDocumentItReads() throws {
        for json in readable {
            let kit = try XCTUnwrap(kitRefs(json), json)
            XCTAssertEqual(InboxRef.refs(blocksJSON: json), kit, json)
        }
    }

    func testDocumentsTheKitCannotReadHaveNoRefsInCore() {
        for json in unreadable {
            XCTAssertNil(kitRefs(json), "the Kit reads it: \(json)")
            XCTAssertEqual(InboxRef.refs(blocksJSON: json), [], json)
        }
    }

    /// The documented gap: Core does not check non-list blocks' own fields.
    func testKnownGapOtherBlockFieldsAreNotChecked() {
        let json = #"{"v":1,"blocks":[{"type":"heading"},{"type":"list","rows":[{"title":"a","ref":{"kind":"track","id":1}}]}]}"#
        XCTAssertNil(kitRefs(json), "a heading without text is unreadable to the Kit")
        XCTAssertEqual(InboxRef.refs(blocksJSON: json), [InboxRef(kind: .track, id: 1)])
    }
}
