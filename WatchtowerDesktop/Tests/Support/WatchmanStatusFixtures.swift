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

    /// acme-web is learned; the relabel pass still sorts 340 earlier decisions.
    package static let relabelling = report([
        enabled(1, "acme-web", analyticsOn: false, sleep: "00:30-07:45", learning: (317, 320, true),
                relabelPending: 340, backtest: lastDone, lastDone: lastDone)
    ])

    // MARK: - Editing (phase 2)

    /// `watchman profile --workbench 1 --json`: design pinned by the owner,
    /// ux_text learned on 14 Nov, the learned sleep window.
    package static let profile = profileJSON([
        ("design", [
            "Settings that differ by folder are per workbench; the rest stay global.",
            "Prefer the simpler flow; never ask for a field the app can derive.",
            "A new screen reuses the design kit; no new component for one use."
        ], true, "2026-11-15T09:00:00Z"),
        ("sleep_window", ["00:30-07:45"], false, "2026-11-14T03:00:00Z"),
        ("ux_text", [
            "Shipped button titles stay unless the guide page changes too.",
            "Say what happened and what to do; no apologies, no exclamation marks."
        ], false, "2026-11-14T03:00:00Z")
    ])

    /// The same workbench with nothing learned yet (the CLI's empty shape).
    package static let profileEmpty = #"{"ok": true, "workbench": 1, "profiles": [], "sleep_window": ""}"#

    private static func profileJSON(_ entries: [(key: String, lines: [String], pinned: Bool, updated: String)]) -> String {
        let rows = entries.map { entry in
            #"{"key": "\#(entry.key)", "text": "\#(entry.lines.joined(separator: "\\n"))", "#
                + #""pinned": \#(entry.pinned), "version": 2, "updated_at": "\#(entry.updated)"}"#
        }
        let sleep = entries.first { $0.key == "sleep_window" }?.lines.first ?? ""
        return #"{"ok": true, "workbench": 1, "sleep_window": "\#(sleep)", "profiles": [\#(rows.joined(separator: ", "))]}"#
    }

    /// The built-in table, in `watchman.BuiltinLimits()` order.
    package static let builtinLimits = ["unreadable", "send_pack", "main_ref", "tag", "release", "testflight",
                                        "force_push", "reset_shared", "delete_outside", "outward",
                                        "standing_grant", "outside_folder"]

    /// `watchman limits list --json` with the owner's `owner` rows.
    package static func limits(_ owner: [(id: Int, kind: String, pattern: String)]) -> String {
        let builtin = builtinLimits.map { "\"\($0)\"" }.joined(separator: ", ")
        let rows = owner.map { #"{"id": \#($0.id), "kind": "\#($0.kind)", "pattern": "\#($0.pattern)"}"# }
        return #"{"ok": true, "builtin": [\#(builtin)], "owner": [\#(rows.joined(separator: ", "))]}"#
    }

    /// Two limits of the owner's: a command and a tool.
    package static let ownerLimits = limits([(4, "command", "terraform apply"), (7, "tool", "create_jira_issue")])

    /// What the center holds after reading `profile` and `ownerLimits` for
    /// workbench 1, for the shots.
    package static func editing(errors: [WatchmanEditSlot: String] = [:]) -> WatchmanEditingData {
        let decoder = JSONDecoder()
        // swiftlint:disable force_try
        let profile = try! decoder.decode(WatchmanProfile.self, from: Data(profile.utf8))
        let limits = try! decoder.decode(WatchmanLimits.self, from: Data(ownerLimits.utf8))
        // swiftlint:enable force_try
        return WatchmanEditingData(profiles: [1: profile], limits: limits, errors: errors)
    }

    // MARK: - Builders

    private static let lastDone = backtest(
        id: 7, status: "done", finished: "\"2026-11-15T03:40:00Z\"", error: "", progress: "",
        categories: [
            Row("design", 30, 25, 1, "strong"), Row("scope", 30, 24, 1, "strong"), Row("ux_text", 30, 18, 3, "weak"),
            Row("tests", 30, 26, 0, "strong"), Row("review_code", 30, 24, 2, "weak"), Row("review_doc", 30, 25, 1, "strong"),
            Row("permission", 30, 29, 0, "strong"), Row("finish", 12, 0, 0, "not_measured", handed: 18)
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
        relabelPending: Int? = nil,
        backtest: String = "null",
        lastDone: String = "null",
        running: Bool = false
    ) -> String {
        let relabel = relabelPending.map { ", \"relabel_pending\": \($0)" } ?? ""
        return """
        {"workbench": \(id), "name": "\(name)", "enabled_at": "2026-11-08T21:04:00Z", "analytics_on": \(analyticsOn),
         "precedents": {"design": 41, "scope": 35, "ux_text": 31, "tests": 40, "review_code": 37,
                        "review_doc": 33, "permission": 88, "finish": 12},
         "sources": {"ask": {"written": 120, "done": true}, "git": {"written": 64, "done": true}},
         "sleep_window": "\(sleep)", "sleep_window_pinned": false, "estimate": null,
         "learning": {"written": \(learning.0), "estimated": \(learning.1), "done": \(learning.2)\(relabel)},
         "backtest": \(backtest), "last_done": \(lastDone), "running": \(running)}
        """
    }

    private struct Row {
        let name: String
        let total: Int
        let agree: Int
        let wrong: Int
        let rating: String
        let handed: Int

        init(_ name: String, _ total: Int, _ agree: Int, _ wrong: Int, _ rating: String, handed: Int = 0) {
            (self.name, self.total, self.agree, self.wrong, self.rating) = (name, total, agree, wrong, rating)
            self.handed = handed
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
                + #""wrong_high": \#(row.wrong), "handed": \#(row.handed), "cost_usd": \#(row.rating == "not_measured" ? 0 : 0.4), "#
                + #""baseline": \#(row.rating == "not_measured" ? 0 : 0.5), "#
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
