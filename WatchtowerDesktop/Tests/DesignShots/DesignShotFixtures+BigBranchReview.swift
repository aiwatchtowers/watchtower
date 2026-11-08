import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Branch review of a big branch (board #1025), one shot per mockup frame of
/// `docs/design/mockups/big-branch-review/`: the run going (1), waiting for the
/// agent's run with a Retry queued (1b), done and checked against the goal (2a),
/// a failed and unreached chapters (2b), the summary failed (2c), a one-chapter
/// PR (3), past the diff cap (4a), the map failed (4b). Sample data only.
@MainActor
enum BigBranchReviewShotFixtures {
    // MARK: - The branch

    private struct Chapter {
        let key: String
        let title: String
        let level: String
        let lane: String?
        var target: Int64?
        var jira: String?
        var signals: [String: Int] = [:]
        let files: [(file: ReviewFixture.File, level: String, signals: [String], also: [String])]
    }

    private static func file(
        _ path: String,
        _ add: Int,
        _ del: Int,
        status: String = "modified",
        level: String = "normal",
        signals: [String] = [],
        also: [String] = []
    ) -> (file: ReviewFixture.File, level: String, signals: [String], also: [String]) {
        (ReviewFixture.File(path: path, status: status, additions: add, deletions: del), level, signals, also)
    }

    private static let chapters: [Chapter] = [
        Chapter(key: "lane:tn/g7", title: "Provider capability table", level: "breaking", lane: "tn/g7", target: 217,
                signals: ["api_removed": 1, "migration_edited": 1], files: [
                    file("internal/providers/capabilities.go", 912, 528, level: "breaking", signals: ["api_removed"]),
                    file("internal/db/migrations/00042_provider_caps.sql", 18, 6, level: "breaking",
                         signals: ["migration_edited"]),
                    file("internal/providers/registry.go", 96, 40),
                    file("internal/providers/capabilities_test.go", 240, 0, status: "added")
                ]),
        Chapter(key: "lane:tn/g8", title: "Fallback chain on rate limit", level: "breaking", lane: "tn/g8", jira: "ACME-412",
                signals: ["test_deleted": 1], files: [
                    file("internal/providers/fallback.go", 1610, 400),
                    file("internal/providers/fallback_legacy_test.go", 0, 300, status: "deleted", level: "breaking",
                         signals: ["test_deleted"])
                ]),
        Chapter(key: "lane:tn/g10", title: "Token store per provider", level: "significant", lane: "tn/g10", target: 219,
                signals: ["security_path": 2], files: [
                    file("internal/auth/token_store.go", 244, 190, level: "significant", signals: ["security_path"]),
                    file("internal/auth/provider_tokens.go", 150, 0, status: "added", level: "significant",
                         signals: ["security_path"]),
                    file("internal/auth/token_store_test.go", 40, 16)
                ]),
        Chapter(key: "lane:build-bump", title: "CI and dependencies", level: "significant", lane: "build-bump",
                signals: ["dependency": 1, "ci": 1], files: [
                    file("go.mod", 60, 40, level: "significant", signals: ["dependency"]),
                    file(".github/workflows/ci.yml", 12, 8, level: "significant", signals: ["ci"])
                ]),
        Chapter(key: "lane:tn/g11", title: "`ai models` command flags", level: "significant", lane: "tn/g11", target: 221,
                signals: ["repo:significant": 1], files: [
                    file("cmd/ai_models.go", 250, 130, level: "significant", signals: ["repo:significant"])
                ]),
        Chapter(key: "lane:tn/g9", title: "Usage meter per provider", level: "normal", lane: "tn/g9", files: [
            file("internal/usage/meter.go", 820, 300, also: ["tn/g7"])
        ]),
        Chapter(key: "lane:tn/g12", title: "Settings → AI providers screen", level: "normal", lane: "tn/g12", target: 223,
                files: [file("app/settings/ProvidersView.swift", 1500, 540)]),
        Chapter(key: "dir:internal/digest", title: "internal/digest", level: "normal", lane: nil, files: [
            file("internal/digest/batch.go", 600, 260)
        ]),
        Chapter(key: "dir:docs/guide", title: "docs/guide", level: "normal", lane: nil, files: [
            file("docs/guide/settings/ai.md", 300, 110)
        ]),
        Chapter(key: "collapsed", title: "Can skip", level: "normal", lane: nil, files: [
            file("internal/providers/testdata/golden.json", 7200, 1900),
            file("go.sum", 520, 250)
        ])
    ]

    private static let lanes = """
    [{"name":"tn/g7","title":"Capability table for every provider","target_id":217},
     {"name":"tn/g8","title":"Fallback chain on rate limit","jira_key":"ACME-412"},
     {"name":"tn/g10","title":"Token store per provider","target_id":219},
     {"name":"build-bump","title":"build-bump"},
     {"name":"tn/g11","title":"CLI flags for ai models","target_id":221},
     {"name":"tn/g9","title":"tn/g9"},
     {"name":"tn/g12","title":"Settings → AI providers: test connection button","target_id":223}]
    """

    private static var files: [ReviewFixture.File] { chapters.flatMap { $0.files.map(\.file) } }

    private static func mapJSON(_ chapters: [Chapter], truncated: Bool = false) -> String {
        let chapterList = chapters.map { c -> String in
            let paths = c.files.map { "\"\($0.file.path)\"" }.joined(separator: ",")
            let lines = c.files.reduce(0) { $0 + $1.file.additions + $1.file.deletions }
            let signals = c.signals.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
            var extra = c.lane.map { #","lane":"\#($0)""# } ?? ""
            if let target = c.target { extra += #","target_id":\#(target)"# }
            if let jira = c.jira { extra += #","jira_key":"\#(jira)""# }
            return #"{"key":"\#(c.key)","title":"\#(c.title)","level":"\#(c.level)","core":\#(c.level == "breaking"),"#
                + #""paths":[\#(paths)],"changed_lines":\#(lines),"signals_summary":{\#(signals)}\#(extra)}"#
        }
        let fileList = chapters.flatMap { c in
            c.files.map { f -> String in
                let signals = f.signals.map { "\"\($0)\"" }.joined(separator: ",")
                let also = f.also.map { "\"\($0)\"" }.joined(separator: ",")
                let lane = c.lane.map { #","lane":"\#($0)""# } ?? ""
                return #"{"path":"\#(f.file.path)","chapter":"\#(c.key)","level":"\#(f.level)","#
                    + #""signals":[\#(signals)],"also":[\#(also)]\#(lane)}"#
            }
        }
        return #"{"ok":true,"map":{"chapters":[\#(chapterList.joined(separator: ","))],"#
            + #""files":[\#(fileList.joined(separator: ","))],"lanes":\#(lanes),"diff_truncated":\#(truncated)}}"#
    }

    private static let context: [(id: Int64, text: String, intent: String)] = [
        (214, "Route each AI call through a provider registry", "Every AI call picks its model through one registry.")
    ]

    // MARK: - Stream lines

    private static let capabilityWhat = "Replaces the per-provider switch in registry.go with one capability table: "
        + "each provider row says which tiers, tools and attachment kinds it supports. The registry now picks a model "
        + "by asking the table instead of hard-coded names."

    private static func described(_ key: String, _ state: String = "ok", what: String = "Described.") -> String {
        #"{"event":"chapter","key":"\#(key)","state":"\#(state)","what":"\#(what)","risks":[]}"#
    }

    private static func failed(_ key: String, _ text: String, detail: String) -> String {
        #"{"event":"chapter","key":"\#(key)","state":"failed","error":{"class":"provider","text":"\#(text)","detail":"\#(detail)"}}"#
    }

    private static func notStarted(_ key: String) -> String {
        #"{"event":"chapter","key":"\#(key)","state":"not_started"}"#
    }

    private static let capabilityLine = #"{"event":"chapter","key":"lane:tn/g7","state":"ok","what":"\#(capabilityWhat)","#
        + #""risks":[{"path":"internal/providers/capabilities.go","level":"high","#
        + #""why":"A caller in another package still reads the removed field by name."},"#
        + #"{"path":"internal/db/migrations/00042_provider_caps.sql","level":"medium","#
        + #""why":"The edited migration does not reach installs that already ran it."}]}"#

    private static let tokenFailure = failed(
        "lane:tn/g10", "The AI provider failed on “Token store per provider”.",
        detail: "HTTP 529 overloaded_error: the provider is temporarily overloaded"
    )

    private static let summaryText = "The branch moves every AI call behind one provider registry with a capability "
        + "table, adds a fallback chain on rate limits and a per-provider usage meter, and gives Settings a provider "
        + "screen. Most of the goal is there; the token store moved but its revoke path is untested, and one chapter "
        + "could not be described."

    private static let doneOverview = """
    {"ok":true,"overview":{"summary":"\(summaryText)",
     "coverage":[{"index":1,"item":"#214 Route each AI call through a provider registry","status":"done","source":"session",
                  "where":["internal/providers/registry.go"]},
                 {"index":2,"item":"#217 Capability table for every provider","status":"done","source":"lane","where":[]},
                 {"index":3,"item":"ACME-412 Fallback chain on rate limit","status":"partial","source":"lane","where":[]},
                 {"index":4,"item":"#219 Token store per provider","status":"partial","source":"lane","where":[]},
                 {"index":5,"item":"#223 Settings → AI providers: test connection button","status":"not_found",
                  "source":"lane","where":[]}],
     "out_of_scope":["internal/digest/batch.go","docs/guide/settings/ai.md"],
     "risk":[],"chapters":[],"incomplete":["lane:tn/g10"]}}
    """

    // MARK: - Shots

    private static func place() -> SessionPlace {
        .worktree(name: "provider-registry", root: URL(fileURLWithPath: "/tmp/acme-provider-registry"),
                  status: WorkbenchGitStatus(branch: "feature/provider-registry", dirty: false, changes: 0))
    }

    /// A Deep round of the big branch: `stream` is the overview's lines, kept going unless `ends`.
    private static func bigPane(
        _ key: String,
        phase: String,
        stream: [String],
        ends: Bool,
        truncated: Bool = false,
        then: (ReviewFixture) -> Void = { _ in }
    ) -> AnyView {
        ReviewShotFixtures.pane(key) {
            let fixture = try ReviewFixture(files: files, context: context, mode: "deep", phase: phase,
                                            map: mapJSON(chapters, truncated: truncated),
                                            // One JSON object per line, as Go prints them.
                                            stream: stream.map { $0.replacingOccurrences(of: "\n", with: "") },
                                            streamEnds: ends)
            fixture.openNow()
            let chapterLines = stream.filter { $0.contains(#""event":"chapter""#) }.count
            spin { fixture.model.streamedChapters.count >= chapterLines }
            if ends { spin { fixture.model.overview != .loading } }
            then(fixture)
            return (fixture, fixture.identity(place: place()))
        }
    }

    /// Frame 1: the run going — two chapters described, one failed, the rest describing.
    static func running() -> AnyView {
        bigPane("bbr-running", phase: "chapters",
                stream: [capabilityLine, described("lane:tn/g11"), described("lane:tn/g9", "cached"),
                         failed("lane:tn/g10", "The overview of “Token store per provider” did not finish in 3 min.",
                                detail: "context deadline exceeded")],
                ends: false) { fixture in
            fixture.markViewedNow(["internal/providers/registry.go"])
        }
    }

    /// Frame 1b: the agent's run holds the branch; a Retry pressed meanwhile is queued.
    static func waiting() -> AnyView {
        bigPane("bbr-waiting", phase: "chapters",
                stream: [#"{"event":"waiting","by":"agent"}"#, described("lane:tn/g11", "cached"),
                         described("lane:tn/g7", "cached")],
                ends: false) { fixture in
            fixture.model.retry(chapter: "lane:tn/g10")
        }
    }

    private static let allDone = [
        capabilityLine, described("lane:tn/g8"), described("lane:build-bump"), described("lane:tn/g11"),
        described("lane:tn/g9"), described("lane:tn/g12"), described("dir:internal/digest"), described("dir:docs/guide")
    ]

    /// Frame 2a: done — the summary checked against the goal; one chapter not covered.
    static func doneMeaning() -> AnyView {
        bigPane("bbr-done", phase: "meaning",
                stream: allDone + [tokenFailure, #"{"event":"summary","state":"ok"}"#, doneOverview], ends: true)
    }

    /// Frame 2b: a chapter that keeps failing and two the run did not reach.
    static func failedChapter() -> AnyView {
        let lines = [capabilityLine, described("lane:tn/g8"), described("lane:build-bump"), described("lane:tn/g11"),
                     described("lane:tn/g9"), described("lane:tn/g12"), tokenFailure,
                     notStarted("dir:internal/digest"), notStarted("dir:docs/guide"),
                     #"{"event":"summary","state":"ok"}"#, doneOverview]
        return bigPane("bbr-failed", phase: "chapters", stream: lines, ends: true) { fixture in
            fixture.markViewedNow(["internal/providers/capabilities.go", "internal/db/migrations/00042_provider_caps.sql",
                                   "internal/providers/registry.go", "internal/providers/capabilities_test.go",
                                   "internal/providers/fallback.go", "internal/providers/fallback_legacy_test.go"])
            selectChapter(fixture, "lane:tn/g10")
        }
    }

    /// Frame 2c: the summary failed, the chapters stay.
    static func summaryFailed() -> AnyView {
        let failure = #"{"event":"summary","state":"failed","error":{"class":"timeout","#
            + #""text":"The summary did not finish in 2 min.","detail":"context deadline exceeded after 120s"}}"#
        let envelope = #"{"ok":true,"overview":{"summary":"","coverage":[],"risk":[],"chapters":[],"incomplete":[]}}"#
        return bigPane("bbr-summary-failed", phase: "meaning",
                       stream: allDone + [described("lane:tn/g10"), failure, envelope], ends: true)
    }

    /// Frame 4a: past the diff cap — the banner, the run describing.
    static func pastTheCap() -> AnyView {
        bigPane("bbr-cap", phase: "chapters", stream: [], ends: false, truncated: true)
    }

    /// Frame 3: a small PR, one chapter — no chapter list, danger marks on the files (Quick).
    static func smallPR() -> AnyView {
        let small = [
            Chapter(key: "dir:internal/imports", title: "internal/imports", level: "significant", lane: nil,
                    signals: ["migration_added": 1], files: [
                        file("internal/imports/runner.go", 64, 12),
                        file("internal/db/migrations/00051_import_tries.sql", 9, 0, status: "added", level: "significant",
                             signals: ["migration_added"]),
                        file("internal/db/schema.sql", 1, 0, level: "significant", signals: ["repo:significant"]),
                        file("internal/imports/runner_test.go", 88, 4),
                        file("docs/guide/imports.md", 6, 2)
                    ]),
            Chapter(key: "collapsed", title: "Can skip", level: "normal", lane: nil, files: [file("go.sum", 8, 8)])
        ]
        let overview = """
        {"summary":"Adds a three-try retry budget to imports, stored per job in a new column.","coverage":[],
         "out_of_scope":[],"risk":[{"path":"internal/db/migrations/00051_import_tries.sql","level":"medium",
         "why":"A new migration"}],"chapters":[]}
        """
        return ReviewShotFixtures.pane("bbr-small") {
            let fixture = try ReviewFixture(files: small.flatMap { $0.files.map(\.file) }, mode: "quick", overview: overview,
                                            map: mapJSON(small))
            fixture.openNow()
            spin { fixture.model.overview != .idle && fixture.model.overview != .loading }
            fixture.markViewedNow(["internal/imports/runner_test.go"])
            return (fixture, fixture.identity(place: .worktree(
                name: "import-retry", root: URL(fileURLWithPath: "/tmp/acme-import-retry"),
                status: WorkbenchGitStatus(branch: "wt/import-retry", dirty: false, changes: 0)
            )))
        }
    }

    /// Frame 4b: the map failed — the banner with Retry over the plain file list (Quick).
    static func mapFailed() -> AnyView {
        ReviewShotFixtures.pane("bbr-map-failed") {
            let fixture = try ReviewFixture(files: files, context: context, mode: "quick",
                                            map: #"{"ok":false,"error":"map failed"}"#)
            fixture.openNow()
            return (fixture, fixture.identity(place: place()))
        }
    }

    // MARK: - Helpers

    private static func selectChapter(_ fixture: ReviewFixture, _ key: String) {
        var done = false
        Task { @MainActor in
            try? await fixture.model.selectChapter(key)
            done = true
        }
        spin { done }
    }

    /// Turns the main run loop until `condition` holds (bounded).
    private static func spin(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
}
