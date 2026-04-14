import SwiftUI

struct GanttChartView: View {
    let epics: [ProjectMapViewModel.EpicItem]

    @State private var collapsedEpics: Set<String> = []

    private let epicRowHeight: CGFloat = 32
    private let issueRowHeight: CGFloat = 28
    private let rowSpacing: CGFloat = 4
    private let labelWidth: CGFloat = 200
    private let dayWidth: CGFloat = 12
    private let headerHeight: CGFloat = 40
    private let barHeight: CGFloat = 20

    private var today: Date { Date() }
    private var calendar: Calendar { Calendar.current }

    // MARK: - Timeline bounds

    /// Epics that have at least one child with timeline data (start+end).
    private var timelineEpics: [ProjectMapViewModel.EpicItem] {
        epics.filter { $0.startDate != nil && $0.endDate != nil }
    }

    private var fallbackEpics: [ProjectMapViewModel.EpicItem] {
        epics.filter { $0.startDate == nil || $0.endDate == nil }
    }

    private var timelineStart: Date {
        // Consider both epic-level and issue-level dates
        var allStarts: [Date] = timelineEpics.compactMap(\.startDate)
        for epic in timelineEpics {
            for issue in epic.issues {
                if let d = ProjectMapViewModel.EpicItem.parseDate(issue.createdAt) {
                    allStarts.append(d)
                }
            }
        }
        let earliest = allStarts.min() ?? today
        return calendar.date(from: calendar.dateComponents([.year, .month], from: earliest)) ?? earliest
    }

    private var timelineEnd: Date {
        var allEnds: [Date] = timelineEpics.compactMap(\.endDate)
        for epic in timelineEpics {
            for issue in epic.issues {
                if !issue.dueDate.isEmpty,
                   let d = ProjectMapViewModel.EpicItem.parseDayDate(issue.dueDate) {
                    allEnds.append(d)
                }
            }
        }
        let latest = allEnds.max() ?? today
        return calendar.date(byAdding: .weekOfYear, value: 2, to: latest) ?? latest
    }

    private var totalDays: Int {
        max(1, calendar.dateComponents([.day], from: timelineStart, to: timelineEnd).day ?? 1)
    }

    private var chartWidth: CGFloat {
        CGFloat(totalDays) * dayWidth
    }

    // MARK: - Body

    var body: some View {
        if epics.isEmpty {
            emptyState
        } else if timelineEpics.isEmpty {
            fallbackView
        } else {
            VStack(spacing: 0) {
                if !timelineEpics.isEmpty {
                    timelineChart
                }
                if !fallbackEpics.isEmpty {
                    Divider().padding(.vertical, 8)
                    Text("Epics without timeline data")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                    fallbackSection
                }
            }
        }
    }

    // MARK: - Timeline Chart

    private var timelineChart: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                dateHeader
                    .frame(height: headerHeight)

                Divider()

                ScrollView(.vertical, showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        todayMarker
                            .frame(maxHeight: .infinity)
                        monthGridLines
                            .frame(maxHeight: .infinity)

                        VStack(spacing: 0) {
                            ForEach(timelineEpics) { epic in
                                epicGroup(epic)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minWidth: labelWidth + chartWidth)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Epic Group (header + child issues)

    private func epicGroup(_ epic: ProjectMapViewModel.EpicItem) -> some View {
        let isCollapsed = collapsedEpics.contains(epic.key)
        return VStack(spacing: 0) {
            // Epic header row
            epicHeaderRow(epic, isCollapsed: isCollapsed)

            // Child issue rows
            if !isCollapsed {
                ForEach(epic.issues, id: \.key) { issue in
                    issueRow(issue)
                }
            }
        }
    }

    private func epicHeaderRow(
        _ epic: ProjectMapViewModel.EpicItem,
        isCollapsed: Bool
    ) -> some View {
        HStack(spacing: 0) {
            // Collapse toggle + epic name
            HStack(spacing: 4) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)

                Text(epic.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("\(epic.doneIssues)/\(epic.totalIssues)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: labelWidth, alignment: .leading)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if collapsedEpics.contains(epic.key) {
                        collapsedEpics.remove(epic.key)
                    } else {
                        collapsedEpics.insert(epic.key)
                    }
                }
            }

            // Aggregated epic bar
            ZStack(alignment: .leading) {
                Color.clear.frame(width: chartWidth, height: epicRowHeight)

                if let start = epic.startDate, let end = epic.endDate {
                    let startDays = max(
                        0,
                        calendar.dateComponents([.day], from: timelineStart, to: start).day ?? 0
                    )
                    let endDays = max(
                        startDays + 1,
                        calendar.dateComponents([.day], from: timelineStart, to: end).day ?? 0
                    )
                    let barOffset = CGFloat(startDays) * dayWidth
                    let barWidth = max(20, CGFloat(endDays - startDays) * dayWidth)

                    epicGanttBar(epic: epic, width: barWidth)
                        .offset(x: barOffset)
                }
            }
            .frame(width: chartWidth, height: epicRowHeight)
        }
        .frame(height: epicRowHeight)
        .background(Color.secondary.opacity(0.04))
    }

    // MARK: - Issue Row

    private func issueRow(_ issue: JiraIssue) -> some View {
        let issueStart = issueStartDate(issue)
        let issueEnd = issueEndDate(issue)

        return HStack(spacing: 0) {
            // Issue label (indented)
            HStack(spacing: 4) {
                Color.clear.frame(width: 16) // indent
                Circle()
                    .fill(statusColor(issue.statusCategory))
                    .frame(width: 6, height: 6)
                Text("\(issue.key)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(issue.summary)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: labelWidth, alignment: .leading)
            .padding(.horizontal, 4)

            // Issue bar
            ZStack(alignment: .leading) {
                Color.clear.frame(width: chartWidth, height: issueRowHeight)

                if let start = issueStart, let end = issueEnd {
                    let startDays = max(
                        0,
                        calendar.dateComponents([.day], from: timelineStart, to: start).day ?? 0
                    )
                    let endDays = max(
                        startDays + 1,
                        calendar.dateComponents([.day], from: timelineStart, to: end).day ?? 0
                    )
                    let barOffset = CGFloat(startDays) * dayWidth
                    let barWidth = max(16, CGFloat(endDays - startDays) * dayWidth)

                    issueGanttBar(issue: issue, width: barWidth)
                        .offset(x: barOffset)
                } else if let start = issueStart {
                    // No end date: show a dot marker at start
                    let startDays = max(
                        0,
                        calendar.dateComponents([.day], from: timelineStart, to: start).day ?? 0
                    )
                    let markerOffset = CGFloat(startDays) * dayWidth

                    Circle()
                        .fill(statusColor(issue.statusCategory))
                        .frame(width: 8, height: 8)
                        .offset(x: markerOffset)
                }
            }
            .frame(width: chartWidth, height: issueRowHeight)
        }
        .frame(height: issueRowHeight)
    }

    // MARK: - Issue date helpers

    private func issueStartDate(_ issue: JiraIssue) -> Date? {
        // Prefer statusCategoryChangedAt for in-progress items, fallback to createdAt
        if !issue.statusCategoryChangedAt.isEmpty,
           issue.statusCategory == "indeterminate" || issue.statusCategory == "in_progress" {
            return ProjectMapViewModel.EpicItem.parseDate(issue.statusCategoryChangedAt)
        }
        return ProjectMapViewModel.EpicItem.parseDate(issue.createdAt)
    }

    private func issueEndDate(_ issue: JiraIssue) -> Date? {
        guard !issue.dueDate.isEmpty else { return nil }
        return ProjectMapViewModel.EpicItem.parseDayDate(issue.dueDate)
    }

    // MARK: - Gantt Bars

    private func epicGanttBar(
        epic: ProjectMapViewModel.EpicItem,
        width: CGFloat
    ) -> some View {
        let color = badgeColor(epic.statusBadge)
        let fillWidth = width * epic.progressPct

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color.opacity(0.2))
                .frame(width: width, height: barHeight)

            if fillWidth > 0 {
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.7))
                    .frame(width: max(4, fillWidth), height: barHeight)
            }

            Text("\(Int(epic.progressPct * 100))%")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.leading, 4)
        }
        .frame(width: width)
    }

    private func issueGanttBar(
        issue: JiraIssue,
        width: CGFloat
    ) -> some View {
        let color = statusColor(issue.statusCategory)
        let isDone = issue.statusCategory == "done"

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(isDone ? 0.6 : 0.25))
                .frame(width: width, height: barHeight - 4)

            if isDone {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.8))
                    .frame(width: width, height: barHeight - 4)
            }

            if width > 40 {
                Text(issue.key)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(isDone ? .white : .primary)
                    .padding(.leading, 3)
            }
        }
        .frame(width: width)
    }

    // MARK: - Status color for child issues

    private func statusColor(_ statusCategory: String) -> Color {
        switch statusCategory {
        case "done": .green
        case "indeterminate", "in_progress": .blue
        case "new": .secondary
        default:
            statusCategory.lowercased().contains("block") ? .red : .secondary
        }
    }

    // MARK: - Date Header

    private var dateHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth)

            ZStack(alignment: .topLeading) {
                ForEach(monthMarkers, id: \.offset) { marker in
                    Text(marker.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .offset(x: marker.offset)
                }
            }
            .frame(width: chartWidth, alignment: .leading)
        }
    }

    private var monthMarkers: [(label: String, offset: CGFloat)] {
        var markers: [(String, CGFloat)] = []
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM yyyy"

        var current = timelineStart
        while current < timelineEnd {
            let days = calendar.dateComponents([.day], from: timelineStart, to: current).day ?? 0
            let offset = CGFloat(days) * dayWidth
            markers.append((fmt.string(from: current), offset))
            current = calendar.date(byAdding: .month, value: 1, to: current) ?? timelineEnd
        }
        return markers
    }

    // MARK: - Today Marker

    private var todayMarker: some View {
        let days = calendar.dateComponents([.day], from: timelineStart, to: today).day ?? 0
        let xOffset = labelWidth + CGFloat(days) * dayWidth

        return Rectangle()
            .fill(.clear)
            .frame(width: labelWidth + chartWidth)
            .overlay(alignment: .topLeading) {
                if days >= 0, CGFloat(days) * dayWidth <= chartWidth {
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 1.5)
                        .overlay(alignment: .top) {
                            Text("Today")
                                .font(.system(size: 9))
                                .foregroundStyle(.red)
                                .offset(x: 0, y: -14)
                        }
                        .offset(x: xOffset)
                }
            }
    }

    // MARK: - Grid Lines

    private var monthGridLines: some View {
        let markers = monthMarkers
        return ZStack(alignment: .topLeading) {
            ForEach(markers, id: \.offset) { marker in
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 0.5)
                    .offset(x: labelWidth + marker.offset)
            }
        }
        .frame(width: labelWidth + chartWidth)
    }

    // MARK: - Fallback Views

    private var fallbackView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: rowSpacing) {
                ForEach(epics) { epic in
                    fallbackRow(epic)
                }
            }
            .padding(12)
        }
    }

    private var fallbackSection: some View {
        VStack(spacing: rowSpacing) {
            ForEach(fallbackEpics) { epic in
                fallbackRow(epic)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func fallbackRow(_ epic: ProjectMapViewModel.EpicItem) -> some View {
        let color = badgeColor(epic.statusBadge)
        return HStack(spacing: 8) {
            Text(epic.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: labelWidth, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))

                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(0.7))
                        .frame(width: max(0, geo.size.width * epic.progressPct))

                    Text("\(Int(epic.progressPct * 100))%")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.leading, 4)
                }
            }
            .frame(height: 20)

            Text("\(epic.doneIssues)/\(epic.totalIssues)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .frame(height: epicRowHeight)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis.ascending")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No epics to display")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func badgeColor(_ badge: ProjectMapViewModel.EpicStatusBadge) -> Color {
        switch badge {
        case .onTrack: .green
        case .atRisk: .orange
        case .behind: .red
        }
    }
}
