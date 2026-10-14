import SwiftUI

/// The link's three steps while the phone checks a code and waits for the
/// Mac (design pass O2): "Code read", "Waiting for <Mac> to confirm",
/// "Linked". Checking makes step 1 current; waiting makes it done and step
/// 2 current, and shows the four-digit code to compare with the Mac's
/// (mobile E2E spec §2.3); once the Mac read the phone's hello, step 2 says
/// "Your Mac sees this iPhone". After 20 s of waiting, a hint says to keep
/// the Mac's Settings open.
struct LinkStepsModel: Equatable {
    struct Step: Equatable {
        let state: StepRow.State
        let text: String
    }

    static let hintDelay: TimeInterval = 20
    static let hintText = "Keep Settings → Mobile open on the Mac."

    static let macSeesPhoneText = "Your Mac sees this iPhone"

    /// "Check that your Mac shows **7342**, then click Link on the Mac.",
    /// the code in bold (Markdown).
    static func codeInstruction(_ code: String) -> String {
        "Check that your Mac shows **\(code)**, then click Link on the Mac."
    }

    let steps: [Step]
    let hint: String?
    /// While waiting: the code to compare, as `codeInstruction`.
    let codeInstruction: String?

    /// `macName` nil: checking the code. A name: waiting for that Mac's
    /// keybox since `startedAt`.
    init(waitingFor macName: String?, code: String? = nil, macSeesPhone: Bool = false, startedAt: Date?, now: Date) {
        self.init(
            waitingFor: macName, code: code, macSeesPhone: macSeesPhone,
            waited: startedAt.map { now.timeIntervalSince($0) }
        )
    }

    /// `waited`: seconds in the phase on a monotonic source; nil is zero.
    init(waitingFor macName: String?, code: String? = nil, macSeesPhone: Bool = false, waited: TimeInterval?) {
        guard let macName else {
            steps = [
                Step(state: .current, text: "Code read"),
                Step(state: .todo, text: "Waiting for your Mac to confirm"),
                Step(state: .todo, text: "Linked")
            ]
            hint = nil
            codeInstruction = nil
            return
        }
        let name = macName.isEmpty ? "your Mac" : macName
        steps = [
            Step(state: .done, text: "Code read"),
            Step(state: .current, text: macSeesPhone ? Self.macSeesPhoneText : "Waiting for \(name) to confirm"),
            Step(state: .todo, text: "Linked")
        ]
        hint = (waited ?? 0) >= Self.hintDelay ? Self.hintText : nil
        codeInstruction = code.map(Self.codeInstruction)
    }
}

/// The steps as `StepRow`s, with the hint under them.
struct LinkStepsView: View {
    let model: LinkStepsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            if let instruction = model.codeInstruction {
                Text(LocalizedStringKey(instruction))
                    .font(.title3)
                    .padding(.bottom, Spacing.regular)
            }
            ForEach(Array(model.steps.enumerated()), id: \.offset) { _, step in
                StepRow(state: step.state, text: step.text)
            }
            if let hint = model.hint {
                // Under the step text: the 22 pt icon column plus its 12 pt gap.
                Text(hint)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 34)
            }
        }
        .padding(.horizontal, Spacing.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.hint) { _, hint in
            if let hint { AccessibilityNotification.Announcement(hint).post() }
        }
    }
}
