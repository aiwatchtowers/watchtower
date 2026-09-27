import XCTest
@testable import WatchtowerCore

final class ArtifactParserTests: XCTestCase {
    private func draft(
        _ key: String,
        _ kind: String,
        _ title: String,
        meta: [String: String] = [:],
        content: String,
        complete: Bool = true
    ) -> ArtifactDraft {
        ArtifactDraft(key: key, kind: kind, title: title, meta: meta, content: content, isComplete: complete)
    }

    func testPlainTextIsOneMarkdownSegment() {
        XCTAssertEqual(ArtifactParser.parse("Hello\n\nworld", final: true).segments, [.markdown("Hello\n\nworld")])
        XCTAssertEqual(ArtifactParser.parse("", final: true).segments, [])
    }

    func testCompleteArtifactSplitsSurroundingMarkdown() {
        let text = #"""
        Here it is:
        :::artifact key="q3" kind="document" title="Q3 plan"
        # Q3
        - ship
        :::
        Done.
        """#
        XCTAssertEqual(ArtifactParser.parse(text, final: true).segments, [
            .markdown("Here it is:"),
            .artifact(draft("q3", "document", "Q3 plan", content: "# Q3\n- ship")),
            .markdown("Done.")
        ])
    }

    func testArtifactInsideBacktickFenceIsNotAnArtifact() {
        let text = #"""
        Syntax:
        ```
        :::artifact key="x" kind="document" title="X"
        body
        :::
        ```
        """#
        let parsed = ArtifactParser.parse(text, final: true)
        XCTAssertEqual(parsed.artifacts, [])
        XCTAssertEqual(parsed.segments, [.markdown(text)])
    }

    func testTildeAndLongerFencesAreRespected() {
        let text = #"""
        ~~~
        :::artifact key="a" kind="document" title="A"
        :::
        ~~~
        ````markdown
        ```
        :::artifact key="b" kind="document" title="B"
        ```
        ````
        :::artifact key="real" kind="document" title="Real"
        yes
        :::
        """#
        XCTAssertEqual(ArtifactParser.parse(text, final: true).artifacts, [draft("real", "document", "Real", content: "yes")])
    }

    func testStreamingOpenBlockIsIncompleteDraft() {
        let text = "Intro\n:::artifact key=\"q3\" kind=\"document\" title=\"Q3\"\nline one\nline t"
        XCTAssertEqual(ArtifactParser.parse(text, final: false).segments, [
            .markdown("Intro"),
            .artifact(draft("q3", "document", "Q3", content: "line one\nline t", complete: false))
        ])
    }

    func testStreamingOpenerWithNoBodyYet() {
        let text = "Intro\n:::artifact key=\"q3\" kind=\"document\" title=\"Q3\"\n"
        XCTAssertEqual(ArtifactParser.parse(text, final: false).segments, [
            .markdown("Intro"),
            .artifact(draft("q3", "document", "Q3", content: "", complete: false))
        ])
    }

    func testFinalUnterminatedBlockIsKeptComplete() {
        let text = "Intro\n:::artifact key=\"q3\" kind=\"document\" title=\"Q3\"\nline one\nline t"
        XCTAssertEqual(ArtifactParser.parse(text, final: true).segments, [
            .markdown("Intro"),
            .artifact(draft("q3", "document", "Q3", content: "line one\nline t", complete: true))
        ])
    }

    func testStreamingPartialOpenerIsHeldBack() {
        XCTAssertEqual(ArtifactParser.parse("Intro\n:::artifact key=\"q3\" kind=\"doc", final: false).segments, [.markdown("Intro")])
        XCTAssertEqual(ArtifactParser.parse("Intro\n:::arti", final: false).segments, [.markdown("Intro")])
        XCTAssertEqual(ArtifactParser.parse("Intro\n:::artifact key=\"q3\" kind=\"document\" title=\"Q3\"", final: false).segments,
                       [.markdown("Intro")], "an opener line is only trusted once its newline arrived")
    }

    func testFinalMalformedOpenerIsMarkdown() {
        let text = "Intro\n:::artifact key=\"q3\" kind=\"doc"
        XCTAssertEqual(ArtifactParser.parse(text, final: true).segments, [.markdown(text)])
    }

    func testCyrillicTitleAndEscapedQuotes() {
        let text = #"""
        :::artifact key="lyst" kind="email" title="Лист для \"Ані\"" to="anna@example.com" subject="Re: \"v2\" — наступні кроки"
        Привіт!
        :::
        """#
        XCTAssertEqual(ArtifactParser.parse(text, final: true).artifacts, [
            draft("lyst", "email", #"Лист для "Ані""#,
                  meta: ["to": "anna@example.com", "subject": #"Re: "v2" — наступні кроки"#],
                  content: "Привіт!")
        ])
    }

    func testUnknownKindBecomesDocumentAndMissingKeyIsSlugged() {
        let text = ":::artifact kind=\"memo\" title=\"План на Q3 — draft!\"\nx\n:::"
        XCTAssertEqual(ArtifactParser.parse(text, final: true).artifacts,
                       [draft("план-на-q3-draft", "document", "План на Q3 — draft!", content: "x")])
        let bare = ":::artifact\nx\n:::"
        XCTAssertEqual(ArtifactParser.parse(bare, final: true).artifacts,
                       [draft("artifact", "document", "Untitled", content: "x")])
    }

    func testCloserInsideInnerCodeFenceDoesNotCloseDocument() {
        let text = #"""
        :::artifact key="doc" kind="document" title="Doc"
        Example:
        ```
        :::
        ```
        :::
        """#
        XCTAssertEqual(ArtifactParser.parse(text, final: true).artifacts,
                       [draft("doc", "document", "Doc", content: "Example:\n```\n:::\n```")])
    }

    func testCodeKindDoesNotTrackInnerFences() {
        let text = ":::artifact key=\"c\" kind=\"code\" title=\"C\" language=\"swift\"\nlet a = 1\n```\n:::"
        XCTAssertEqual(ArtifactParser.parse(text, final: true).artifacts,
                       [draft("c", "code", "C", meta: ["language": "swift"], content: "let a = 1\n```")])
    }

    func testTwoArtifactsAndSameKeyTwiceBothSurface() {
        let text = ":::artifact key=\"a\" kind=\"table\" title=\"A\"\nx,y\n:::\nmid\n:::artifact key=\"a\" kind=\"table\" title=\"A\"\nx,z\n:::"
        XCTAssertEqual(ArtifactParser.parse(text, final: true).segments, [
            .artifact(draft("a", "table", "A", content: "x,y")),
            .markdown("mid"),
            .artifact(draft("a", "table", "A", content: "x,z"))
        ])
    }

    func testCRLFLineEndings() {
        let text = "a\r\n:::artifact key=\"k\" kind=\"table\" title=\"T\"\r\nx,y\r\n:::\r\n"
        XCTAssertEqual(ArtifactParser.parse(text, final: true).segments, [
            .markdown("a"),
            .artifact(draft("k", "table", "T", content: "x,y"))
        ])
    }

    func testSlug() {
        XCTAssertEqual(ArtifactParser.slug("Q3 plan — draft!"), "q3-plan-draft")
        XCTAssertEqual(ArtifactParser.slug("План на Q3"), "план-на-q3")
        XCTAssertEqual(ArtifactParser.slug("!!!"), "artifact")
        XCTAssertEqual(ArtifactParser.slug(String(repeating: "a", count: 100)).count, 64)
    }
}
