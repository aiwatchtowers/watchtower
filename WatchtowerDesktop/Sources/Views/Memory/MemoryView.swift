import SwiftUI

// MARK: - MemoryView
//
// Secretary memory browser — two-panel master-detail over the vault. The left
// column is FTS search + type filter + node list (beliefs get a dashboard
// header); the right pane renders the selected node with tappable wiki-links,
// backlinks, vault git history, and the owner-edit editor (MEM-03).
struct MemoryView: View {
    @Bindable var vm: MemoryViewModel

    var body: some View {
        content
            .onAppear {
                Task { await vm.refresh() }
            }
            // Stays local because it needs `vm` — the wiki-link tap resolves
            // against this view's model, which the app-wide handler cannot
            // reach. Its fallthrough consults the same allowlist instead of
            // handing everything to `.systemAction`, so overriding the
            // environment here can never be weaker than the app-wide gate
            // (episodes carry calendar-invite and e-mail text verbatim).
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == MemoryMarkdown.linkScheme else {
                    return AllowedURLSchemes.permits(url) ? .systemAction : .discarded
                }
                vm.openWikiLink(url: url)
                return .handled
            })
            .sheet(isPresented: $vm.isEditing) {
                MemoryNodeEditorSheet(vm: vm)
            }
            .sheet(isPresented: $vm.isFocusEditing) {
                MemoryFocusEditorSheet(vm: vm)
            }
            // A focus.md READ failure (permissions, a directory in its place, a
            // decode error, …) sets focusEditorError but deliberately leaves the
            // sheet closed (beginFocusEditing) — surfaced here instead, since a
            // save-time error (sheet already open) is shown inline in the sheet.
            .alert("Focus file error", isPresented: Binding(
                get: { vm.focusEditorError != nil && !vm.isFocusEditing },
                set: { if !$0 { vm.focusEditorError = nil } }
            )) {
                Button("OK") { vm.focusEditorError = nil }
            } message: {
                Text(vm.focusEditorError ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        if !vm.vaultExists {
            emptyVaultState
        } else {
            HSplitView {
                listColumn
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Left column

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            typeFilterBar
            if !vm.isSearching {
                sortBar
            }
            Divider()
            if vm.isSearching {
                searchResultsList
            } else {
                nodeList
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await vm.beginFocusEditing() }
                } label: {
                    Label("Focus", systemImage: "scope")
                }
                .help("Edit focus.md — the Now/Cooled salience directives")
            }
        }
    }

    private var sortBar: some View {
        Picker("Sort", selection: Binding(
            get: { vm.sort },
            set: { newValue in
                vm.sort = newValue
                Task { await vm.refresh() }
            }
        )) {
            Text("Recent").tag(MemorySort.recent)
            Text("Important").tag(MemorySort.important)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search memory…", text: $vm.searchText)
                .textFieldStyle(.plain)
                .onChange(of: vm.searchText) { vm.searchChanged() }
            if vm.isSearching {
                Button {
                    vm.searchText = ""
                    vm.searchChanged()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var typeFilterBar: some View {
        HStack(spacing: 4) {
            typeChip(nil, label: "All")
            typeChip("entity", label: "Entities")
            typeChip("episode", label: "Episodes")
            typeChip("rollup", label: "Rollups")
            typeChip("belief", label: "Beliefs")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func typeChip(_ type: String?, label: String) -> some View {
        let count = type.map { vm.typeCounts[$0] ?? 0 }
        let isOn = vm.typeFilter == type
        return Button {
            vm.typeFilter = type
        } label: {
            Text(count.map { "\(label) \($0)" } ?? label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isOn ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var nodeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.typeFilter == "belief" {
                beliefStatsHeader
                Divider()
            }
            List(selection: Binding(
                get: { vm.selectedID },
                set: { id in
                    if let id { Task { await vm.select(id: id) } }
                }
            )) {
                if vm.typeFilter == "belief" {
                    ForEach(vm.beliefs) { belief in
                        MemoryBeliefRowView(belief: belief)
                            .tag(belief.id)
                    }
                } else {
                    ForEach(vm.filteredNodes) { node in
                        MemoryNodeRow(node: node)
                            .tag(node.id)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var beliefStatsHeader: some View {
        let stats = vm.beliefStats
        return HStack(spacing: 12) {
            statPair("\(stats.total)", "beliefs")
            statPair("\(stats.shaken)", "shaken")
            statPair("\(stats.disputed)", "disputed")
            statPair(String(format: "%.0f%%", stats.averageConfidence * 100), "avg conf")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func statPair(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.callout).fontWeight(.semibold).monospacedDigit()
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var searchResultsList: some View {
        List(selection: Binding(
            get: { vm.selectedID },
            set: { id in
                if let id { Task { await vm.select(id: id) } }
            }
        )) {
            ForEach(vm.searchHits) { hit in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(hit.title.isEmpty ? hit.id : hit.title)
                            .font(.callout)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        MemoryTypeChip(type: hit.type)
                    }
                    if !hit.snippet.isEmpty {
                        Text(hit.snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
                .tag(hit.id)
            }
            if vm.searchHits.isEmpty {
                Text("No matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Right pane

    @ViewBuilder
    private var detailPane: some View {
        if let detail = vm.detail {
            MemoryNodeDetailView(vm: vm, detail: detail)
        } else if let error = vm.error {
            Text(error)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "archivebox")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Select a memory node")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyVaultState: some View {
        VStack(spacing: 10) {
            Image(systemName: "archivebox")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Memory vault not initialized")
                .font(.headline)
            Text("Enable memory (`memory.enabled`) and let the daemon run, or run `watchtower memory reindex`.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Small colored type label used across the memory browser.
struct MemoryTypeChip: View {
    let type: String

    var body: some View {
        Text(type)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch type {
        case "entity": .blue
        case "episode": .teal
        case "rollup": .indigo
        case "belief": .orange
        default: .secondary
        }
    }
}
