import SwiftUI

// MARK: - IdeasView

/// The Ideas & Decisions registry screen. This is a minimal placeholder —
/// Task 13 replaces the body with the real master-detail review/registry UI.
struct IdeasView: View {
    let vm: IdeasViewModel

    var body: some View {
        List {
            Section("Review") {
                ForEach(vm.reviewItems) { idea in
                    Text(idea.title)
                }
            }
            Section("Registry") {
                ForEach(vm.registryItems) { idea in
                    Text(idea.title)
                }
            }
        }
        .navigationTitle("Ideas")
        .onAppear { vm.startObserving() }
    }
}
