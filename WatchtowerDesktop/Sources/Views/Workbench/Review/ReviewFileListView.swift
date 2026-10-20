import SwiftUI
import WatchtowerCore

/// The Branch review's file column (board #328, #712 spec §4.4): the
/// Summary card (the AI overview folded, with the reading order inside),
/// then the changed files — glyph, path, `+a −d`, Viewed, comment count —
/// and the folded ones (lockfiles, generated, too large) last.
struct ReviewFileListView: View {
    let model: ReviewChangesModel

    var body: some View {
        List {
            if model.hasChanges, showsSummary {
                summaryCard.reviewListRow()
            }
            header("Files", systemImage: "doc.on.doc", detail: filesDetail)
            if shown.isEmpty {
                Text(ReviewChangesPaneView.nothingNewText(model) ?? "No changes")
                    .foregroundStyle(.secondary)
                    .reviewListRow()
            }
            ForEach(shown) { file in row(file) }
            if !folded.isEmpty {
                header("Folded", systemImage: "rectangle.compress.vertical", detail: "\(folded.count)")
                ForEach(folded) { file in row(file) }
            }
        }
        .panelListStyle()
        .panelSurface()
    }

    /// `8 · 3 viewed`.
    private var filesDetail: String {
        "\(shown.count) · \(shown.filter { model.isViewed($0.path) }.count) viewed"
    }

    private func header(_ title: String, systemImage: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            SectionHeader(title: title, systemImage: systemImage)
            Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.top, Spacing.regular)
        .padding(.horizontal, Spacing.regular)
        .reviewListRow()
    }

    /// The agent or the AI ordered the files: the reading order is worth showing.
    private var ordered: Bool { model.chapters.contains { $0.source != .mechanical } }
    private var showsSummary: Bool { model.overview != .idle || ordered }

    /// The overview folded into one card; the reading order sits inside it.
    private var summaryCard: some View {
        ReviewOverviewView(model: model, style: .compact) {
            if ordered { readingOrder }
        }
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .padding(.bottom, Spacing.small)
    }

    private var readingOrder: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("Reading order").font(.caption.weight(.semibold))
            ForEach(Array(model.chapters.enumerated()), id: \.element.key) { index, chapter in
                Text("\(index + 1). \(chapter.title)").font(.caption).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var shown: [ReviewDiffFile] { model.files.filter { $0.collapsedReason == nil } }
    private var folded: [ReviewDiffFile] { model.files.filter { $0.collapsedReason != nil } }

    private func row(_ file: ReviewDiffFile) -> some View { Self.row(file, model: model) }

    /// A file's row with the model's Viewed mark and comment count (Chapters reuses it).
    static func row(_ file: ReviewDiffFile, model: ReviewChangesModel) -> some View {
        ReviewFileRow(
            file: file,
            selected: model.selectedPath == file.path,
            viewed: model.isViewed(file.path),
            comments: model.comments.filter { $0.path == file.path && $0.status != .resolved }.count,
            risk: model.risk(for: file.path),
            select: { Task { await model.select(file.path) } },
            toggleViewed: { Task { try? await model.toggleViewed(file.path) } } // a failure lands in lastError
        )
    }
}

private extension View {
    /// A row of the review's plain lists: no separator, no stock background,
    /// the content's own insets.
    func reviewListRow() -> some View {
        listRowInsets(EdgeInsets(top: Spacing.tight, leading: Spacing.regular, bottom: Spacing.tight, trailing: Spacing.regular))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

struct ReviewFileRow: View {
    let file: ReviewDiffFile
    let selected: Bool
    let viewed: Bool
    let comments: Int
    var risk: ReviewOverview.Risk?
    let select: () -> Void
    let toggleViewed: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(Self.glyph(file.status))
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(Self.color(file.status))
                .frame(width: 14)
                .help(file.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                if let reason = file.collapsedReason {
                    Text(Self.foldReason(reason)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            ReviewRiskBadge(level: risk?.level, why: risk?.why ?? "")
            if comments > 0 {
                Text("\(comments)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .background(Fill.on, in: Capsule())
                    .accessibilityLabel("\(comments) comment\(comments == 1 ? "" : "s")")
            }
            Text("+\(file.additions) −\(file.deletions)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Toggle("Viewed", isOn: Binding(get: { viewed }, set: { _ in toggleViewed() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(viewed ? "Viewed" : "Mark as viewed")
        }
        .opacity(viewed ? 0.6 : 1)
        .kitRow(isSelected: selected)
        .onTapGesture(perform: select)
        .reviewListRow()
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    static func glyph(_ status: String) -> String {
        switch status {
        case "added": "A"
        case "deleted": "D"
        case "renamed": "R"
        default: "M"
        }
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "added": .green
        case "deleted": .red
        case "renamed": .blue
        default: .orange
        }
    }

    static func foldReason(_ reason: String) -> String {
        switch reason {
        case "lockfile": "Lockfile"
        case "generated": "Generated"
        case "too_large": "Too large"
        default: reason
        }
    }
}
