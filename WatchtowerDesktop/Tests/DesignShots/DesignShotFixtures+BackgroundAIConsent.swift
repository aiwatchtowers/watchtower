import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// Design-only scenes for the background AI consent (#1886, spec
/// `docs/superpowers/specs/2026-11-17-background-ai-consent-design.md`).
/// Nothing here is wired into the app; the strings are
/// `BackgroundAIConsentMockCopy`. Sample data only (`acme`).
@MainActor
enum BackgroundAIConsentShotFixtures {
    /// The consent screen as onboarding's last step.
    enum Step: String, CaseIterable {
        case claude, codex, ollama, claudeReserve, saving, error
    }

    /// Settings → AI → Background AI, one frame per state.
    enum Settings: String, CaseIterable {
        case allowed, paused, orgOff, orgAllowed, saving, error
    }

    static var shots: [DesignShot] {
        Step.allCases.map { step in
            DesignShot(name: "ai-consent-step-\(step.rawValue)", size: NSSize(width: 860, height: 0)) {
                AnyView(ConsentStepMock(step: step))
            }
        } + [
            DesignShot(name: "ai-consent-step-claude-narrow", size: NSSize(width: 600, height: 0)) {
                AnyView(ConsentStepMock(step: .claude))
            },
            DesignShot(name: "ai-consent-sheet-claude", size: NSSize(width: 560, height: 0)) {
                AnyView(ConsentSheetMock(error: nil))
            },
            DesignShot(name: "ai-consent-sheet-error", size: NSSize(width: 560, height: 0)) {
                AnyView(ConsentSheetMock(error: "config.yaml: permission denied"))
            }
        ] + Settings.allCases.map { state in
            DesignShot(name: "ai-consent-settings-\(state.rawValue)", size: NSSize(width: 640, height: 0)) {
                AnyView(SettingsSectionMock(state: state))
            }
        } + [
            DesignShot(name: "ai-consent-home-paused", size: NSSize(width: 420, height: 0)) {
                AnyView(HomeCardMock(organization: false))
            },
            DesignShot(name: "ai-consent-home-org", size: NSSize(width: 420, height: 0)) {
                AnyView(HomeCardMock(organization: true))
            },
            DesignShot(name: "ai-consent-empty-paused", size: NSSize(width: 720, height: 360)) {
                AnyView(EmptyStateMock(organization: false))
            },
            DesignShot(name: "ai-consent-empty-org", size: NSSize(width: 720, height: 360)) {
                AnyView(EmptyStateMock(organization: true))
            },
            DesignShot(name: "ai-consent-automations-paused", size: NSSize(width: 720, height: 0)) {
                AnyView(AutomationsNoticeMock(organization: false))
            },
            DesignShot(name: "ai-consent-automations-org", size: NSSize(width: 720, height: 0)) {
                AnyView(AutomationsNoticeMock(organization: true))
            }
        ]
    }
}

private typealias Copy = BackgroundAIConsentMockCopy

// MARK: - The consent body (shared by the step and the sheet)

private struct ConsentBodyMock: View {
    let agent: Copy.Agent
    var reserve: Copy.Agent?

    private static let icons = [
        "arrow.triangle.2.circlepath", "clock", "sun.max", "clock.arrow.circlepath", "bolt"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(Copy.title).font(.title2.weight(.semibold))
            Text(Copy.intro(agent)).fixedSize(horizontal: false, vertical: true)
            Text(Copy.plan(agent)).fixedSize(horizontal: false, vertical: true)
            if let reserve {
                Text(Copy.reserve(from: agent, to: reserve))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Spacing.regular) {
                Text(Copy.whatRunsTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                let rows = Copy.whatRuns(pollMinutes: 15, backfillDays: 30)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                        Image(systemName: Self.icons[index])
                            .foregroundStyle(.secondary)
                            .frame(width: IconSize.composer)
                        Text(row).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
            Text(Copy.userStarted).font(.caption).foregroundStyle(.secondary)
            Text(Copy.changeLater).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The two answers, with the saving and error states.
private struct ConsentButtonsMock: View {
    var showBack: Bool
    var saving = false
    var error: String?
    var large = true

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.regular) {
            HStack(spacing: Spacing.regular) {
                if showBack {
                    Button(Copy.back) {}.buttonStyle(.kitQuiet).disabled(saving)
                }
                Spacer()
                if saving {
                    ProgressView().controlSize(.small)
                    Text(Copy.saving).font(.caption).foregroundStyle(.secondary)
                }
                Button(Copy.notNow) {}.buttonStyle(.kitSecondary).disabled(saving)
                Button(Copy.allow) {}.buttonStyle(.kitPrimary).disabled(saving)
            }
            .controlSize(large ? .large : .regular)
            if let error {
                Text(Copy.saveFailed(error))
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(Copy.notNowNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Onboarding's last step

private struct ConsentStepMock: View {
    let step: BackgroundAIConsentShotFixtures.Step

    private var agent: Copy.Agent {
        switch step {
        case .codex: .codex
        case .ollama: .other("Ollama")
        default: .claude
        }
    }

    var body: some View {
        VStack(spacing: Spacing.page) {
            StepIndicatorMock(steps: ["Goals", "Connect", Copy.stepTitle], current: 2)
            VStack(alignment: .leading, spacing: Spacing.large) {
                ConsentBodyMock(agent: agent, reserve: step == .claudeReserve ? .codex : nil)
                ConsentButtonsMock(
                    showBack: true,
                    saving: step == .saving,
                    error: step == .error ? "config.yaml: permission denied" : nil
                )
                .padding(.top, Spacing.regular)
            }
        }
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(Surface.window)
    }
}

/// Onboarding's step indicator with the new third step (the real one is
/// `OnboardingStepIndicator` over `OnboardingV2Step`).
private struct StepIndicatorMock: View {
    let steps: [String]
    let current: Int

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                HStack(spacing: Spacing.small) {
                    Circle()
                        .fill(index <= current ? Color.accentColor : Color.secondary)
                        .frame(width: IconSize.chevron, height: IconSize.chevron)
                        .opacity(index <= current ? 1 : 0.3)
                    Text(title).foregroundStyle(index == current ? .primary : .secondary)
                }
                if index < steps.count - 1 {
                    Rectangle().fill(.tertiary).frame(width: Spacing.hero, height: Stroke.hairline)
                }
            }
        }
        .font(.caption)
    }
}

// MARK: - The one-time sheet after an upgrade

private struct ConsentSheetMock: View {
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            ConsentBodyMock(agent: .claude)
            ConsentButtonsMock(showBack: false, error: error, large: false)
        }
        .padding(Spacing.wide)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.window)
    }
}

// MARK: - Settings → AI → Background AI

private struct SettingsSectionMock: View {
    let state: BackgroundAIConsentShotFixtures.Settings

    private var isOn: Bool {
        switch state {
        case .allowed, .orgAllowed: true
        case .paused, .orgOff, .saving, .error: false
        }
    }

    private var caption: String {
        switch state {
        case .allowed: Copy.captionAllowed(.claude)
        case .paused, .saving, .error: Copy.captionPaused
        case .orgOff: Copy.captionOrgOff
        case .orgAllowed: Copy.captionOrgAllowed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            SettingsSection(title: Copy.sectionTitle, footer: Copy.settingsFooter, isBusy: state == .saving) {
                SettingRow(title: Copy.switchTitle, caption: caption) {
                    Toggle("", isOn: .constant(isOn))
                        .labelsHidden()
                        .disabled(state == .saving)
                        .managedByOrganization(state == .orgOff)
                }
                if state == .error {
                    Text(Copy.saveFailed("config.yaml: permission denied"))
                        .font(.caption)
                        .foregroundStyle(Tone.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailBackground()
    }
}

// MARK: - Home's one card

private struct HomeCardMock: View {
    let organization: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(spacing: Spacing.regular) {
                Image(systemName: "pause.circle")
                    .foregroundStyle(organization ? Color.secondary : Tone.warning)
                Text(organization ? Copy.homeOrgTitle : Copy.homeTitle).font(.headline)
                Spacer()
                if organization { ManagedByOrganizationBadge() }
            }
            Text(organization ? Copy.homeOrgBody : Copy.homeBody)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !organization {
                Button(Copy.allowAction) {}.buttonStyle(.kitSecondary).controlSize(.small)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .padding(Spacing.page)
        .detailBackground()
    }
}

// MARK: - A tab's empty state (Digests)

private struct EmptyStateMock: View {
    let organization: Bool

    var body: some View {
        VStack(spacing: Spacing.medium) {
            Image(systemName: "text.bubble")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No digests yet").font(.title3.weight(.semibold))
            Text("Digests summarize each Slack channel you follow after every sync.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: Spacing.small) {
                Image(systemName: organization ? "lock.fill" : "pause.circle")
                Text(organization ? Copy.readinessOrg : Copy.readinessPaused)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !organization {
                Button(Copy.allowAction) {}.buttonStyle(.kitSecondary).controlSize(.small)
            }
        }
        .frame(maxWidth: PaneWidth.narrowPage)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .detailBackground()
    }
}

// MARK: - The Automations tab's notice

private struct AutomationsNoticeMock: View {
    let organization: Bool

    private struct Row {
        let name: String
        let when: String
        let ai: Bool
    }

    private let rows = [
        Row(name: "Morning brief", when: "Every day at 08:00", ai: true),
        Row(name: "Weekly status for acme", when: "Fridays at 16:00", ai: true),
        Row(name: "Archive old exports", when: "Every day at 02:00 · no AI", ai: false)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Image(systemName: organization ? "lock.fill" : "pause.circle")
                    .foregroundStyle(organization ? Color.secondary : Tone.warning)
                Text(organization ? Copy.automationsOrgNotice : Copy.automationsNotice)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.medium)
                if !organization {
                    Button(Copy.allowAction) {}.buttonStyle(.kitSecondary).controlSize(.small)
                }
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            VStack(alignment: .leading, spacing: Spacing.tight) {
                ForEach(rows, id: \.name) { row in
                    HStack(spacing: Spacing.regular) {
                        Text(row.name).font(.body)
                        Spacer()
                        Text(row.when).font(.caption).foregroundStyle(.secondary)
                        Chip(
                            text: row.ai ? Copy.automationWaitingChip : "On",
                            color: row.ai ? Tone.status("gray") : Tone.success,
                            dot: true
                        )
                    }
                    .padding(.horizontal, Spacing.regular)
                    .frame(minHeight: ListLayout.rowMinHeight)
                    .kitRow(isSelected: false)
                }
            }
        }
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailBackground()
    }
}
