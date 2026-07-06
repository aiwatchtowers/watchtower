import Observation
import SwiftUI
import WatchtowerKit
import GRDB

@MainActor
@Observable
final class InboxViewModel {
    private(set) var items: [InboxItem] = []
    private var cancellable: AnyDatabaseCancellable?

    func start(store: ReplicaStore) {
        guard cancellable == nil else { return }
        cancellable = ReplicaObserver.observe(InboxItem.self, kind: .inboxItem, in: store) { [weak self] items in
            self?.items = items.sorted { $0.priorityOrder < $1.priorityOrder }
        }
    }
}

struct InboxView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = InboxViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List(model.items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.triggerIcon)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.snippet).font(.subheadline).lineLimit(2)
                            HStack(spacing: 6) {
                                Badge(text: item.status, color: .gray)
                                Badge(text: item.priority, color: color(item.priorityColor))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .overlay { if model.items.isEmpty { ContentUnavailableView("Inbox empty", systemImage: "tray") } }
                SyncStatusFooter()
            }
            .navigationTitle("Inbox")
        }
        .onAppear { model.start(store: env.store) }
    }
}

// MARK: - Shared badge

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Maps the models' string color names to SwiftUI colors.
func color(_ name: String) -> Color {
    switch name {
    case "red": return .red
    case "orange": return .orange
    case "green": return .green
    case "blue": return .blue
    case "purple": return .purple
    case "gray": return .gray
    default: return .gray
    }
}
