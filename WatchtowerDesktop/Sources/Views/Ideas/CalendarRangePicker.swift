import SwiftUI

// MARK: - CalendarRangePicker
//
// A single-month calendar that picks a past date RANGE in one control: the
// first click anchors the range, the second completes it (either order), and
// any external change to the bound dates (the sheet's presets) cancels a
// pending anchor. macOS has no native range picker — the two compact
// DatePickers this replaces were fiddly to drive.
struct CalendarRangePicker: View {
    @Binding var fromDate: Date
    @Binding var toDate: Date
    /// Mirrors "a first click is waiting for its second" out to the host, so
    /// it can hold its submit action while the visible selection is not yet
    /// applied to the bindings. `.constant(false)` when the host doesn't care.
    @Binding var hasPendingAnchor: Bool
    let isDisabled: Bool

    /// First day of the month currently shown.
    @State private var displayedMonth: Date
    /// First click of an in-progress range; committed by the second click.
    @State private var anchor: Date? {
        didSet { hasPendingAnchor = anchor != nil }
    }

    private let calendar = Calendar.current

    init(
        fromDate: Binding<Date>,
        toDate: Binding<Date>,
        hasPendingAnchor: Binding<Bool> = .constant(false),
        isDisabled: Bool = false
    ) {
        _fromDate = fromDate
        _toDate = toDate
        _hasPendingAnchor = hasPendingAnchor
        self.isDisabled = isDisabled
        _displayedMonth = State(initialValue: Self.monthStart(of: toDate.wrappedValue, calendar: .current))
    }

    var body: some View {
        VStack(spacing: 6) {
            monthHeader
            weekdayHeader
            dayGrid
        }
        .frame(width: 7 * Self.cellWidth)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        // A preset (or any outside write) supersedes a half-picked range and
        // re-centers the grid when the new range is entirely off-screen (an
        // internal commit never is — the clicked day is in the shown month).
        .onChange(of: fromDate) { snapToExternalRange() }
        .onChange(of: toDate) { snapToExternalRange() }
    }

    private func snapToExternalRange() {
        anchor = nil
        if let snapped = Self.monthSnap(
            displayed: displayedMonth, from: fromDate, to: toDate, calendar: calendar) {
            displayedMonth = snapped
        }
    }

    // MARK: - Pieces

    private static let cellWidth: CGFloat = 34
    private static let cellHeight: CGFloat = 26

    private static let monthFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "LLLL yyyy"
        return fmt
    }()

    private var monthHeader: some View {
        HStack {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
            Spacer()
            Text(Self.monthFormatter.string(from: displayedMonth))
                .font(.callout)
                .fontWeight(.medium)
            Spacer()
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .disabled(isCurrentMonthShown)
        }
        .padding(.horizontal, 4)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Self.orderedWeekdaySymbols(calendar: calendar), id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.cellWidth)
            }
        }
    }

    private var dayGrid: some View {
        let cells = Self.gridDays(month: displayedMonth, calendar: calendar)
        let columns = Array(repeating: GridItem(.fixed(Self.cellWidth), spacing: 0), count: 7)
        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(width: Self.cellWidth, height: Self.cellHeight)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isFuture = day > Date()
        let isEndpoint: Bool
        let isInRange: Bool
        if let anchor {
            // A half-picked range shows only its anchor.
            isEndpoint = calendar.isDate(day, inSameDayAs: anchor)
            isInRange = false
        } else {
            isEndpoint = calendar.isDate(day, inSameDayAs: fromDate) || calendar.isDate(day, inSameDayAs: toDate)
            isInRange = day >= calendar.startOfDay(for: fromDate) && day <= toDate
        }
        return Button {
            select(day)
        } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.callout)
                .monospacedDigit()
                .frame(width: Self.cellWidth, height: Self.cellHeight)
                .background(
                    isEndpoint ? Color.accentColor
                        : isInRange ? Color.accentColor.opacity(0.2)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .foregroundStyle(
                    isFuture ? AnyShapeStyle(.tertiary)
                        : isEndpoint ? AnyShapeStyle(Color.white)
                        : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
    }

    // MARK: - Behavior

    private func select(_ day: Date) {
        if let first = anchor {
            // Clear BEFORE writing the bindings — their onChange fires
            // synchronously and must not cancel this very commit.
            anchor = nil
            let range = Self.commitRange(anchor: first, day: day, calendar: calendar)
            fromDate = range.from
            toDate = range.to
        } else {
            anchor = day
        }
    }

    private func shiftMonth(_ delta: Int) {
        guard let shifted = calendar.date(byAdding: .month, value: delta, to: displayedMonth) else { return }
        displayedMonth = shifted
    }

    private var isCurrentMonthShown: Bool {
        calendar.isDate(displayedMonth, equalTo: Date(), toGranularity: .month)
    }

    // MARK: - Pure helpers (unit-tested directly)

    /// The committed range for a two-click pick, either click order.
    /// Pure — unit-tested directly.
    static func commitRange(anchor: Date, day: Date, calendar: Calendar) -> (from: Date, to: Date) {
        (from: normalized(min(anchor, day), calendar: calendar),
         to: normalized(max(anchor, day), calendar: calendar))
    }

    /// Noon-anchored: a local-noon instant maps to the same calendar day in
    /// UTC for any |offset| < 12h (the VM's `--from`/`--to` formatter is
    /// UTC-pinned and day-granular, so an instant a few hours ahead of now is
    /// harmless — clamping to `Date()` would reintroduce the day-roll for
    /// "today picked before local noon" in positive-offset zones).
    static func normalized(_ day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    /// Where the grid should jump after an external range write: the range's
    /// end month when the current month shows neither endpoint, nil to stay
    /// put. Pure — unit-tested directly.
    static func monthSnap(displayed: Date, from: Date, to: Date, calendar: Calendar) -> Date? {
        let showsFrom = calendar.isDate(from, equalTo: displayed, toGranularity: .month)
        let showsTo = calendar.isDate(to, equalTo: displayed, toGranularity: .month)
        guard !showsFrom, !showsTo else { return nil }
        return monthStart(of: to, calendar: calendar)
    }

    static func monthStart(of date: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    /// The month's day cells with leading nils so day 1 lands on its weekday
    /// column under the calendar's own `firstWeekday`.
    static func gridDays(month: Date, calendar: Calendar) -> [Date?] {
        let start = monthStart(of: month, calendar: calendar)
        guard let dayRange = calendar.range(of: .day, in: .month, for: start) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        var cells = [Date?](repeating: nil, count: leading)
        for day in dayRange {
            cells.append(calendar.date(byAdding: .day, value: day - 1, to: start))
        }
        return cells
    }

    /// Weekday symbols rotated so the calendar's `firstWeekday` comes first.
    static func orderedWeekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }
}
