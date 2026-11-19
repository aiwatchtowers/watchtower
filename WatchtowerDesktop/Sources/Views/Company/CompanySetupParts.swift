import AppKit
import SwiftUI
import WatchtowerCore

// The small pieces the setup wizard's steps are drawn from (company screens
// spec §2): a notice card, a problem line, a step mark, numbered guide lines,
// labelled fields, radio choices, a checklist, value rows with a button.
// Words come from `CompanySetupWizardModel` / `CompanyVendorGuide` only.

/// A tinted icon, an optional bold title and a body, on a card.
struct WizardNotice: View {
    let icon: String
    let tone: Color
    var title: String?
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: icon).foregroundStyle(tone)
            VStack(alignment: .leading, spacing: Spacing.small) {
                if let title { Text(title).font(.headline).fixedSize(horizontal: false, vertical: true) }
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// A warning line under a step's content (a check's refusal, a run's problem).
struct WizardProblem: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// A secondary line that wraps.
struct WizardCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A spinner beside a line (looking, checking).
struct WizardBusy: View {
    let text: String

    var body: some View {
        HStack(spacing: Spacing.regular) {
            ProgressView().controlSize(.small)
            WizardCaption(text)
        }
    }
}

/// A progress or rail mark.
struct WizardMark: View {
    enum Kind { case done, running, waiting, failed, skipped }
    let kind: Kind

    var body: some View {
        Group {
            switch kind {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.success)
            case .running: ProgressView().controlSize(.small)
            case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Tone.status("gray"))
            case .skipped: Image(systemName: "minus.circle").foregroundStyle(.tertiary)
            }
        }
        .frame(width: ListLayout.markColumn)
    }

    init(_ kind: Kind) { self.kind = kind }

    init(_ mark: SlackAppSetupModel.StepMark) {
        switch mark {
        case .done: kind = .done
        case .running: kind = .running
        case .waiting: kind = .waiting
        case .failed: kind = .failed
        }
    }
}

/// Marked lines on a card (a run's progress, the Publish summary).
struct WizardStepLines: View {
    let lines: [(title: String, mark: WizardMark.Kind)]
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    WizardMark(line.mark)
                    Text(line.title)
                        .font(.callout)
                        .foregroundStyle(line.mark == .waiting ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let caption { WizardCaption(caption) }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Numbered guide lines, each with **Open** (its deep link) and an optional
/// Copy button.
struct WizardGuide: View {
    let vendor: CompanyVendor
    @Environment(\.openURL) private var openURL

    var body: some View {
        let lines = CompanyVendorGuide.guideLines(vendor)
        let copies = CompanyVendorGuide.guideCopyButtons(vendor)
        VStack(alignment: .leading, spacing: Spacing.regular) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Text("\(index + 1).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Text(line.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Spacing.regular)
                    if let title = copies[index] {
                        let text = CompanyVendorGuide.guideCopyText(vendor, line: index)
                        Button(title) { WizardPasteboard.copy(text) }
                            .buttonStyle(.kitQuiet)
                            .disabled(text.isEmpty)
                    }
                    if let link = line.link {
                        Button(CompanySetupWizardModel.openTitle) { openURL(link) }.buttonStyle(.kitSecondary)
                    }
                }
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// A labelled text or secure field.
struct WizardField: View {
    let label: String
    let text: Binding<String>
    var secure = false
    var prompt: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if secure {
                SecureField(label, text: text, prompt: prompt.map { Text($0) }).textFieldStyle(.kit)
            } else {
                TextField(label, text: text, prompt: prompt.map { Text($0) }).textFieldStyle(.kit)
            }
        }
    }
}

/// One radio row: a title and a detail; the selected row is filled.
struct WizardChoice: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(title).font(.callout)
                    WizardCaption(detail)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.regular)
            .contentShape(Rectangle())
            .kitRow(isSelected: selected)
        }
        .buttonStyle(.plain)
    }
}

/// One checklist row: a checkbox, a title and detail, an optional quiet button.
struct WizardCheckRow: View {
    let title: String
    var detail: String?
    let checked: Bool
    let toggle: () -> Void
    var trailing: (title: String, action: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(title).font(.callout)
                        if let detail { WizardCaption(detail) }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: Spacing.regular)
            if let trailing { Button(trailing.title, action: trailing.action).buttonStyle(.kitQuiet) }
        }
    }
}

/// A label, a one-line monospaced value and its button (Copy, Save…, Remove).
struct WizardValueRow: View {
    let label: String
    let value: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if !label.isEmpty { Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            HStack(spacing: Spacing.regular) {
                Text(value).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: Spacing.regular)
                Button(button, action: action).buttonStyle(.kitSecondary)
            }
        }
    }
}

enum WizardPasteboard {
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
