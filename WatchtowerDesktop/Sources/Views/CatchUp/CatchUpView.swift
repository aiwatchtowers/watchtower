import SwiftUI
import WatchtowerCore

// MARK: - CatchUpView
//
// Catch-Up v2 — two-panel master-detail review UX. The left column streams the
// active session's themes (CatchUpThemeRow) as expand completes; the right pane
// (CatchUpReviewPane) is the rich single-theme review screen with the action
// bar. The operator reviews one theme at a time; Done cascades mark-read and
// auto-advances to the next pending theme.
struct CatchUpView: View {
    @Bindable var vm: CatchUpViewModel
    @Environment(AppState.self) private var appState

    var body: some View {
        content
            .onAppear { vm.startObserving() }
    }

    @ViewBuilder
    private var content: some View {
        if let error = vm.error, vm.themes.isEmpty {
            errorState(error)
        } else if vm.isLoading && vm.themes.isEmpty {
            loadingState
        } else if vm.themes.isEmpty {
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

    // MARK: - Left: streaming theme list

    private var themeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            progressHeader
            Divider()
            List(selection: Binding(
                get: { vm.selected?.id },
                set: { id in vm.selected = vm.themes.first { $0.id == id } }
            )) {
                ForEach(vm.themes) { theme in
                    CatchUpThemeRow(theme: theme)
                        .tag(theme.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var progressHeader: some View {
        if let session = vm.session {
            HStack(spacing: 8) {
                Text("\(session.reviewedCount) of \(session.totalThemes) reviewed")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer(minLength: 0)
                Button {
                    vm.startSession()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Start review")
                .disabled(vm.isLoading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Right: review pane

    @ViewBuilder
    private var reviewPane: some View {
        if let theme = vm.selected {
            CatchUpReviewPane(theme: theme, vm: vm, onOpenSource: openSource)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                Text("All themes reviewed")
                    .font(.title3)
                Text("Nothing left in this pass.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Source navigation
    //
    // Digests and tracks expand inline under their source row inside the review
    // pane (handled by CatchUpReviewPane). Only briefings and inbox — which have
    // no inline renderer — route here to switch the sidebar destination. Ref areas
    // are persisted plural by the Go pipeline.
    private func openSource(_ ref: CatchUpRef) {
        switch ref.area {
        case "briefings":
            appState.navigateToBriefing(ref.id)
        case "inbox":
            appState.selectedDestination = .inbox
        default:
            break
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Clustering everything you missed into themes…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("All caught up")
                .font(.title3)
            Text("Start a review to cluster everything you missed into themes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Start review") { vm.startSession() }
                .disabled(vm.isLoading)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Catch-up failed")
                .font(.title3)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") { vm.startSession() }
                .disabled(vm.isLoading)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
