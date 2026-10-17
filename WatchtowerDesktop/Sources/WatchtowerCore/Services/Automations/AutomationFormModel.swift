import Foundation
import Observation

/// The edit form's draft of one recipe (spec §12.2 "Edit form", mockup 4).
///
/// One source of truth: `buffer.text`, the whole recipe file the Monaco pane
/// shows and a Save writes (R-P3-10). The form's controls edit `fields`, and
/// every change is spliced into the buffer's frontmatter at once
/// (`RecipeFrontmatter.splice`), so the Monaco pane shows it and a script edit
/// there is kept. The form never reads the frontmatter back from the text:
/// once the owner edits the frontmatter in the Monaco pane
/// (`frontmatterEditedInRecipe`), the form stops writing and its controls are
/// disabled until the draft is saved or discarded, so neither side overwrites
/// the other.
@MainActor
@Observable
package final class AutomationFormModel {
    nonisolated package static let nameRunes = 1...80
    nonisolated package static let buttonLabelRunes = 1...24
    nonisolated package static let budgetTokensRange = 1000...2_000_000
    nonisolated package static let budgetMinutesRange = 1...60
    nonisolated package static let concurrencyRange = 1...4
    nonisolated package static let pauseTimeoutRange = 1...168
    /// Go's `automations.EventTypes`, in its order.
    nonisolated package static let eventTypes = [
        "slack.new_messages", "gmail.new_messages", "jira.issue_changed", "calendar.event_changed",
        "confluence.page_changed", "slack.reaction_added"
    ]
    /// Go's `automations.EventFields`: per event type, the fields a `where`
    /// may match.
    nonisolated package static let eventFields: [String: [String]] = [
        "slack.new_messages": ["account", "channel", "channel_id"],
        "gmail.new_messages": ["account", "provider"],
        "jira.issue_changed": ["account", "key", "project", "field"],
        "calendar.event_changed": ["account", "event_id", "change"],
        "confluence.page_changed": ["space", "page_id"],
        "slack.reaction_added": ["account", "channel_id", "emoji"]
    ]

    /// The trigger the form's **On an event** choice starts from.
    nonisolated package static let defaultEventTrigger = RecipeFrontmatter.Trigger.event(
        type: eventTypes[0], where: [:]
    )

    /// An event trigger of `type` keeping only the `where` keys that type has
    /// (Go's parser refuses any other).
    nonisolated package static func eventTrigger(type: String, keeping filter: [String: String])
        -> RecipeFrontmatter.Trigger {
        let fields = Set(eventFields[type] ?? [])
        return .event(type: type, where: filter.filter { fields.contains($0.key) })
    }
    nonisolated package static let outputKinds = ["inbox", "briefing", "report", "target", "slack"]

    package var fields: RecipeFrontmatter {
        didSet {
            guard fields != oldValue, !frontmatterEditedInRecipe else { return }
            writeFields()
        }
    }

    /// The form's last change was overwritten by an edit typed in the Monaco
    /// pane at the same moment that also touched the settings: the form is
    /// paused and says the change did not land.
    package private(set) var lostFormEdit = false

    package let detail: AutomationDetail
    /// The recipe file being edited (frontmatter, description, script).
    package let buffer: RecipeBufferModel

    /// The frontmatter block as the form last wrote it (or as loaded).
    @ObservationIgnored private var formBlock: String?
    /// Every block the form wrote or loaded: a page edit carrying one of the
    /// older ones touched only the script.
    @ObservationIgnored private var formBlocks: Set<String> = []
    /// The buffer revision of the form's last splice.
    @ObservationIgnored private var spliceRevision = 0

    package init(detail: AutomationDetail) {
        self.detail = detail
        fields = RecipeFrontmatter(detail: detail)
        buffer = RecipeBufferModel(automationID: detail.id, text: detail.recipeText, contentHash: detail.contentHash)
        formBlock = RecipeFrontmatter.block(in: detail.recipeText).map(String.init)
        if let formBlock { formBlocks.insert(formBlock) }
        buffer.onPageSent = { [weak self] base in self?.pageSent(base: base) }
    }

    private func writeFields() {
        let text = RecipeFrontmatter.splice(fields, into: buffer.text)
        formBlock = RecipeFrontmatter.block(in: text).map(String.init)
        if let formBlock { formBlocks.insert(formBlock) }
        buffer.replace(text: text)
        spliceRevision = buffer.revision
    }

    /// A page edit typed before the form's last splice reached the page
    /// replaced the text, form change included. When it touched only the
    /// script (its settings block is one the form wrote earlier), the form's
    /// fields are spliced in again; otherwise the form pauses and says so.
    private func pageSent(base: Int) {
        guard base < spliceRevision else { return }
        let block = RecipeFrontmatter.block(in: buffer.text).map(String.init)
        guard block != formBlock else { return }
        if let block, formBlocks.contains(block) {
            writeFields()
        } else {
            lostFormEdit = true
        }
    }

    /// The owner changed the frontmatter in the Monaco pane: the form's
    /// fields no longer describe the text, so the form stops writing.
    package var frontmatterEditedInRecipe: Bool {
        RecipeFrontmatter.block(in: buffer.text).map(String.init) != formBlock
    }

    /// The text a Save writes: the buffer, which holds the form's fields and
    /// the owner's edits in the Monaco pane.
    package func renderedText() -> String {
        buffer.text
    }

    /// Out-of-range values, blocked in the form before `validate` runs.
    package var problems: [String] {
        guard !frontmatterEditedInRecipe else { return [] }
        var out: [String] = []
        let name = fields.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !Self.nameRunes.contains(name.unicodeScalars.count) { out.append("Name must be 1–80 characters.") }
        switch fields.trigger {
        case let .schedule(expr):
            if expr.split(separator: " ", omittingEmptySubsequences: true).count != 5 {
                out.append("The schedule must be a 5-field cron expression.")
            }
        case let .button(label, _):
            let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !Self.buttonLabelRunes.contains(label.unicodeScalars.count) { out.append("The button label must be 1–24 characters.") }
        case let .event(type, _):
            if !Self.eventTypes.contains(type) { out.append("Choose an event type.") }
        case .manual:
            break
        }
        if !Self.budgetTokensRange.contains(fields.budgetTokens) {
            out.append("Tokens per run must be between 1,000 and 2,000,000.")
        }
        if !Self.budgetMinutesRange.contains(fields.budgetMinutes) {
            out.append("Minutes per run must be between 1 and 60.")
        }
        if !Self.concurrencyRange.contains(fields.concurrency) {
            out.append("Runs at a time must be between 1 and 4.")
        }
        if !Self.pauseTimeoutRange.contains(fields.pauseTimeoutHours) {
            out.append("The pause timeout must be between 1 and 168 hours.")
        }
        if fields.permissions.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            out.append("A permission is empty.")
        }
        return out
    }
}

/// The edit form's human schedule picker (mockup 4): every weekday / day /
/// week on… / hour, or a custom cron, plus the time; it writes the cron.
package struct ScheduleChoice: Equatable, Sendable {
    package enum Repeat: String, CaseIterable, Sendable {
        case weekdays, daily, weekly, hourly, custom

        package var label: String {
            switch self {
            case .weekdays: "Every weekday"
            case .daily: "Every day"
            case .weekly: "Every week on…"
            case .hourly: "Every hour"
            case .custom: "Custom (cron)"
            }
        }
    }

    package var repeats: Repeat
    package var hour: Int
    package var minute: Int
    /// 0 = Sunday … 6 = Saturday, as in cron.
    package var weekday: Int
    package var custom: String

    package init(cron: String) {
        repeats = .custom
        hour = 9
        minute = 0
        weekday = 1
        custom = cron
        let f = cron.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard f.count == 5, f[2] == "*", f[3] == "*", let m = Int(f[0]), (0...59).contains(m) else { return }
        if f[1] == "*", f[4] == "*" {
            repeats = .hourly
            minute = m
            return
        }
        guard let h = Int(f[1]), (0...23).contains(h) else { return }
        switch f[4] {
        case "*": repeats = .daily
        case "1-5": repeats = .weekdays
        default:
            guard let d = Int(f[4]), (0...6).contains(d) else { return }
            repeats = .weekly
            weekday = d
        }
        hour = h
        minute = m
    }

    package var cron: String {
        switch repeats {
        case .weekdays: "\(minute) \(hour) * * 1-5"
        case .daily: "\(minute) \(hour) * * *"
        case .weekly: "\(minute) \(hour) * * \(weekday)"
        case .hourly: "\(minute) * * * *"
        case .custom: custom.trimmingCharacters(in: .whitespaces)
        }
    }

    /// The next time the picker's schedule fires after `now`; nil for a custom cron.
    package func next(after now: Date, calendar: Calendar) -> Date? {
        let weekdays: [Int?]
        switch repeats {
        case .weekdays: weekdays = [2, 3, 4, 5, 6]
        case .daily: weekdays = [nil]
        case .weekly: weekdays = [weekday + 1]
        case .hourly:
            return calendar.nextDate(after: now, matching: DateComponents(minute: minute), matchingPolicy: .nextTime)
        case .custom: return nil
        }
        let candidates = weekdays.compactMap {
            calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, weekday: $0),
                              matchingPolicy: .nextTime)
        }
        return candidates.min()
    }

    /// "Next: tomorrow 09:00 · cron 0 9 * * 1-5"; a custom cron in words.
    package func nextLine(now: Date, calendar: Calendar = .current) -> String {
        guard let next = next(after: now, calendar: calendar) else {
            return "\(CronText.sentence(cron)) · cron \(cron)"
        }
        let time = String(format: "%02d:%02d", calendar.component(.hour, from: next),
                          calendar.component(.minute, from: next))
        let day: String
        if calendar.isDate(next, inSameDayAs: now) {
            day = "today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
                  calendar.isDate(next, inSameDayAs: tomorrow) {
            day = "tomorrow"
        } else {
            day = calendar.shortWeekdaySymbols[calendar.component(.weekday, from: next) - 1]
        }
        return "Next: \(day) \(time) · cron \(cron)"
    }
}
