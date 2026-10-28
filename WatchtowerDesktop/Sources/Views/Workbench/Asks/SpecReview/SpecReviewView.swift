import SwiftUI
import WatchtowerCore

/// The spec review screen of a review ask (spec 2026-10-25 §7): the header
/// (title, the reviewer's state, **Read the spec**, **Re-run reviewer**),
/// then Meaning → Chapters → Wrap-up over the reviewer's findings, shaped
/// like Deep review. While the reviewer has no result the body is its
/// status page; **Read the spec** (the classic view) is always one click away.
/// `askContext` is the ask's own header (summary, focus points, what changed,
/// its questions), shown on Meaning.
struct SpecReviewView<AskContext: View>: View {
    let model: SpecReviewModel
    let onReadSpec: () -> Void
    @ViewBuilder let askContext: () -> AskContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.regular)
            if model.isLoop {
                loopBody
            } else if let result = SpecReviewPresentation.reviewedResult(model.row) {
                ReviewPhasePicker(
                    phase: Binding(get: { model.phase }, set: { model.phase = $0 }),
                    progress: SpecReviewPresentation.progressLine(model)
                )
                .padding(.horizontal, Spacing.medium)
                .padding(.bottom, Spacing.regular)
                Divider()
                phaseBody(result)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Divider()
                // The header carries Read the spec.
                SpecReviewStatusView(model: model, style: .page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(SpecReviewPresentation.title(docName: model.docName)).font(.headline)
                if let line = SpecReviewPresentation.statusLine(model.row) {
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let error = model.lastError {
                    Text(error).font(.caption).foregroundStyle(Tone.error).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.regular)
            if model.row != nil, !model.isReviewerActive, !model.isLoop {
                Button("Re-run reviewer") { Task { await model.runReviewer(force: true) } }
                    .buttonStyle(.kitQuiet)
                    .controlSize(.small)
                    .help("Run the reviewer again; your marks on findings it finds again are kept")
            }
            Button("Read the spec", action: onReadSpec)
                .buttonStyle(.kitSecondary)
                .controlSize(.small)
                .help("Open the document with margin comments")
        }
    }

    /// A finished author loop (spec 2026-10-26 §6): **Decide** (the
    /// disputes, the author's fixes, Approve) first, then Meaning and the
    /// chapters to read, with no marks. Without a readable result there is
    /// only Decide.
    @ViewBuilder
    private var loopBody: some View {
        if let result = SpecReviewPresentation.reviewedResult(model.row) {
            HStack(spacing: Spacing.cozy) {
                KitSegmentedPicker(
                    title: "Phase",
                    selection: Binding(get: { model.phase }, set: { model.phase = $0 }),
                    segments: SpecReviewPresentation.loopPhases.map { KitSegment(value: $0.phase, title: $0.title) }
                )
                if let line = model.row.flatMap(SpecReviewSummary.loopLine) {
                    Text(line).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.bottom, Spacing.regular)
            Divider()
            Group {
                switch model.phase {
                case .wrapup: SpecReviewLoopView(model: model)
                case .meaning: SpecReviewMeaningView(model: model, result: result, askContext: askContext)
                case .chapters: SpecReviewChaptersView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Divider()
            SpecReviewLoopView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func phaseBody(_ result: SpecReviewResult) -> some View {
        switch model.phase {
        case .meaning: SpecReviewMeaningView(model: model, result: result, askContext: askContext)
        case .chapters: SpecReviewChaptersView(model: model)
        case .wrapup: SpecReviewWrapUpView(model: model, result: result)
        }
    }
}

extension SpecReviewView where AskContext == EmptyView {
    init(model: SpecReviewModel, onReadSpec: @escaping () -> Void) {
        self.init(model: model, onReadSpec: onReadSpec) { EmptyView() }
    }
}

/// The way forward at the foot of a step, as in Deep review: Meaning →
/// Chapters, Chapters → Wrap-up.
struct SpecReviewNextStepButton: View {
    let model: SpecReviewModel

    var body: some View {
        if let next = SpecReviewPresentation.nextStep(model.phase, loop: model.isLoop) {
            HStack {
                Spacer()
                Button(next.title) { model.phase = next.phase }
                    .buttonStyle(.kitSecondary)
                    .controlSize(.small)
            }
        }
    }
}

/// The screen's strings, badges and groupings, kept out of the views so
/// they are tested (`SpecReviewViewTests`).
enum SpecReviewPresentation {
    /// A badge's colour, named so tests can compare it. On a finding only
    /// its severity is coloured (spec 2026-10-28 §2); the kind and the loop
    /// status are neutral.
    enum Tint: Equatable {
        case success, warning, error, neutral

        var color: Color {
            switch self {
            case .success: Tone.success
            case .warning: Tone.warning
            case .error: Tone.error
            case .neutral: Tone.status("gray")
            }
        }
    }

    struct Badge: Equatable, Hashable {
        let title: String
        let tint: Tint
    }

    /// What the drawer shows for a review ask: the spec review screen, or
    /// the classic view with a strip above it (the reviewer's state, or the
    /// banner offering its findings).
    enum DrawerMode: Equatable {
        /// The first load has not returned: nothing yet, so the classic
        /// view does not flash before the screen.
        case loading
        case review
        case classic(Strip?)
    }

    enum Strip: Equatable {
        case status, banner
    }

    /// `showClassic`: the owner chose **Read the spec**, or the drawer
    /// opened before the reviewer's row existed. A review that finishes
    /// while the classic view is open offers a banner and never replaces
    /// it; a failed or skipped one leaves the classic view below its reason.
    /// A finished author loop (`loop == .owner`) always has its screen,
    /// whatever the reviewer's last status.
    static func drawerMode(row: SpecReviewRow?, showClassic: Bool, loaded: Bool = true) -> DrawerMode {
        guard loaded else { return .loading }
        guard let row else { return .classic(nil) }
        if row.loop == .owner { return showClassic ? .classic(.banner) : .review }
        if reviewedResult(row) != nil { return showClassic ? .classic(.banner) : .review }
        if row.status == .queued || row.status == .running { return showClassic ? .classic(.status) : .review }
        return .classic(.status)
    }

    /// Whether the drawer looks for a spec review: an open review ask of a
    /// spec or a plan (the only documents Go queues a reviewer for), with
    /// the CLI to run it. Any other ask opens straight into its own layout.
    static func applies(kind: OwnerAskKind, docType: String, isOpen: Bool, hasCLI: Bool) -> Bool {
        kind == .review && (docType == "spec" || docType == "plan") && isOpen && hasCLI
    }

    /// The result to review: only a done row's, decoded.
    static func reviewedResult(_ row: SpecReviewRow?) -> SpecReviewResult? {
        guard let row, row.status == .done else { return nil }
        return row.result
    }

    /// The loop screen's **Go to Meaning** button: only when the ask has
    /// questions and Meaning exists — a reviewed result to show it from
    /// (a loop whose reviewer failed has none, and the button would do
    /// nothing).
    static func showsGoToMeaning(row: SpecReviewRow?, hasQuestions: Bool) -> Bool {
        hasQuestions && reviewedResult(row) != nil
    }

    static func title(docName: String) -> String {
        docName.isEmpty ? "Spec review" : "Spec review · \(docName)"
    }

    /// The reviewer's state in one line; nil when there is no row.
    static func statusLine(_ row: SpecReviewRow?) -> String? {
        guard let row else { return nil }
        if let line = SpecReviewSummary.stateLine(row) { return line }
        switch row.status {
        case .queued, .running, .failed, .skipped: return nil
        case .done:
            if row.result == nil { return "The reviewer's result could not be read" }
            return row.model.isEmpty ? "Reviewer finished" : "Reviewer finished · \(row.model)"
        case .unknown: return "Reviewer state is not known to this version of the app"
        }
    }

    /// "2 blockers · 1 major — 9 as agreed · 1 differs · …": the severity
    /// counts lead when the reviewer gave any; zero counts are left out.
    static func countsLine(_ result: SpecReviewResult) -> String {
        let counts = SpecReviewSummary.countsLine(result)
        guard let severities = severityCounts(result) else { return counts }
        return "\(severities) — \(counts)"
    }

    /// "2 blockers · 3 major · 4 minor" over every finding to act on; nil
    /// when none has a severity (an old review, a customised prompt).
    static func severityCounts(_ result: SpecReviewResult) -> String? {
        let all = result.agreements.filter { $0.status != "as_agreed" }.map(\.severity)
            + result.decidedAlone.map(\.severity) + result.blindSpots.map(\.severity)
            + result.checks.filter { $0.answer == "concern" }.map(\.severity)
        let parts: [String] = SpecReviewSeverity.allCases.compactMap { level in
            let n = all.filter { $0 == level }.count
            guard n > 0 else { return nil }
            return level == .blocker ? "\(n) blocker\(n == 1 ? "" : "s")" : "\(n) \(level.rawValue)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The coloured chip of a finding; nil without a severity.
    static func severityBadge(_ severity: SpecReviewSeverity?) -> Badge? {
        switch severity {
        case .blocker: Badge(title: "Blocker", tint: .error)
        case .major: Badge(title: "Major", tint: .warning)
        case .minor: Badge(title: "Minor", tint: .neutral)
        case nil: nil
        }
    }

    /// Items sorted blocker, major, minor, none; stable within a level.
    static func sortedBySeverity<T>(_ items: [T], _ severity: (T) -> SpecReviewSeverity?) -> [T] {
        func rank(_ item: T) -> Int {
            severity(item).flatMap { SpecReviewSeverity.allCases.firstIndex(of: $0) } ?? SpecReviewSeverity.allCases.count
        }
        let indexed = items.enumerated().map { (rank: rank($0.element), offset: $0.offset, element: $0.element) }
        let sorted = indexed.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.offset < $1.offset }
        return sorted.map(\.element)
    }

    /// An agreement's kind chip: As agreed stays green (it is not a
    /// finding); the others are neutral, their colour is the severity's.
    static func agreementBadge(status: String) -> Badge {
        switch status {
        case "as_agreed": Badge(title: "As agreed", tint: .success)
        case "differs": Badge(title: "Differs", tint: .neutral)
        case "missing": Badge(title: "Missing", tint: .neutral)
        default: Badge(title: status.isEmpty ? "Agreement" : status, tint: .neutral)
        }
    }

    /// A finding's kind chip, neutral beside its severity chip.
    static func badge(for finding: SpecReviewChapterFinding) -> Badge {
        switch finding {
        case let .agreement(f): agreementBadge(status: f.status)
        case .decidedAlone: Badge(title: "Decided alone", tint: .neutral)
        case .blindSpot: Badge(title: "Blind spot", tint: .neutral)
        }
    }

    static func checkBadge(answer: String) -> Badge {
        switch answer {
        case "ok": Badge(title: "OK", tint: .success)
        case "concern": Badge(title: "Concern", tint: .neutral)
        case "n/a": Badge(title: "N/A", tint: .neutral)
        default: Badge(title: answer.isEmpty ? "—" : answer, tint: .neutral)
        }
    }

    static func verdictBadge(_ verdict: String) -> Badge {
        switch verdict {
        case "matches": Badge(title: "Matches", tint: .success)
        case "narrowed": Badge(title: "Narrowed", tint: .warning)
        case "differs": Badge(title: "Differs", tint: .error)
        default: Badge(title: verdict.isEmpty ? "No verdict" : verdict, tint: .neutral)
        }
    }

    /// A chapter row's badges with their counts: each finding (As agreed
    /// left out) and each concern counts under its severity, or under its
    /// neutral kind without one; severities first, most serious first.
    static func chapterBadges(_ chapter: SpecReviewChapterVM) -> [(badge: Badge, count: Int)] {
        var order: [Badge] = []
        var counts: [Badge: Int] = [:]
        func count(_ badge: Badge) {
            if counts[badge] == nil { order.append(badge) }
            counts[badge, default: 0] += 1
        }
        for finding in chapter.findings {
            let kind = badge(for: finding)
            if kind.tint == .success { continue }
            count(severityBadge(finding.severity) ?? kind)
        }
        for check in chapter.checks where check.answer == "concern" {
            count(severityBadge(check.severity) ?? checkBadge(answer: "concern"))
        }
        let severities = SpecReviewSeverity.allCases.compactMap(severityBadge)
        let ranked = severities.filter { counts[$0] != nil } + order.filter { !severities.contains($0) }
        return ranked.map { ($0, counts[$0] ?? 0) }
    }

    /// The label over an agreement's source quote. Only the owner's own
    /// words are "What you said"; anything else is named by where it came from.
    static func sourceLabel(_ source: SpecReviewResult.Source) -> String {
        let ref = refLabel(source.ref)
        if source.speaker == "owner" { return ref.map { "What you said · \($0)" } ?? "What you said" }
        let kind: String = switch source.kind {
        case "conversation": "The agent said"
        case "ask": "Ask"
        case "target": "Target"
        case "comment": "Comment"
        case "decisions": "Decisions"
        case "spec": "Spec"
        case "": "Source"
        default: source.kind.capitalized
        }
        return ref.map { "\(kind) · \($0)" } ?? kind
    }

    /// The label over the idea's quote: "Your idea" only for the owner's own words.
    static func ideaLabel(_ idea: SpecReviewResult.Idea) -> String {
        guard let source = idea.ownerSource else { return "The idea" }
        return source.speaker == "owner" ? "Your idea" : "The idea · \(sourceLabel(source))"
    }

    /// `ask:571` reads "ask #571", `target:12` "target #12"; other refs are not shown.
    private static func refLabel(_ ref: String) -> String? {
        let parts = ref.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, ["ask", "target", "comment"].contains(parts[0]), Int(parts[1]) != nil else { return nil }
        return "\(parts[0]) #\(parts[1])"
    }

    /// Meaning's notes: what the reviewer could not see or kept back.
    static func notes(row: SpecReviewRow?, result: SpecReviewResult) -> [String] {
        var out = result.notes
        let dropped = max(result.dropped, row?.dropped ?? 0)
        if dropped > 0 {
            out.append("\(dropped) finding\(dropped == 1 ? " was" : "s were") dropped: the quote was not found in its source.")
        }
        if !result.codeRead { out.append("The reviewer did not read the code.") }
        return out
    }

    @MainActor static func progressLine(_ model: SpecReviewModel) -> String {
        let chapters = model.chapters
        let viewed = chapters.filter(\.viewed).count
        let unmarked = model.unmarkedCount
        let marks = unmarked == 0 ? "all marked" : "\(unmarked) not marked"
        return "\(viewed)/\(chapters.count) chapters viewed · \(marks)"
    }

    /// A finished loop's steps: Decide (the `.wrapup` slot) first, then
    /// Meaning and Chapters to read.
    static let loopPhases: [(phase: ReviewPhase, title: String)] = [
        (.wrapup, "1 Decide"), (.meaning, "2 Meaning"), (.chapters, "3 Chapters")
    ]

    static func nextStep(_ phase: ReviewPhase, loop: Bool = false) -> (phase: ReviewPhase, title: String)? {
        if loop {
            switch phase {
            case .meaning: return (.chapters, "Next: Chapters →")
            case .chapters: return (.wrapup, "Back to Decide →")
            case .wrapup: return nil
            }
        }
        switch phase {
        case .meaning: return (.chapters, "Next: Chapters →")
        case .chapters: return (.wrapup, "Next: Wrap-up →")
        case .wrapup: return nil
        }
    }

    /// A quote with its inline Markdown applied (code spans, emphasis,
    /// links as text); the raw text when it does not parse.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// The verdict a key names: ⌘⇧↩ Request changes, ⌘↩ Approve; nil
    /// when that button is off.
    static func keyVerdict(shift: Bool, canSend: Bool, canApprove: Bool) -> OwnerAskAnswer.Verdict? {
        if shift { return canSend ? .changes : nil }
        return canApprove ? .approved : nil
    }

    /// A loop card's neutral chip: the finding's kind and where it stands —
    /// the reviewer kept it after the author's fix (Disputed), the author
    /// disagreed and the loop ended (Not settled), a fix nobody checked
    /// (Fix not checked), or a finding the author never saw an answer for
    /// (New in round N). Colour is the severity chip's.
    static func loopBadge(_ entry: SpecReviewLedgerEntry) -> Badge {
        let state: String
        if entry.verdict != "unsettled" {
            state = "Disputed"
        } else {
            switch entry.item.reply?.reply {
            case "disagree": state = "Not settled"
            case "fixed": state = "Fix not checked"
            default: state = "New in round \(max(entry.item.round, 1))"
            }
        }
        let kind = loopKindTitle(entry.item.kind)
        return Badge(title: kind.map { "\($0) · \(state)" } ?? state, tint: .neutral)
    }

    /// The kind of a loop item in words; nil for one this build does not know.
    static func loopKindTitle(_ kind: String) -> String? {
        switch kind {
        case "agreement": "Agreement"
        case "decided_alone": "Decided alone"
        case "blind_spot": "Blind spot"
        case "check": "Concern"
        default: nil
        }
    }

    /// The reviewer's argument: on a dispute its answer to the author's
    /// reply (the verdict note), else the finding's own note — never a
    /// loop-end line such as "Not settled in 3 rounds".
    static func reviewerPosition(_ entry: SpecReviewLedgerEntry) -> String? {
        let verdict = entry.verdictNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let own = entry.item.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if entry.verdict == "disputed", !verdict.isEmpty { return verdict }
        return own.isEmpty ? nil : own
    }

    /// Why an unsettled card is still open: the loop-end note (the cap, a
    /// fix not checked, Show Now); nil on a dispute or when it only repeats
    /// the author's reason or the reviewer's argument.
    static func loopStatus(_ entry: SpecReviewLedgerEntry) -> String? {
        guard entry.verdict == "unsettled" else { return nil }
        let note = entry.verdictNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if note.isEmpty || note == authorReason(entry) || note == reviewerPosition(entry) { return nil }
        return note
    }

    /// The author's reason (its last reply's note); nil when it gave none.
    static func authorReason(_ entry: SpecReviewLedgerEntry) -> String? {
        let note = entry.item.reply?.note.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return note.isEmpty ? nil : note
    }

    /// "Round 2": the round the fix was confirmed in.
    static func fixRound(_ entry: SpecReviewLedgerEntry) -> String {
        "Round \(entry.settled > 0 ? entry.settled : entry.item.round)"
    }

    /// The author's note on a fix, or "no note".
    static func fixNote(_ entry: SpecReviewLedgerEntry) -> String {
        authorReason(entry) ?? "no note"
    }

    struct WrapUpItem: Equatable, Identifiable {
        let key: String
        let text: String
        let chapter: String
        var id: String { key }
    }

    struct WrapUpGroup: Equatable, Identifiable {
        let title: String
        let items: [WrapUpItem]
        var id: String { title }
    }

    /// Wrap-up's lists, in order: As agreed, Differs, Missing, Other (an
    /// agreement status this build does not know), Decided alone, Blind
    /// spots, Concerns (checks that raised one). Empty groups are left out.
    static func wrapUpGroups(_ result: SpecReviewResult) -> [WrapUpGroup] {
        func agreements(_ pick: (String) -> Bool) -> [WrapUpItem] {
            result.agreements.filter { pick($0.status) }.map { WrapUpItem(key: $0.key, text: $0.text, chapter: $0.chapter) }
        }
        let known: Set = ["as_agreed", "differs", "missing"]
        let groups = [
            WrapUpGroup(title: "As agreed", items: agreements { $0 == "as_agreed" }),
            WrapUpGroup(title: "Differs", items: agreements { $0 == "differs" }),
            WrapUpGroup(title: "Missing", items: agreements { $0 == "missing" }),
            WrapUpGroup(title: "Other", items: agreements { !known.contains($0) }),
            WrapUpGroup(title: "Decided alone", items: result.decidedAlone.map {
                WrapUpItem(key: $0.key, text: $0.text, chapter: $0.chapter)
            }),
            WrapUpGroup(title: "Blind spots", items: result.blindSpots.map {
                WrapUpItem(key: $0.key, text: $0.text, chapter: $0.chapter)
            }),
            WrapUpGroup(title: "Concerns", items: result.checks.filter { $0.answer == "concern" }.map {
                WrapUpItem(key: $0.key, text: $0.question, chapter: $0.chapter)
            })
        ]
        return groups.filter { !$0.items.isEmpty }
    }
}
