import SwiftUI
import WatchtowerCore

struct BriefingsListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    @State private var viewModel: BriefingViewModel?
    @State private var selectedBriefingID: Int?

    var body: some View {
        Group {
            if let vm = viewModel {
                if let selID = selectedBriefingID,
                   let briefing = vm.briefings.first(where: { $0.id == selID }) {
                    detailView(briefing)
                } else {
                    listView(vm)
                }
            } else {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await appState.refreshOwner() }
        .onAppear {
            if viewModel == nil, let db = appState.databaseManager {
                let vm = BriefingViewModel(dbManager: db)
                viewModel = vm
                vm.startObserving()
            }
            if let id = appState.pendingBriefingID {
                selectedBriefingID = id
                appState.pendingBriefingID = nil
            }
        }
        .onChange(of: appState.isDBAvailable) {
            if viewModel == nil, let db = appState.databaseManager {
                let vm = BriefingViewModel(dbManager: db)
                viewModel = vm
                vm.startObserving()
            }
        }
        .onChange(of: appState.pendingBriefingID) { _, newID in
            if let id = newID {
                selectedBriefingID = id
                appState.pendingBriefingID = nil
            }
        }
        .onChange(of: selectedBriefingID) { _, newID in
            if let id = newID {
                viewModel?.markAsRead(id)
            }
        }
    }

    // MARK: - List View

    private func listView(_ vm: BriefingViewModel) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Briefings")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                if vm.unreadCount > 0 {
                    Text("\(vm.unreadCount) unread")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            if vm.briefings.isEmpty && !vm.isLoading {
                emptyList(vm)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(vm.briefings) { briefing in
                            briefingRow(briefing)
                        }

                        if vm.hasMore {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                                .onAppear { vm.loadMore() }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func briefingRow(_ briefing: Briefing) -> some View {
        let attention = briefing.parsedAttention
        let yourDay = briefing.parsedYourDay
        let whatHappened = briefing.parsedWhatHappened

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedBriefingID = briefing.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Header row
                HStack(spacing: 8) {
                    if !briefing.isRead {
                        Circle()
                            .fill(.blue)
                            .frame(width: 8, height: 8)
                    }

                    Text(briefing.dateLabel)
                        .font(.headline)
                        .fontWeight(briefing.isRead ? .regular : .semibold)

                    if !briefing.role.isEmpty {
                        Text(briefing.role)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        if !attention.isEmpty {
                            Label("\(attention.count)", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if !yourDay.isEmpty {
                            Label("\(yourDay.count) tasks", systemImage: "checklist")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if !whatHappened.isEmpty {
                            Label("\(whatHappened.count)", systemImage: "newspaper")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Attention preview
                if !attention.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(attention.prefix(2)) { item in
                            HStack(spacing: 5) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Text(item.text)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                        }
                        if attention.count > 2 {
                            Text("+\(attention.count - 2) more")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // Your Day preview
                if !yourDay.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(yourDay.prefix(2)) { item in
                            HStack(spacing: 5) {
                                Image(systemName: "checklist")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                                Text(item.text)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        if yourDay.count > 2 {
                            Text("+\(yourDay.count - 2) more")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail View

    private func detailView(_ briefing: Briefing) -> some View {
        VStack(spacing: 0) {
            // Back button header
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedBriefingID = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Briefings")
                    }
                    .font(.callout)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            BriefingDetailView(briefing: briefing)
                .id(briefing.id)
        }
    }

    // MARK: - Empty State

    private func emptyList(_ vm: BriefingViewModel) -> some View {
        BriefingsEmptyState(
            owner: appState.owner,
            processing: appState.backgroundTaskManager.hasActiveTasks,
            isGenerating: vm.isGenerating,
            generateError: vm.generateError,
            onGenerate: { Task { await vm.generateBriefing() } },
            onOpenConnections: {
                appState.settingsTab = .connections
                openSettings()
            }
        )
    }
}

/// The Briefings list's empty state, split out of `BriefingsListView` so it
/// takes no `@Environment(AppState.self)` and ViewInspector can drive it (the
/// `TrayMenuContent` pattern). With no owner identity it offers the way to
/// connect one instead of a Generate the CLI would refuse (OWNER-02).
struct BriefingsEmptyState: View {
    let owner: Owner
    let processing: Bool
    let isGenerating: Bool
    let generateError: String?
    let onGenerate: () -> Void
    let onOpenConnections: () -> Void

    var body: some View {
        if owner.isKnown {
            generatePrompt
        } else {
            NoOwnerEmptyState(openConnections: onOpenConnections)
        }
    }

    private var generatePrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "sun.max")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No briefings yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Briefings are generated daily after sync completes.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button(action: onGenerate) {
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                    Text("Generating...")
                } else {
                    Label("Generate Briefing", systemImage: "sparkles")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(processing || isGenerating)
            .help(processing ? "Wait for data processing to complete" : "Generate a briefing now")

            if processing {
                Text("Data is still being processed...")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let generateError {
                Text(generateError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
