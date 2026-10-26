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
    let phase: SessionCleanupPhase
    @Binding var ticks: Set<String>
    @Binding var confirming: Bool

    static let anotherRunning = "Another cleanup is running"

    var body: some View {
        let live = model.liveTicks(ticks)
        let free = vm.canRefreshCleanup(projectID: projectID)
        // This screen's own apply is not "another" cleanup.
        let otherRuns = !free && phase != .applying
        HStack(spacing: Spacing.regular) {
            Button("Select All That Can Go") {
                ticks = model.selectAll(filters: state.filters, into: ticks)
            }
            .keyboardShortcut("a", modifiers: .command)
            .buttonStyle(.kitQuiet)
            if !ticks.isEmpty {
                Button("Clear") { ticks = [] }
                    .keyboardShortcut(.escape, modifiers: [])
                    .buttonStyle(.kitQuiet)
            }
            Spacer(minLength: Spacing.regular)
            total(otherRuns ? Self.anotherRunning : model.totalText(for: live))
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
    private func total(_ text: String) -> some View {
        let parts = text.components(separatedBy: " · ")
        let counts = text == "Nothing selected" || text == Self.anotherRunning ? nil : parts.first
        return HStack(spacing: 0) {
            if let counts {
                Text(counts).fontWeight(.medium).foregroundStyle(.primary)
                if parts.count > 1 {
                    Text(" · " + parts.dropFirst().joined(separator: " · ")).foregroundStyle(.secondary)
                }
            } else {
                Text(text).foregroundStyle(.secondary)
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
