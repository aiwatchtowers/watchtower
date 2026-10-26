import SwiftUI
import WatchtowerCore

/// The Clean Up screen's footer (spec §4.5): **Select All That Can Go**
/// (⌘A) and **Clear** (Esc) on the left; the ticks' total and **Clean Up…**
/// — the screen's one prominent action — on the right. While another
/// cleanup of the workbench runs the total reads "Another cleanup is
/// running" and Clean Up… waits; ticking stays possible.
struct CleanupFooter: View {
    let vm: WorkbenchesViewModel
    let projectID: Int64
    let model: CleanupScreenModel
    let state: CleanupScreenState
    @Binding var ticks: Set<String>
    @Binding var confirming: Bool
    /// The Search field has the keyboard: ⌘A and Esc stay the field's.
    var searchFocused = false

    static let anotherRunning = "Another cleanup is running"

    /// ⌘A (Select All That Can Go) and Esc (Clear) — none while the Search
    /// field has the keyboard, so they select and clear its text instead.
    static func shortcuts(searchFocused: Bool) -> (selectAll: KeyboardShortcut?, clear: KeyboardShortcut?) {
        guard !searchFocused else { return (nil, nil) }
        return (KeyboardShortcut("a", modifiers: .command), KeyboardShortcut(.escape, modifiers: []))
    }

    var body: some View {
        let live = model.liveTicks(ticks)
        let free = vm.canRefreshCleanup(projectID: projectID)
        // This screen's own apply (`sweepRuns`, until its run fully ends)
        // is not "another" cleanup.
        let otherRuns = !free && vm.sweepRuns[projectID] == nil
        let keys = Self.shortcuts(searchFocused: searchFocused)
        HStack(spacing: Spacing.regular) {
            Button("Select All That Can Go") {
                ticks = model.selectAll(filters: state.filters, into: ticks)
            }
            .keyboardShortcut(keys.selectAll)
            .buttonStyle(.kitQuiet)
            if !ticks.isEmpty {
                Button("Clear") { ticks = [] }
                    .keyboardShortcut(keys.clear)
                    .buttonStyle(.kitQuiet)
            }
            Spacer(minLength: Spacing.regular)
            total(otherRuns: otherRuns, live: live)
            Button("Clean Up…") { confirming = true }
                .buttonStyle(.kitDestructive)
                .disabled(!free || model.applyKeys(for: live).isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.page)
        .padding(.vertical, Spacing.cozy)
        .overlay(alignment: .top) {
            Rectangle().fill(Stroke.hairlineColor).frame(height: Stroke.hairline)
        }
        .padding(.top, Spacing.regular)
    }

    /// "3 worktrees, 3 branches · ~25 GB": the counts in the primary colour.
    private func total(otherRuns: Bool, live: Set<String>) -> some View {
        HStack(spacing: 0) {
            if otherRuns {
                Text(Self.anotherRunning).foregroundStyle(.secondary)
            } else if let parts = model.totalParts(for: live) {
                Text(parts.counts).fontWeight(.medium).foregroundStyle(.primary)
                if let size = parts.size {
                    Text(" · " + size).foregroundStyle(.secondary)
                }
            } else {
                Text(model.totalText(for: live)).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }
}

/// **Clean Up…**'s one question (spec §5): what goes, and that each item is
/// checked again right before it goes.
struct CleanupConfirmSheet: View {
    let title: String
    let onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss

    static let message = "Each one is checked again right before it goes: anything with unsaved or unpushed work, "
        + "or that changed since the check, is kept."

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(title).font(.headline)
            Text(Self.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.kitSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Remove") {
                    onRemove()
                    dismiss()
                }
                .buttonStyle(.kitDestructive)
            }
            .padding(.top, Spacing.compact)
        }
        .padding(Spacing.page)
        .frame(width: 420)
    }
}
