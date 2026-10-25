import SwiftUI
import WatchtowerCore

/// The spec review screen of a review ask (spec 2026-10-25 §7): the header
/// (title, the reviewer's state, **Read the spec**, **Re-run reviewer**),
/// then Meaning → Chapters → Wrap-up over the reviewer's findings, shaped
/// like Deep review. While the reviewer has no result the body is its
/// status page; **Read the spec** (the classic view) is always one click away.
struct SpecReviewView: View {
    let model: SpecReviewModel
    let onReadSpec: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.regular)
            if let result = SpecReviewPresentation.reviewedResult(model.row) {
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
            if model.row != nil, !model.isReviewerActive {
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

    @ViewBuilder
    private func phaseBody(_ result: SpecReviewResult) -> some View {
        switch model.phase {
        case .meaning: SpecReviewMeaningView(model: model, result: result)
        case .chapters: SpecReviewChaptersView(model: model)
        case .wrapup: SpecReviewWrapUpView(model: model, result: result)
        }
    }
}

/// The way forward at the foot of a step, as in Deep review: Meaning →
/// Chapters, Chapters → Wrap-up.
struct SpecReviewNextStepButton: View {
    let model: SpecReviewModel

    var body: some View {
        if let next = SpecReviewPresentation.nextStep(model.phase) {
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
    /// A badge's colour, named so tests can compare it.
    enum Tint: Equatable {
        case success, warning, error, accent, neutral

        var color: Color {
            switch self {
            case .success: Tone.success
            case .warning: Tone.warning
            case .error: Tone.error
            case .accent: Tone.status("blue")
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
    static func drawerMode(row: SpecReviewRow?, showClassic: Bool, loaded: Bool = true) -> DrawerMode {
        guard loaded else { return .loading }
        guard let row else { return .classic(nil) }
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

    /// "9 as agreed · 1 differs · 1 missing · 4 decided alone · 2 blind
    /// spots"; zero counts are left out.
    static func countsLine(_ result: SpecReviewResult) -> String {
        SpecReviewSummary.countsLine(result)
    }

    static func agreementBadge(status: String) -> Badge {
        switch status {
        case "as_agreed": Badge(title: "As agreed", tint: .success)
        case "differs": Badge(title: "Differs", tint: .warning)
        case "missing": Badge(title: "Missing", tint: .error)
        default: Badge(title: status.isEmpty ? "Agreement" : status, tint: .neutral)
        }
    }

    static func badge(for finding: SpecReviewChapterFinding) -> Badge {
        switch finding {
        case let .agreement(f): agreementBadge(status: f.status)
        case .decidedAlone: Badge(title: "Decided alone", tint: .accent)
        case .blindSpot: Badge(title: "Blind spot", tint: .error)
        }
    }

    static func checkBadge(answer: String) -> Badge {
        switch answer {
        case "ok": Badge(title: "OK", tint: .success)
        case "concern": Badge(title: "Concern", tint: .warning)
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

    /// A chapter row's badges: one per kind other than As agreed, with its count.
    static func chapterBadges(_ chapter: SpecReviewChapterVM) -> [(badge: Badge, count: Int)] {
        var order: [Badge] = []
        var counts: [Badge: Int] = [:]
        for finding in chapter.findings {
            let badge = badge(for: finding)
            if badge.tint == .success { continue }
            if counts[badge] == nil { order.append(badge) }
            counts[badge, default: 0] += 1
        }
        let concerns = chapter.checks.filter { $0.answer == "concern" }.count
        if concerns > 0 {
            let badge = checkBadge(answer: "concern")
            order.append(badge)
            counts[badge] = concerns
        }
        return order.map { ($0, counts[$0] ?? 0) }
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

    static func nextStep(_ phase: ReviewPhase) -> (phase: ReviewPhase, title: String)? {
        switch phase {
        case .meaning: (.chapters, "Next: Chapters →")
        case .chapters: (.wrapup, "Next: Wrap-up →")
        case .wrapup: nil
        }
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
