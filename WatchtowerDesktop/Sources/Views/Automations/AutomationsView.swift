import SwiftUI
import WatchtowerCore

/// What the tab hands to other surfaces. A nil hook leaves its button
/// disabled until the surface behind it exists (New automation sheet,
/// Templates gallery, Edit form, Change in words — plan Tasks 10, 11, 13).
struct AutomationsTabActions {
    var onNew: (() -> Void)?
    var onTemplates: (() -> Void)?
    var onEdit: ((Int64) -> Void)?
    var onChangeInWords: ((Int64) -> Void)?
    /// A step's proposal → the Inbox.
    var onOpenInbox: ((Int64) -> Void)?
}

/// The Automations tab (spec §12.1, approved mockup 1): a header with
/// **Templates**, **+ New** and "Search automations", the list on the left
/// and the selected automation's card on the right. All state lives in the
/// `AppState`-owned `AutomationsViewModel`; only the search text is local.
struct AutomationsView: View {
    @Bindable var vm: AutomationsViewModel
    var actions = AutomationsTabActions()
    var workbenchName: (Int64) -> String? = { _ in nil }
    var emptyStateContext: EmptyStateContext = .neutral

    @State private var searchText = ""

    private var filteredItems: [AutomationListItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return vm.items }
        return vm.items.filter {
            $0.automation.name.localizedCaseInsensitiveContains(query)
                || $0.automation.slug.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let message = vm.lastError {
                errorBanner(message)
            }
            if vm.items.isEmpty {
                TabEmptyState(.automations, context: emptyStateContext, onTabAction: { actions.onNew?() }, extra: {
                    if actions.onTemplates != nil {
                        Button("Browse templates") { actions.onTemplates?() }
                            .buttonStyle(.link)
                    }
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    listPanel
                        .frame(minWidth: 300, idealWidth: 380, maxWidth: 440)
                    cardPanel
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Automations")
        .onAppear {
            vm.setTabVisible(true)
            selectFirstIfNeeded()
        }
        .onDisappear { vm.setTabVisible(false) }
        .onChange(of: vm.items.map(\.id)) { _, _ in selectFirstIfNeeded() }
    }

    /// The card is never blank while there are automations to show.
    private func selectFirstIfNeeded() {
        guard vm.selectedID == nil || !vm.items.contains(where: { $0.id == vm.selectedID }),
              let first = filteredItems.first ?? vm.items.first else { return }
        vm.select(first.id)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            Button {
                vm.lastError = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - List

    private var listPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Automations")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Templates") { actions.onTemplates?() }
                    .disabled(actions.onTemplates == nil)
                Button("+ New") { actions.onNew?() }
                    .buttonStyle(.borderedProminent)
                    .disabled(actions.onNew == nil)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 10)

            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search automations")
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    let now = Date()
                    ForEach(filteredItems) { item in
                        AutomationListRow(
                            item: item,
                            changes: vm.details[item.id]?.changes,
                            isSelected: vm.selectedID == item.id,
                            now: now
                        ) { vm.select(item.id) }
                        Divider()
                    }
                }
            }
            .overlay {
                if filteredItems.isEmpty {
                    Text("No automation matches “\(searchText)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .panelBackground()
    }

    // MARK: - Card

    @ViewBuilder private var cardPanel: some View {
        if let id = vm.selectedID, let item = vm.items.first(where: { $0.id == id }) {
            AutomationCardView(
                vm: vm,
                item: item,
                actions: actions,
                workbenchName: item.automation.projectID.flatMap(workbenchName),
                now: Date()
            )
            .id(id)
        } else {
            Text("Select an automation")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
