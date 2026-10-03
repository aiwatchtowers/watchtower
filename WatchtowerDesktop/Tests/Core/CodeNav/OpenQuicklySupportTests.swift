import XCTest
@testable import WatchtowerCore

/// The pure pieces around Open Quickly: the double-Shift detector (spec
/// §8.1), the recently opened list (last 50 per workbench, ruling R22), the
/// kind badges and theme colours (spec §2 decision 2) and the preview's
/// lines and tokens.
final class OpenQuicklySupportTests: XCTestCase {
    // MARK: Double Shift

    func testTwoShiftsWithin300msFire() {
        var detector = DoubleShiftDetector()
        XCTAssertFalse(detector.shiftPressed(at: 10.0))
        XCTAssertTrue(detector.shiftPressed(at: 10.3))
    }

    func testTwoShiftsFurtherApartDoNotFire() {
        var detector = DoubleShiftDetector()
        XCTAssertFalse(detector.shiftPressed(at: 10.0))
        XCTAssertFalse(detector.shiftPressed(at: 10.31))
        XCTAssertTrue(detector.shiftPressed(at: 10.5), "the second press starts a new pair")
    }

    func testAKeyBetweenTheShiftsDoesNotFire() {
        var detector = DoubleShiftDetector()
        XCTAssertFalse(detector.shiftPressed(at: 1.0))
        detector.otherKeyPressed()
        XCTAssertFalse(detector.shiftPressed(at: 1.1))
    }

    func testThreeShiftsFireOnce() {
        var detector = DoubleShiftDetector()
        let fires = [1.0, 1.1, 1.2].map { detector.shiftPressed(at: $0) }
        XCTAssertEqual(fires, [false, true, false])
    }

    // MARK: Focus when the panel closes

    func testTheWorkbenchWindowTakesTheKeyboardBackOnlyWhenNothingElseHasIt() {
        XCTAssertTrue(OpenQuicklyFocusPolicy.makesParentKey(restoringFocus: true, keyWindowIsElsewhere: false), "Esc")
        XCTAssertTrue(OpenQuicklyFocusPolicy.makesParentKey(restoringFocus: false, keyWindowIsElsewhere: false), "an open: the panel was key")
        XCTAssertFalse(
            OpenQuicklyFocusPolicy.makesParentKey(restoringFocus: false, keyWindowIsElsewhere: true),
            "a click into another window keeps that window key"
        )
    }

    // MARK: Recently opened

    func testRecentFilesMostRecentFirstWithoutDuplicatesCappedAt50() {
        var recent = CodeRecentFiles()
        for n in 0 ..< 60 { recent.record("f\(n).go") }
        recent.record("f20.go")
        XCTAssertEqual(recent.paths.count, CodeRecentFiles.cap)
        XCTAssertEqual(recent.paths.first, "f20.go")
        XCTAssertEqual(recent.paths.filter { $0 == "f20.go" }.count, 1)
        XCTAssertEqual(recent.paths[1], "f59.go")
        XCTAssertFalse(recent.paths.contains("f9.go"), "the oldest fell off")
    }

    func testRecentFilesPruneAndKey() {
        var recent = CodeRecentFiles(paths: ["a", "gone", "b"])
        recent.prune { $0 != "gone" }
        XCTAssertEqual(recent.paths, ["a", "b"])
        XCTAssertEqual(CodeRecentFiles.key(workbenchID: 7), "workbench.files.recent.7")
        XCTAssertEqual(CodeRecentFiles(paths: (0 ..< 80).map(String.init)).paths.count, 50)
    }

    // MARK: Badges and colours

    func testBadgeLettersAndRoles() {
        let letters = CodeSymbolKind.allCases.map(\.badgeLetter)
        XCTAssertEqual(letters, ["F", "M", "C", "S", "E", "P", "P", "T", "K", "K", "K", "N", "#"])
        XCTAssertEqual(CodeSymbolKind.method.badgeRole, .keyword)
        XCTAssertEqual(CodeSymbolKind.function.badgeRole, .keyword)
        XCTAssertEqual(CodeSymbolKind.struct.badgeRole, .type)
        XCTAssertEqual(CodeSymbolKind.field.badgeRole, .variable)
        XCTAssertEqual(CodeThemePalette.light.rgb(.keyword), 0x0000FF)
        XCTAssertEqual(CodeThemePalette.light.rgb(.type), 0x267F99)
        XCTAssertEqual(CodeThemePalette.light.rgb(.string), 0xA31515)
        XCTAssertEqual(CodeThemePalette.dark.rgb(.keyword), 0x569CD6)
        XCTAssertEqual(CodeThemePalette.dark.rgb(.type), 0x4EC9B0)
        XCTAssertEqual(CodeThemePalette.dark.rgb(.string), 0xCE9178)
    }

    // MARK: Preview

    func testPreviewLinesFromALine() {
        let text = (1 ... 30).map { "line \($0)" }.joined(separator: "\n")
        let lines = OpenQuicklyPreviewText.lines(of: text, from: 25, count: 12)
        XCTAssertEqual(lines.map(\.number), Array(25 ... 30))
        XCTAssertEqual(lines.first?.text, "line 25")
        XCTAssertEqual(OpenQuicklyPreviewText.lines(of: "a\r\nb", from: 1, count: 12).map(\.text), ["a", "b"])
        XCTAssertEqual(OpenQuicklyPreviewText.lines(of: "a", from: 5, count: 12).count, 0)
    }

    func testPreviewAroundATextMatch() {
        let match = CodeSearchMatch(path: "a.go", line: 10, col: 3, text: "hit", textCol: 1, before: ["b8", "b9"], after: ["a11", "a12"])
        let lines = OpenQuicklyPreviewText.around(match)
        XCTAssertEqual(lines.map(\.number), [9, 10, 11])
        XCTAssertEqual(lines.map(\.text), ["b9", "hit", "a11"])
    }

    func testTokens() {
        let line = #"func save() -> Int { return "x" // done"#
        let roles = CodePreviewHighlighter.tokens(line, hashComments: false).map { token in
            ((line as NSString).substring(with: NSRange(token.range)), token.role)
        }
        XCTAssertEqual(roles.map(\.0), ["func", "return", "\"x\"", "// done"])
        XCTAssertEqual(roles.map(\.1), [.keyword, .keyword, .string, .comment])

        let python = CodePreviewHighlighter.tokens("x = 42  # note", hashComments: true)
        XCTAssertEqual(python.map(\.role), [.number, .comment])
        XCTAssertEqual(CodePreviewHighlighter.tokens(#""a\"b" c"#, hashComments: false).map(\.range), [0 ..< 6])
        XCTAssertTrue(CodePreviewHighlighter.usesHashComments(path: "tools/run.py"))
        XCTAssertFalse(CodePreviewHighlighter.usesHashComments(path: "main.go"))
    }
}
