import SwiftUI
import WatchtowerCore

/// The edit form's Save sheet (spec §3.3, §6.4): what the change lets the
/// automation also do, the auto grants it pauses with unchecked "Keep auto
/// for …" boxes (AUTO-03), and **Save and confirm**. Shown only when the
/// plan needs it (`AutomationSavePlan.needsSheet`).
struct AutomationSaveSheet: View {
    let name: String
    let onCancel: () -> Void
    let onSave: (AutomationSavePlan) -> Void

    /// The owner's checks live here until **Save and confirm**.
    @State private var plan: AutomationSavePlan

    init(
        plan: AutomationSavePlan,
        name: String,
        onCancel: @escaping () -> Void,
        onSave: @escaping (AutomationSavePlan) -> Void
    ) {
        _plan = State(initialValue: plan)
        self.name = name
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save and confirm “\(name)”?")
                .font(.title3.weight(.semibold))
            Text(plan.wasConfirmed
                ? "Saving confirms the new version: it runs as saved."
                : "It has not been confirmed yet: saving confirms it, and it can run as saved.")
                .foregroundStyle(.secondary)

            if plan.validated.widening.isEmpty {
                Text("No change to what it can access.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This change lets the automation also:")
                        .font(.headline)
                    ForEach(plan.validated.widening, id: \.self) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(AutomationCardPresentation.permissionLine(entry))
                            Text(entry)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !plan.pausedGrants.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Auto paused by this change")
                        .font(.headline)
                    Text("These tools ran without asking. After this change they ask first, unless you keep auto.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(plan.pausedGrants, id: \.self) { tool in
                        Toggle("Keep auto for \(tool)", isOn: keepBinding(tool))
                            .toggleStyle(.checkbox)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save and confirm") { onSave(plan) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func keepBinding(_ tool: String) -> Binding<Bool> {
        Binding(
            get: { plan.keepAuto.contains(tool) },
            set: { on in
                if on { plan.keepAuto.insert(tool) } else { plan.keepAuto.remove(tool) }
            }
        )
    }
}
