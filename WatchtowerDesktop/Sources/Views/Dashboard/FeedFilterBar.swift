import SwiftUI

/// Thin filter strip above the feed list: per-type chips plus "Important" and
/// "Hidden" toggles. State lives on `FeedViewModel` (persisted to UserDefaults).
struct FeedFilterBar: View {
    @Bindable var vm: FeedViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(FeedItem.ItemType.allCases, id: \.rawValue) { type in
                    Button {
                        vm.toggleType(type)
                    } label: {
                        Text(type.label)
                            .font(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                vm.typeFilter.contains(type) ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1),
                                in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                Toggle("Important only", isOn: $vm.importantOnly)
                    .font(.caption2)
                Toggle("Show hidden", isOn: $vm.showHidden)
                    .font(.caption2)
                Spacer()
            }
            .toggleStyle(.checkbox)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
