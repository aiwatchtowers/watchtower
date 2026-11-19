import DesignKit
import SwiftUI
import WatchtowerCore

private typealias Model = OwnGoogleProjectModel

/// **Use my own Google project** (#1887 C4, company screens spec §5.2): a
/// page in the Google detail with **‹ Google** as the way back — the guide
/// to a Google Cloud project of the person's own, the client JSON's drop
/// zone, and Connect. Every word is `OwnGoogleProjectModel`'s.
struct OwnGoogleProjectPage: View {
    let model: OwnGoogleProjectModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                Button { model.close() } label: { Label(Model.backTitle, systemImage: "chevron.left") }
                    .buttonStyle(.kitQuiet)
                if let done = model.doneLines {
                    Text(Model.title).font(.title3.weight(.semibold))
                    WizardNotice(icon: "checkmark.circle.fill", tone: Tone.success, title: done.title, text: done.body)
                    if let missing = model.notGrantedNote { WizardProblem(text: missing) }
                    if let weekly = model.weeklyNote { WizardCaption(weekly) }
                } else {
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        Text(Model.title).font(.title3.weight(.semibold))
                        WizardCaption(Model.intro)
                    }
                    WizardGuide(lines: Model.guide)
                    WizardDropZone(line: model.droppedLine, problem: model.fileProblem, disabled: model.isRunning) { data, name in
                        model.drop(data, fileName: name)
                    }
                    switch model.status {
                    case .note(let text): WizardCaption(text)
                    case .busy(let text): WizardBusy(text: text)
                    case .problem(let text): WizardProblem(text: text)
                    }
                }
                HStack {
                    Spacer(minLength: 0)
                    Button(model.primaryTitle, action: primary)
                        .buttonStyle(.kitPrimary)
                        .disabled(!model.primaryEnabled)
                }
            }
            .controlSize(.small)
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .detailBackground()
    }

    private func primary() {
        if model.doneLines != nil {
            model.finish()
        } else {
            Task { await model.connect() }
        }
    }
}
