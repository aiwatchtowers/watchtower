import XCTest
@testable import WatchtowerCore

final class MentionTokenizerTests: XCTestCase {
    private func utf16Count(_ s: String) -> Int { s.utf16.count }

    func testActiveQueryAtStartAndAfterSpace() {
        XCTAssertEqual(MentionTokenizer.activeQuery(text: "@an", cursor: 3), "an")
        XCTAssertEqual(MentionTokenizer.activeQuery(text: "ask @an", cursor: 7), "an")
        XCTAssertEqual(MentionTokenizer.activeQuery(text: "ask @", cursor: 5), "")
        XCTAssertEqual(MentionTokenizer.activeMention(text: "ask @an", cursor: 7), ComposerTrigger(start: 4, query: "an"))
    }

    func testNoTriggerInsideEmailOrAfterSpaceInQuery() {
        XCTAssertNil(MentionTokenizer.activeQuery(text: "anna@example.com", cursor: 16))
        XCTAssertNil(MentionTokenizer.activeQuery(text: "@anna ivanova", cursor: 13), "query ends at whitespace")
        XCTAssertNil(MentionTokenizer.activeQuery(text: "no mention", cursor: 10))
    }

    /// The same whitespace-boundary rule that keeps `anna@example.com` inert
    /// also keeps an `@` glued to a code span's backtick from opening —
    /// neither is preceded by whitespace or the start of the text.
    func testNoTriggerRightAfterACodeSpanBacktick() {
        XCTAssertNil(MentionTokenizer.activeQuery(text: "see `@decorator`", cursor: 6))
        XCTAssertNil(MentionTokenizer.activeQuery(text: "see `@decorator", cursor: 8),
                     "still glued to the backtick even without a closing one")
    }

    func testCursorInTheMiddleUsesTextBeforeCursorOnly() {
        let text = "ask @an about it"
        XCTAssertEqual(MentionTokenizer.activeQuery(text: text, cursor: 7), "an")
        XCTAssertNil(MentionTokenizer.activeQuery(text: text, cursor: text.utf16.count))
    }

    func testCursorIsUTF16Offset() {
        let text = "привет 👋 @Ив"
        XCTAssertEqual(MentionTokenizer.activeQuery(text: text, cursor: utf16Count(text)), "Ив")
    }

    func testOutOfRangeCursorIsNil() {
        XCTAssertNil(MentionTokenizer.activeQuery(text: "@a", cursor: 5))
        XCTAssertNil(MentionTokenizer.activeQuery(text: "@a", cursor: -1))
    }

    func testReplaceActiveQueryKeepsSuffixAndMovesCursor() {
        let edit = MentionTokenizer.replace(
            ComposerTrigger(start: 4, query: "an"), in: "ask @an about", cursor: 7, with: "@Anna Ivanova ")
        XCTAssertEqual(edit.text, "ask @Anna Ivanova  about")
        XCTAssertEqual(edit.cursor, 4 + "@Anna Ivanova ".utf16.count)
    }

    func testLiveMentionsKeepsOnlyThoseStillInTextDeduped() {
        let anna = MentionCandidate(kind: .person, ref: "1:U1", label: "Anna", detail: "")
        let pay = MentionCandidate(kind: .jira, ref: "PAY-1", label: "PAY-1", detail: "")
        XCTAssertEqual(
            MentionTokenizer.liveMentions(text: "ping @Anna about it", mentions: [anna, pay, anna]),
            [anna]
        )
    }

    func testReferenceTokensAndInsertionText() {
        XCTAssertEqual(MentionCandidate(kind: .person, ref: "1:U1", label: "Anna", detail: "").referenceToken, "person:1:U1")
        XCTAssertEqual(MentionCandidate(kind: .channel, ref: "1:C1", label: "#pay", detail: "").referenceToken, "channel:1:C1")
        XCTAssertEqual(MentionCandidate(kind: .jira, ref: "PAY-1", label: "PAY-1", detail: "").referenceToken, "jira:PAY-1")
        XCTAssertEqual(MentionCandidate(kind: .target, ref: "5", label: "Ship", detail: "").referenceToken, "target:5")
        XCTAssertEqual(MentionCandidate(kind: .track, ref: "9", label: "Rev", detail: "").referenceToken, "track:9")
        XCTAssertEqual(MentionCandidate(kind: .channel, ref: "1:C1", label: "#pay", detail: "").insertionText, "@#pay")
    }

    func testCandidateFromHitSkipsJiraProjects() {
        XCTAssertNil(MentionCandidate(hit: ChatEntityHit(kind: .jiraProject, ref: "PAY", label: "PAY", detail: "")))
        XCTAssertNil(MentionCandidate(hit: ChatEntityHit(kind: .confluenceSpace, ref: "ENG", label: "ENG", detail: "")))
        XCTAssertEqual(
            MentionCandidate(hit: ChatEntityHit(kind: .jiraIssue, ref: "PAY-1", label: "PAY-1", detail: "x"))?.kind,
            .jira
        )
    }

    /// A raw newline in a label would break the single-line REFERENCED
    /// format and the `@Label` insertion text (review Minor a) — collapsed
    /// to a space at construction, in both initializers.
    func testMentionCandidateCollapsesNewlinesInLabel() {
        let direct = MentionCandidate(kind: .person, ref: "1:U1", label: "Anna\r\nIvanova\nJane", detail: "")
        XCTAssertEqual(direct.label, "Anna Ivanova Jane")
        XCTAssertFalse(direct.insertionText.contains("\n"))

        let hit = ChatEntityHit(kind: .target, ref: "5", label: "Ship\nit", detail: "")
        XCTAssertEqual(MentionCandidate(hit: hit)?.label, "Ship it")
    }

    func testActiveSkillOnlyAtTheStartOfTheDraft() {
        XCTAssertEqual(MentionTokenizer.activeSkill(text: "/sta", cursor: 4), ComposerTrigger(start: 0, query: "sta"))
        XCTAssertEqual(MentionTokenizer.activeSkill(text: "  /", cursor: 3), ComposerTrigger(start: 2, query: ""))
        XCTAssertNil(MentionTokenizer.activeSkill(text: "see /usr", cursor: 8), "not the first word")
        XCTAssertNil(MentionTokenizer.activeSkill(text: "/usr/bin", cursor: 8), "second slash is mid-word")
        XCTAssertNil(MentionTokenizer.activeSkill(text: "/Status!", cursor: 8), "not a skill-name prefix")
        XCTAssertNil(MentionTokenizer.activeSkill(text: "/status now", cursor: 11), "query ended")
    }
}
