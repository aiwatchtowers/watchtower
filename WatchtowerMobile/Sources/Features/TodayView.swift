import Observation
import SwiftUI
import WatchtowerKit
import GRDB

@MainActor
@Observable
final class TodayViewModel {
    private(set) var briefing: Briefing?
    private(set) var events: [CalendarEvent] = []

    private var briefingCancellable: AnyDatabaseCancellable?
    private var eventsCancellable: AnyDatabaseCancellable?

    func start(store: ReplicaStore) {
        guard briefingCancellable == nil else { return }
        briefingCancellable = ReplicaObserver.observe(Briefing.self, kind: .briefing, in: store) { [weak self] items in
            self?.briefing = items.first
        }
        eventsCancellable = ReplicaObserver.observe(CalendarEvent.self, kind: .calendarEvent, in: store) { [weak self] items in
            self?.events = items
                .filter { Calendar.current.isDateInToday($0.startDate) }
                .sorted { $0.startDate < $1.startDate }
        }
    }
}

struct TodayView: View {
    @Environment(AppEnvironment.self) private var env
    /// Feature-gated sections (briefing, day plan) follow the desktop
    /// Feature Manager via the synced `feature_state` slice.
    @Environment(FeatureGate.self) private var gate
    @State private var model = TodayViewModel()
    /// Owns the plan's observations and its action overlay; shared with the
    /// full-plan screen so an in-flight done/skip survives navigating there
    /// and back.
    @State private var planModel = DayPlanViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    if let briefing = model.briefing, gate.isVisible(.todayBriefing) {
                        Section("Briefing · \(briefing.dateLabel)") {
                            Text(briefing.role).font(.headline)
                            ForEach(briefing.parsedYourDay) { item in
                                Label(item.text, systemImage: "circle")
                                    .font(.subheadline)
                            }
                        }
                    }
                    // Above the calendar: the plan is what the user is meant
                    // to DO today; the calendar below is what is already
                    // fixed in it.
                    // The error/failed banners belong to the plan's actions,
                    // so they hide with the section when day-plan is off.
                    if gate.isVisible(.todayDayPlan) {
                        if let message = planModel.actionErrorMessage {
                            ActionErrorRow(message: message) { planModel.clearActionError() }
                        }
                        ForEach(planModel.failedActions) { failed in
                            FailedActionBanner(
                                failed: failed,
                                onRetry: { Task { await planModel.retry(failed) } },
                                onDismiss: { planModel.dismissFailure(failed) }
                            )
                        }
                        DayPlanSection(model: planModel)
                    }
                    Section("Today's Calendar") {
                        if model.events.isEmpty {
                            Text("No events today").foregroundStyle(.secondary)
                        }
                        ForEach(model.events) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title).font(.body)
                                Text("\(event.formattedTimeRange) · \(event.location)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // Recordings are meeting-shaped, so they hang off the
                        // calendar section instead of claiming a seventh tab
                        // (the iPhone tab bar already folds two of the six
                        // under "More"). Labeled for the PAST so it never
                        // reads as part of today's agenda above it.
                        NavigationLink {
                            RecordingsView()
                        } label: {
                            Label("Past meeting recordings", systemImage: "waveform")
                                .font(.subheadline)
                        }
                    }
                }
                SyncStatusFooter()
            }
            .navigationTitle("Today")
        }
        .onAppear {
            model.start(store: env.store)
            planModel.start(store: env.store, outbox: env.outbox)
        }
    }
}
