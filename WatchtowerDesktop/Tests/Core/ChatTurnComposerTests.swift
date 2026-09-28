import XCTest
@testable import WatchtowerCore

final class ChatTurnComposerTests: XCTestCase {
    private let anna = MentionCandidate(kind: .person, ref: "1:U1", label: "Anna \"Ann\" I", detail: "")
    private let pay = MentionCandidate(kind: .jira, ref: "PAY-1", label: "PAY-1", detail: "")

    func testComposePlainTextIsUnchangedButTrimmed() {
        XCTAssertEqual(ChatTurnComposer.compose(text: "  hello \n", skill: nil, mentions: []), "hello")
    }

    func testComposeAppendsReferencedLineWithEscapedLabels() {
        let out = ChatTurnComposer.compose(text: "ask @Anna \"Ann\" I about @PAY-1", skill: nil, mentions: [anna, pay])
        XCTAssertEqual(out, """
            ask @Anna "Ann" I about @PAY-1

            REFERENCED: person:1:U1 "Anna \\"Ann\\" I"; jira:PAY-1 "PAY-1"
            """)
    }

    func testComposePrefixesSkillLine() {
        XCTAssertEqual(
            ChatTurnComposer.compose(text: "draft it", skill: "status-update", mentions: []),
            "Use skill status-update: load it with load_skill first.\n\ndraft it"
        )
    }

    func testDisplayPartsRoundTrip() {
        let stored = ChatTurnComposer.compose(text: "line one\n\nline two", skill: "break-down", mentions: [anna, pay])
        let parts = ChatTurnComposer.displayParts(stored)
        XCTAssertEqual(parts.skill, "break-down")
        XCTAssertEqual(parts.body, "line one\n\nline two")
        XCTAssertEqual(parts.references, [
            ChatTurnReference(token: "person:1:U1", label: "Anna \"Ann\" I"),
            ChatTurnReference(token: "jira:PAY-1", label: "PAY-1")
        ])
    }

    func testDisplayPartsOfPlainLegacyMessage() {
        let parts = ChatTurnComposer.displayParts("just text\n\nmore")
        XCTAssertNil(parts.skill)
        XCTAssertEqual(parts.body, "just text\n\nmore")
        XCTAssertTrue(parts.references.isEmpty)
        XCTAssertNil(parts.referencedLine)
    }

    /// Anything the send path appended after the REFERENCED line (the
    /// "ACTIONS SINCE YOUR LAST MESSAGE" block) is not part of the body.
    func testDisplayPartsIgnoresTrailingBlocksAfterReferenced() {
        let stored = ChatTurnComposer.compose(text: "hi", skill: nil, mentions: [pay])
            + "\n\nACTIONS SINCE YOUR LAST MESSAGE:\n- approved x"
        XCTAssertEqual(ChatTurnComposer.displayParts(stored).body, "hi")
    }

    /// Editing a message keeps its skill and references (Review Focus 3).
    func testRecomposeKeepsSkillAndReferences() {
        let stored = ChatTurnComposer.compose(text: "old", skill: "break-down", mentions: [pay])
        XCTAssertEqual(
            ChatTurnComposer.recompose(stored: stored, newBody: "new"),
            ChatTurnComposer.compose(text: "new", skill: "break-down", mentions: [pay])
        )
        XCTAssertEqual(ChatTurnComposer.recompose(stored: "plain", newBody: "edited"), "edited")
    }

    // MARK: - Sentinel collisions (review Important finding 1)

    /// A malformed REFERENCED-looking line — no real marker `compose` ever
    /// produces one where an item fails to parse — is never treated as one:
    /// the body keeps the whole thing, nothing is dropped, no chip appears.
    func testDisplayPartsTreatsAMalformedReferencedLineAsRawText() {
        let stored = "look at this\n\nREFERENCED: not a well formed item"
        let parts = ChatTurnComposer.displayParts(stored)
        XCTAssertNil(parts.referencedLine)
        XCTAssertTrue(parts.references.isEmpty)
        XCTAssertEqual(parts.body, stored)
    }

    /// An owner message whose OWN text organically ends with a
    /// REFERENCED-shaped line (one that WOULD strictly parse) round-trips
    /// exactly when no real mentions are attached — never truncated, never
    /// turned into a phantom reference chip.
    func testComposeAndDisplayPartsRoundTripOwnerTextThatLooksLikeAReferencedLineWithNoRealMentions() {
        let text = "remember to write\n\nREFERENCED: fake:1 \"looks real\""
        let stored = ChatTurnComposer.compose(text: text, skill: nil, mentions: [])
        let parts = ChatTurnComposer.displayParts(stored)
        XCTAssertEqual(parts.body, text)
        XCTAssertTrue(parts.references.isEmpty)
        XCTAssertNil(parts.referencedLine)
    }

    /// Two organic look-alike lines (the first at the very start): every one
    /// is escaped, not just the last, so `displayParts` never falls back to
    /// an earlier one and truncates the body there — for send and edit alike.
    func testTwoReferencedLookAlikesBothRoundTripWithNoRealMentions() {
        let text = "REFERENCED: fake:1 \"first\"\n\nsome notes\n\nREFERENCED: fake:2 \"second\"\n\ntail"
        let stored = ChatTurnComposer.compose(text: text, skill: nil, mentions: [])
        let parts = ChatTurnComposer.displayParts(stored)
        XCTAssertEqual(parts.body, text, "the whole body survives, not just the part before a look-alike")
        XCTAssertTrue(parts.references.isEmpty)
        XCTAssertNil(parts.referencedLine)

        let edited = ChatTurnComposer.recompose(stored: ChatTurnComposer.compose(text: "old", skill: nil, mentions: []),
                                                newBody: text)
        XCTAssertEqual(ChatTurnComposer.displayParts(edited).body, text)
    }

    /// The same collision, but real mentions ARE attached this time: the
    /// owner's fake line stays literal body text and the REAL trailing block
    /// (compose's own, always last) is the only one read as references.
    func testComposeAndDisplayPartsRoundTripOwnerTextThatLooksLikeAReferencedLineWithRealMentionsAttached() {
        let text = "remember to write\n\nREFERENCED: fake:1 \"looks real\""
        let stored = ChatTurnComposer.compose(text: text, skill: nil, mentions: [pay])
        let parts = ChatTurnComposer.displayParts(stored)
        XCTAssertEqual(parts.body, text, "the owner's own fake line is preserved verbatim in the body")
        XCTAssertEqual(parts.references, [ChatTurnReference(token: "jira:PAY-1", label: "PAY-1")])
    }

    /// An owner message whose first line organically matches the exact skill
    /// sentence (with a syntactically valid skill name) round-trips exactly
    /// when no real skill is attached.
    func testComposeAndDisplayPartsRoundTripOwnerTextThatLooksLikeASkillLineWithNoRealSkill() {
        let text = "Use skill made-up: load it with load_skill first.\nplan it"
        let stored = ChatTurnComposer.compose(text: text, skill: nil, mentions: [])
        let parts = ChatTurnComposer.displayParts(stored)
        XCTAssertNil(parts.skill)
        XCTAssertEqual(parts.body, text)
    }

    /// The same collision, but a REAL skill is also attached: the real skill
    /// line (compose's own, always first) is read as the skill, and the
    /// owner's look-alike line — now second — is preserved literally.
    func testComposeAndDisplayPartsRoundTripOwnerTextThatLooksLikeASkillLineWithRealSkillAttached() {
        let text = "Use skill made-up: load it with load_skill first.\nplan it"
        let stored = ChatTurnComposer.compose(text: text, skill: "status-update", mentions: [])
        let parts = ChatTurnComposer.displayParts(stored)
        XCTAssertEqual(parts.skill, "status-update")
        XCTAssertEqual(parts.body, text, "the owner's own look-alike line is preserved verbatim, not reinterpreted")
    }

    /// `recompose` (the edit path) is immune to the same collisions.
    func testRecomposeRoundTripsOwnerTextThatLooksLikeASentinelWithNoRealSkillOrMentions() {
        let stored = ChatTurnComposer.compose(text: "old", skill: nil, mentions: [])
        let collidingBody = "REFERENCED: fake:1 \"x\""
        let recomposed = ChatTurnComposer.recompose(stored: stored, newBody: collidingBody)
        XCTAssertEqual(ChatTurnComposer.displayParts(recomposed).body, collidingBody)
    }
}
