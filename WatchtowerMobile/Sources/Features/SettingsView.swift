import Observation
import SwiftUI
import WatchtowerKit
import GRDB

@MainActor
@Observable
final class SettingsViewModel {
    /// Replica record counts per slice kind (rawValue → count).
    private(set) var counts: [(kind: String, count: Int)] = []
    private var cancellable: AnyDatabaseCancellable?

    func start(store: ReplicaStore) {
        guard cancellable == nil else { return }
        let observation = ValueObservation.tracking { db -> [(String, Int)] in
            try Row.fetchAll(db, sql: "SELECT kind, COUNT(*) AS n FROM slice_records GROUP BY kind ORDER BY kind")
                .map { ($0["kind"], $0["n"]) }
        }
        cancellable = observation.start(
            in: store.reader,
            scheduling: .async(onQueue: .main),
            onError: { print("settings counts error: \($0)") },
            onChange: { [weak self] rows in MainActor.assumeIsolated { self?.counts = rows.map { (kind: $0.0, count: $0.1) } } }
        )
    }
}

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = SettingsViewModel()

    var body: some View {
        NavigationStack {
            List {
                Section("App") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("WatchtowerKit", value: WatchtowerKitInfo.version)
                    LabeledContent("Connected transport", value: env.transportLabel)
                }
                Section("Replica records") {
                    if model.counts.isEmpty {
                        Text("No records").foregroundStyle(.secondary)
                    }
                    ForEach(model.counts, id: \.kind) { row in
                        LabeledContent(row.kind, value: "\(row.count)")
                    }
                }
            }
            .navigationTitle("Settings")
        }
        .onAppear { model.start(store: env.store) }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}
