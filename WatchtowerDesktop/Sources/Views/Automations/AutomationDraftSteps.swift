import SwiftUI
import WatchtowerCore

/// The editor's footer under the draft column, the same on every step: the
/// AI-step line, the hint and the save or confirm buttons of `verdict`. A
/// view over values; the panel decides what a press does.
struct AutomationDraftFooterBar: View {
    let verdict: AutomationDraftFooter
    /// The step shown: **Save Look** on the Look step.
    let step: AutomationEditorStep
    /// A press may land: checked bytes and nothing saving.
    let ready: Bool
    /// These bytes are being checked: the primary reads "Checking…".
    let checking: Bool
    let isSaving: Bool
    /// The shell, #559 and AI-step warnings, shown above the hint.
    let warnings: AutomationDraftFooter.Warnings
    let onPress: (AutomationDraftFooter.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            if let shell = warnings.shell { LLMWarningLabel(text: shell).font(.callout) }
            if let llm = warnings.llm { LLMWarningLabel(text: llm).font(.callout) }
            if let aiStep = warnings.aiStep { AutomationLLMStepWarning(text: aiStep) }
            if !checking {
                Text(verdict.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Spacing.regular) {
                if isSaving { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
                if let secondary = verdict.secondary {
                    Button(secondary.title) { onPress(secondary) }
                        .buttonStyle(.kitSecondary)
                        .disabled(!ready)
                }
                Button(checking ? AutomationDraftColumnModel.checkingLine : verdict.primaryTitle(on: step)) {
                    onPress(verdict.primary)
                }
                .buttonStyle(.kitPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!ready || !verdict.primaryEnabled)
            }
        }
        .controlSize(.small)
    }
}

/// The editor's draft column a step at a time (spec "The Look step"): the
/// step picker, **What it collects** / **Look** / **When it runs**, and the
/// footer, the same under every step.
struct AutomationDraftSteps<Look: View, Footer: View>: View {
    @Binding var step: AutomationEditorStep
    let column: AutomationDraftColumnModel
    @Binding var keepAuto: Set<String>
    let onDryRunAgain: (() -> Void)?
    @ViewBuilder let look: () -> Look
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            KitSegmentedPicker(
                title: "Step",
                selection: $step,
                segments: AutomationEditorStep.allCases.map { KitSegment(value: $0, title: $0.title) }
            )
            .padding(.horizontal, Spacing.large)
            .padding(.top, Spacing.medium)
            switch step {
            case .collects:
                AutomationDraftColumn(model: column, keepAuto: $keepAuto, onDryRunAgain: onDryRunAgain,
                                      section: .collects)
            case .look:
                ScrollView { look().padding(Spacing.large) }
            case .schedule:
                AutomationDraftColumn(model: column, keepAuto: $keepAuto, onDryRunAgain: nil, section: .schedule)
            }
            footer()
        }
    }
}

/// The editor's pinned row above the footer (AUTO-06, ask #486): the
/// hashed fields a save or confirm pressed on `step` confirms that the step
/// does not show (`AutomationDraftColumnModel.confirmationRow(on:)`), every
/// line wrapped, none cut. Nothing when the step shows them all.
struct AutomationSaveConfirmation: View {
    let column: AutomationDraftColumnModel
    let step: AutomationEditorStep

    var body: some View {
        if let row = column.confirmationRow(on: step) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                SectionHeader(title: row.title, systemImage: "arrow.left.arrow.right")
                if let note = row.note {
                    Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(row.items.enumerated()), id: \.offset) { _, item in
                    Text(item.text)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.medium)
            .card()
        }
    }
}
