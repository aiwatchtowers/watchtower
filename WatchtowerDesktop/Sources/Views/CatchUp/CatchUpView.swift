import SwiftUI

// NOTE: This is the interim review-mode shell wired to the v2 `CatchUpViewModel`.
// Task 11 replaces it with the full two-panel master-detail UX
// (CatchUpThemeRow + CatchUpReviewPane). It is kept minimal here only so the
// target builds after the ViewModel rewrite (Task 10).
struct CatchUpView: View {
    @Bindable var vm: CatchUpViewModel

    var body: some View {
        Group {
            if vm.themes.isEmpty {
                emptyState
            } else {
                HSplitView {
                    themeList
                        .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                    reviewPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Catch Up")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    vm.startSession()
                } label: {
                    Label("Start review", systemImage: "arrow.clockwise")
                }
                .disabled(vm.isLoading)
            }
        }
        .onAppear { vm.startObserving() }
    }

    private var themeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = vm.session {
                Text("\(session.reviewedCount) of \(session.totalThemes) reviewed")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            List(selection: Binding(
                get: { vm.selected?.id },
                set: { id in vm.selected = vm.themes.first { $0.id == id } }
            )) {
                ForEach(vm.themes) { theme in
                    themeRow(theme).tag(theme.id)
                }
            }
        }
    }

    private func themeRow(_ theme: CatchUpTheme) -> some View {
        HStack(spacing: 8) {
            Circle().fill(priorityColor(theme.priority)).frame(width: 8, height: 8)
            Text(theme.title.isEmpty ? "Untitled" : theme.title)
                .lineLimit(1)
            Spacer()
            if theme.isExpanding {
                ProgressView().controlSize(.small)
            } else if theme.isReviewed {
                Image(systemName: "checkmark").foregroundStyle(.secondary)
            } else if theme.needsYou {
                Image(systemName: "person.fill.questionmark").foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var reviewPane: some View {
        if let theme = vm.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(theme.title).font(.largeTitle.bold())
                    if !theme.narrative.isEmpty {
                        Text(theme.narrative).font(.body)
                    }
                    if !theme.suggestedAction.isEmpty {
                        Label(theme.suggestedAction, systemImage: "lightbulb")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Done") { Task { await vm.acknowledge(theme) } }
                        Button("👍") { vm.submitFeedback(theme, rating: 1, comment: "") }
                        Button("👎") { vm.submitFeedback(theme, rating: -1, comment: "") }
                    }
                    .padding(.top, 8)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a theme to review")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(.green)
            Text("All caught up").font(.title3)
            Text("Start a review to cluster everything you missed into themes.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Start review") { vm.startSession() }
                .disabled(vm.isLoading)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "high": return .red
        case "medium": return .orange
        default: return .secondary
        }
    }
}
