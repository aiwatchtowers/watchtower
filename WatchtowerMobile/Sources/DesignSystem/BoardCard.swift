import SwiftUI
import WatchtowerKit

/// What a board card shows, the Desktop's `WorkbenchBoardCardView` (mockup
/// 5): the status glyph in its tone, the title (struck through when done),
/// `#number`, a priority chip with a dot (high red and low blue from
/// `PriorityMark`, medium gray, since the phone's orange is waiting only; a
/// priority from a newer Mac draws no chip), the status
/// chip in the status tone, a counter ("1/2"), a progress bar grey while
/// partial and green when complete, and the live sessions.
struct BoardCardModel: Equatable {
    let numberText: String
    let title: String
    let glyph: String
    let tone: PhoneTone
    let chips: [PillItem]
    let counter: String?
    let progress: Double?
    let progressTone: PhoneTone
    /// "1 session", "2 sessions"; nil without a live session.
    let sessionsText: String?
    let isDone: Bool

    /// `statusText` is the column's or status's label (the screen's
    /// `BoardRowModel.statusLabel`); `progress` is 0…1, nil for no bar.
    init(
        number: Int64,
        title: String,
        status: WorkbenchTargetStatus,
        statusText: String,
        priority: WorkbenchTargetPriority,
        counter: String? = nil,
        progress: Double? = nil,
        liveSessions: Int = 0
    ) {
        let style = TargetStatusStyle.of(status)
        numberText = "#\(number)"
        self.title = title.isEmpty ? "Untitled" : title
        glyph = style.glyph
        tone = style.tone
        var chips: [PillItem] = []
        if let priorityTone = PriorityMark.tone(priority) ?? (priority == .medium ? .gray : nil) {
            chips.append(PillItem(text: priority.rawValue.capitalized, tone: priorityTone, dot: true))
        }
        chips.append(PillItem(text: statusText, tone: style.tone))
        self.chips = chips
        self.counter = counter
        self.progress = progress.map { min(1, max(0, $0)) }
        progressTone = (progress ?? 0) >= 1 ? .green : .gray
        sessionsText = liveSessions > 0 ? "\(liveSessions) session\(liveSessions == 1 ? "" : "s")" : nil
        isDone = status == .done
    }

    var toneUses: [ToneUse] {
        [ToneUse(element: "board card \(numberText) status", tone: tone, role: .status)]
            + chips.map { ToneUse(element: "board card \(numberText) chip \($0.text)", tone: $0.tone, role: $0.dot ? .priority : .status) }
            + (progress == nil ? [] : [ToneUse(element: "board card \(numberText) progress", tone: progressTone, role: .progress)])
    }
}

/// The card: plain, or highlighted when selected (the Desktop's selected
/// card); a closed card dims.
///
///     BoardCard(model: BoardCardModel(number: 1, title: "Billing export", status: .inProgress,
///                                     statusText: "In Progress", priority: .high, counter: "1/2", progress: 0.5),
///               isSelected: false)
struct BoardCard: View {
    let model: BoardCardModel
    var isSelected = false
    var isDimmed = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Image(systemName: model.glyph)
                .foregroundStyle(model.tone.color)
                .frame(width: PhoneMetrics.iconColumn)
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(model.title)
                    .font(TypeScale.rowTitle.weight(.medium))
                    .strikethrough(model.isDone)
                    .foregroundStyle(model.isDone ? Color.secondary : Color.primary)
                FlowRow {
                    Text(model.numberText).font(TypeScale.time).foregroundStyle(.secondary)
                    ForEach(model.chips, id: \.text) { Pill(item: $0) }
                    if let counter = model.counter {
                        Text(counter).font(TypeScale.time).foregroundStyle(.secondary)
                    }
                    if let sessions = model.sessionsText {
                        HStack(spacing: Spacing.small) {
                            SessionDot(tone: .green, isRing: false, size: PhoneMetrics.priorityDot)
                            Text(sessions)
                        }
                        .font(TypeScale.meta)
                        .foregroundStyle(.secondary)
                    }
                }
                if let progress = model.progress {
                    ThinProgressBar(value: progress, tone: model.progressTone)
                        .padding(.top, Spacing.tight)
                }
            }
        }
        .card(isSelected ? .highlighted : .plain)
        .opacity(isDimmed && !isSelected ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}
