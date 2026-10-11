import Foundation

/// Owner asks without the mouse (board #412, spec 2026-10-10 Part 9.4):
/// which action a key press means where the keyboard is. Every key here is
/// a bare key (Shift only with Tab), never auto-repeated, and taken only
/// where no field, terminal or editor has the keyboard (`Place.typing`
/// takes nothing: the terminal and Monaco keep their keys). ⌘↩ / ⌘⇧↩ stay
/// `OwnerAskKeyCatcher.answerKey`'s. Pure.
///
/// | Key | Where | Action |
/// |---|---|---|
/// | A | the workbench page | open the stack (`openStack`) |
/// | J / K | the drawer, a stack card | next / previous ask |
/// | ↓ / ↑ | a stack card | next / previous ask |
/// | Tab / ⇧Tab | the drawer | next / previous question, step or the note |
/// | 1–9 | the drawer | pick that option of the question, mark the step (1 Works, 2 Doesn't work, 3 Didn't check) |
/// | 1–3 | a Quick ask's banner or stack card | answer with that option |
/// | Return | the drawer | write in the field of the question, step or note |
/// | Return | a banner or stack card | open the ask in the drawer |
/// | N / P | a review's drawer | next / previous margin comment |
package enum OwnerAskKeyMap {
    /// The most options a digit picks on a Quick ask's banner or card.
    package static let maxQuickDigit = 3

    package struct Press: Equatable, Sendable {
        package enum Key: Equatable, Sendable {
            case character(Character)
            case tab
            case returnKey
            case upArrow
            case downArrow
            case other
        }

        package let key: Key
        package let shift: Bool
        /// ⌘, ⌥ or ⌃ held: never one of these keys.
        package let otherModifiers: Bool
        package let isRepeat: Bool

        package init(key: Key, shift: Bool = false, otherModifiers: Bool = false, isRepeat: Bool = false) {
            self.key = key
            self.shift = shift
            self.otherModifiers = otherModifiers
            self.isRepeat = isRepeat
        }

        /// A press read from the typed characters (ignoring modifiers):
        /// "\t" is Tab (⇧Tab arrives as "\u{19}"), "\r" and the keypad's
        /// Enter are Return; a letter counts whatever its case.
        package init(characters: String, shift: Bool, otherModifiers: Bool, isRepeat: Bool) {
            self.init(key: Self.key(characters), shift: shift, otherModifiers: otherModifiers, isRepeat: isRepeat)
        }

        private static func key(_ characters: String) -> Key {
            guard characters.count == 1, let character = characters.first else { return .other }
            switch character {
            case "\t", "\u{19}": return .tab
            case "\r", "\u{3}": return .returnKey
            case "\u{F700}": return .upArrow
            case "\u{F701}": return .downArrow
            default: return .character(Character(character.lowercased()))
            }
        }
    }

    /// Where the key was pressed.
    package enum Place: Equatable, Sendable {
        /// A field, the terminal, an editor or any other view has the keyboard.
        case typing
        /// The workbench page with nothing focused.
        case page
        /// An open drawer, with nothing focused or its read-only text;
        /// `choices` is how many options the digits pick at the keyboard
        /// cursor (a question's options, a step's three marks; 0 on the
        /// note), `isReview` whether it holds a review's comments.
        case drawer(choices: Int, isReview: Bool)
        /// A banner or stack card holding the keyboard; `quickChoices` is
        /// its Quick ask's options (0 for a Full ask).
        case card(quickChoices: Int)
    }

    package enum Action: Equatable, Sendable {
        case openStack
        case nextAsk
        case previousAsk
        case nextStop
        case previousStop
        /// The option (0-based) the digit names.
        case choose(Int)
        /// Into the field of the stop at the cursor.
        case edit
        /// The ask in the drawer.
        case open
        case nextComment
        case previousComment
    }

    /// The action of `press` at `place`; nil leaves the key to whoever
    /// else takes it.
    package static func action(for press: Press, at place: Place) -> Action? {
        guard !press.isRepeat, !press.otherModifiers else { return nil }
        if press.shift { return press.key == .tab && isDrawer(place) ? .previousStop : nil }
        switch place {
        case .typing: return nil
        case .page: return press.key == .character("a") ? .openStack : nil
        case let .drawer(choices, isReview): return drawerAction(press.key, choices: choices, isReview: isReview)
        case let .card(quickChoices): return cardAction(press.key, quickChoices: quickChoices)
        }
    }

    private static func isDrawer(_ place: Place) -> Bool {
        if case .drawer = place { return true }
        return false
    }

    private static func drawerAction(_ key: Press.Key, choices: Int, isReview: Bool) -> Action? {
        switch key {
        case .tab: return .nextStop
        case .returnKey: return .edit
        case let .character(character):
            if let digit = digit(character, limit: min(choices, 9)) { return .choose(digit) }
            return letterInDrawer(character, isReview: isReview)
        default: return nil
        }
    }

    private static func letterInDrawer(_ character: Character, isReview: Bool) -> Action? {
        switch character {
        case "j": .nextAsk
        case "k": .previousAsk
        case "n": isReview ? .nextComment : nil
        case "p": isReview ? .previousComment : nil
        default: nil
        }
    }

    private static func cardAction(_ key: Press.Key, quickChoices: Int) -> Action? {
        switch key {
        case .downArrow, .character("j"): return .nextAsk
        case .upArrow, .character("k"): return .previousAsk
        case .returnKey: return .open
        case let .character(character):
            return digit(character, limit: min(quickChoices, maxQuickDigit)).map(Action.choose)
        default: return nil
        }
    }

    /// The 0-based option of digit `character` ("1" is 0) within `limit`.
    private static func digit(_ character: Character, limit: Int) -> Int? {
        guard character.isASCII, let value = character.wholeNumberValue, value >= 1, value <= limit else { return nil }
        return value - 1
    }
}

/// The drawer's keyboard cursor (board #412): Tab walks the ask's
/// questions, then a check's steps, then the note; digits pick at the
/// cursor and Return writes in its field. Pure.
package enum OwnerAskKeyStop: Hashable, Sendable {
    case question(String)
    case step(String)
    case note

    /// The stops of `ask` in drawer order; none on a closed ask or while an
    /// answer is written (`editable` false).
    package static func stops(for ask: OwnerAsk, editable: Bool) -> [Self] {
        guard editable else { return [] }
        let questions = ask.payload.questions.map { Self.question($0.id) }
        let steps = ask.kind == .check ? ask.payload.checklist.map { Self.step($0.id) } : []
        return questions + steps + [.note]
    }

    /// The stop index after (`forward`) or before `current` among `count`,
    /// wrapping; from no cursor, the first or the last. nil when there are
    /// no stops.
    package static func moved(from current: Int?, forward: Bool, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current, current < count else { return forward ? 0 : count - 1 }
        return (current + (forward ? 1 : count - 1)) % count
    }

    /// How many options a digit picks at this stop.
    package func choices(in ask: OwnerAsk) -> Int {
        switch self {
        case let .question(id): ask.payload.questions.first { $0.id == id }?.options.count ?? 0
        case .step: OwnerAskPresentation.checkStates.count
        case .note: 0
        }
    }

    /// The comment after (`forward`) or before the active one, in document
    /// order (`locations`: each comment's passage, nil when not found in
    /// the snapshot — skipped), wrapping; from none, the first or the
    /// last. nil when no comment is placed.
    package static func movedComment(from active: Int?, forward: Bool, locations: [Int?]) -> Int? {
        let order = locations.indices.filter { locations[$0] != nil }
            .sorted { (locations[$0] ?? 0, $0) < (locations[$1] ?? 0, $1) }
        guard !order.isEmpty else { return nil }
        guard let active, let place = order.firstIndex(of: active) else { return forward ? order.first : order.last }
        return order[(place + (forward ? 1 : order.count - 1)) % order.count]
    }
}

extension ChatQuestionAnswer.Entry {
    /// `label` clicked or picked by its digit: a multi-choice question's
    /// labels toggle it; a single-choice question's become it alone, its
    /// Other cleared (one answer per single-choice question).
    package func toggling(_ label: String, multi: Bool) -> Self {
        var entry = self
        if multi {
            if let index = entry.labels.firstIndex(of: label) {
                entry.labels.remove(at: index)
            } else {
                entry.labels.append(label)
            }
        } else {
            entry.labels = [label]
            entry.other = nil
        }
        return entry
    }
}
