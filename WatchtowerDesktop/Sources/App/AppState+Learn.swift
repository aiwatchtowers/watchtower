import AppKit
import GRDB
import WatchtowerCore

extension AppState {
    /// Starts Home's Learn zone on the open database. The version memory is
    /// per workspace (the database's folder), like the seen rows.
    func startLearn(pool: DatabasePool) {
        let workspace = URL(fileURLWithPath: pool.path).deletingLastPathComponent().lastPathComponent
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let newAfter = LearnVersionPolicy(workspace: workspace)
            .newAfter(currentVersion: version, onboardingFinished: learnOnboardingFinishedAtLaunch, now: Date())
        learnCenter.start(pool: pool, newAfter: newAfter)
    }

    /// The Learn zone's actions for `HomeContent`.
    var learnZoneActions: LearnZoneActions {
        LearnZoneActions(
            primary: { [weak self] in self?.pressLearnPrimary($0) },
            gotIt: { [weak self] id in Task { await self?.learnCenter.gotIt(id) } },
            readMore: { [weak self] in self?.openLearnGuide($0) },
            ask: { [weak self] in self?.openHelpChat(prefill: $0.askPrompt) },
            showAgain: { [weak self] id in Task { await self?.learnCenter.showAgain(id) } })
    }

    /// A card's main button: the card is recorded `action`, then the action
    /// runs (a hotkey card only shows its key).
    func pressLearnPrimary(_ pick: LearnPick) {
        Task { await learnCenter.recordAction(pick.id) }
        switch LearnPrimary(pick) {
        case .nav(let screen): openNavLink(NavLink.url(screen))
        case .connect(let source): openAccountConnection(source: LearnPrimary.connectionService(source))
        case .turnOn(let featureID): Task { await turnOnFeatureFromEmptyState(featureID) }
        case .chat(let prompt): openHelpChat(prefill: prompt)
        case .hotkey: break
        case .readMore: openLearnGuide(pick.card)
        }
    }

    /// Read more: the card's guide section in the browser.
    func openLearnGuide(_ card: LearnCard) {
        guard let url = card.guideURL else { return }
        NSWorkspace.shared.open(url)
    }
}
