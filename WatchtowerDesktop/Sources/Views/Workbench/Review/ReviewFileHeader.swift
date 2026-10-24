import SwiftUI
import WatchtowerCore

/// The row above a file's diff (board #712, spec §4.5): status glyph, path
/// (directory quiet, name semibold, truncated in the middle), `+a −d`, the
/// risk badge, Viewed, and ‹ › to the previous / next unviewed file
/// (⌥⌘↑ / ⌥⌘↓) — reading a file and marking it never leaves the diff.
struct ReviewFileHeader: View {
    let model: ReviewChangesModel
    let file: ReviewDiffFile

    var body: some View {
        let previous = model.previousUnviewed(before: file.path)
        let next = model.nextUnviewed(after: file.path)
        let risk = model.highestRisk(for: file.path)
        HStack(spacing: Spacing.regular) {
            Text(ReviewFileRow.glyph(file.status))
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(ReviewFileRow.color(file.status))
                .help(file.status)
            path
            Text("+\(file.additions)").foregroundStyle(Tone.success)
                .font(.caption.monospacedDigit())
            Text("−\(file.deletions)").foregroundStyle(Tone.error)
                .font(.caption.monospacedDigit())
            ReviewRiskBadge(level: risk?.level, why: risk?.why ?? "")
            Spacer(minLength: Spacing.small)
            // A failure lands in lastError.
            Toggle("Viewed", isOn: Binding(
                get: { model.isViewed(file.path) },
                set: { _ in Task { try? await model.toggleViewed(file.path) } }
            ))
            .toggleStyle(.checkbox)
            Button { select(previous) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.kitIcon(isOn: false))
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                .disabled(previous == nil)
                .help("Previous unviewed file (⌥⌘↑)")
                .accessibilityLabel("Previous unviewed file")
            Button { select(next) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.kitIcon(isOn: false))
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                .disabled(next == nil)
                .help("Next unviewed file (⌥⌘↓)")
                .accessibilityLabel("Next unviewed file")
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
    }

    /// `Sources/Recording/` quiet, then `RecordCapsule.swift` semibold, as one
    /// line that truncates in the middle.
    private var path: some View {
        let directory = (file.path as NSString).deletingLastPathComponent
        let name = (file.path as NSString).lastPathComponent
        let dirText = directory.isEmpty ? "" : directory + "/"
        return Text("\(Text(dirText).foregroundStyle(.secondary))\(Text(name).fontWeight(.semibold))")
            .font(.callout.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }

    private func select(_ path: String?) {
        guard let path else { return }
        Task { await model.select(path) }
    }
}
