import SwiftUI
import WatchtowerCore

/// The row above a file's diff (board #712, spec §4.5): status glyph, path
/// (directory quiet, name semibold, truncated in the middle), `+a −d`, the
/// risk badge, Changes | Full file (board #959), Viewed, and ‹ › to the previous / next unviewed file
/// (⌥⌘↑ / ⌥⌘↓) — reading a file and marking it never leaves the diff.
struct ReviewFileHeader: View {
    let model: ReviewChangesModel
    let file: ReviewDiffFile

    /// Narrower than `twoRowsBelow` (the agent chat beside the diff, #962):
    /// the controls go on a second row instead of squeezing the path away.
    @State private var twoRows = false
    private static let twoRowsBelow: CGFloat = 640

    var body: some View {
        Group {
            if twoRows {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    HStack(spacing: Spacing.regular) { info }
                    HStack(spacing: Spacing.regular) {
                        Spacer(minLength: 0)
                        controls
                    }
                }
            } else {
                HStack(spacing: Spacing.regular) {
                    info
                    Spacer(minLength: Spacing.small)
                    controls
                }
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.twoRowsBelow } action: { twoRows = $0 }
    }

    /// Status glyph, path, `+a −d` and the risk badge.
    @ViewBuilder private var info: some View {
        let risk = model.highestRisk(for: file.path)
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
    }

    /// Changes | Full file, Viewed, ‹ ›.
    @ViewBuilder private var controls: some View {
        let previous = model.previousUnviewed(before: file.path)
        let next = model.nextUnviewed(after: file.path)
        KitSegmentedPicker(
            title: "Diff extent",
            selection: Binding(get: { model.fullFile }, set: { model.fullFile = $0 }),
            segments: [
                KitSegment(value: false, title: "Changes", help: "The changes, with unchanged lines folded"),
                KitSegment(value: true, title: "Full file", help: "The whole file")
            ]
        )
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
