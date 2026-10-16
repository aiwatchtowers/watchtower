import SwiftUI
import WatchtowerCore

/// The workbench's `trigger.button` automations in its header (spec §12.4):
/// up to four buttons, the rest in "More". What a click does is
/// `WorkbenchAutomationButtonsModel`'s; a runnable click only queues a run
/// (AUTO-09). Hidden while the `automations` feature is off.
struct WorkbenchAutomationButtons: View {
    let project: Workbench
    @Environment(AppState.self) private var appState
    /// The `confirm: true` button whose "Run <label>?" is up.
    @State private var confirming: AutomationHeaderButton?
    /// A failed run call: its label and the CLI's stderr.
    @State private var failure: (label: String, message: String)?

    var body: some View {
        if let vm = appState.automationsViewModel {
            let shown = WorkbenchAutomationButtonsModel.shown(
                vm.headerButtons(projectID: project.id), featureEnabled: appState.isAutomationsFeatureEnabled
            )
            let layout = WorkbenchAutomationButtonsModel.layout(shown)
            HStack(spacing: 4) {
                ForEach(layout.visible) { button in
                    headerButton(button, vm: vm)
                }
                if !layout.overflow.isEmpty {
                    overflowMenu(layout.overflow, vm: vm)
                }
            }
            // The poll is slow off the Automations tab: opening a workbench
            // reads now, so a new recipe or a finished run shows at once.
            .onAppear { vm.refresh() }
            .alert(
                WorkbenchAutomationButtonsModel.confirmTitle(label: confirming?.label ?? ""),
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                presenting: confirming
            ) { button in
                Button("Run") { click(.run, on: button, vm: vm) }
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "Could not run \(failure?.label ?? "the automation")",
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { dismissFailure(vm) } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure?.message ?? "")
            }
        }
    }

    private func headerButton(_ button: AutomationHeaderButton, vm: AutomationsViewModel) -> some View {
        let busy = vm.busy[button.automationID] != nil
        return Button {
            click(WorkbenchAutomationButtonsModel.action(for: button), on: button, vm: vm)
        } label: {
            HStack(spacing: 4) {
                if WorkbenchAutomationButtonsModel.isSpinning(button, busy: busy) {
                    ProgressView().controlSize(.mini)
                }
                Text(button.label)
                    .lineLimit(1)
            }
            .foregroundStyle(WorkbenchAutomationButtonsModel.isDimmed(button) ? .secondary : .primary)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .opacity(WorkbenchAutomationButtonsModel.isDimmed(button) ? 0.6 : 1)
        // The run call in flight: a second click would only be refused.
        .disabled(busy)
        .help(WorkbenchAutomationButtonsModel.help(for: button) ?? "Run \(button.label)")
    }

    private func overflowMenu(_ buttons: [AutomationHeaderButton], vm: AutomationsViewModel) -> some View {
        Menu("More") {
            ForEach(buttons) { button in
                Button {
                    click(WorkbenchAutomationButtonsModel.action(for: button), on: button, vm: vm)
                } label: {
                    let help = WorkbenchAutomationButtonsModel.help(for: button)
                    Text(help.map { "\(button.label) — \($0)" } ?? button.label)
                }
                .disabled(vm.busy[button.automationID] != nil)
            }
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help("More automations of this workbench")
    }

    /// The alert showed `vm.lastError`; dismissing it clears it, so the
    /// Automations tab does not show the same failure again.
    private func dismissFailure(_ vm: AutomationsViewModel) {
        failure = nil
        vm.lastError = nil
    }

    private func click(
        _ action: WorkbenchAutomationButtonsModel.Action,
        on button: AutomationHeaderButton,
        vm: AutomationsViewModel
    ) {
        if case .confirmThenRun = action {
            confirming = button
            return
        }
        Task {
            let ok = await WorkbenchAutomationButtonsModel.perform(action, on: button, vm: vm) { id, runID in
                appState.openAutomationRun(automationID: id, runID: runID)
            }
            if !ok { failure = (button.label, vm.lastError ?? "The automation did not start.") }
        }
    }
}
