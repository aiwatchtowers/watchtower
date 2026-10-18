import SwiftUI
import WatchtowerCore

/// The AI overview of the round (board #328, Plan 3): Make overview in Quick
/// mode when none is cached (board #585), a spinner while it is
/// prepared, the reason and Retry when it failed, else the summary, how the
/// intent is covered, the files outside the intent and the size. Deep shows
/// it whole in Meaning; Quick folds it into one disclosure line.
struct ReviewOverviewView: View {
    enum Style { case full, compact }

    let model: ReviewChangesModel
    var style = Style.full
    @State private var expanded = false

    var body: some View {
        switch model.overview {
        case .idle:
            EmptyView()
        case .onRequest:
            makeRow("An AI summary, intent coverage, risk and reading order — one strong-model call.")
        case let .outdated(earlier):
            VStack(alignment: .leading, spacing: 4) {
                makeRow("This overview is for an earlier version of the changes. A new one is one strong-model call.")
                Text(ReviewPresentation.firstLine(earlier.summary)).font(.callout).lineLimit(2).foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing the AI overview…").font(.callout).foregroundStyle(.secondary)
            }
        case let .failed(reason):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("The AI overview failed: \(reason)").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Retry") { model.retryOverview() }.controlSize(.small)
            }
        case let .ready(overview):
            switch style {
            case .full: full(overview)
            case .compact: compact(overview)
            }
        }
    }

    private func makeRow(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(note).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("Make overview") { model.makeOverview() }.controlSize(.small)
        }
    }

    private func compact(_ overview: ReviewOverview) -> some View {
        DisclosureGroup(isExpanded: $expanded) {
            full(overview).padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(ReviewPresentation.firstLine(overview.summary)).font(.callout).lineLimit(2)
                let risk = ReviewPresentation.riskLine(overview)
                if !risk.isEmpty { Text(risk).font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    private func full(_ overview: ReviewOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(overview.summary).font(.callout).textSelection(.enabled)
            if !overview.coverage.isEmpty {
                Text("Does it cover the intent?").font(.caption.weight(.semibold))
                ForEach(Array(overview.coverage.enumerated()), id: \.offset) { _, entry in coverageRow(entry) }
            }
            if !overview.outOfScope.isEmpty {
                Text("Outside the intent").font(.caption.weight(.semibold))
                ForEach(overview.outOfScope, id: \.self) { path in
                    fileLink(path, path: path)
                }
            }
            Text(ReviewPresentation.sizeLine(changedLines: model.progress.totalLines, minutes: model.estimateMinutes))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func coverageRow(_ entry: ReviewOverview.Coverage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: Self.icon(entry.status))
                .foregroundStyle(Self.color(entry.status))
                .accessibilityLabel(Self.label(entry.status))
            VStack(alignment: .leading, spacing: 1) {
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
        if style == .full, model.mode == .deep, model.phase == .meaning { try? model.setPhase(.chapters) }
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
