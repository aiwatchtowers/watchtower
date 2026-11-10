import SwiftUI
import WatchtowerCore

/// "▸ N closed" on a session row (or the stack's lines for the asks filed
/// outside the app and the automation runs'): shows that list in the ask
/// drawer (#1713 spec), beside the session it belongs to.
struct OwnerAskClosedButton: View {
    let vm: WorkbenchesViewModel
    let projectID: Int64
    let sessionID: Int64?
    /// The automation runs' closed asks (`sessionID` nil).
    var automations = false
    let count: Int

    var body: some View {
        Button {
            Task { await vm.showClosedList(projectID: projectID, sessionID: sessionID, automations: automations) }
        } label: {
            Text(ClosedAskListCopy.entryLabel(count)).font(.caption2)
        }
        .buttonStyle(.kitQuiet)
        .foregroundStyle(.secondary)
        .help(ClosedAskListCopy.buttonHelp)
    }
}

/// The drawer's list mode (#1713 spec): a session's (or the session-less)
/// closed asks, newest first in day groups, with search from 10 asks; a
/// row opens its ask read-only in the same drawer, with a way back.
struct OwnerAskClosedListPane: View {
    let vm: WorkbenchesViewModel
    let key: OwnerAsksViewModel.ClosedListKey
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private typealias Copy = ClosedAskListCopy
    private typealias Model = ClosedAskListModel
    private var asks: OwnerAsksViewModel { vm.asks }

    private var query: Binding<String> {
        Binding(get: { asks.closedListQueries[key] ?? "" }, set: { asks.closedListQueries[key] = $0 })
    }

    var body: some View {
        let list = asks.closedLists[key]
        let searching = Model.isSearching(query.wrappedValue)
        let sections = list.map {
            Model.sections(asks: $0, replacements: asks.replacements[key.projectID] ?? [:],
                           labels: asks.automationLabels[key.projectID] ?? [:], query: query.wrappedValue,
                           now: Date(), calendar: .current)
        } ?? []
        let ids = sections.flatMap { $0.rows.map(\.id) }
        VStack(spacing: 0) {
            header(total: list?.count, shown: ids.count, searching: searching)
            Divider()
            if let list, Model.showsSearch(total: list.count) { searchRow }
            banners(hasList: list != nil)
            content(list: list, sections: sections, ids: ids, searching: searching)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Surface.text)
        .controlSize(.small)
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(ids, forward: true) }
        .onKeyPress(.upArrow) { move(ids, forward: false) }
        .onKeyPress(.return) { openCursor(ids) }
        .onKeyPress(.escape) { escape() }
        .onKeyPress(keys: ["f"], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            searchFocused = true
            return .handled
        }
        // A click in the list borrows the keyboard and its close hands it
        // back, as the ask drawer does (board #536); opening the list
        // leaves the keyboard where it was.
        .background(OwnerAskKeyCatcher(
            onMouseDown: { [asks, projectID = key.projectID] inside in asks.setDrawerKeysActive(inside, projectID: projectID) },
            resizeEdge: asks.drawerExpanded ? 0 : PanelResizeHandle.thickness,
            canHandBack: { [asks, projectID = key.projectID] in asks.drawerIsEmpty(projectID: projectID) },
            loan: asks.keyboardLoan(projectID: key.projectID)
        ))
    }

    // MARK: Header, search, banners

    private func header(total: Int?, shown: Int, searching: Bool) -> some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "tray.full")
                .foregroundStyle(.secondary)
                .frame(width: IconSize.header)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.compact) {
                    Text(Copy.title).font(.headline)
                    if let total, total > 0 {
                        Text(Model.countText(shown: shown, total: total, searching: searching))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if total != nil, asks.closedLoading.contains(key) {
                        ProgressView().controlSize(.mini).help(Copy.busyHelp)
                    }
                }
                Text(scope).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Spacing.regular)
            OwnerAskDrawerExpandButton(asks: asks)
                .buttonStyle(.kitIcon(isOn: false))
            Button {
                asks.closeDrawer(projectID: key.projectID)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.kitIcon(isOn: false))
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.cozy)
    }

    private var scope: String {
        if key.automations { return Copy.scopeAutomations }
        guard let sessionID = key.sessionID else { return Copy.scopeOutside }
        let title = vm.sessions.first { $0.id == sessionID }?.title ?? "#\(sessionID)"
        return Copy.scopeSession(title)
    }

    private var searchRow: some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("", text: query)
                .textFieldStyle(.plain)
                .accessibilityLabel(Copy.searchPlaceholder)
                // The placeholder in the tertiary style the kit's fields use.
                .background(alignment: .leading) {
                    if query.wrappedValue.isEmpty {
                        Text(Copy.searchPlaceholder).foregroundStyle(.tertiary).allowsHitTesting(false)
                    }
                }
                .focused($searchFocused)
                .onSubmit { listFocused = true }
                .onKeyPress(.escape) {
                    clearSearch()
                    return .handled
                }
            if !query.wrappedValue.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                // An icon inside the field: no tint, no plate.
                .buttonStyle(.plain)
                .help(Copy.clearSearch)
                .accessibilityLabel(Copy.clearSearch)
            }
        }
        .font(.callout)
        .padding(.horizontal, Spacing.regular)
        .padding(.vertical, Spacing.compact)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .padding(.horizontal, Spacing.medium)
        .padding(.top, Spacing.cozy)
        .padding(.bottom, Spacing.small)
    }

    @ViewBuilder
    private func banners(hasList: Bool) -> some View {
        if hasList, let error = asks.closedErrors[key] {
            banner(error, retry: true)
        }
        if let notice = asks.closedListNotices[key] {
            banner(notice, retry: false)
        }
        if let unreadable = asks.closedUnreadable[key] {
            banner(unreadable, retry: false)
        }
    }

    private func banner(_ text: String, retry: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning).accessibilityHidden(true)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if retry {
                Button(Copy.retry, action: reload).buttonStyle(.kitQuiet)
            }
        }
        .padding(Spacing.regular)
        .card()
        .padding(.horizontal, Spacing.medium)
        .padding(.top, Spacing.small)
    }

    // MARK: Content

    @ViewBuilder
    private func content(list: [OwnerAsk]?, sections: [Model.Section], ids: [Int64], searching: Bool) -> some View {
        if list == nil, let error = asks.closedErrors[key] {
            stateBlock(icon: "exclamationmark.triangle", tone: Tone.warning, text: error, hint: nil, action: (Copy.retry, reload))
        } else if list == nil {
            stateBlock(icon: nil, tone: .secondary, text: Copy.loading, hint: nil, action: nil)
        } else if list?.isEmpty == true {
            stateBlock(icon: "tray", tone: .secondary, text: Copy.empty, hint: Copy.emptyHint, action: nil)
        } else if sections.isEmpty, searching {
            stateBlock(icon: "magnifyingglass", tone: .secondary,
                       text: Copy.noMatch(query.wrappedValue.trimmingCharacters(in: .whitespaces)),
                       hint: nil, action: (Copy.clearSearch, clearSearch))
        } else {
            rows(sections)
        }
    }

    private func rows(_ sections: [Model.Section]) -> some View {
        let cursor = asks.closedListCursors[key]
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.large) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            HStack(spacing: Spacing.compact) {
                                Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                Text("\(section.rows.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, Spacing.regular)
                            .padding(.bottom, Spacing.tight)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isHeader)
                            ForEach(section.rows) { row in
                                OwnerAskClosedRow(row: row, isSelected: row.id == cursor) { open(row.id) }
                                    .id(row.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, Spacing.small)
                .padding(.top, Spacing.regular)
                .padding(.bottom, Spacing.medium)
            }
            .onAppear {
                if let cursor { proxy.scrollTo(cursor, anchor: .center) }
            }
            .onChange(of: cursor) { _, id in
                if let id { withAnimation(Motion.toggle) { proxy.scrollTo(id) } }
            }
        }
    }

    private func stateBlock(icon: String?, tone: Color, text: String, hint: String?, action: (String, () -> Void)?) -> some View {
        VStack(spacing: Spacing.regular) {
            if let icon {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tone)
                    .accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).font(.callout).multilineTextAlignment(.center)
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let action {
                Button(action.0, action: action.1).buttonStyle(.kitSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.wide)
        .padding(.vertical, Spacing.hero)
    }

    // MARK: Actions

    private func open(_ askID: Int64) {
        Task { await vm.openClosedAsk(askID, from: key) }
    }

    private func reload() {
        Task { await asks.loadClosed(projectID: key.projectID, sessionID: key.sessionID, automations: key.automations) }
    }

    private func clearSearch() {
        asks.closedListQueries[key] = nil
        listFocused = true
    }

    private func move(_ ids: [Int64], forward: Bool) -> KeyPress.Result {
        guard !searchFocused else { return .ignored }
        asks.moveClosedListCursor(key, ids: ids, forward: forward)
        return .handled
    }

    /// Return opens the cursor's row only while it is on screen: a row the
    /// search hid is never opened blind.
    private func openCursor(_ ids: [Int64]) -> KeyPress.Result {
        guard !searchFocused, let id = asks.closedListCursors[key], ids.contains(id) else { return .ignored }
        open(id)
        return .handled
    }

    private func escape() -> KeyPress.Result {
        if !(asks.closedListQueries[key] ?? "").isEmpty {
            clearSearch()
        } else {
            asks.closeDrawer(projectID: key.projectID)
        }
        return .handled
    }
}

/// One closed ask: kind, title (two lines), status chip and "#id · detail",
/// and the time filed. A click opens it.
struct OwnerAskClosedRow: View {
    let row: ClosedAskListModel.Row
    let isSelected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Image(systemName: OwnerAskPresentation.askKindIcon(row.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: IconSize.composer)
                    .accessibilityLabel(OwnerAskPresentation.askKindLabel(row.kind))
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text(row.title)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Spacing.compact) {
                        Chip(text: row.chip.text, color: Tone.status(row.chip.toneName))
                        Text(row.caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: Spacing.small)
                Text(row.time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .kitRow(isSelected: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// Above an ask opened from a closed list: "‹ Closed asks  84", back to
/// that list (Esc does the same).
struct OwnerAskClosedBackRow: View {
    let vm: WorkbenchesViewModel
    let key: OwnerAsksViewModel.ClosedListKey

    var body: some View {
        HStack(spacing: Spacing.compact) {
            Button {
                vm.asks.backToClosedList(projectID: key.projectID)
            } label: {
                Label(ClosedAskListCopy.back, systemImage: "chevron.left")
            }
            .buttonStyle(.kitQuiet)
            .help(ClosedAskListCopy.backHelp)
            if let count = vm.asks.closedLists[key]?.count {
                Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.medium)
        .padding(.top, Spacing.regular)
    }
}
