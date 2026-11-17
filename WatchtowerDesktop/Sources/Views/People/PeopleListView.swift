import SwiftUI
import WatchtowerCore

struct PeopleListView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: PeopleViewModel?
    @State private var selectedUserID: String?
    @State private var searchText = ""

    private static let teamSummaryID = "__team_summary__"

    var body: some View {
        HStack(spacing: 0) {
            if let vm = viewModel {
                listPanel(vm)

                if let userID = selectedUserID {
                    Divider()
                    if userID == Self.teamSummaryID, let cs = vm.cardSummary {
                        TeamSummaryDetailView(
                            summary: cs
                        ) { selectedUserID = nil }
                        .id(userID)
                        .frame(minWidth: 400, idealWidth: 500)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else if vm.isCardStopped(userID) {
                        PersonStoppedView(
                            userName: vm.userName(for: userID),
                            onClose: { selectedUserID = nil },
                            onMakeAgain: {
                                Task {
                                    await vm.makeCardsAgain(userID: userID)
                                    // No card until the next people run; close
                                    // only if the owner is still on this person.
                                    if !vm.isCardStopped(userID), selectedUserID == userID { selectedUserID = nil }
                                }
                            },
                            onDismissError: { vm.dismissCardActionError(for: userID) },
                            isPending: vm.isStopPending(userID),
                            actionError: vm.cardActionError(for: userID)
                        )
                        .id(userID)
                        .frame(minWidth: 400, idealWidth: 500)
                    } else if let card = vm.cards.first(where: { $0.userID == userID }) {
                        PersonDetailView(
                            card: card,
                            userName: vm.userName(for: userID),
                            history: vm.cardHistory(userID: userID),
                            userNameResolver: { vm.userName(for: $0) },
                            onClose: { selectedUserID = nil },
                            isCurrentUser: userID == vm.currentUserID,
                            profile: userID == vm.currentUserID ? vm.currentProfile : nil,
                            onUpdateConnections: { reports, peers, manager in
                                Task { await vm.updateConnections(reports: reports, peers: peers, manager: manager) }
                            },
                            allCards: vm.cards,
                            dbManager: appState.databaseManager,
                            onStopCard: userID == vm.currentUserID
                                ? nil
                                : { Task { await vm.stopCard(userID: userID) } },
                            onDismissError: { vm.dismissCardActionError(for: userID) },
                            isStopPending: vm.isStopPending(userID),
                            actionError: vm.cardActionError(for: userID)
                        )
                        .id(userID)
                        .frame(minWidth: 400, idealWidth: 500)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedUserID)
        .navigationTitle("People")
        .onAppear {
            if let db = appState.databaseManager, viewModel == nil {
                viewModel = PeopleViewModel(dbManager: db)
                viewModel?.startObserving()
            }
            if let userID = appState.pendingPersonUserID {
                selectedUserID = userID
                appState.pendingPersonUserID = nil
            }
        }
        .onChange(of: appState.pendingPersonUserID) { _, newID in
            if let userID = newID {
                selectedUserID = userID
                appState.pendingPersonUserID = nil
            }
        }
    }

    /// No cards at all (a filter that hides every card is not this).
    static func emptyState(context: EmptyStateContext) -> some View {
        TabEmptyState(.people, context: context)
    }

    /// Current user's card (for "My Card" pinned row).
    private var myCard: PeopleCard? {
        guard let vm = viewModel, let uid = vm.currentUserID else { return nil }
        return vm.cards.first { $0.userID == uid }
    }

    private var filteredCards: [PeopleCard] {
        guard let vm = viewModel else { return [] }
        let excluding = vm.cards.filter { $0.userID != vm.currentUserID }
        if searchText.isEmpty { return excluding }
        let query = searchText.lowercased()
        return excluding.filter { card in
            let name = vm.userName(for: card.userID).lowercased()
            if name.contains(query) { return true }
            if card.summary.lowercased().contains(query) { return true }
            if card.communicationStyle.lowercased().contains(query) { return true }
            if card.decisionRole.lowercased().contains(query) { return true }
            return false
        }
    }

    private func listPanel(_ vm: PeopleViewModel) -> some View {
        VStack(spacing: 0) {
            windowPicker(vm)
            statsAndSearch(vm)
            Divider()
            if vm.cards.isEmpty, vm.stoppedPeopleIDs.isEmpty, let error = vm.loadError {
                ErrorView(title: "Error", message: error, actionTitle: PeopleCardCopy.retry) { vm.load() }
            } else if vm.cards.isEmpty, vm.stoppedPeopleIDs.isEmpty {
                Self.emptyState(context: appState.emptyStateContext)
            } else {
                if let error = vm.loadError {
                    // The rows stay reachable; the reload is one press away.
                    HStack(spacing: Spacing.regular) {
                        WriteErrorBanner(message: error, onClose: nil)
                        Button(PeopleCardCopy.retry) { vm.load() }
                            .buttonStyle(.kitSecondary)
                            .padding(.trailing, Spacing.medium)
                    }
                }
                if let error = vm.errorMessage {
                    WriteErrorBanner(message: error) { vm.errorMessage = nil }
                }
                userListScrollView(vm)
            }
        }
        .frame(minWidth: 300, idealWidth: 360)
    }

    @ViewBuilder
    private func windowPicker(_ vm: PeopleViewModel) -> some View {
        if vm.availableWindows.count > 1 {
            HStack {
                Button {
                    let next = vm.selectedWindow + 1
                    if next < vm.availableWindows.count {
                        vm.loadWindow(at: next)
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(vm.selectedWindow >= vm.availableWindows.count - 1)

                Spacer()
                Text(vm.currentWindowLabel)
                    .font(.headline)
                Spacer()

                Button {
                    let prev = vm.selectedWindow - 1
                    if prev >= 0 {
                        vm.loadWindow(at: prev)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(vm.selectedWindow <= 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } else {
            Text(vm.currentWindowLabel)
                .font(.headline)
                .padding(.vertical, 8)
        }
    }

    private func statsAndSearch(_ vm: PeopleViewModel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.large) {
                StatBadge(value: "\(vm.cards.count)", label: "users")
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.bottom, 6)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                SearchField(
                    text: $searchText,
                    placeholder: "Filter people..."
                )
                .frame(height: 22)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func userListScrollView(_ vm: PeopleViewModel) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                teamSummaryRow(vm)
                myCardPinnedRow(vm)

                ForEach(filteredCards) { card in
                    personRow(card, vm: vm)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedUserID = card.userID
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            selectedUserID == card.userID
                                ? Color.accentColor.opacity(0.15)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .padding(.horizontal, 4)
                }

                PeopleStoppedCardsSection(
                    people: stoppedPeople(vm),
                    selectedUserID: selectedUserID
                ) { selectedUserID = $0 }
            }
            .padding(.vertical, 4)
        }
    }

    /// Stopped people matching the filter, as (id, name).
    private func stoppedPeople(_ vm: PeopleViewModel) -> [(id: String, name: String)] {
        let all = vm.stoppedPeople.map { (id: $0, name: vm.userName(for: $0)) }
        if searchText.isEmpty { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    @ViewBuilder
    private func teamSummaryRow(_ vm: PeopleViewModel) -> some View {
        if let cs = vm.cardSummary, searchText.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                HStack {
                    Label(PeopleCardCopy.teamSummaryTitle, systemImage: "person.3")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(cs.summary)
                    .font(.subheadline)
                    .lineLimit(3)
            }
            .padding(Spacing.cozy)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedUserID = Self.teamSummaryID
            }
            .card(selected: selectedUserID == Self.teamSummaryID)
            .padding(.horizontal, Spacing.regular)
            .padding(.bottom, Spacing.regular)
        }
    }

    @ViewBuilder
    private func myCardPinnedRow(_ vm: PeopleViewModel) -> some View {
        if let my = myCard, let vm = viewModel, searchText.isEmpty {
            myCardRow(my, vm: vm)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedUserID = my.userID
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    selectedUserID == my.userID
                        ? Color.accentColor.opacity(0.15)
                        : Color.accentColor.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal, 4)
                .padding(.bottom, 4)

            Divider()
                .padding(.horizontal, 8)
        }
    }

    private func myCardRow(_ card: PeopleCard, vm: PeopleViewModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(card.styleEmoji)
                Text("My Card")
                    .fontWeight(.bold)
                    .foregroundStyle(Color.accentColor)
                Text("@\(vm.userName(for: card.userID))")
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 8) {
                if let profile = vm.currentProfile {
                    if !profile.role.isEmpty {
                        Text(profile.role)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !profile.team.isEmpty {
                        Text(profile.team)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                    }
                }

                Text(card.communicationStyle)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    private func personRow(_ card: PeopleCard, vm: PeopleViewModel) -> some View {
        PeoplePersonRow(card: card, userName: vm.userName(for: card.userID)) {
            StarToggleButton(isStarred: vm.isPersonStarred(card.userID)) {
                Task { await vm.toggleStarredPerson(card.userID) }
            }
            .disabled(vm.isStarPending(card.userID))
        }
    }
}

/// The end of the People list: people whose cards the owner stopped. A row
/// opens the person's view with Make cards again (#1769, A14).
struct PeopleStoppedCardsSection: View {
    let people: [(id: String, name: String)]
    let selectedUserID: String?
    let onSelect: (String) -> Void

    var body: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.small) {
                SectionHeader(
                    title: PeopleCardCopy.stoppedCardsTitle, systemImage: "person.crop.circle.badge.xmark",
                    count: people.count
                )
                ForEach(people, id: \.id) { person in
                    Text("@\(person.name)")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.cozy)
                        .padding(.vertical, Spacing.compact)
                        .contentShape(Rectangle())
                        .kitRow(isSelected: selectedUserID == person.id)
                        .onTapGesture { onSelect(person.id) }
                }
            }
            .padding(.horizontal, Spacing.small)
            .padding(.top, Spacing.medium)
        }
    }
}

/// A People list row: the person, their decision role and work topics. No
/// red-flag mark, message count or volume change (#1769, A12).
struct PeoplePersonRow<Accessory: View>: View {
    let card: PeopleCard
    let userName: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.regular) {
                Text("@\(userName)").font(.body.weight(.medium))
                accessory
                if !card.decisionRole.isEmpty {
                    Chip(text: card.decisionRole, color: Tone.status("blue"))
                }
                Spacer(minLength: Spacing.regular)
                if card.isInsufficientData {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(PeopleCardCopy.insufficientDataShort)
                }
            }
            if !card.summary.isEmpty {
                Text(card.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, Spacing.small)
        .opacity(card.isInsufficientData ? 0.6 : 1.0)
    }
}

struct StatBadge: View {
    let value: String
    let label: String
    var color: Color = .accentColor

    var body: some View {
        HStack(spacing: 4) {
            Text(value)
                .fontWeight(.bold)
                .foregroundStyle(color)
            Text(label)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
