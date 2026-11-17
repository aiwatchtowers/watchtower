import SwiftUI
import WatchtowerCore

/// People → Connections on the owner's card: only the org links the owner
/// entered (manager, peers, reports). No interaction graph or scores
/// (#1769, A15).
struct ConnectionsView: View {
    let profile: UserProfile?
    let allCards: [PeopleCard]
    let userNameResolver: (String) -> String
    var onUpdateConnections: (([String], [String], String) -> Void)?

    @State private var showEditSheet = false

    private var links: [(role: PeopleCardCopy.OrgRole, userID: String)] {
        guard let profile else { return [] }
        var links: [(role: PeopleCardCopy.OrgRole, userID: String)] = []
        if !profile.manager.isEmpty { links.append((.manager, profile.manager)) }
        links += profile.decodedPeers.map { (.peer, $0) }
        links += profile.decodedReports.map { (.report, $0) }
        return links
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                HStack(spacing: Spacing.regular) {
                    Text(PeopleCardCopy.orgLinksTitle).font(.title3.weight(.semibold))
                    Spacer(minLength: Spacing.medium)
                    editButton
                }
                if links.isEmpty {
                    Text(PeopleCardCopy.orgLinksEmpty)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        ForEach(links, id: \.userID) { link in
                            HStack(spacing: Spacing.regular) {
                                Text(PeopleCardCopy.orgRoleTitle(link.role))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: ListLayout.numberColumn, alignment: .leading)
                                Text("@\(userNameResolver(link.userID))").font(.body.weight(.medium))
                                Spacer(minLength: Spacing.regular)
                            }
                        }
                    }
                    .padding(Spacing.medium)
                    .card()
                }
            }
            .controlSize(.small)
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var editButton: some View {
        if onUpdateConnections != nil {
            Button {
                showEditSheet = true
            } label: {
                Label(PeopleCardCopy.editConnections, systemImage: "pencil")
            }
            .buttonStyle(.kitSecondary)
            .sheet(isPresented: $showEditSheet) {
                EditConnectionsSheet(
                    profile: profile,
                    userNameResolver: userNameResolver,
                    allCards: allCards,
                    onSave: { reports, peers, manager in
                        onUpdateConnections?(reports, peers, manager)
                        showEditSheet = false
                    },
                    onCancel: { showEditSheet = false }
                )
            }
        }
    }
}

// MARK: - Edit Connections Sheet

struct EditConnectionsSheet: View {
    let profile: UserProfile?
    let userNameResolver: (String) -> String
    let allCards: [PeopleCard]
    let onSave: ([String], [String], String) -> Void
    let onCancel: () -> Void

    @State private var selectedReports: Set<String> = []
    @State private var selectedPeers: Set<String> = []
    @State private var selectedManager: String = ""
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Connections")
                .font(.headline)
                .padding(.top, 12)

            searchBar
            connectionsList
            actionButtons
        }
        .frame(width: 400, height: 500)
        .onAppear {
            selectedReports = Set(profile?.decodedReports ?? [])
            selectedPeers = Set(profile?.decodedPeers ?? [])
            selectedManager = profile?.manager ?? ""
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search people...", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
    }

    private var connectionsList: some View {
        List {
            Section("Manager") {
                ForEach(usersForManager, id: \.userID) { card in
                    HStack {
                        Text("@\(userNameResolver(card.userID))")
                        Spacer()
                        if selectedManager == card.userID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedManager = selectedManager == card.userID ? "" : card.userID
                    }
                }
            }

            Section("Key Peers") {
                ForEach(usersForPeers, id: \.userID) { card in
                    HStack {
                        Text("@\(userNameResolver(card.userID))")
                        Spacer()
                        if selectedPeers.contains(card.userID) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.orange)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedPeers.contains(card.userID) {
                            selectedPeers.remove(card.userID)
                        } else {
                            selectedPeers.insert(card.userID)
                        }
                    }
                }
            }

            Section("My Reports") {
                ForEach(usersForReports, id: \.userID) { card in
                    HStack {
                        Text("@\(userNameResolver(card.userID))")
                        Spacer()
                        if selectedReports.contains(card.userID) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedReports.contains(card.userID) {
                            selectedReports.remove(card.userID)
                        } else {
                            selectedReports.insert(card.userID)
                        }
                    }
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Save") {
                onSave(
                    Array(selectedReports),
                    Array(selectedPeers),
                    selectedManager
                )
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private var availableUsers: [PeopleCard] {
        let filtered = allCards
        if searchText.isEmpty { return filtered }
        let query = searchText.lowercased()
        return filtered.filter {
            userNameResolver($0.userID).lowercased().contains(query)
        }
    }

    private var usersForManager: [PeopleCard] {
        let excluded = selectedPeers.union(selectedReports)
        return availableUsers.filter { !excluded.contains($0.userID) }
    }

    private var usersForPeers: [PeopleCard] {
        var excluded = selectedReports
        if !selectedManager.isEmpty { excluded.insert(selectedManager) }
        return availableUsers.filter { !excluded.contains($0.userID) }
    }

    private var usersForReports: [PeopleCard] {
        var excluded = selectedPeers
        if !selectedManager.isEmpty { excluded.insert(selectedManager) }
        return availableUsers.filter { !excluded.contains($0.userID) }
    }
}
