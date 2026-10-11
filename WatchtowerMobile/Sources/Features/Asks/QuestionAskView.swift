import SwiftUI

/// One question page: the question, its options (a recommended one
/// badged), and Other. A single-select question takes one option, a
/// multi-select one any number.
struct QuestionAskView: View {
    let page: AskFormModel.QuestionPage
    let model: AskViewModel
    let isEditable: Bool

    var body: some View {
        Section {
            ForEach(page.options) { option in
                Button {
                    model.pick(option.label, in: page)
                } label: {
                    OptionLabel(option: option, multi: page.multi)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEditable)
                .accessibilityLabel(option.recommended ? "\(option.label), recommended" : option.label)
                .accessibilityHint(option.description)
                .accessibilityAddTraits(option.isPicked ? .isSelected : [])
            }
            TextField("Other: your own answer", text: otherBinding, axis: .vertical)
                .lineLimit(1...4)
                .frame(minHeight: 44)
                .disabled(!isEditable)
                .accessibilityLabel("Other answer")
        } header: {
            Text(page.question).textCase(nil).font(.headline).foregroundStyle(.primary)
        } footer: {
            Text(page.multi ? "Pick any that apply, or answer in Other." : "Pick one, or answer in Other.")
        }
    }

    private var otherBinding: Binding<String> {
        Binding(get: { model.draft.picks[page.questionID]?.other ?? "" }, set: { model.setOther($0, for: page.questionID) })
    }
}

private struct OptionLabel: View {
    let option: AskFormModel.QuestionPage.Option
    let multi: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(option.isPicked ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(option.label).font(.body.weight(.medium))
                    if option.recommended {
                        Text("RECOMMENDED")
                            .font(.caption2.monospaced())
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 1))
                    }
                }
                if !option.description.isEmpty {
                    Text(option.description).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var symbol: String {
        if multi { return option.isPicked ? "checkmark.square.fill" : "square" }
        return option.isPicked ? "largecircle.fill.circle" : "circle"
    }
}
