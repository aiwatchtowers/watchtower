import AppKit
import SwiftUI
import WatchtowerCore

extension OnboardingGoal {
    var title: String {
        switch self {
        case .workCommunication: "Work communication"
        case .tasksAndJira: "Tasks & Jira"
        case .meetings: "Meetings"
        case .development: "Development in Workbench"
        }
    }

    var pitch: String {
        switch self {
        case .workCommunication:
            "Back from a week off — Catch-Up in a minute. Every morning: what’s on fire and who’s waiting on you"
        case .tasksAndJira: "Jira issues and chat follow-ups in one list, with a suggested next step for each"
        case .meetings: "Before a meeting — context on people and topic. After — transcript and notes"
        case .development: "Claude Code works your folder’s board. No connections needed"
        }
    }
}

/// Onboarding step 1: goals, the assistant language and the AI CLI check.
/// Everything stateful is `AppState.onboardingGoals`; `onContinue` gets the
/// route Continue saved.
struct OnboardingGoalsStepView: View {
    let onContinue: (OnboardingRoute) async -> Void

    @Environment(AppState.self) private var appState
    @State private var showManualPath = false
    @State private var showNodeHelp = false
    @State private var manualPath = ""
    @State private var manualPathError: String?

    private var model: OnboardingGoalsModel { appState.onboardingGoals }

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isCustomizingFeatures {
                FeatureCustomizeView(selection: $model.selection) { model.isCustomizingFeatures = false }
            } else {
                goals
            }
        }
        .task { await model.prepareGoalsStep(configuredLanguage: ConfigService().digestLanguage) }
    }

    private var cliFailed: Bool {
        if case .failed = model.cliCheck { return true }
        return false
    }

    private var goals: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("What do you want Watchtower for?").font(.headline)
                if !cliFailed {
                    Text("Pick any").font(.subheadline).foregroundStyle(.secondary)
                }
            }

            if cliFailed {
                goalChips
            } else {
                goalCards
                customizeLine
            }

            if case .failed(let reason) = model.cliCheck {
                cliRequiredBox(reason)
            }

            Spacer(minLength: 0)

            if let error = model.continueError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    AssistantLanguageLine(selection: $model.language)
                    cliStatusLine
                }
                Spacer()
                if cliFailed {
                    Text("Continue unlocks once the CLI is found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task {
                        appState.clearOnboardingStepError()
                        if let route = await model.submit(
                            hasSlackAccount: appState.onboardingHasSlackAccount
                        ) {
                            await onContinue(route)
                        }
                    }
                } label: {
                    if model.isContinuing {
                        ProgressView().controlSize(.small).frame(minWidth: 80)
                    } else {
                        Text("Continue").frame(minWidth: 80)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canContinue || appState.isFinishingOnboarding)
            }
        }
        .disabled(model.isContinuing)
    }

    private var goalCards: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(OnboardingGoal.allCases, id: \.self) { goal in
                goalCard(goal)
            }
        }
    }

    private func goalCard(_ goal: OnboardingGoal) -> some View {
        let checked = model.selection.goals.contains(goal)
        return Button {
            model.toggleGoal(goal)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(goal.title).fontWeight(.semibold)
                    Text(goal.pitch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(checked ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(checked ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: checked ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    /// The goals while the CLI box takes the room: one chip per goal.
    private var goalChips: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingGoal.allCases, id: \.self) { goal in
                let checked = model.selection.goals.contains(goal)
                Button(goal.title) { model.toggleGoal(goal) }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(checked ? Color.accentColor.opacity(0.15) : .clear))
                    .overlay(Capsule().strokeBorder(checked ? Color.accentColor : Color.secondary.opacity(0.3)))
                    .foregroundStyle(checked ? .primary : .secondary)
            }
        }
    }

    @ViewBuilder
    private var customizeLine: some View {
        if model.selection.isCustomized {
            HStack(spacing: 4) {
                Text("Features customized ·").foregroundStyle(.secondary)
                Button("Reset") { model.selection.resetToGoals() }.buttonStyle(.link)
                Text("·").foregroundStyle(.secondary)
                Button("Customize features →") { model.isCustomizingFeatures = true }.buttonStyle(.link)
            }
            .font(.callout)
        } else {
            Button("Customize features →") { model.isCustomizingFeatures = true }
                .buttonStyle(.link)
                .font(.callout)
        }
    }

    @ViewBuilder
    private var cliStatusLine: some View {
        switch model.cliCheck {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking for Claude Code or Codex CLI…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .ready(let provider):
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("\(Self.cliName(provider)) found and signed in")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failed:
            EmptyView()
        }
    }

    /// `ai.provider` as the owner knows it; empty is the claude default.
    static func cliName(_ provider: String) -> String {
        switch provider {
        case "", "claude": "Claude Code"
        case "codex": "Codex CLI"
        case "ollama": "Ollama"
        default: provider
        }
    }

    private func cliRequiredBox(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Claude Code or Codex CLI is required", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("The assistant, Workbench and every AI feature run on it. Install it and sign in from Terminal:")
                .font(.callout)
                .foregroundStyle(.secondary)
            codeBlock("npm install -g @anthropic-ai/claude-code && claude")
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
            HStack(spacing: 16) {
                Button("Check again") { Task { await model.runCLICheck() } }
                Button("Set the path manually") { showManualPath.toggle() }.buttonStyle(.link)
                Button("No npm?") { showNodeHelp.toggle() }.buttonStyle(.link)
            }
            if showManualPath { manualPathRow }
            if showNodeHelp {
                Text("Install Node.js first from nodejs.org, then run the command above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.5)))
    }

    private var manualPathRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("e.g. /usr/local/bin/claude", text: $manualPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.message = "Select the 'claude' executable"
                    if panel.runModal() == .OK, let url = panel.url {
                        manualPath = url.path
                    }
                }
                Button("Use this path") { saveManualPath() }
                    .disabled(manualPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let manualPathError {
                Text(manualPathError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func saveManualPath() {
        let path = manualPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileManager.default.isExecutableFile(atPath: path) else {
            manualPathError = "File not found or not executable: \(path)"
            return
        }
        do {
            try OnboardingClaudePathConfig.save(path, configPath: Constants.configPath)
        } catch {
            manualPathError = "Could not save the path to \(Constants.configPath): \(error.localizedDescription)"
            return
        }
        manualPathError = nil
        Task { await model.runCLICheck() }
    }

    private func codeBlock(_ code: String) -> some View {
        HStack {
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Copy to clipboard")
            .accessibilityLabel("Copy to clipboard")
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
}
