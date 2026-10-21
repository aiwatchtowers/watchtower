import Foundation
import Observation

/// The template panel (spec A3): a template's params, its recipe files as
/// `install-template --render` renders and validates them (nothing written),
/// and **Save and Turn On** — install with the rendered params, then confirm
/// and turn on each installed copy. A copy is confirmed only when its
/// `approval_hash` equals the rendered file's, the hash the panel showed
/// (AUTO-06); the first copy that differs stops the flow, and that copy and
/// every later one stay unconfirmed and off. Nothing is rolled back: a copy
/// left unconfirmed is reviewed from its card.
///
/// Owned by `AppState` through `AutomationTemplatePanels`, so an install
/// started in the panel finishes when the panel goes away.
@MainActor
@Observable
package final class AutomationTemplatePanelModel {
    package enum State: Equatable, Sendable {
        case rendering
        case rendered(AutomationsCLI.RenderResult)
        case failed(String)
        case installing
        case done(firstID: Int64)
        /// Installed (`ids`), but not every copy is confirmed and on.
        case stopped(String, ids: [Int64])
    }

    nonisolated package static let differs =
        "This copy differs from what was shown — review it before confirming."
    nonisolated package static let multiFileCaption = "Install it, then edit each one."
    nonisolated package static func notInstalled(_ message: String) -> String { "Not installed: \(message)" }
    nonisolated package static func notConfirmed(_ message: String) -> String {
        "Installed, but not confirmed: \(message)"
    }

    nonisolated package static func notTurnedOn(_ message: String) -> String {
        "Installed and confirmed, but not turned on: \(message)"
    }

    package let template: AutomationTemplate
    package let scope: AutomationScopeChoice
    /// The owner's param values by key; an empty value leaves the choice to
    /// the CLI (the field's placeholder is the param's `example`).
    package var params: [String: String] = [:]
    package private(set) var state: State = .rendering
    /// One column per rendered file, in the render's order; each says
    /// "Checking…" while `isRendering`.
    package private(set) var columns: [AutomationDraftColumnModel] = []
    /// The shown render's files (their slugs title the columns), the source
    /// of `columns`.
    package private(set) var renderedFiles: [AutomationsCLI.RenderedFile] = []
    /// A render newer than the shown one is pending (debounced or running).
    package private(set) var isRendering = false {
        didSet { if isRendering != oldValue { rebuildColumns() } }
    }

    @ObservationIgnored private let cli: AutomationsCLI
    @ObservationIgnored private let refresh: @MainActor (Int64?) async -> Void
    @ObservationIgnored private let checkDelay: Duration
    @ObservationIgnored private let sleep: (Duration) async -> Void
    /// The params the shown render was asked for (empty values dropped).
    @ObservationIgnored private var renderedRequest: [String: String]?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    /// Bumped by every render: only the newest render's result is shown.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hasRendered = false

    /// `refresh` re-reads the list (and the first installed copy's card)
    /// after an install; `sleep` is the param debounce's wait (a test seam).
    package init(
        template: AutomationTemplate,
        scope: AutomationScopeChoice,
        cli: AutomationsCLI,
        refresh: @escaping @MainActor (Int64?) async -> Void,
        checkDelay: Duration = .milliseconds(500),
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.template = template
        self.scope = scope
        self.cli = cli
        self.refresh = refresh
        self.checkDelay = checkDelay
        self.sleep = sleep
    }

    /// Whether the panel is past rendering: an install ran or is running.
    private var isInstallingOrInstalled: Bool {
        switch state {
        case .installing, .done, .stopped: true
        case .rendering, .rendered, .failed: false
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// **Save and Turn On** is on: a render of exactly the params shown,
    /// every file valid with every hashed field shown (AUTO-06).
    package var canSave: Bool {
        guard case let .rendered(result) = state, !result.files.isEmpty else { return false }
        return result.files.allSatisfy(\.validate.showsAllFields) && renderedRequest == Self.normalized(params)
    }

    /// **Adjust in Chat** is offered for a one-file template only; a
    /// multi-file one shows `multiFileCaption` instead.
    package var canAdjustInChat: Bool { columns.count == 1 }

    /// The single rendered file's text, for **Adjust in Chat**.
    package var adjustText: String? { canAdjustInChat ? columns.first?.recipeText : nil }

    /// The panel appeared: renders once (again after a failure).
    package func appear() async {
        if hasRendered, !isFailed { return }
        await render()
    }

    /// A param field changed: renders `checkDelay` after the edits stop.
    package func paramsChanged() {
        guard !isInstallingOrInstalled else { return }
        renderTask?.cancel()
        // A render in flight is of the old params: its result is dropped.
        generation += 1
        isRendering = true
        let delay = checkDelay
        let sleep = sleep
        renderTask = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            renderTask = nil
            await render()
        }
    }

    /// Renders and validates the template with the params as they are now.
    package func render() async {
        guard !isInstallingOrInstalled else { return }
        renderTask?.cancel()
        renderTask = nil
        hasRendered = true
        generation += 1
        let mine = generation
        let request = Self.normalized(params)
        isRendering = true
        if renderedRequest == nil { state = .rendering }
        let outcome: Result<AutomationsCLI.RenderResult, Error>
        do {
            outcome = try await .success(cli.renderTemplate(template.name, workbenchID: scope.workbenchID,
                                                            params: request))
        } catch {
            outcome = .failure(error)
        }
        guard mine == generation, !isInstallingOrInstalled else { return }
        switch outcome {
        case let .success(result):
            renderedRequest = request
            renderedFiles = result.files
            state = .rendered(result)
        case let .failure(error):
            renderedRequest = nil
            renderedFiles = []
            state = .failed(AutomationsViewModel.message(for: error))
        }
        if isRendering { isRendering = false } else { rebuildColumns() }
    }

    private func rebuildColumns() {
        let checking = isRendering
        columns = renderedFiles.map {
            AutomationDraftColumnModel(text: $0.text, validated: $0.validate, isChecking: checking,
                                       newestChatEntry: nil, confirmedText: nil, isNew: true, plan: nil)
        }
    }

    /// **Save and Turn On**: installs with the rendered params, then for
    /// each installed copy in order confirms the hash the panel showed and
    /// turns it on. Runs once: a stopped or finished install never installs
    /// again.
    package func saveAndTurnOn() async {
        guard canSave, case let .rendered(shown) = state else { return }
        renderTask?.cancel()
        renderTask = nil
        isRendering = false
        state = .installing
        let installParams = shown.params.mapValues { $0.joined(separator: ",") }
        let installed: [AutomationsCLI.InstalledRecipe]
        do {
            installed = try await cli.installTemplate(template.name, workbenchID: scope.workbenchID,
                                                      params: installParams).installed
        } catch {
            renderedRequest = nil
            state = .failed(Self.notInstalled(AutomationsViewModel.message(for: error)))
            await refresh(nil)
            return
        }
        let ids = installed.map(\.automationID)
        state = await confirmAndEnable(installed, shown: shown.files)
        await refresh(ids.first)
    }

    /// Confirms and turns on each copy whose hash is the shown one; the
    /// first copy that differs, or the first failure, stops it.
    private func confirmAndEnable(_ installed: [AutomationsCLI.InstalledRecipe],
                                  shown: [AutomationsCLI.RenderedFile]) async -> State {
        let ids = installed.map(\.automationID)
        // An older CLI reports no copies: nothing can be matched to what was shown.
        guard let first = ids.first, installed.count == shown.count else {
            return .stopped(Self.differs, ids: ids)
        }
        for (copy, file) in zip(installed, shown) {
            let hash = file.validate.approvalHash
            guard !hash.isEmpty, copy.approvalHash == hash else { return .stopped(Self.differs, ids: ids) }
            do {
                try await cli.confirm(copy.automationID, hash: hash)
            } catch {
                return .stopped(Self.notConfirmed(AutomationsViewModel.message(for: error)), ids: ids)
            }
            do {
                try await cli.setEnabled(copy.automationID, true)
            } catch {
                return .stopped(Self.notTurnedOn(AutomationsViewModel.message(for: error)), ids: ids)
            }
        }
        return .done(firstID: first)
    }

    /// Params as the CLI receives them: empty values left to its choice.
    private static func normalized(_ params: [String: String]) -> [String: String] {
        params.filter { !$0.value.isEmpty }
    }
}

/// The template panels by `"<template>|<scope>"`, owned by `AppState` so a
/// panel (and an install it started) survives navigation.
@MainActor
package final class AutomationTemplatePanels {
    private var panels: [String: AutomationTemplatePanelModel] = [:]

    private let make: @MainActor (AutomationTemplate, AutomationScopeChoice)
        -> AutomationTemplatePanelModel

    package init(make: @escaping @MainActor (AutomationTemplate, AutomationScopeChoice)
        -> AutomationTemplatePanelModel) {
        self.make = make
    }

    nonisolated package static func key(template: String, scope: AutomationScopeChoice) -> String {
        switch scope {
        case .personal: "\(template)|personal"
        case let .workbench(id, _, _): "\(template)|workbench:\(id)"
        }
    }

    /// **Continue** on a template in the New automation panel: the panel
    /// for `template` in `scope`, a fresh one when the last one finished
    /// (`.done`), so the same template can be added again.
    package func start(_ template: AutomationTemplate, scope: AutomationScopeChoice)
        -> AutomationTemplatePanelModel {
        let key = Self.key(template: template.name, scope: scope)
        if let panel = panels[key], case .done = panel.state { panels[key] = nil }
        return panel(for: template, scope: scope)
    }

    /// The panel for `template` in `scope`, made on first use; kept as it
    /// is (a finished one too) until `start` is called again.
    package func panel(for template: AutomationTemplate, scope: AutomationScopeChoice)
        -> AutomationTemplatePanelModel {
        let key = Self.key(template: template.name, scope: scope)
        if let panel = panels[key] { return panel }
        let panel = make(template, scope)
        panels[key] = panel
        return panel
    }
}
