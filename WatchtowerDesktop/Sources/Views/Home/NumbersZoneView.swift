import SwiftUI
import WatchtowerCore

/// Home's today in numbers: muted — secondary values over tertiary captions
/// in a two-column grid, no colour, no charts. A number whose source is off
/// or absent (nil) is left out; a failed read shows "—". The header always
/// shows.
struct NumbersZoneView: View {
    let numbers: HomeNumbers

    /// One grid cell.
    struct Cell: Equatable {
        let value: String
        let caption: String
        /// The Claude plan's 5 h percentage, drawn as a thin bar.
        var bar: Int?
    }

    var body: some View {
        HomeZone(title: "Today in numbers", systemImage: "chart.bar") {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Spacing.cozy) {
                ForEach(Self.cells(numbers), id: \.caption) { cell in
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(cell.value)
                            .font(.callout.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(cell.caption)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        if let bar = cell.bar {
                            ProgressView(value: Double(min(max(bar, 0), 100)), total: 100)
                                .progressViewStyle(.linear)
                                .controlSize(.mini)
                                .tint(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .homeZoneInset()
            .padding(.top, Spacing.small)
        }
    }

    private static let columns = [
        GridItem(.flexible(), spacing: Spacing.medium, alignment: .topLeading),
        GridItem(.flexible(), spacing: Spacing.medium, alignment: .topLeading)
    ]

    /// The cells in the mockup's order; a pair shows while either half has a
    /// value or failed.
    static func cells(_ numbers: HomeNumbers) -> [Cell] {
        let failed = numbers.failed
        func part(_ value: Int?, _ field: String) -> String? {
            failed.contains(field) ? "—" : value.map(String.init)
        }
        var cells: [Cell] = []
        if let pair = pair(part(numbers.messagesToMe, "messagesToMe"), part(numbers.messagesSent, "messagesSent")) {
            cells.append(Cell(value: pair, caption: "messages to me / sent"))
        }
        if let meetings = part(numbers.meetings, "meetings") {
            let hours = failed.contains("meetingHours") ? "—" : numbers.meetingHours.map(Self.hours)
            let value = numbers.meetings == 0 || hours == nil ? meetings : "\(meetings) · \(hours ?? "")"
            cells.append(Cell(value: value, caption: "meetings"))
        }
        if failed.contains("aiSpendUSD") {
            cells.append(Cell(value: "—", caption: "AI spend"))
        } else if let spend = numbers.aiSpendUSD {
            cells.append(Cell(value: String(format: "$%.2f", spend), caption: "AI spend"))
        }
        if let plan = planCell(numbers) {
            cells.append(plan)
        }
        if let pair = pair(part(numbers.workbenchCreated, "workbenchCreated"),
                           part(numbers.workbenchDone, "workbenchDone")) {
            cells.append(Cell(value: pair, caption: "workbench targets new / done"))
        }
        if let recorded = part(numbers.meetingsRecorded, "meetingsRecorded") {
            cells.append(Cell(value: recorded,
                              caption: numbers.meetingsRecorded == 1 ? "meeting recorded" : "meetings recorded"))
        }
        return cells
    }

    /// "38 / 12"; one missing half reads "—"; both missing: no cell.
    private static func pair(_ lhs: String?, _ rhs: String?) -> String? {
        guard lhs != nil || rhs != nil else { return nil }
        return "\(lhs ?? "—") / \(rhs ?? "—")"
    }

    /// "41% · 63%" with "Claude 5 h · week", or one of them alone.
    private static func planCell(_ numbers: HomeNumbers) -> Cell? {
        if numbers.failed.contains("plan5h") || numbers.failed.contains("planWeek") {
            return Cell(value: "—", caption: "Claude 5 h · week")
        }
        switch (numbers.plan5h, numbers.planWeek) {
        case let (session?, week?): return Cell(value: "\(session)% · \(week)%", caption: "Claude 5 h · week", bar: session)
        case let (session?, nil): return Cell(value: "\(session)%", caption: "Claude 5 h", bar: session)
        case let (nil, week?): return Cell(value: "\(week)%", caption: "Claude week")
        case (nil, nil): return nil
        }
    }

    /// "3.5 h", "3 h".
    private static func hours(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value)) h" : String(format: "%.1f h", value)
    }
}
