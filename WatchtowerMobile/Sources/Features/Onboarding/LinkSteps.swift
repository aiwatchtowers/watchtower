import SwiftUI

/// The link's three steps while the phone checks a code and waits for the
/// Mac (design pass O2): "Code read", "Waiting for <Mac> to confirm",
/// "Linked". Checking makes step 1 current; waiting makes it done and step
/// 2 current. After 20 s of waiting, a hint says to keep the Mac's Settings
/// open.
struct LinkStepsModel: Equatable {
    struct Step: Equatable {
        let state: StepRow.State
        let text: String
    }

    static let hintDelay: TimeInterval = 20
    static let hintText = "Keep Settings → Mobile open on the Mac."

    let steps: [Step]
    let hint: String?

    /// `macName` nil: checking the code. A name: waiting for that Mac's
    /// grant since `startedAt`.
    init(waitingFor macName: String?, startedAt: Date?, now: Date) {
        self.init(waitingFor: macName, waited: startedAt.map { now.timeIntervalSince($0) })
    }

    /// `waited`: seconds in the phase on a monotonic source; nil is zero.
    init(waitingFor macName: String?, waited: TimeInterval?) {
        guard let macName else {
            steps = [
                Step(state: .current, text: "Code read"),
                Step(state: .todo, text: "Waiting for your Mac to confirm"),
                Step(state: .todo, text: "Linked")
            ]
            hint = nil
            return
        }
        let name = macName.isEmpty ? "your Mac" : macName
        steps = [
            Step(state: .done, text: "Code read"),
            Step(state: .current, text: "Waiting for \(name) to confirm"),
            Step(state: .todo, text: "Linked")
        ]
        hint = (waited ?? 0) >= Self.hintDelay ? Self.hintText : nil
    }
}

/// The steps as `StepRow`s, with the hint under them.
struct LinkStepsView: View {
    let model: LinkStepsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
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
