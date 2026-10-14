import SwiftUI
import WatchtowerCore

/// **Clean Up Old Worktrees…** (board #535, spec 2026-10-12-session-cleanup
/// §9/§12): every worktree and branch of the workbench repository with its
/// size, why it is kept and whose it probably is. Nothing is ticked — the
/// owner picks what goes; **Clean Up** applies exactly the ticked keys and
/// shows the result. The plan and the result live in `SessionCleanupCenter`
/// and the apply runs on the view model, so an apply goes on when the sheet
/// closes (its failure then shows on the page); the ticks are this sheet's.
struct WorkbenchSweepSheet: View {
    let vm: WorkbenchesViewModel
    let project: Workbench
    @Environment(\.dismiss) private var dismiss
    @State private var ticked: Set<String> = []

    var body: some View {
        let phase = vm.sweepPhase(projectID: project.id)
        VStack(alignment: .leading, spacing: 12) {
            Text("Clean up old worktrees of “\(project.name)”").font(.headline)
            Text("Worktrees and branches older sessions left. Nothing is selected: tick what goes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SessionCleanupPhaseView(
                phase: phase, ticked: $ticked,
                emptyText: "Nothing to clean up: the repository has no other worktree or branch."
            ) {
                Task { await vm.planSweepForSheet(projectID: project.id) }
            }
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
            footer(phase)
        }
        .padding(20)
        .frame(width: 640)
        .task(id: project.id) { await vm.planSweepForSheet(projectID: project.id) }
        .onAppear { vm.sweepSheetAppeared(projectID: project.id) }
        .onDisappear { vm.sweepSheetDisappeared(projectID: project.id) }
        // A new plan starts with nothing ticked — whatever the JSON's
        // `sweep` flag says: this sheet is a sweep, and a destructive
        // default never keys off a wire field (fail closed).
        .onChange(of: phase, initial: true) { _, now in
            if case .ready = now { ticked = [] }
        }
    }

    @ViewBuilder
    private func footer(_ phase: SessionCleanupPhase) -> some View {
        HStack {
            if case .ready = phase {
                let chosen = vm.sweepCleanupChoice(projectID: project.id, ticked: ticked)
                Text(SessionCleanupPresentation.totalText(chosen) ?? "Nothing selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Clean Up", role: .destructive) {
                    let (vm, id, ticked) = (vm, project.id, ticked)
                    Task { await vm.applySweepCleanup(projectID: id, ticked: ticked) }
                }
                .disabled(chosen.isEmpty)
            } else {
                Spacer()
                Button(phase == .applying ? "Close" : "Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func close() {
        vm.closeSweepSheet(projectID: project.id)
        dismiss()
    }
}
