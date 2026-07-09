import SwiftUI

// MARK: - MeetingFeedPane

/// Right pane for an upcoming meeting: event facts plus the cached meeting
/// prep (if `meeting_prep_cache` has one) — no CLI call from the feed.
struct MeetingFeedPane: View {
    let event: CalendarEvent
    let prep: MeetingPrepResult?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(event.title).font(.title2).fontWeight(.semibold)
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                    Text(event.startDate, style: .time)
                    Text("–")
                    Text(event.endDate, style: .time)
                    if !event.location.isEmpty {
                        Image(systemName: "mappin").padding(.leading, 8)
                        Text(event.location)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                if let url = URL(string: event.htmlLink), !event.htmlLink.isEmpty {
                    Link("Open in Google Calendar", destination: url).font(.callout)
                }

                let attendees = event.parsedAttendees
                if !attendees.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Attendees").font(.headline)
                        ForEach(attendees) { a in
                            Text(a.displayName.isEmpty ? a.email : a.displayName)
                                .font(.callout)
                        }
                    }
                }

                if let prep {
                    Divider()
                    if !prep.talkingPoints.isEmpty {
                        feedPaneSection("Talking points", prep.talkingPoints.map(\.text))
                    }
                    if !prep.openItems.isEmpty {
                        feedPaneSection("Open items", prep.openItems.map(\.text))
                    }
                    if !prep.suggestedPrep.isEmpty {
                        feedPaneSection("Suggested prep", prep.suggestedPrep)
                    }
                } else if !event.description.isEmpty {
                    Divider()
                    Text(event.description).font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}

// MARK: - RecapFeedPane

/// Right pane for a finished meeting's recap: summary, decisions, action items.
struct RecapFeedPane: View {
    let recap: MeetingRecap
    let event: CalendarEvent?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(event?.title ?? "Meeting recap").font(.title2).fontWeight(.semibold)
                if let content = recap.parsed {
                    Text(content.summary).font(.callout)
                    if !content.keyDecisions.isEmpty {
                        feedPaneSection("Key decisions", content.keyDecisions)
                    }
                    if !content.actionItems.isEmpty {
                        feedPaneSection("Action items", content.actionItems)
                    }
                    if !content.openQuestions.isEmpty {
                        feedPaneSection("Open questions", content.openQuestions)
                    }
                } else {
                    Text("Recap unavailable").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}

// MARK: - DayPlanFeedPane

/// Right pane for a day plan: compact time-block/backlog list with a jump to
/// the full Day Plan tab (interactive editing lives there, not in the feed).
struct DayPlanFeedPane: View {
    let plan: DayPlan
    @Environment(AppState.self) private var appState
    @State private var items: [DayPlanItem] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Day plan — \(plan.planDate)").font(.title2).fontWeight(.semibold)
                    Spacer()
                    Button("Open Day Plan") { appState.navigateToDayPlan(plan.planDate) }
                }
                if plan.hasConflicts, let summary = plan.conflictSummary, !summary.isEmpty {
                    Label(summary, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                ForEach(items, id: \.id) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isDone ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.callout)
                            if let range = item.timeRange {
                                Text(range).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .task(id: plan.id) {
            guard let dbPool = appState.databaseManager?.dbPool else { return }
            items = (try? await dbPool.read { db in
                try DayPlanQueries.fetchItems(db, planId: plan.id)
            }) ?? []
        }
    }
}

// MARK: - Shared

@ViewBuilder
func feedPaneSection(_ title: String, _ lines: [String]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.headline)
        ForEach(lines, id: \.self) { line in
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                Text(line)
            }
            .font(.callout)
        }
    }
}
