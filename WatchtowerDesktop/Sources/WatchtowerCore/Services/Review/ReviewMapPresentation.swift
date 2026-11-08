import Foundation

/// The branch review's words over the map and the streamed run (board #1025,
/// tech spec §5, mockups `docs/design/mockups/big-branch-review/`): danger
/// badges and hints, a chapter's caption, its run line and the progress card.
/// Views stay thin; `ReviewMapPresentationTests` pins these.
package enum ReviewMapPresentation {
    // MARK: - Danger

    /// "Breaking" / "Significant"; a normal level has no badge.
    package static func levelTitle(_ level: ReviewDangerLevel) -> String? {
        switch level {
        case .breaking: "Breaking"
        case .significant: "Significant"
        case .normal: nil
        }
    }

    /// The signals in the order their words are listed (most dangerous first).
    private static let signalOrder = [
        "api_removed", "migration_edited", "test_deleted", "migration_added", "security_path",
        "dependency", "ci", "file_deleted", "repo:breaking", "repo:significant"
    ]

    /// A file badge's word for a signal (`Migration edited`), nil for one the Desktop does not know.
    package static func badge(_ signal: String) -> String? {
        switch signal {
        case "api_removed": "API removed"
        case "migration_edited": "Migration edited"
        case "test_deleted": "Test deleted"
        case "migration_added": "Migration"
        case "security_path": "Auth"
        case "dependency": "Dependency"
        case "ci": "CI"
        case "file_deleted": "Deleted"
        case "repo:breaking", "repo:significant": "Repository rule"
        default: nil
        }
    }

    /// A chapter hint's words for a signal (`public API removed`).
    package static func hint(_ signal: String) -> String? {
        switch signal {
        case "api_removed": "public API removed"
        case "migration_edited": "migration edited"
        case "test_deleted": "tests deleted"
        case "migration_added": "new migration"
        case "security_path": "auth / tokens"
        case "dependency": "dependency"
        case "ci": "CI"
        case "file_deleted": "files deleted"
        case "repo:breaking", "repo:significant": "repository rule"
        default: nil
        }
    }

    private static func ordered(_ signals: some Sequence<String>) -> [String] {
        let set = Set(signals)
        return signalOrder.filter(set.contains)
    }

    /// A file's danger badge: its most dangerous known signal, only on a breaking
    /// or significant file (a normal file has none).
    package static func fileBadge(_ file: ReviewMap.File) -> String? {
        guard file.level != .normal else { return nil }
        return ordered(file.signals).lazy.compactMap(badge).first
    }

    /// `public API removed · migration edited`, "" without known signals.
    package static func chapterHint(_ chapter: ReviewMap.Chapter) -> String {
        ordered(chapter.signalsSummary.keys).compactMap(hint).joined(separator: " · ")
    }

    /// `public API removed (1), migration edited (1)`: the chapter header's signals line.
    package static func signalsLine(_ chapter: ReviewMap.Chapter) -> String {
        ordered(chapter.signalsSummary.keys).compactMap { id in
            hint(id).map { "\($0) (\(chapter.signalsSummary[id] ?? 0))" }
        }
        .joined(separator: ", ")
    }

    /// A chapter's lane as its row shows it: the board ticket (`#219`), else the
    /// Jira key, else the lane's branch; a package chapter says it has none, an
    /// agent chapter whose it is. A lane chapter's files touched by other lanes add
    /// `also <lane>`.
    package static func laneCaption(_ chapter: ReviewMap.Chapter, files: [ReviewMap.File]) -> String {
        if chapter.key.hasPrefix("agent:") { return "by the agent" }
        guard let lane = chapter.lane else { return "package · no lane" }
        let own = chapter.targetId.map { "#\($0)" } ?? chapter.jiraKey ?? lane
        let paths = Set(chapter.paths)
        var also: [String] = []
        for file in files where paths.contains(file.path) {
            for other in file.also where other != lane && !also.contains(other) { also.append(other) }
        }
        return also.isEmpty ? own : "\(own) also \(also.joined(separator: ", "))"
    }

    /// `1,840 lines`.
    package static func lines(_ count: Int) -> String {
        "\(grouped(count)) \(count == 1 ? "line" : "lines")"
    }

    /// `9,870` — grouped the same way whatever the Mac's locale.
    package static func grouped(_ count: Int) -> String {
        let digits = String(count.magnitude)
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index).isMultiple(of: 3) { out.append(",") }
            out.append(digit)
        }
        return count < 0 ? "-" + out : out
    }

    /// `214 files · 9,870 lines`: the folded Can skip section's size.
    package static func canSkipDetail(_ chapter: ReviewMap.Chapter) -> String {
        let files = chapter.paths.count
        return "\(files) \(files == 1 ? "file" : "files") · \(lines(chapter.changedLines))"
    }

    /// `11 chapters / 396 files left`.
    package static func counterLine(chapters: Int, files: Int) -> String {
        "\(chapters) \(chapters == 1 ? "chapter" : "chapters") / \(grouped(files)) \(files == 1 ? "file" : "files") left"
    }

    // MARK: - A chapter's run line

    /// What a chapter row says about its description.
    package enum RunLine: Equatable, Sendable {
        case none
        case describing
        /// Another run (the agent's) describes it while this one waits.
        case beingDescribedElsewhere(String)
        case queued
        case described
        /// The owner's sentence and the provider's text (shown behind a disclosure).
        case failed(text: String, detail: String?)
        case notDescribed
    }

    /// The row's line. A chapter that failed while the summary is in says the summary
    /// does not cover it (business spec item 4).
    package static func runLine(_ state: ChapterRunState?, summary: ChapterRunState, waitingFor: String?) -> RunLine {
        switch state {
        case nil, .pending?: return .none
        case .running?: return .describing
        case .waiting?: return .beingDescribedElsewhere(elsewhereText(waitingFor))
        case .queued?: return .queued
        case .ok?, .cached?: return .described
        case .notStarted?: return .notDescribed
        case let .failed(text, detail)?:
            return .failed(text: summaryIn(summary) ? notCoveredText : text, detail: detail)
        }
    }

    package static let notCoveredText = "Not described — not covered by the summary"
    package static let queuedText = "Queued — Retry runs after the current run"
    package static let notDescribedText = "Not described yet"

    /// The row's words for `line` ("" for none).
    package static func text(_ line: RunLine) -> String {
        switch line {
        case .none: ""
        case .describing: "Describing…"
        case let .beingDescribedElsewhere(text): text
        case .queued: queuedText
        case .described: "Described"
        case let .failed(text, _): text
        case .notDescribed: notDescribedText
        }
    }

    private static func elsewhereText(_ caller: String?) -> String {
        switch caller {
        case "agent": "Being described by the agent's run"
        case "desktop": "Being described by Branch review's run"
        default: "Being described by another run"
        }
    }

    private static func summaryIn(_ state: ChapterRunState) -> Bool {
        state == .ok || state == .cached
    }

    // MARK: - The progress card

    /// The progress / summary card over the chapter list (mockup frames 1, 1b, 2b).
    package struct Progress: Equatable, Sendable {
        package let title: String
        package let body: String?
        /// Chapters the run did not reach: **Describe N remaining** (0 = no button).
        package let remaining: Int
        /// A run still goes (the card's spinner); false once the summary is in.
        package let running: Bool

        fileprivate init(title: String, body: String?, remaining: Int = 0, running: Bool = true) {
            self.title = title
            self.body = body
            self.remaining = remaining
            self.running = running
        }
    }

    /// The card while a run goes, after it settles, or nil when there is nothing to
    /// say yet (no run asked for, or the summary's failure, which has its own card).
    /// `keys` are the describable chapters (Can skip excluded); `waiting` is the
    /// model's `waitingText`.
    package static func progress(
        keys: [String], states: [String: ChapterRunState], summary: ChapterRunState, waiting: String?
    ) -> Progress? {
        let all = keys.map { states[$0] }
        let done = all.filter { $0 == .ok || $0 == .cached }.count
        let total = keys.count
        if let waiting {
            return Progress(title: waiting, body: "\(done) of \(total) done.")
        }
        let describing = all.filter { $0 == .running || $0 == .waiting }.count
        let queued = all.filter { $0 == .queued }.count
        if describing + queued > 0 {
            var parts = describing > 0 ? ["\(describing) describing"] : []
            if queued > 0 { parts.append("\(queued) queued") }
            let left = describing + queued
            return Progress(
                title: "Describing chapters — \(done) of \(total) done",
                body: "Summary waits for \(left) \(left == 1 ? "chapter" : "chapters") (\(parts.joined(separator: ", "))). "
                    + "Chapters fill in as they finish."
            )
        }
        if summary == .running || summary == .waiting || summary == .queued {
            let line = done == total ? allDescribed(total) + "." : "\(done) of \(total) chapters are described."
            return Progress(title: "Writing the summary", body: line)
        }
        guard summaryIn(summary) else { return nil }
        let failed = all.filter { if case .failed = $0 { true } else { false } }.count
        let notReached = all.filter { $0 == .notStarted }.count
        return Progress(title: "Summary ready", body: notCoveredLine(failed: failed, notReached: notReached),
                        remaining: notReached, running: false)
    }

    /// `1 chapter failed, 2 were not reached · they are listed as not covered.`; nil when none.
    package static func notCoveredLine(failed: Int, notReached: Int) -> String? {
        var parts: [String] = []
        if failed > 0 { parts.append("\(failed) \(failed == 1 ? "chapter" : "chapters") failed") }
        if notReached > 0 {
            let verb = notReached == 1 ? "was" : "were"
            parts.append(failed > 0 ? "\(notReached) \(verb) not reached"
                                    : "\(notReached) \(notReached == 1 ? "chapter" : "chapters") \(verb) not reached")
        }
        guard !parts.isEmpty else { return nil }
        let pronoun = failed + notReached == 1 ? "it is" : "they are"
        return parts.joined(separator: ", ") + " · \(pronoun) listed as not covered."
    }

    /// `Describe 2 remaining`.
    package static func describeRemainingTitle(_ count: Int) -> String {
        "Describe \(count) remaining"
    }

    /// The summary's failure card (mockup frame 2c): how many chapters it can be remade from.
    package static func summaryFailedLine(described: Int, total: Int) -> String {
        (described == total ? allDescribed(total) : "\(described) of \(total) chapters are described")
            + " — open Chapters to read them."
    }

    private static func allDescribed(_ total: Int) -> String {
        total == 1 ? "The chapter is described" : "All \(total) chapters are described"
    }

    package static let summaryRetryNote =
        "Retry remakes only the summary from the described chapters. Until it exists the agent cannot finish its session."
}
