import SwiftUI
import WatchtowerCore

/// Onboarding step 3 (only with Slack connected): role and team, and the
/// manager / reports / peers pickers over the synced Slack users. Done
/// writes the answers, Later only marks onboarding done; both finish.
struct OnboardingAboutYouStepView: View {
    let onBack: () -> Void
    /// `about` is nil for Later.
    let onFinish: (_ about: OnboardingAboutYou?) async -> Void

    @Environment(AppState.self) private var appState

    private var model: OnboardingAboutYouModel { appState.onboardingAboutYou }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Who you are at work").font(.headline)
                Text("This decides whose messages and tasks Watchtower puts in front of you first, "
                    + "and how it advises you on people.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Text("Role and team")
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                TextField("Role and team", text: $model.role, prompt: Text("e.g. Engineering Manager, Platform"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    OnboardingPeoplePicker(
                        title: "Your manager",
                        model: model,
                        selection: Binding(
                            get: { model.manager.isEmpty ? [] : [model.manager] },
                            set: { model.manager = $0.last ?? "" }
                        )
                    )
                    Text("Picking someone replaces the current manager.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                OnboardingPeoplePicker(title: "Your reports", model: model, selection: $model.reports)
                VStack(alignment: .leading, spacing: 6) {
                    OnboardingPeoplePicker(title: "Peers", model: model, selection: $model.peers)
                    rosterLine
                }
            }

            if let error = model.profileError {
                HStack(spacing: 6) {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { Task { await loadModel() } }.buttonStyle(.link)
                }
                .font(.caption)
            }
            if let error = model.peopleError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Back", action: onBack)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Later") { Task { await onFinish(nil) } }
                    .controlSize(.large)
                Button {
                    Task { await onFinish(model.answers) }
                } label: {
                    Text("Done").frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                // Done before the prefill would write empty fields over the
                // profile.
                .disabled(!model.isPrefilled)
            }
            .disabled(appState.isFinishingOnboarding)
        }
        .task { await watchPeople() }
    }

    private func loadModel() async {
        guard let pool = appState.databaseManager?.dbPool else {
            model.databaseUnavailable()
            return
        }
        await model.load(from: pool)
    }

    /// Reads the people, then again every ~2 s while the roster load is
    /// still saving them — and through a failure, until a Retry ends it —
    /// with one last read once it is over.
    private func watchPeople() async {
        appState.resumePeopleRosterIfNeeded()
        await loadModel()
        guard let pool = appState.databaseManager?.dbPool else { return }
        while appState.peopleRoster.state.isLoadingOrFailed {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            if case .loading = appState.peopleRoster.state {
                await model.reloadPeople(from: pool)
            }
        }
        await model.reloadPeople(from: pool)
    }

    @ViewBuilder
    private var rosterLine: some View {
        let roster = appState.peopleRoster
        if let text = roster.state.stillLoadingText {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(text)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if case .failed(let reason) = roster.state {
            HStack(spacing: 6) {
                Text("Couldn't load people: \(reason)")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Button("Retry") { roster.retry() }.buttonStyle(.link)
            }
            .font(.caption)
        }
    }
}

/// A token field over the Slack users: the picked people as chips, a search
/// field (Return picks the first match), and the matches under it. One pick
/// for a single-person field is expressed by the binding keeping only the
/// last id. People picked in any field are not offered again.
struct OnboardingPeoplePicker: View {
    let title: String
    let model: OnboardingAboutYouModel
    @Binding var selection: [String]

    @State private var query = ""

    private var matches: [User] {
        OnboardingAboutYouModel.search(query, in: model.people, excluding: model.allPicked)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(selection, id: \.self) { id in chip(id) }
                TextField("Search…", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search \(title)")
                    .onSubmit {
                        if let first = matches.first { pick(first) }
                    }
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))

            let matches = matches
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { user in
                        Button {
                            pick(user)
                        } label: {
                            HStack(spacing: 4) {
                                Text(user.bestName)
                                if !user.name.isEmpty {
                                    Text("@\(user.name)").foregroundStyle(.secondary)
                                }
                                if let workspace = model.workspaceName(for: user.id) {
                                    Text("· \(workspace)").foregroundStyle(.tertiary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(accessibilityName(user))
                    }
                }
                .font(.caption)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func pick(_ user: User) {
        selection.append(user.id)
        query = ""
    }

    private func accessibilityName(_ user: User) -> String {
        [user.bestName, user.name.isEmpty ? nil : "@\(user.name)", model.workspaceName(for: user.id)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private func chip(_ id: String) -> some View {
        let user = model.people.first { SlackAccountID.matches($0.id, id) }
        let name = [user?.bestName ?? id, model.workspaceName(for: id)].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 2) {
            Text(name)
            Button {
                selection.removeAll { $0 == id }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(name)")
        }
        .font(.caption)
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
    }
}
