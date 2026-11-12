import AppKit
import WatchtowerCore
import WebKit

/// Print… for an html or document artifact: the standard print panel, whose
/// PDF menu is the PDF export. The page is laid out in an offscreen web view
/// made exactly like `SandboxedHTMLView` (same content rules — no network —,
/// no bridge, links open nothing); printing turns nothing on (CHAT-05).
/// Each job keeps itself alive until the panel is dismissed.
@MainActor
final class ArtifactPrinter: NSObject {
    private static var jobs: Set<ArtifactPrinter> = []
    /// The layout size the page is laid out at before printing. WebKit
    /// paginates from the view's width (a zero-size view prints blank
    /// pages); horizontal pagination is `.fit`, so this width is scaled to
    /// the paper's printable width. 540 pt is US Letter (612 pt) less two
    /// half-inch margins, near A4's 595 pt less the same (523 pt); the
    /// height only has to be non-zero (vertical pagination is automatic).
    private static let pageFrame = NSRect(x: 0, y: 0, width: 540, height: 760)

    private let coordinator: SandboxedHTMLView.Coordinator
    private let title: String
    private let onError: (String) -> Void
    private var webView: WKWebView?
    private var started = false
    /// Finishes the job when the page never finishes loading.
    private var loadTimeout: Task<Void, Never>?
    private let loadTimeoutDuration: Duration
    /// How the load timeout waits (tests: a wait they end by hand).
    private let sleep: @Sendable (Duration) async -> Void

    /// `coordinator` and `sleep` are for tests (a load that never finishes,
    /// a timeout that passes when the test says so).
    init(
        title: String,
        coordinator: SandboxedHTMLView.Coordinator? = nil,
        loadTimeout: Duration = .seconds(15),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        onError: @escaping (String) -> Void
    ) {
        self.title = title
        self.coordinator = coordinator ?? SandboxedHTMLView.Coordinator()
        self.loadTimeoutDuration = loadTimeout
        self.sleep = sleep
        self.onError = onError
    }

    /// The load-timeout task, kept after the job ends so a test can await it.
    var loadTimeoutTask: Task<Void, Never>? { loadTimeout }

    /// Opens the print panel on `window` for `draft`; nothing happens for an
    /// artifact that cannot be printed (`ArtifactPrint.canPrint`).
    static func print(_ draft: ArtifactDraft, window: NSWindow?, onError: @escaping (String) -> Void) {
        guard let page = ArtifactPrint.printPage(for: draft) else { return }
        guard let window else {
            artifactExportLog.error("Print failed: no window to show the print panel in")
            return onError("Print failed: no window to show the print panel in.")
        }
        start(ArtifactPrinter(title: draft.title, onError: onError), .page(page), window: window)
    }

    /// Keeps `job` alive and loads `content` for the print panel on
    /// `window`. Internal so a test can start a job made its own way.
    static func start(_ job: ArtifactPrinter, _ content: SandboxedHTMLContent, window: NSWindow) {
        jobs.insert(job)
        job.start(content, window: window)
    }

    /// The job is still kept alive (tests: every way a job ends drops it).
    static func isRunning(_ job: ArtifactPrinter) -> Bool { jobs.contains(job) }

    private func start(_ content: SandboxedHTMLContent, window: NSWindow) {
        webView = SandboxedHTMLView.makeWebView(coordinator: coordinator, frame: Self.pageFrame)
        coordinator.onLoaded = { [weak self, weak window] webView in
            guard let self else { return }
            guard let window else { // the chat closed meanwhile
                artifactExportLog.notice("Print dropped: the window closed before the page loaded")
                return self.finish(error: nil)
            }
            self.run(webView, window: window)
        }
        coordinator.onFailed = { [weak self] message in
            guard let self else { return }
            guard !self.started else { // the print panel is up; its run ends the job
                return artifactExportLog.error("Print page failed under the print panel: \(message, privacy: .public)")
            }
            self.finish(error: "Print failed: \(message)")
        }
        coordinator.show(content, token: 0)
        loadTimeout = Task { [weak self, loadTimeoutDuration, sleep] in
            await sleep(loadTimeoutDuration)
            guard !Task.isCancelled, let self, !self.started else { return }
            self.finish(error: "Print failed: the page did not finish loading.")
        }
    }

    private func run(_ webView: WKWebView, window: NSWindow) {
        guard !started else { return }
        started = true
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.jobTitle = title // the PDF's default file name
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // The operation's view must have a size, or the pages come out blank.
        operation.view?.frame = webView.bounds
        // WebKit prints asynchronously: only the sheet-modal run produces pages.
        operation.runModal(
            for: window, delegate: self,
            didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil
        )
    }

    @objc private func printOperationDidRun(
        _ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
        // false also when the owner cancelled the panel: no notice for it.
        if !success { artifactExportLog.notice("Print operation ended without printing (cancelled or failed)") }
        finish(error: nil)
    }

    private func finish(error: String?) {
        if let error {
            artifactExportLog.error("\(error, privacy: .public)")
            onError(error)
        }
        loadTimeout?.cancel()
        coordinator.cancel()
        coordinator.onLoaded = nil
        coordinator.onFailed = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        Self.jobs.remove(self)
    }
}
