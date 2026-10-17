import SwiftUI
import WatchtowerCore

/// The Changes pane's left column (board #328): what the session works on
/// (the intent card), then the changed files — glyph, path, `+a −d`, Viewed,
/// comment count; folded files (lockfiles, generated, too large) last.
struct ReviewFileListView: View {
    let model: ReviewChangesModel

    var body: some View {
        List {
            overviewSection
            if !model.context.isEmpty {
                Section("Working on") {
                    ForEach(Array(model.context.enumerated()), id: \.offset) { _, item in
                        ReviewIntentCard(item: item)
                    }
                }
            }
            Section("Files") {
                if shown.isEmpty {
                    Text("No changes").foregroundStyle(.secondary)
                }
                ForEach(shown) { file in row(file) }
            }
            if !folded.isEmpty {
                Section("Folded") {
                    ForEach(folded) { file in row(file) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// The collapsed overview and, when the agent or the AI ordered the files, the reading order.
    @ViewBuilder private var overviewSection: some View {
        let ordered = model.chapters.contains { $0.source != .mechanical }
        if model.overview != .idle || ordered {
            Section("Overview") {
                ReviewOverviewView(model: model, style: .compact)
                if ordered {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reading order").font(.caption.weight(.semibold))
                        ForEach(Array(model.chapters.enumerated()), id: \.element.key) { index, chapter in
                            Text("\(index + 1). \(chapter.title)").font(.caption).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
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
            toggleViewed: { try? model.toggleViewed(file.path) } // a failure lands in lastError
        )
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
                    .background(Color.accentColor.opacity(0.2), in: Capsule())
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
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .listRowBackground(selected ? Color.accentColor.opacity(0.15) : Color.clear)
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

/// One task the session works on: its text, intent, and the plan task's
/// text folded to three lines.
private struct ReviewIntentCard: View {
    let item: ReviewContextItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.text).font(.callout.weight(.medium))
            if !item.intent.isEmpty {
                Text(item.intent).font(.caption).foregroundStyle(.secondary)
            }
            if let missing = item.missing {
                Label(missing == "plan" ? "plan file missing" : "task not found", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let plan = item.planText, !plan.isEmpty {
                Text(plan)
                    .font(.caption)
                    .lineLimit(expanded ? nil : 3)
                Button(expanded ? "less" : "more") { expanded.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}
