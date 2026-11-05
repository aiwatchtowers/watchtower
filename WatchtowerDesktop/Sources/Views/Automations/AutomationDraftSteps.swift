import SwiftUI
import WatchtowerCore

/// The editor's footer, the same under every step: the AI-step line, the
/// hint and the save or confirm buttons of `verdict`. Under a step a press
/// opens the save review; in the review it saves. A view over values; the
/// panel decides what a press does.
struct AutomationDraftFooterBar: View {
    let verdict: AutomationDraftFooter
    /// The step shown (**Save Look** on the Look step, `stepHint`); nil in
    /// the save review, which shows every hashed field above it.
    let step: AutomationEditorStep?
    /// A press may land: checked bytes and nothing saving.
    let ready: Bool
    /// These bytes are being checked: the primary reads "Checking…".
    let checking: Bool
    let isSaving: Bool
    /// `AutomationDraftFooter.aiStepWarning`; nil hides the line.
    let aiStepWarning: String?
    let onPress: (AutomationDraftFooter.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            if let aiStepWarning { AutomationLLMStepWarning(text: aiStepWarning) }
            if !checking {
                Text(step == nil ? verdict.hint : verdict.stepHint)
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
                Button(checking ? AutomationDraftColumnModel.checkingLine : primaryTitle) {
                    onPress(verdict.primary)
                }
                .buttonStyle(.kitPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!ready || !verdict.primaryEnabled)
            }
        }
        .controlSize(.small)
    }

    private var primaryTitle: String {
        step.map(verdict.primaryTitle(on:)) ?? verdict.primary.title
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

/// The editor's save review (AUTO-06): the whole draft column — every
/// hashed field of the bytes on screen, the warnings and the Keep auto
/// boxes — over the footer that saves or confirms them.
struct AutomationSaveReview<Footer: View>: View {
    static var size: CGSize { CGSize(width: 460, height: 620) }

    let column: AutomationDraftColumnModel
    @Binding var keepAuto: Set<String>
    @ViewBuilder let footer: () -> Footer
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Review and save").font(.headline)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.kitQuiet)
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top], Spacing.large)
            AutomationDraftColumn(model: column, keepAuto: $keepAuto, onDryRunAgain: nil)
            footer()
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}
