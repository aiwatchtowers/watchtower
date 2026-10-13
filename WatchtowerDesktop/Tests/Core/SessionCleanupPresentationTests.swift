import XCTest
import WatchtowerCore

final class SessionCleanupPresentationTests: XCTestCase {
    private typealias Presentation = SessionCleanupPresentation
    private typealias Item = SessionCleanupItem

    // MARK: - Reasons in step with Go

    /// Every reason code Go's `internal/sessioncleanup` emits, with the
    /// phrase Go's `ReasonPhrase` gives it (its `reasonPhrases` map, or the
    /// code with spaces where Go has none). A code Go adds must be added
    /// here and to `SessionCleanupReason.Code` with its phrase.
    private static let goPhrases: [String: String] = [
        "main_folder": "the main folder",
        "workbench_folder": "a workbench folder",
        "locked": "locked",
        "uncommitted_changes": "uncommitted changes",
        "process_running": "a process is running in it",
        "process_unknown": "a process could not be checked",
        "session_in_it": "another session works in it",
        "you_are_in_it": "you are in it",
        "unpushed_commits": "unpushed commits",
        "operation_in_progress": "an operation in progress",
        "default_branch": "the default branch",
        "default_branch_unknown": "default branch unknown",
        "checked_out": "checked out",
        "claude_home": "under ~/.claude",
        "not_a_worktree": "not a worktree",
        "not_a_branch": "not a branch",
        "session_recent": "its session was active recently",
        "check_failed": "could not be checked",
        "contains_worktree": "another worktree is inside",
        "not_this_session": "not this session's",
        "existed_before_session": "existed before the session",
        "created_unknown": "creation time unknown",
        "git_refused": "git refused",
        "moved": "moved since the check",
        "not_selected": "not selected",
        "not_in_plan": "not in the plan",
        "not_attempted": "not attempted after a failure",
        "worktree_kept": "worktree kept",
        "bundle_exists": "bundle exists",
        "bundle_unreadable": "its bundle could not be checked"
    ]

    func testEveryGoReasonCodeHasItsGoPhrase() {
        for (code, phrase) in Self.goPhrases {
            XCTAssertNotNil(SessionCleanupReason.Code(rawValue: code), "\(code) is not a SessionCleanupReason.Code")
            XCTAssertEqual(Presentation.reasonText(SessionCleanupReason(code: code)), phrase, code)
        }
        XCTAssertEqual(Set(SessionCleanupReason.Code.allCases.map(\.rawValue)), Set(Self.goPhrases.keys),
                       "the Swift codes and the Go list differ")
    }

    func testAnUnknownReasonReadsAsItsCodeInWords() {
        XCTAssertEqual(Presentation.reasonText(.unknown("cosmic_rays_hit")), "cosmic rays hit")
    }

    /// The Go sources themselves: every `Reason* = "…"` constant in
    /// `internal/sessioncleanup` is a Swift code, and every entry of Go's
    /// `reasonPhrases` map reads the same in Swift — so a reason or phrase
    /// changed on the Go side fails here.
    func testTheGoSourcesAgreeWithSwift() throws {
        let constants = try Self.goReasonConstants()
        XCTAssertGreaterThanOrEqual(constants.count, 20, "the Go reason parse found too few constants")
        for (name, code) in constants {
            XCTAssertNotNil(SessionCleanupReason.Code(rawValue: code), "Go's \(name) = \(code) has no Swift code")
        }
        for (name, phrase) in try Self.goPhraseMap() {
            let code = try XCTUnwrap(constants[name], "reasonPhrases names an unknown constant \(name)")
            XCTAssertEqual(Presentation.reasonText(SessionCleanupReason(code: code)), phrase, code)
        }
    }

    private static let goPackage = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Core
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerDesktop
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("internal/sessioncleanup")

    private static func goSources() throws -> [String] {
        let files = try FileManager.default.contentsOfDirectory(at: goPackage, includingPropertiesForKeys: nil)
        return try files
            .filter { $0.pathExtension == "go" && !$0.lastPathComponent.hasSuffix("_test.go") }
            .map { try String(contentsOf: $0, encoding: .utf8) }
    }

    private static func matches(_ pattern: String, in source: String) throws -> [(String, String)] {
        let regex = try NSRegularExpression(pattern: pattern)
        let text = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: text.length)).map {
            (text.substring(with: $0.range(at: 1)), text.substring(with: $0.range(at: 2)))
        }
    }

    /// Constant name → code.
    private static func goReasonConstants() throws -> [String: String] {
        var out: [String: String] = [:]
        for source in try goSources() {
            for (name, code) in try matches(#"\b(Reason[A-Z]\w*)\s*=\s*"([a-z_]+)""#, in: source) {
                out[name] = code
            }
        }
        return out
    }

    /// Constant name → phrase, from Go's `reasonPhrases` map; required to
    /// parse to something once the map exists.
    private static func goPhraseMap() throws -> [String: String] {
        var out: [String: String] = [:]
        var mapSeen = false
        for source in try goSources() where source.contains("reasonPhrases = map[string]string{") {
            mapSeen = true
            for (name, phrase) in try matches(#"(?m)^\s*(Reason[A-Z]\w*):\s*"([^"]*)","#, in: source) {
                out[name] = phrase
            }
        }
        if mapSeen, out.isEmpty { XCTFail("Go's reasonPhrases map is there but parsed to nothing") }
        return out
    }

    // MARK: - Sizes

    func testByteTextMirrorsGoSizeText() {
        XCTAssertEqual(Presentation.byteText(0), "0 B")
        XCTAssertEqual(Presentation.byteText(512), "512 B")
        XCTAssertEqual(Presentation.byteText(1_500), "1.5 KB")
        XCTAssertEqual(Presentation.byteText(12_000_000_000), "12 GB")
        XCTAssertEqual(Presentation.byteText(1_540_000_000), "1.5 GB")
        XCTAssertEqual(Presentation.byteText(999_000_000), "999 MB")
        XCTAssertEqual(Presentation.byteText(3_000_000_000_000_000), "3000 TB")
    }

    func testSizeText() {
        XCTAssertEqual(Presentation.sizeText(bytes: 12_000_000_000, known: true), "~12 GB")
        XCTAssertEqual(Presentation.sizeText(bytes: 12_000_000_000, known: false), "size unknown")
    }

    // MARK: - Offer line and totals

    private func worktree(_ key: String, _ bytes: Int64, known: Bool = true, keep reason: String? = nil) -> Item {
        Item(key: key, kind: .worktree, bytes: bytes, bytesKnown: known, action: reason == nil ? .remove : .keep,
             reason: reason.map(SessionCleanupReason.init(code:)))
    }

    private func branch(_ key: String, keep reason: String? = nil) -> Item {
        Item(key: key, kind: .branch, action: reason == nil ? .remove : .keep,
             reason: reason.map(SessionCleanupReason.init(code:)))
    }

    func testOfferLineWithKeptItems() {
        let plan = SessionCleanupPlan(items: [
            worktree("a", 7_000_000_000), worktree("b", 5_000_000_000),
            branch("x"), branch("y"), branch("z"),
            worktree("c", 1_000, keep: "uncommitted_changes")
        ])
        XCTAssertEqual(Presentation.offerLine(plan),
                       "Also clean up: 2 worktrees, 3 branches (~12 GB). Kept: 1 worktree — uncommitted changes.")
    }

    func testOfferLineWithoutKeptItems() {
        let plan = SessionCleanupPlan(items: [branch("x")])
        XCTAssertEqual(Presentation.offerLine(plan), "Also clean up: 1 branch.")
    }

    func testOfferLineIsNilWhenNothingIsRemovable() {
        XCTAssertNil(Presentation.offerLine(SessionCleanupPlan()))
        let keptOnly = SessionCleanupPlan(items: [worktree("a", 1, keep: "locked"), branch("b", keep: "default_branch")])
        XCTAssertNil(Presentation.offerLine(keptOnly))
    }

    func testOfferLineSizeVariants() {
        let unknown = SessionCleanupPlan(items: [worktree("a", 0, known: false)])
        XCTAssertEqual(Presentation.offerLine(unknown), "Also clean up: 1 worktree (size unknown).")
        let some = SessionCleanupPlan(items: [worktree("a", 2_000_000_000), worktree("b", 0, known: false)])
        XCTAssertEqual(Presentation.offerLine(some), "Also clean up: 2 worktrees (~2.0 GB, some sizes unknown).")
    }

    func testKeptReasonsAreListedOnceInFirstSeenOrder() {
        let items = [
            branch("a", keep: "checked_out"), worktree("b", 1, keep: "uncommitted_changes"),
            branch("c", keep: "checked_out"),
            Item(key: "p", kind: .process, action: .keep, reason: .known(.processRunning))
        ]
        XCTAssertEqual(Presentation.keptText(items), "1 worktree, 2 branches — checked out, uncommitted changes")
    }

    func testTotalTextCountsEveryKnownKind() {
        let items = [
            Item(key: "p", kind: .process, action: .remove),
            Item(key: "l1", kind: .lsreg, action: .remove), Item(key: "l2", kind: .lsreg, action: .remove),
            Item(key: "u", kind: .unknown("volume"), action: .remove)
        ]
        XCTAssertEqual(Presentation.totalText(items), "1 process, 2 LaunchServices entries")
        XCTAssertNil(Presentation.totalText([]))
    }

    // MARK: - Sweep owner and report

    func testOwnerText() throws {
        let now = try XCTUnwrap(TimeFormatting.parseISO("2026-10-12T12:00:00Z"))
        let owner = SessionCleanupOwner(sessionID: 7, title: "Fix the login form", lastActive: "2026-10-10T12:00:00Z")
        XCTAssertEqual(Presentation.ownerText(owner, now: now), "Fix the login form · active 2d ago")
        let fresh = SessionCleanupOwner(sessionID: 7, title: "", lastActive: "2026-10-12T11:59:30Z")
        XCTAssertEqual(Presentation.ownerText(fresh, now: now), "Session 7 · active just now")
        XCTAssertEqual(Presentation.ownerText(SessionCleanupOwner(sessionID: 7, title: "T"), now: now), "T")
        XCTAssertEqual(Presentation.ownerText(SessionCleanupOwner(isUnknown: true), now: now), "Owner unknown")
        XCTAssertEqual(Presentation.ownerText(SessionCleanupOwner(), now: now), "Owner unknown")
    }

    func testReportLine() {
        let done = SessionCleanupRecord(result: SessionCleanupPlan(summary: "2 worktrees removed (~3.0 GB)"), at: "")
        XCTAssertEqual(Presentation.reportLine(done), "2 worktrees removed (~3.0 GB)")
        XCTAssertNil(Presentation.reportLine(SessionCleanupRecord(result: nil, at: "2026-10-12T10:00:00Z")))
        XCTAssertNil(Presentation.reportLine(SessionCleanupRecord(result: SessionCleanupPlan(), at: "")))
    }
}
