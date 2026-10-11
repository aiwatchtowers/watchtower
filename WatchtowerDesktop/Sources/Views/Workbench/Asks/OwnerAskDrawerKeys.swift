import SwiftUI
import WatchtowerCore

/// Return on a stop of the drawer's keyboard cursor (board #412): the
/// keyboard goes into that stop's field — a question's Other…, a broken
/// step's What happened?, the note. Each press is a new request.
struct OwnerAskFieldFocus: Equatable {
    let stop: OwnerAskKeyStop
    let id = UUID()

    /// The request for the field of `stop`; nil for another stop's.
    static func request(_ focus: Self?, for stop: OwnerAskKeyStop) -> UUID? {
        focus?.stop == stop ? focus?.id : nil
    }
}

/// N / P on a review (board #412): the margin comment after or before the
/// active one. Each press is a new request.
struct OwnerAskCommentStep: Equatable {
    let forward: Bool
    let id = UUID()
}

/// The drawer's bare keys (board #412, `OwnerAskKeyMap`), pressed while
/// no field has the keyboard (`OwnerAskKeyCatcher`): J / K switch asks as
/// "k of N" does, Tab / ⇧Tab move the cursor over the questions, a
/// check's steps and the note, a digit picks an option or marks a step at
/// the cursor (the first stop without one), Return writes in its field,
/// N / P walk a review's comments. Every change goes through the draft as
/// a click would (`editDraft`, refused while an answer is written).
@MainActor
struct OwnerAskDrawerKeys {
    let vm: WorkbenchesViewModel
    let ask: OwnerAsk
    let editable: Bool
    let cursor: Binding<Int?>
    let fieldFocus: Binding<OwnerAskFieldFocus?>
    let commentStep: Binding<OwnerAskCommentStep?>

    private var asks: OwnerAsksViewModel { vm.asks }
    private var stops: [OwnerAskKeyStop] { OwnerAskKeyStop.stops(for: ask, editable: editable) }

    /// The stop under the cursor; the first stop while there is none.
    private var current: (index: Int, stop: OwnerAskKeyStop)? {
        let stops = stops
        if let index = cursor.wrappedValue, index < stops.count { return (index, stops[index]) }
        return stops.first.map { (0, $0) }
    }

    /// The stop the cursor shows; nil until a key moved it.
    var shownStop: OwnerAskKeyStop? {
        guard let index = cursor.wrappedValue, index < stops.count else { return nil }
        return stops[index]
    }

    /// True when the key acted; false leaves it to the window.
    func press(_ press: OwnerAskKeyMap.Press) -> Bool {
        let place = OwnerAskKeyMap.Place.drawer(choices: current?.stop.choices(in: ask) ?? 0, isReview: ask.kind == .review)
        guard let action = OwnerAskKeyMap.action(for: press, at: place) else { return false }
        switch action {
        case .nextAsk, .previousAsk: return switchAsk(forward: action == .nextAsk)
        case .nextStop, .previousStop: return moveCursor(forward: action == .nextStop)
        case let .choose(option): return choose(option)
        case .edit: return edit()
        case .nextComment, .previousComment: return stepComment(forward: action == .nextComment)
        case .openStack, .open: return false
        }
    }

    private func switchAsk(forward: Bool) -> Bool {
        let stack = asks.stack(projectID: ask.projectID)
        guard let other = forward ? stack.next(after: ask.id) : stack.previous(before: ask.id) else { return false }
        Task { await vm.showAsk(other.id, projectID: ask.projectID) }
        return true
    }

    private func moveCursor(forward: Bool) -> Bool {
        guard let moved = OwnerAskKeyStop.moved(from: cursor.wrappedValue, forward: forward, count: stops.count) else { return false }
        cursor.wrappedValue = moved
        return true
    }

    private func choose(_ option: Int) -> Bool {
        guard let (index, stop) = current else { return false }
        cursor.wrappedValue = index
        switch stop {
        case let .question(id): return pick(option, questionID: id)
        case let .step(id): return mark(option, stepID: id)
        case .note: return false
        }
    }

    private func pick(_ option: Int, questionID: String) -> Bool {
        guard let question = ask.payload.questions.first(where: { $0.id == questionID }),
              option < question.options.count else { return false }
        let label = question.options[option].label
        return asks.editDraft(ask.id) { draft in
            draft.picks[questionID] = (draft.picks[questionID] ?? .init()).toggling(label, multi: question.multi)
        }
    }

    /// 1 Works, 2 Doesn't work, 3 Didn't check; the mark already there
    /// clears, as a second click does.
    private func mark(_ option: Int, stepID: String) -> Bool {
        let states = OwnerAskPresentation.checkStates
        guard option < states.count else { return false }
        let state = states[option].state
        return asks.editDraft(ask.id) { draft in
            draft.checks[stepID] = draft.checks[stepID] == state ? nil : state
        }
    }

    /// A step has a field only while it is marked Doesn't work.
    private func edit() -> Bool {
        guard let (index, stop) = current else { return false }
        if case let .step(id) = stop, asks.drafts.askDraft(for: ask.id).checks[id] != .broken { return false }
        cursor.wrappedValue = index
        fieldFocus.wrappedValue = OwnerAskFieldFocus(stop: stop)
        return true
    }

    private func stepComment(forward: Bool) -> Bool {
        let comments = ask.answer?.comments.count ?? asks.drafts.askDraft(for: ask.id).comments.count
        guard comments > 0 else { return false }
        commentStep.wrappedValue = OwnerAskCommentStep(forward: forward)
        return true
    }
}

extension View {
    /// The drawer's keyboard cursor around a question, a step or the note
    /// (board #412).
    func ownerAskKeyCursor(_ isOn: Bool) -> some View {
        overlay {
            if isOn {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .padding(-4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
