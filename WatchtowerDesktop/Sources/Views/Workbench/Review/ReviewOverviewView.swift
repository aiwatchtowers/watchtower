import SwiftUI
import WatchtowerCore

/// The AI overview of the round (board #328, Plan 3): Make overview in Quick
/// mode when none is cached (board #585), a spinner while it is
/// prepared, the reason and Retry when it failed, else the summary, how the
/// intent is covered, the files outside the intent and the size. Deep shows
/// it whole in Meaning; Quick's Summary card (#712) folds it to its first
/// line and risk line, with `extra` (the reading order) inside the fold.
struct ReviewOverviewView<Extra: View>: View {
    enum Style { case full, compact }

    let model: ReviewChangesModel
    var style = Style.full
    @ViewBuilder var extra: () -> Extra
    @State private var expanded = false

    var body: some View {
        switch model.overview {
        case .idle:
            if model.summaryOnlyAfterFailure {
                // A first run whose summary failed: its chapters stay, the summary's Retry and its run (frame 2c).
                ReviewRunCard(model: model, framed: false)
            }
            if style == .compact { extra() }
        case .onRequest:
            makeRow(style == .compact
                ? "AI summary, intent coverage and risk"
                : "An AI summary, intent coverage, risk and reading order — one strong-model call.")
            if style == .compact { extra() }
        case let .outdated(earlier):
            VStack(alignment: .leading, spacing: Spacing.small) {
                makeRow("This overview is for an earlier version of the changes. A new one is one strong-model call.")
                Text(ReviewPresentation.firstLine(earlier.summary)).font(.callout).lineLimit(2).foregroundStyle(.secondary)
                if style == .compact { extra() }
            }
        case .loading:
            if style == .full, !model.describableKeys.isEmpty {
                // The streamed run: how far it is, chapter by chapter (board #1025).
                ReviewRunCard(model: model, framed: false)
            } else {
                HStack(spacing: Spacing.compact) {
                    ProgressView().controlSize(.small)
                    Text("Preparing the AI overview…").font(.callout).foregroundStyle(.secondary)
                }
            }
        case let .failed(reason, detail):
            ReviewFailureNotice(text: "The AI overview failed: \(reason)", detail: detail) { model.retryOverview() }
        case let .ready(overview):
            if case let .failed(text, detail) = model.summaryState {
                // The summary failed, the chapters stay (mockup frame 2c): its own Retry.
                ReviewFailureNotice(text: text, lines: [model.summaryFailedLine, ReviewMapPresentation.summaryRetryNote],
                                    detail: detail) { model.retrySummary() }
            }
            if case .failed = model.summaryState, overview.summary.isEmpty {
                // No summary to show under the notice.
                if style == .compact { extra() }
            } else {
                // A follow-up run (a Retry, Describe N remaining) that failed keeps the summary it had.
                switch style {
                case .full: full(overview)
                case .compact: compact(overview)
                }
            }
        }
    }

    private func makeRow(_ note: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.compact) {
            Text(note).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: Spacing.small)
            Button("Make overview") { model.makeOverview() }.buttonStyle(.kitSecondary).controlSize(.small)
        }
    }

    /// The card's fold: its own chevron inside the card (a `DisclosureGroup`
    /// in a List draws its chevron at the list's edge, outside the card).
    private func compact(_ overview: ReviewOverview) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: IconSize.chevron, weight: .semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(ReviewPresentation.firstLine(overview.summary)).font(.callout.weight(.medium)).lineLimit(2)
                    let risk = ReviewPresentation.riskLine(overview)
                    if !risk.isEmpty { Text(risk).font(.caption).foregroundStyle(Tone.warning) }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(Motion.panel) { expanded.toggle() } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(expanded ? "Folds the overview" : "Shows the whole overview")
            if expanded {
                full(overview)
                extra()
            }
        }
    }

    private func full(_ overview: ReviewOverview) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(overview.summary).font(.callout).textSelection(.enabled)
            if !overview.coverage.isEmpty {
                Text("Does it cover the goal?").font(.caption.weight(.semibold))
                coverage(overview.coverage)
            }
            notCovered
            if !overview.outOfScope.isEmpty {
                Text("Outside the goal").font(.caption.weight(.semibold))
                ForEach(overview.outOfScope, id: \.self) { path in
                    fileLink(path, path: path)
                }
            }
            Text(ReviewPresentation.sizeLine(changedLines: model.progress.totalLines, minutes: model.estimateMinutes))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The session's own items, then the lanes' tickets (tech spec §3.1); an
    /// overview without sources lists them as one group.
    @ViewBuilder private func coverage(_ entries: [ReviewOverview.Coverage]) -> some View {
        let session = entries.filter { $0.source != .lane }
        let lanes = entries.filter { $0.source == .lane }
        if lanes.isEmpty {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in coverageRow(entry) }
        } else {
            if !session.isEmpty {
                Text("This session's ticket").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(session.enumerated()), id: \.offset) { _, entry in coverageRow(entry) }
            }
            Text("Lane tickets").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(lanes.enumerated()), id: \.offset) { _, entry in coverageRow(entry) }
        }
    }

    /// The chapters that failed or the run did not reach (business spec item 4):
    /// the summary saw only their titles, files and signals.
    @ViewBuilder private var notCovered: some View {
        if case .ready(let map) = model.map {
            let missing = map.chapters.filter { chapter in
                !chapter.isCollapsed && model.notDescribed(chapter.key)
            }
            if !missing.isEmpty {
                Text("Not covered").font(.caption.weight(.semibold))
                ForEach(missing) { chapter in notCoveredRow(chapter) }
            }
        }
    }

    private func notCoveredRow(_ chapter: ReviewMap.Chapter) -> some View {
        let hint = ReviewMapPresentation.chapterHint(chapter)
        let files = "\(chapter.paths.count) \(chapter.paths.count == 1 ? "file" : "files")"
        let line = ([chapter.title, files] + (hint.isEmpty ? [] : [hint]) + ["not described"]).joined(separator: " · ")
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            Text("–").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(line).font(.callout)
            Spacer(minLength: Spacing.small)
            // A chapter with none of its files in this view (a later round's Since) has nothing to open.
            if model.chapters.contains(where: { $0.key == chapter.key }) {
                Button("Open chapter") { openChapter(chapter.key) }
                    .buttonStyle(.kitQuiet)
                    .font(.caption)
            }
        }
    }

    /// Deep's Meaning has no diff: the chapter opens in Chapters.
    private func openChapter(_ key: String) {
        Task {
            // A failure lands in lastError; the first one stops here so the next call does not clear it.
            do {
                if model.mode == .deep, model.phase != .chapters { try await model.setPhase(.chapters) }
                try await model.selectChapter(key)
            } catch {}
        }
    }

    private func coverageRow(_ entry: ReviewOverview.Coverage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            Image(systemName: Self.icon(entry.status))
                .foregroundStyle(Self.color(entry.status))
                .accessibilityLabel(Self.label(entry.status))
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(entry.item).font(.callout)
                ForEach(entry.where, id: \.self) { place in
                    fileLink(place, path: ReviewPresentation.coveragePath(place, files: model.files))
                }
            }
        }
    }

    /// A place that names a file of the diff selects it; any other stays text.
    @ViewBuilder private func fileLink(_ text: String, path: String?) -> some View {
        if let path, model.files.contains(where: { $0.path == path }) {
            Button(text) { open(path) }
                .buttonStyle(.link)
                .font(.caption.monospaced())
        } else {
            Text(text).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    /// Deep's Meaning has no diff: the file opens in Chapters.
    private func open(_ path: String) {
        if style == .full, model.mode == .deep, model.phase == .meaning { Task { try? await model.setPhase(.chapters) } }
        Task { await model.select(path) }
    }

    static func icon(_ status: ReviewOverview.Coverage.Status) -> String {
        switch status {
        case .done: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .notFound: "xmark.circle"
        }
    }

    static func color(_ status: ReviewOverview.Coverage.Status) -> Color {
        switch status {
        case .done: .green
        case .partial: .orange
        case .notFound: .red
        }
    }

    static func label(_ status: ReviewOverview.Coverage.Status) -> String {
        switch status {
        case .done: "Done"
        case .partial: "Partly"
        case .notFound: "Not found"
        }
    }
}

extension ReviewOverviewView where Extra == EmptyView {
    init(model: ReviewChangesModel, style: Style = .full) {
        self.init(model: model, style: style) { EmptyView() }
    }
}

/// The agent's notes as a walkthrough (Deep, Meaning): `file:lines`, the
/// note, and "no longer in the file" for one that lost its place.
struct ReviewNotesWalkthrough: View {
    let model: ReviewChangesModel

    var body: some View {
        let rows = ReviewPresentation.walkthrough(
            model.notes, files: model.files, selectedPath: model.selectedPath, placements: model.notePlacements
        )
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("The agent's walkthrough").font(.headline)
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.place).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(row.text).font(.callout).textSelection(.enabled)
                        if !row.placed {
                            Text("no longer in the file").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}
