import AppKit
import SwiftUI
import WatchtowerCore

/// The Goals step's AI agent section (#1521): one tile per CLI and, while
/// the picked one is not ready, its setup steps. All copy comes from
/// `OnboardingAgentChoice`.
struct OnboardingAgentSection: View {
    let choice: OnboardingAgentChoice
    let onPick: (OnboardingAgentChoice.Agent) -> Void
    let onCheckAgain: () -> Void
    let onChoosePath: (OnboardingAgentChoice.Agent) -> Void
    var onSignIn: () -> Void = {}
    var onStopSignIn: () -> Void = {}
    /// The live sign-in terminal (`<agent> auth login` in a PTY); the
    /// mockups pass a still of one.
    var signInTerminal: () -> AnyView = { AnyView(EmptyView()) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack(alignment: .top, spacing: Spacing.medium) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(OnboardingAgentChoice.title).fontWeight(.semibold)
                    Text(choice.caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if choice.showsTiles {
                HStack(spacing: Spacing.medium) {
                    ForEach(OnboardingAgentChoice.Agent.allCases, id: \.self) { agent in
                        tile(choice.tile(agent))
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(OnboardingAgentChoice.title)
                if let setup = choice.setup {
                    setupPanel(setup)
                }
            }
        }
        .padding(Spacing.medium + Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func tile(_ tile: OnboardingAgentChoice.Tile) -> some View {
        Button { onPick(tile.agent) } label: {
            HStack(alignment: .top, spacing: Spacing.cozy) {
                Image(systemName: tile.selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(tile.selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text(tile.title).fontWeight(.semibold)
                    HStack(spacing: Spacing.compact) {
                        if tile.busy {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle().fill(color(tile.tone)).frame(width: IconSize.stateDot, height: IconSize.stateDot)
                        }
                        Text(tile.status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(selected: tile.selected, fill: tile.selected ? Fill.selected : Fill.rest)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tile.enabled)
        .opacity(tile.enabled ? 1 : 0.55)
        .accessibilityLabel("\(tile.title), \(tile.status)")
        .accessibilityAddTraits(tile.selected ? .isSelected : [])
    }

    private func setupPanel(_ setup: OnboardingAgentChoice.Setup) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(setup.title).font(.callout.weight(.semibold))
            if setup.runsSignIn { signInBlock(setup) }
            ForEach(Array(setup.steps.enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text(setup.steps.count > 1 ? "\(index + 1). \(step.label)" : step.label).font(.caption).foregroundStyle(.secondary)
                    if let command = step.command { OnboardingCommandLine(command: command) }
                }
            }
            if let detail = setup.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            HStack(spacing: Spacing.medium) {
                Button(OnboardingAgentChoice.Setup.checkAgain, action: onCheckAgain)
                    .buttonStyle(.kitSecondary)
                if let docsURL = setup.docsURL, let url = URL(string: docsURL) {
                    Link(OnboardingAgentChoice.Setup.docsLink, destination: url)
                        .font(.caption)
                }
                if setup.showsManualPath {
                    Button(OnboardingAgentChoice.Setup.manualPath) { onChoosePath(setup.agent) }
                        .buttonStyle(.kitQuiet)
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            Text(OnboardingAgentChoice.Setup.autoCheck).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.text, in: RoundedRectangle(cornerRadius: Radius.row))
    }

    @ViewBuilder
    private func signInBlock(_ setup: OnboardingAgentChoice.Setup) -> some View {
        if let note = setup.signInNote {
            Text(note)
                .font(.caption)
                .foregroundStyle(setup.signInNoteWarns ? Tone.warning : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if choice.signIn == .running {
            signInTerminal()
                .frame(height: Self.terminalHeight)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
            Button(OnboardingAgentChoice.stopSignIn, action: onStopSignIn)
                .buttonStyle(.kitSecondary)
                .controlSize(.small)
        } else {
            Button(OnboardingAgentChoice.signInAgain, action: onSignIn)
                .buttonStyle(.kitSecondary)
                .controlSize(.small)
        }
    }

    /// About ten terminal rows: the login flow's URL and prompts fit.
    static let terminalHeight: CGFloat = 180

    private func color(_ tone: OnboardingAgentChoice.Tone) -> Color {
        switch tone {
        case .success: Tone.success
        case .warning: Tone.warning
        case .error: Tone.error
        case .neutral: .secondary
        }
    }
}

/// A Terminal command with a copy button.
struct OnboardingCommandLine: View {
    let command: String

    var body: some View {
        HStack {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.caption)
            }
            .buttonStyle(.kitQuiet)
            .help("Copy to clipboard")
            .accessibilityLabel("Copy to clipboard")
        }
        .padding(Spacing.regular)
        .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.control))
    }
}
