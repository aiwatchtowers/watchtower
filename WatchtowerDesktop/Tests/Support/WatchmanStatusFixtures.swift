import Foundation
import WatchtowerCore

/// `watchman status --json` replies, one per Settings → Watchman state, in
/// the CLI's pinned keys (`cmd/watchman.go`). Sample data only: `acme`,
/// made-up ids. Shared by the decoding, center and design-shot tests.
package enum WatchmanStatusFixtures {
    package static func decode(_ json: String) throws -> WatchmanStatus {
        try JSONDecoder().decode(WatchmanStatus.self, from: Data(json.utf8))
    }

    /// For a test or a shot that cannot fail on a fixture of its own.
    package static func status(_ json: String) -> WatchmanStatus {
        try! decode(json)  // swiftlint:disable:this force_try
    }

    /// Nothing learned: acme-api and acme-web with their estimates.
    package static let notLearned = report([
        notEnabled(2, "acme-api", decisions: 1850, needLabels: 1200, tokens: 1_600_000),
        notEnabled(3, "acme-web", decisions: 620, needLabels: 410, tokens: 500_000)
    ])

    /// acme-api learns (340 of 1 850 so far); acme-web is not on.
    package static let learning = report([
        enabled(2, "acme-api", analyticsOn: true, sleep: "", learning: (340, 1850, false)),
        notEnabled(3, "acme-web", decisions: 620, needLabels: 410, tokens: 500_000)
    ])

    /// acme-web is learned and has never run a backtest.
    package static let neverRun = report([
        enabled(1, "acme-web", analyticsOn: true, sleep: "", learning: (317, 320, true))
    ])

    package static let running = report([
        enabled(1, "acme-web", analyticsOn: false, sleep: "00:30-07:45", learning: (317, 320, true),
                backtest: backtest(id: 8, status: "running", finished: nil, error: "",
                                   progress: "ux_text, 18 of 30 · 3 of 8 categories done", categories: []),
                lastDone: lastDone, running: true)
    ])

    package static let failed = report([
        enabled(1, "acme-web", analyticsOn: false, sleep: "00:30-07:45", learning: (317, 320, true),
                backtest: backtest(id: 8, status: "failed", finished: "\"2026-11-16T03:20:00Z\"",
                                   error: "the AI provider hit your plan limit", progress: "", categories: []),
                lastDone: lastDone)
    ])

    package static let results = report([
        enabled(1, "acme-web", analyticsOn: false, sleep: "00:30-07:45", learning: (317, 320, true),
                backtest: lastDone, lastDone: lastDone)
    ])

    // MARK: - Builders

    private static let lastDone = backtest(
        id: 7, status: "done", finished: "\"2026-11-15T03:40:00Z\"", error: "", progress: "",
        categories: [
            Row("design", 30, 25, 1, "strong"), Row("scope", 30, 24, 1, "strong"), Row("ux_text", 30, 18, 3, "weak"),
            Row("tests", 30, 26, 0, "strong"), Row("review_code", 30, 24, 2, "weak"), Row("review_doc", 30, 25, 1, "strong"),
            Row("permission", 30, 29, 0, "strong"), Row("finish", 12, 0, 0, "not_measured")
        ]
    )

    private static func report(_ rows: [String]) -> String {
        #"{"ok": true, "workbenches": ["# + rows.joined(separator: ", ") + "]}"
    }

    private static func notEnabled(_ id: Int, _ name: String, decisions: Int, needLabels: Int, tokens: Int) -> String {
        """
        {"workbench": \(id), "name": "\(name)", "enabled_at": null, "analytics_on": true,
         "precedents": {}, "sources": {}, "sleep_window": "", "sleep_window_pinned": false,
         "estimate": {"decisions": \(decisions), "need_labels": \(needLabels), "tokens": \(tokens)},
         "learning": null, "backtest": null, "last_done": null, "running": false}
        """
    }

    private static func enabled(
        _ id: Int,
        _ name: String,
        analyticsOn: Bool,
        sleep: String,
        learning: (Int, Int, Bool),
        backtest: String = "null",
        lastDone: String = "null",
        running: Bool = false
    ) -> String {
        """
        {"workbench": \(id), "name": "\(name)", "enabled_at": "2026-11-08T21:04:00Z", "analytics_on": \(analyticsOn),
         "precedents": {"design": 41, "scope": 35, "ux_text": 31, "tests": 40, "review_code": 37,
                        "review_doc": 33, "permission": 88, "finish": 12},
         "sources": {"ask": {"written": 120, "done": true}, "git": {"written": 64, "done": true}},
         "sleep_window": "\(sleep)", "sleep_window_pinned": false, "estimate": null,
         "learning": {"written": \(learning.0), "estimated": \(learning.1), "done": \(learning.2)},
         "backtest": \(backtest), "last_done": \(lastDone), "running": \(running)}
        """
    }

    private struct Row {
        let name: String
        let total: Int
        let agree: Int
        let wrong: Int
        let rating: String

        init(_ name: String, _ total: Int, _ agree: Int, _ wrong: Int, _ rating: String) {
            (self.name, self.total, self.agree, self.wrong, self.rating) = (name, total, agree, wrong, rating)
        }
    }

    private static func backtest(
        id: Int,
        status: String,
        finished: String?,
        error: String,
        progress: String,
        categories: [Row]
    ) -> String {
        let rows = categories.map { row in
            #"{"category": "\#(row.name)", "total": \#(row.total), "agree": \#(row.agree), "#
                + #""wrong_high": \#(row.wrong), "cost_usd": \#(row.rating == "not_measured" ? 0 : 0.4), "#
                + #""status": "\#(row.rating)"}"#
        }
        let cost = categories.isEmpty ? 0 : 2.75
        let verdict = status == "done" ? "go" : ""
        return """
        {"id": \(id), "status": "\(status)", "started_at": "2026-11-15T03:12:00Z", "finished_at": \(finished ?? "null"),
         "error": "\(error)", "verdict": "\(verdict)", "cost_usd": \(cost), "progress": "\(progress)",
         "categories": [\(rows.joined(separator: ", "))]}
        """
    }
}
