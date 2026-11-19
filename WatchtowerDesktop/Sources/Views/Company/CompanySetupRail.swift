import SwiftUI
import WatchtowerCore

/// The wizard's step rail (company screens spec §2.2): Services, one row per
/// ticked service, Link deny list, Publish — each with its mark and word; the
/// current step is the selected row, a reached step is clickable, and
/// **Change services** sits under it from the second step on.
struct CompanySetupRail: View {
    let model: CompanySetupWizardModel

    var body: some View {
        let marks = model.marks()
        VStack(alignment: .leading, spacing: Spacing.tight) {
            ForEach(model.steps, id: \.self) { step in
                row(step, mark: marks[step] ?? .notStarted)
            }
            if model.current != .services, !model.isPublished, model.publishState != .running {
                Button(CompanySetupWizardModel.changeServices) { model.goTo(.services) }
                    .buttonStyle(.kitQuiet)
                    .padding(.leading, Spacing.regular)
            }
        }
    }

    private func row(_ step: CompanySetupWizardModel.Step, mark: CompanySetupWizardModel.StepMark) -> some View {
        let current = step == model.current
        let reachable = model.reached.contains(step) && !current && !model.isPublished && model.publishState != .running
        return Button { if reachable { model.goTo(step) } } label: {
            HStack(spacing: Spacing.regular) {
                WizardMark(Self.kind(mark))
                Text(CompanySetupWizardModel.railName(step))
                    .font(.callout)
                    .foregroundStyle(current || mark != .notStarted ? .primary : .secondary)
                Spacer(minLength: Spacing.small)
                if let word = CompanySetupWizardModel.railWord(mark) {
                    Text(word).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Spacing.regular)
            .padding(.vertical, Spacing.compact)
            .contentShape(Rectangle())
            .kitRow(isSelected: current)
        }
        .buttonStyle(.plain)
    }

    static func kind(_ mark: CompanySetupWizardModel.StepMark) -> WizardMark.Kind {
        switch mark {
        case .done, .reused: .done
        case .skipped: .skipped
        case .waiting, .notStarted: .waiting
        }
    }
}
