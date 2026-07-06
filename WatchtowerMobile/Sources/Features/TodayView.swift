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
    @State private var model = TodayViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    if let briefing = model.briefing {
                        Section("Briefing · \(briefing.dateLabel)") {
                            Text(briefing.role).font(.headline)
                            ForEach(briefing.parsedYourDay) { item in
                                Label(item.text, systemImage: "circle")
                                    .font(.subheadline)
                            }
                        }
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
                    }
                }
                SyncStatusFooter()
            }
            .navigationTitle("Today")
        }
        .onAppear { model.start(store: env.store) }
    }
}
