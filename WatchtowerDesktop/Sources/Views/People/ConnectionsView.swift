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

    /// One org link; the same person may be both manager and peer.
    private struct OrgLink {
        let role: PeopleCardCopy.OrgRole
        let userID: String
        var id: String { "\(role):\(userID)" }
    }

    private var links: [OrgLink] {
        guard let profile else { return [] }
        var links: [OrgLink] = []
        if !profile.manager.isEmpty { links.append(OrgLink(role: .manager, userID: profile.manager)) }
        links += profile.decodedPeers.map { OrgLink(role: .peer, userID: $0) }
        links += profile.decodedReports.map { OrgLink(role: .report, userID: $0) }
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
                        ForEach(links, id: \.id) { link in
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
                ForEach(usersForManager, id: \.self) { userID in
                    HStack {
                        Text("@\(userNameResolver(userID))")
                        Spacer()
                        if selectedManager == userID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedManager = selectedManager == userID ? "" : userID
                    }
                }
            }

            Section("Key Peers") {
                ForEach(usersForPeers, id: \.self) { userID in
                    HStack {
                        Text("@\(userNameResolver(userID))")
                        Spacer()
                        if selectedPeers.contains(userID) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.orange)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedPeers.contains(userID) {
                            selectedPeers.remove(userID)
                        } else {
                            selectedPeers.insert(userID)
                        }
                    }
                }
            }

            Section("My Reports") {
                ForEach(usersForReports, id: \.self) { userID in
                    HStack {
                        Text("@\(userNameResolver(userID))")
                        Spacer()
                        if selectedReports.contains(userID) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedReports.contains(userID) {
                            selectedReports.remove(userID)
                        } else {
                            selectedReports.insert(userID)
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

    private var availableUsers: [String] {
        let all = Self.choices(cards: allCards, profile: profile)
        if searchText.isEmpty { return all }
        let query = searchText.lowercased()
        return all.filter { userNameResolver($0).lowercased().contains(query) }
    }

    /// Everyone with a card plus everyone already linked: a link to a person
    /// without a card (stopped, or not in this window) can still be removed.
    static func choices(cards: [PeopleCard], profile: UserProfile?) -> [String] {
        var ids = cards.map(\.userID)
        var linked = (profile?.decodedReports ?? []) + (profile?.decodedPeers ?? [])
        if let manager = profile?.manager, !manager.isEmpty { linked.insert(manager, at: 0) }
        for id in linked where !ids.contains(id) { ids.append(id) }
        return ids
    }

    private var usersForManager: [String] {
        let excluded = selectedPeers.union(selectedReports)
        return availableUsers.filter { !excluded.contains($0) }
    }

    private var usersForPeers: [String] {
        var excluded = selectedReports
        if !selectedManager.isEmpty { excluded.insert(selectedManager) }
        return availableUsers.filter { !excluded.contains($0) }
    }

    private var usersForReports: [String] {
        var excluded = selectedPeers
        if !selectedManager.isEmpty { excluded.insert(selectedManager) }
        return availableUsers.filter { !excluded.contains($0) }
    }
}
