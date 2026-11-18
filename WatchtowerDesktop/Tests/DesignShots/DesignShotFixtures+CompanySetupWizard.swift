import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

private typealias Copy = CompanySetupMockCopy

// MARK: - The admin wizard (spec §2)

enum RailState { case done, reused, skipped, current, todo }

struct WizardScene {
    let name: String
    let step: Int
    var rail: [RailState]
    var resume = false
    let blocks: [MockBlock]

    init(_ name: String, step: Int, rail: [RailState]? = nil, resume: Bool = false, _ blocks: [MockBlock]) {
        self.name = name
        self.step = step
        self.rail = rail ?? (0..<Copy.railSteps.count).map { $0 < step ? .done : ($0 == step ? .current : .todo) }
        self.resume = resume
        self.blocks = blocks
    }
}

/// The wizard sheet: the step rail on the left (one line at narrow width),
/// the step's content on the right, the buttons at the bottom.
struct CompanyWizardMock: View {
    let scene: WizardScene
    var narrow = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            MockBlockView(block: .title(Copy.wizardTitle, Copy.wizardIntro))
            if scene.resume { resumeLine }
            if narrow {
                Text(Copy.stepLine(scene.step)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: Spacing.large) {
                if !narrow { rail.frame(width: PaneWidth.sideListIdeal) }
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    if !narrow { Text(Copy.railSteps[scene.step]).font(.headline) }
                    ForEach(Array(scene.blocks.enumerated()), id: \.offset) { _, block in MockBlockView(block: block) }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    private var resumeLine: some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "arrow.uturn.forward.circle").foregroundStyle(.secondary)
            Text(Copy.resumeLine).font(.caption)
            Spacer(minLength: Spacing.regular)
            Button(Copy.discardSetup) {}.buttonStyle(.kitQuiet)
        }
        .padding(Spacing.regular)
        .card()
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            ForEach(Array(Copy.railSteps.enumerated()), id: \.offset) { index, title in
                let state = scene.rail[index]
                HStack(spacing: Spacing.regular) {
                    railMark(state)
                    Text(title).font(.callout).foregroundStyle(state == .todo ? .secondary : .primary)
                    Spacer(minLength: Spacing.small)
                    if let word = railWord(state) { Text(word).font(.caption2).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, Spacing.regular)
                .padding(.vertical, Spacing.compact)
                .kitRow(isSelected: state == .current)
            }
        }
    }

    private func railMark(_ state: RailState) -> some View {
        switch state {
        case .done, .reused: MockMarkView(mark: .done)
        case .skipped: MockMarkView(mark: .skipped)
        case .current, .todo: MockMarkView(mark: .waiting)
        }
    }

    private func railWord(_ state: RailState) -> String? {
        switch state {
        case .done: Copy.railDone
        case .reused: Copy.railReused
        case .skipped: Copy.railSkipped
        case .current, .todo: nil
        }
    }
}

@MainActor
enum CompanyWizardScenes {
    private static let close = MockButton(title: Copy.close, kind: .quiet)
    private static let skip = MockButton(title: Copy.skipStep, kind: .quiet)
    private static let back = MockButton(title: Copy.back)

    static func footer(
        _ primary: String = Copy.continueStep,
        disabled: Bool = false,
        skip canSkip: Bool = true,
        extra: MockButton? = nil
    ) -> MockBlock {
        var trailing: [MockButton] = canSkip ? [skip] : []
        trailing.append(extra ?? back)
        trailing.append(MockButton(title: primary, kind: .primary, disabled: disabled))
        return .buttons(leading: [close], trailing: trailing)
    }

    private static func notFound(_ empty: String?, hint: String) -> [MockBlock] {
        var blocks: [MockBlock] = []
        if let empty { blocks.append(.caption(empty)) }
        blocks += [
            .choices([MockChoice(title: Copy.createNew, detail: Copy.createNewDetail, selected: true),
                      MockChoice(title: Copy.alreadyHaveOne, detail: Copy.alreadyHaveDetail, selected: false)]),
            .caption(hint),
            footer()
        ]
        return blocks
    }

    private static let slackToken: [MockBlock] = [
        .body(Copy.slackTokenStep1),
        .caption(Copy.slackTokenHelp),
        .buttons(leading: [MockButton(title: Copy.openTokenPage)], trailing: []),
        .body(Copy.slackTokenStep2),
        .fields([MockField(label: Copy.tokenPlaceholder, value: "xoxe.xoxp-1-sample-token", secure: true)], error: nil),
        .caption(Copy.tokenNote)
    ]

    private static let dropped = MockBlock.drop(Copy.droppedJSON)
    private static let googleGuide = MockBlock.guide(Copy.googleGuide, extras: [:])
    private static let atlassianGuide = MockBlock.guide(Copy.atlassianGuide, extras: [1: Copy.copyScopes, 2: Copy.copyCallbacks])
    private static let atlassianFields = MockBlock.fields([
        MockField(label: Copy.clientID, value: "9f3a8d0e4b7c21"),
        MockField(label: Copy.clientSecret, value: "sample-secret", secure: true)
    ], error: nil)

    private static let publishRail: [RailState] = [.reused, .done, .done, .skipped, .done, .done, .current]
    private static let allDone: [RailState] = [.reused, .done, .done, .skipped, .done, .done, .done]

    private static var publishSummary: MockBlock {
        .steps(Copy.publishSummary.enumerated().map { index, line in
            MockStep(title: line, mark: index == 3 ? .skipped : .done)
        }, caption: nil)
    }

    static var scenes: [WizardScene] {
        slackScenes + googleScenes + laterScenes + publishScenes
    }

    private static var slackScenes: [WizardScene] {
        [
            WizardScene("looking", step: 0, [.busy(Copy.lookingSlack), footer(disabled: true)]),
            WizardScene("slack-notFound", step: 0, notFound(nil, hint: Copy.notSureSlack)),
            WizardScene("slack-found", step: 0, [
                .caption(Copy.foundTitle),
                .choices([MockChoice(title: Copy.foundSlackApp, detail: Copy.foundSlackSource, selected: true)]),
                .caption(Copy.reuseCaption),
                footer(Copy.useSlackApp, extra: MockButton(title: Copy.createNew))
            ]),
            WizardScene("slack-create", step: 0, slackToken + [footer(Copy.createApp)]),
            WizardScene("slack-existing", step: 0, [
                .choices([MockChoice(title: Copy.alreadyHaveOne, detail: Copy.alreadyHaveDetail, selected: true)]),
                .fields([MockField(label: Copy.slackSettingsLink, value: "https://acme.slack.com/apps")],
                        error: Copy.slackSettingsInvalid),
                .caption(Copy.slackSettingsHelp),
                footer(disabled: true)
            ]),
            WizardScene("slack-progress", step: 0, [
                .steps([MockStep(title: Copy.slackReuseSteps[0], mark: .done),
                        MockStep(title: Copy.slackReuseSteps[1], mark: .running),
                        MockStep(title: Copy.slackReuseSteps[2], mark: .waiting)],
                       caption: Copy.slackProgressCaption),
                footer(disabled: true, skip: false)
            ]),
            WizardScene("slack-manifestDiff", step: 0, [
                .notice(MockNotice(icon: "arrow.triangle.2.circlepath", tone: Tone.status("blue"),
                                   title: Copy.manifestDiffTitle, body: Copy.manifestDiffBody)),
                .steps(Copy.manifestDiffLines.map { MockStep(title: $0, mark: .waiting) }, caption: nil),
                footer(Copy.updateApp, skip: false)
            ]),
            WizardScene("slack-notCollaborator", step: 0, [.problem(Copy.notCollaborator, nil), footer(Copy.tryAgain)]),
            WizardScene("slack-wrongWorkspace", step: 0, [
                .fields([MockField(label: Copy.slackSettingsLink, value: Copy.slackSettingsValue)], error: nil),
                .problem(Copy.wrongWorkspace, nil),
                footer(Copy.tryAgain)
            ]),
            WizardScene("slack-badToken", step: 0, slackToken + [.problem(Copy.badToken, nil), footer(Copy.tryAgain)])
        ]
    }

    private static var googleScenes: [WizardScene] {
        let rail: [RailState] = [.reused, .current, .todo, .todo, .todo, .todo, .todo]
        return [
            WizardScene("google-notFound", step: 1, rail: rail, notFound(Copy.notFoundGoogle, hint: Copy.notSureGoogle)),
            WizardScene("google-found", step: 1, rail: rail, [
                .caption(Copy.foundTitle),
                .choices([MockChoice(title: Copy.foundGoogleA, detail: Copy.foundGoogleASource, selected: true),
                          MockChoice(title: Copy.foundGoogleB, detail: Copy.foundGoogleBSource, selected: false)]),
                .caption(Copy.googleReuseCaption),
                footer(Copy.useSelected, extra: MockButton(title: Copy.createNew))
            ]),
            WizardScene("google-reuseSecret", step: 1, rail: rail, [
                .choices([MockChoice(title: Copy.foundGoogleA, detail: Copy.foundGoogleASource, selected: true)]),
                .caption(Copy.reuseSecretBody),
                .buttons(leading: [MockButton(title: Copy.openClient)], trailing: []),
                .fields([MockField(label: Copy.clientSecret, value: "", secure: true)], error: nil),
                footer(disabled: true)
            ]),
            WizardScene("google-create", step: 1, rail: rail, [googleGuide, .drop(nil), footer(disabled: true)]),
            WizardScene("google-checking", step: 1, rail: rail, [googleGuide, dropped, .busy(Copy.checkingGoogle),
                                                                 footer(disabled: true)]),
            WizardScene("google-checkFailed", step: 1, rail: rail, [
                googleGuide, dropped, .problem(Copy.googleRejected, MockButton(title: Copy.tryAgain)), footer(disabled: true)
            ])
        ]
    }

    private static var laterScenes: [WizardScene] {
        let atlassianRail: [RailState] = [.reused, .done, .current, .todo, .todo, .todo, .todo]
        return [
            WizardScene("atlassian-create", step: 2, rail: atlassianRail, [atlassianGuide, atlassianFields, footer()]),
            WizardScene("atlassian-confirm", step: 2, rail: atlassianRail, [
                .body(Copy.confirmTitle),
                .caption(Copy.confirmBody),
                .checks(Copy.confirmChecks.enumerated().map { index, title in
                    MockCheck(title: title, checked: index < 2, trailing: Copy.open)
                }),
                footer(disabled: true)
            ]),
            WizardScene("resume", step: 2, rail: [.reused, .skipped, .current, .todo, .todo, .todo, .todo], resume: true,
                        [atlassianGuide, atlassianFields, footer()]),
            WizardScene("linear-create", step: 3, rail: [.reused, .done, .done, .current, .todo, .todo, .todo], [
                .guide(Copy.linearGuide, extras: [1: Copy.copyCallback]),
                .fields([MockField(label: Copy.clientID, value: "")], error: nil),
                .caption(Copy.linearNote),
                .caption(Copy.linearSkipped),
                footer(disabled: true)
            ]),
            WizardScene("microsoft-create", step: 4, rail: [.reused, .done, .done, .skipped, .current, .todo, .todo], [
                .guide(Copy.microsoftGuide, extras: [2: Copy.copyPermissions]),
                .fields([MockField(label: Copy.microsoftClientID, value: "4b1e0c9d-0000-4f00-a000-00000000077a"),
                         MockField(label: Copy.microsoftTenantID, value: "0000-acme")], error: nil),
                .caption(Copy.microsoftNote),
                .caption(Copy.microsoftSkipped),
                footer()
            ]),
            WizardScene("microsoft-checkFailed", step: 4, rail: [.reused, .done, .done, .skipped, .current, .todo, .todo], [
                .fields([MockField(label: Copy.microsoftClientID, value: "4b1e0c9d-0000-4f00-a000-00000000077a"),
                         MockField(label: Copy.microsoftTenantID, value: "0000-acme")], error: nil),
                .problem(Copy.microsoftRejected, MockButton(title: Copy.tryAgain)),
                footer(disabled: true)
            ]),
            WizardScene("denyList", step: 5, rail: [.reused, .done, .done, .skipped, .done, .current, .todo], [
                .caption(Copy.denyBody),
                .fields([MockField(label: Copy.addHost, value: "")], error: nil),
                .values(Copy.denyHosts.map { MockValue(label: "", value: $0, button: "Remove") }),
                footer()
            ]),
            WizardScene("denyList-invalid", step: 5, rail: [.reused, .done, .done, .skipped, .done, .current, .todo], [
                .caption(Copy.denyBody),
                .fields([MockField(label: Copy.addHost, value: "https://intranet.example.com/home")], error: Copy.denyInvalid),
                footer()
            ])
        ]
    }

    private static var publishScenes: [WizardScene] {
        let token = MockField(label: Copy.tokenPlaceholder, value: "xoxe.xoxp-1-fresh-token", secure: true)
        return [
            WizardScene("publish-ready", step: 6, rail: publishRail, [
                .fields([MockField(label: Copy.companyName, value: "Acme")], error: nil),
                .caption(Copy.companyNameHelp),
                publishSummary,
                .caption(Copy.publishCaption),
                footer(Copy.publish, skip: false)
            ]),
            WizardScene("publish-busy", step: 6, rail: publishRail, [
                .steps([MockStep(title: Copy.publishSteps[0], mark: .done),
                        MockStep(title: Copy.publishSteps[1], mark: .running)], caption: nil),
                footer(Copy.publish, disabled: true, skip: false)
            ]),
            WizardScene("publish-done", step: 6, rail: allDone, publishedBlocks(Copy.publishedBody)),
            WizardScene("publish-done-noSlack", step: 6, rail: [.skipped, .done, .done, .skipped, .done, .done, .done],
                        publishedBlocks(Copy.publishedNoSlack)),
            WizardScene("publish-tokenExpired", step: 6, rail: publishRail, [
                .problem(Copy.publishTokenExpired, nil),
                .buttons(leading: [MockButton(title: Copy.openTokenPage)], trailing: []),
                .fields([token], error: nil),
                footer(Copy.tryAgain, skip: false)
            ]),
            WizardScene("publish-failed", step: 6, rail: publishRail, [
                publishSummary, .problem(Copy.publishFailed, nil), footer(Copy.tryAgain, skip: false)
            ])
        ]
    }

    static func publishedBlocks(_ body: String) -> [MockBlock] {
        [
            .success(Copy.publishedTitle, body),
            .values([MockValue(label: Copy.linkLabel, value: Copy.linkValue, button: Copy.copy),
                     MockValue(label: Copy.codeLabel, value: Copy.codeValue, button: Copy.copy),
                     MockValue(label: Copy.profileLabel, value: Copy.profileValue, button: Copy.saveProfile)]),
            .buttons(leading: [MockButton(title: Copy.itGuideLink, kind: .quiet)], trailing: []),
            .buttons(leading: [], trailing: [MockButton(title: Copy.done), MockButton(title: Copy.connectThisMac, kind: .primary)])
        ]
    }
}

// MARK: - The employee: confirm, chain, replace (spec §3)

@MainActor
enum CompanyConnectScenes {
    private static func vendorChecks(connected: Set<Int> = []) -> MockBlock {
        .checks(Copy.vendorRows.enumerated().map { index, row in
            connected.contains(index)
                ? MockCheck(title: row.0, detail: row.1, checked: true, disabled: true, trailing: Copy.alreadyConnected)
                : MockCheck(title: row.0, detail: row.1)
        })
    }

    private static let connectButtons = MockBlock.buttons(
        leading: [], trailing: [MockButton(title: Copy.cancel), MockButton(title: Copy.connect, kind: .primary)])

    private static func chain(_ marks: [MockMark], _ details: [String?]) -> MockBlock {
        .steps(Copy.vendorRows.enumerated().map { index, row in
            MockStep(title: row.0, mark: marks[index], detail: details[index])
        }, caption: Copy.chainCaption)
    }

    private static let chainButtons = MockBlock.buttons(
        leading: [], trailing: [MockButton(title: Copy.stop), MockButton(title: Copy.skipService)])

    static var scenes: [(String, [MockBlock])] {
        [
            ("confirm", [.title(Copy.confirmConnectTitle, nil), .body(Copy.confirmLinkBody), vendorChecks(),
                         .caption(Copy.confirmCaption), connectButtons]),
            ("confirm-code", [.title(Copy.confirmConnectTitle, nil), .body(Copy.confirmCodeBody), vendorChecks(),
                              .caption(Copy.confirmCaption), connectButtons]),
            ("confirm-again", [.title(Copy.confirmConnectTitle, nil), .body(Copy.confirmLinkBody),
                               vendorChecks(connected: [0, 1]), .caption(Copy.confirmCaption), connectButtons]),
            ("confirm-mdm", [.title(Copy.mdmTitle, nil), .managedBadge, .body(Copy.mdmBody), vendorChecks(),
                             .caption(Copy.confirmCaption), connectButtons]),
            ("chain", [.title(Copy.chainTitle, nil),
                       chain([.done, .running, .waiting, .waiting, .waiting],
                             [Copy.chainSlackDone, Copy.chainBrowserGoogle, Copy.chainNext, nil, nil]),
                       chainButtons]),
            ("chain-failed", [.title(Copy.chainTitle, nil),
                              chain([.done, .failed, .running, .waiting, .waiting],
                                    [Copy.chainSlackDone, Copy.chainDenied, Copy.chainBrowserAtlassian, Copy.chainNext, nil]),
                              chainButtons]),
            ("done", [.title(Copy.chainDonePartial, nil),
                      .steps([MockStep(title: Copy.vendorRows[0].0, mark: .done),
                              MockStep(title: Copy.vendorRows[1].0, mark: .failed, detail: Copy.notConnected),
                              MockStep(title: Copy.vendorRows[2].0, mark: .done),
                              MockStep(title: Copy.vendorRows[3].0, mark: .done),
                              MockStep(title: Copy.vendorRows[4].0, mark: .skipped, detail: Copy.chainSkipped)], caption: nil),
                      .body(Copy.chainDoneBody),
                      .buttons(leading: [], trailing: [MockButton(title: Copy.done, kind: .primary)])]),
            ("replace", [.warning(Copy.replaceBody, title: Copy.replaceTitle),
                         .steps(Copy.replaceLines.map { MockStep(title: $0, mark: .waiting) }, caption: Copy.replaceCaption),
                         .buttons(leading: [], trailing: [MockButton(title: Copy.replace),
                                                          MockButton(title: Copy.keepCurrent, kind: .primary)])])
        ]
    }
}

/// The loopback listener's browser pages (Go `internal/oauthpage`), drawn
/// in its card layout: icon, heading, message, hint.
struct BrowserPageMock: View {
    let icon: String
    let tone: Color
    let heading: String
    let message: String
    var hint: String?

    var body: some View {
        VStack(spacing: Spacing.medium) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(tone)
            Text(heading).font(.title2.weight(.semibold))
            Text(message).font(.body).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.wide)
        .frame(maxWidth: PaneWidth.narrowPage)
        .card()
        .padding(Spacing.hero)
        .frame(maxWidth: .infinity)
        .detailBackground()
    }
}
