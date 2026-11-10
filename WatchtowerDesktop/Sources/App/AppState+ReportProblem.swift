import AppKit
import WatchtowerCore

/// Help → Report a Problem… and Settings → System → Logs (#1527): one sheet on
/// the main window over `ReportProblemModel`.
extension AppState {
    /// Fronts the main window (opening one when none is visible, so the sheet
    /// never lands behind Settings or nowhere), then presents the sheet. A
    /// second call while it is shown keeps the same model: the one presented
    /// sheet comes forward with its text, and no second collection starts.
    func reportProblem(
        windows: [NSWindow]? = nil,
        activate: () -> Void = ActivationPolicyDecision.becomeRegularAndActivate,
        runner: any CLIRunnerProtocol = AppState.reportProblemRunner(),
        buildFlavor: String? = Bundle.main.object(forInfoDictionaryKey: "WTBuildFlavor") as? String
    ) {
        bringMainWindowForward(windows: windows, activate: activate)
        guard reportProblemModel == nil else { return }
        let model = ReportProblemModel(
            runner: runner,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            macOS: Self.reportProblemMacOS(ProcessInfo.processInfo.operatingSystemVersion),
            iPhoneOn: Self.reportProblemIPhoneOn(
                hubState: hubCenter?.status?.state,
                mobileSyncMode: managedPolicy.policy.mobileSyncMode
            ),
            isCorp: Self.isCorpBuild(buildFlavor),
            openURL: { NSWorkspace.shared.open($0) },
            writePasteboard: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        )
        reportProblemModel = model
        model.start()
    }

    /// Every way the sheet goes away (Cancel, Done, Esc, the window closing):
    /// stops a running collection — the runner terminates the child — and
    /// keeps nothing. Only the model on screen is dropped, so a late
    /// `onDisappear` of a closed sheet never takes a newer one with it.
    func closeReportProblem(_ model: ReportProblemModel) {
        model.cancel()
        if reportProblemModel === model { reportProblemModel = nil }
    }

    /// The installed CLI, or one that reports it missing (the sheet then
    /// shows "the watchtower command is missing" and the partial lines).
    nonisolated static func reportProblemRunner() -> any CLIRunnerProtocol {
        ProcessCLIRunner.makeDefault() ?? MissingCLIRunner()
    }

    /// `--iphone on` only while the Go hub serves Mobile (its status is
    /// anything but `off`) and the organization's `MobileSync` allows it.
    /// No status yet reads as off: the report never claims a companion the
    /// app has not seen.
    nonisolated static func reportProblemIPhoneOn(hubState: String?, mobileSyncMode: String) -> Bool {
        guard mobileSyncMode != "off", let hubState else { return false }
        return hubState != "off"
    }

    /// `macOS <x.y>` of the partial lines and the link.
    nonisolated static func reportProblemMacOS(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion)"
    }
}

/// No `watchtower` binary found: every run fails as missing.
private struct MissingCLIRunner: CLIRunnerProtocol {
    func run(args: [String]) async throws -> Data {
        throw CLIRunnerError.binaryNotFound
    }
}
