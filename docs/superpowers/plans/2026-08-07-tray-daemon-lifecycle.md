# Tray + Daemon Lifecycle + CLI Binary Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Menu-bar tray with open/quit, opinionated daemon lifecycle (close→tray, Cmd+Q→full quit with daemon stop, login autostart to tray), and an out-of-bundle CLI binary store so rebuilds never break live processes.

**Architecture:** All-Swift, zero Go changes. A `MenuBarExtra` scene plus an `NSApplicationDelegateAdaptor` own the lifecycle; a new `CLIBinaryStore` service keeps a SHA256-verified copy of the CLI in Application Support and `Constants.findCLIPath()` resolves to it; quit routes through `applicationShouldTerminate` → bounded `sync stop`.

**Tech Stack:** SwiftUI (macOS 14), AppKit delegate, ServiceManagement (`SMAppService.mainApp`), CryptoKit (SHA256), existing `DaemonManager`.

**Spec:** `docs/superpowers/specs/2026-08-07-tray-daemon-lifecycle-design.md` — read it first.

## Global Constraints

- Swift 5.10 language mode, macOS 14 platform floor (`WatchtowerDesktop/Package.swift`); build needs a Swift 6+ toolchain.
- Everything in the repo is English (docs, comments, commits).
- Run tests as `cd WatchtowerDesktop && swift test ...`; capture the real exit code (redirect to a log and check `$?`), never pipe through `tail`, never wrap in the `timeout` binary (breaks xctest arch).
- Go side must not change (`cmd/`, `internal/` untouched).
- House Swift conventions: `docs/review/review-rules.md` "Swift / Desktop conventions".
- Working directory is the worktree `.claude/worktrees/tray-daemon-lifecycle`; never run working-tree-wide git commands (stash/reset/clean); commit only the files you touched.
- The main window is identified by `frameAutosaveName == "WatchtowerMainWindow"` (set in `OpaqueWindowBackground`, `WatchtowerApp.swift`).

---

### Task 1: CLIBinaryStore service

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/CLIBinaryStore.swift`
- Test: `WatchtowerDesktop/Tests/CLIBinaryStoreTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `CLIBinaryStore.storeBinaryPath: String`, `CLIBinaryStore.installedPath: String?`, `CLIBinaryStore.sync(bundleBinary:storeBinary:stopDaemon:) async -> Outcome` with `enum Outcome: Equatable { case installed, upToDate, replaced, failed(String) }`. Task 2 calls `sync` and reads `installedPath`.

- [ ] **Step 1: Write the failing tests**

`WatchtowerDesktop/Tests/CLIBinaryStoreTests.swift`:

```swift
import XCTest
@testable import WatchtowerDesktop

final class CLIBinaryStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ content: String) throws -> String {
        let path = dir.appendingPathComponent(name).path
        try content.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func storePath() -> String {
        // Nested dir that does not exist yet — sync must create it.
        dir.appendingPathComponent("store/bin/watchtower").path
    }

    func testFirstInstallCopiesWithoutStoppingDaemon() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        var stopped = false
        let outcome = await CLIBinaryStore.sync(
            bundleBinary: bundle, storeBinary: store, stopDaemon: { stopped = true })
        XCTAssertEqual(outcome, .installed)
        XCTAssertFalse(stopped, "no store file existed, nothing could be running from it")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: store))
        XCTAssertEqual(try String(contentsOfFile: store, encoding: .utf8), "v1")
    }

    func testMatchingHashIsNoOp() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store, stopDaemon: {})
        var stopped = false
        let outcome = await CLIBinaryStore.sync(
            bundleBinary: bundle, storeBinary: store, stopDaemon: { stopped = true })
        XCTAssertEqual(outcome, .upToDate)
        XCTAssertFalse(stopped)
    }

    func testStaleCopyStopsDaemonAndReplaces() async throws {
        let bundle = try write("bundle-cli", "v2")
        let store = storePath()
        try FileManager.default.createDirectory(
            atPath: (store as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try "v1".data(using: .utf8)!.write(to: URL(fileURLWithPath: store))
        var stopped = false
        let outcome = await CLIBinaryStore.sync(
            bundleBinary: bundle, storeBinary: store, stopDaemon: { stopped = true })
        XCTAssertEqual(outcome, .replaced)
        XCTAssertTrue(stopped, "a stale store copy may back a live daemon — must stop before replacing")
        XCTAssertEqual(try String(contentsOfFile: store, encoding: .utf8), "v2")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: store))
    }

    func testMissingBundleBinaryFailsAndLeavesStoreUntouched() async throws {
        let store = storePath()
        try FileManager.default.createDirectory(
            atPath: (store as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try "v1".data(using: .utf8)!.write(to: URL(fileURLWithPath: store))
        let outcome = await CLIBinaryStore.sync(
            bundleBinary: dir.appendingPathComponent("nope").path,
            storeBinary: store, stopDaemon: {})
        guard case .failed = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertEqual(try String(contentsOfFile: store, encoding: .utf8), "v1")
    }

    func testInstalledPathNilWhenMissing() {
        XCTAssertNil(CLIBinaryStore.installedPath(storeBinary: storePath()))
    }

    func testInstalledPathReturnsExecutableCopy() async throws {
        let bundle = try write("bundle-cli", "v1")
        let store = storePath()
        _ = await CLIBinaryStore.sync(bundleBinary: bundle, storeBinary: store, stopDaemon: {})
        XCTAssertEqual(CLIBinaryStore.installedPath(storeBinary: store), store)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd WatchtowerDesktop && swift test --filter CLIBinaryStoreTests > /tmp/t1.log 2>&1; echo "exit=$?"
```
Expected: `exit=1`, compile error `cannot find 'CLIBinaryStore' in scope`.

- [ ] **Step 3: Implement `CLIBinaryStore`**

`WatchtowerDesktop/Sources/Services/CLIBinaryStore.swift`:

```swift
import Foundation
import CryptoKit

/// Owns the out-of-bundle CLI copy the daemon and all Desktop-spawned CLI
/// processes run from. Rebuilding or updating the app overwrites the bundle
/// binary, and macOS invalidates the code signature of any live process whose
/// backing file changed — so live processes must never run from the bundle.
/// The store copy is replaced only after the daemon is stopped, via an atomic
/// rename, so no process ever runs from a file that gets overwritten.
enum CLIBinaryStore {
    enum Outcome: Equatable {
        case installed   // no copy existed; bundle CLI copied in
        case upToDate    // copy matches the bundle CLI byte-for-byte
        case replaced    // stale copy replaced (daemon stopped first)
        case failed(String)
    }

    /// Default on-disk location of the store copy.
    nonisolated static var storeBinaryPath: String {
        NSString("~/Library/Application Support/Watchtower/bin/watchtower").expandingTildeInPath
    }

    /// The store copy if present and executable, nil otherwise (callers fall
    /// back to the bundle / PATH lookup).
    nonisolated static func installedPath(storeBinary: String = storeBinaryPath) -> String? {
        FileManager.default.isExecutableFile(atPath: storeBinary) ? storeBinary : nil
    }

    /// Bring the store copy in sync with the bundled CLI. `stopDaemon` runs
    /// only when an existing (possibly live) copy is about to be replaced.
    nonisolated static func sync(
        bundleBinary: String,
        storeBinary: String = storeBinaryPath,
        stopDaemon: () async -> Void
    ) async -> Outcome {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: bundleBinary) else {
            return .failed("bundled CLI missing or not executable at \(bundleBinary)")
        }
        guard let bundleHash = sha256(bundleBinary) else {
            return .failed("cannot read bundled CLI at \(bundleBinary)")
        }
        let existing = sha256(storeBinary)
        if existing == bundleHash { return .upToDate }

        let firstInstall = !fm.fileExists(atPath: storeBinary)
        if !firstInstall { await stopDaemon() }

        let storeDir = (storeBinary as NSString).deletingLastPathComponent
        let tmp = storeDir + "/.watchtower-\(ProcessInfo.processInfo.processIdentifier).tmp"
        do {
            try fm.createDirectory(atPath: storeDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: tmp) { try fm.removeItem(atPath: tmp) }
            try fm.copyItem(atPath: bundleBinary, toPath: tmp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp)
        } catch {
            try? fm.removeItem(atPath: tmp)
            return .failed(error.localizedDescription)
        }
        // rename(2) is atomic and re-points the directory entry: even if a
        // straggler still runs from the old inode, that inode's bytes are
        // never modified, so its code signature stays intact.
        guard rename(tmp, storeBinary) == 0 else {
            let err = String(cString: strerror(errno))
            try? fm.removeItem(atPath: tmp)
            return .failed("rename to \(storeBinary) failed: \(err)")
        }
        return firstInstall ? .installed : .replaced
    }

    nonisolated private static func sha256(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd WatchtowerDesktop && swift test --filter CLIBinaryStoreTests > /tmp/t1.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`, 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/CLIBinaryStore.swift WatchtowerDesktop/Tests/CLIBinaryStoreTests.swift
git commit -m "feat(desktop): add CLIBinaryStore — out-of-bundle CLI copy with atomic replace"
```

---

### Task 2: Resolve CLI path via the store + sync on launch

**Files:**
- Modify: `WatchtowerDesktop/Sources/Utilities/Constants.swift:198-212` (`findCLIPath`)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (`initialize()` Task, before the `Task.detached { DatabaseManager.runCLIMigrations() ... }` block; add `cliStoreError` property)

**Interfaces:**
- Consumes: `CLIBinaryStore.sync`, `CLIBinaryStore.installedPath()` (Task 1).
- Produces: `Constants.bundledCLIPath() -> String?`; `Constants.findCLIPath()` now resolves store → bundle → PATH; `AppState.cliStoreError: String?` (read by the tray in Task 5).

- [ ] **Step 1: Split the bundle lookup out of `findCLIPath` and make it store-first**

In `Constants.swift` replace the current `findCLIPath` with:

```swift
    /// The CLI binary shipped inside the app bundle. Live processes must not
    /// run from this path — rebuilds overwrite it (see CLIBinaryStore).
    nonisolated static func bundledCLIPath() -> String? {
        if let bundlePath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("watchtower").path,
           FileManager.default.isExecutableFile(atPath: bundlePath) {
            return bundlePath
        }
        return nil
    }

    /// Resolve the watchtower CLI binary path.
    /// Priority: Application Support store copy → app bundle → resolved PATH.
    nonisolated static func findCLIPath() -> String? {
        if let store = CLIBinaryStore.installedPath() { return store }
        if let bundled = bundledCLIPath() { return bundled }
        return findInPath("watchtower")
    }
```

- [ ] **Step 2: Sync the store at app startup, before any CLI invocation**

In `AppState.swift`, add the stored property next to `errorMessage`:

```swift
    /// Non-nil when the CLI binary store could not be synced this launch —
    /// the app is falling back to the bundle binary (status-quo behavior).
    var cliStoreError: String?
```

In `initialize()`, at the top of the `Task {` block (before `let splashStart = ContinuousClock.now` — the store must be synced before `DatabaseManager.runCLIMigrations()` spawns the CLI):

```swift
            // Sync the out-of-bundle CLI copy before anything spawns the CLI,
            // so migrations, the daemon, and OAuth logins all run from the
            // store, never from the (rebuild-overwritten) bundle binary.
            if let bundled = Constants.bundledCLIPath() {
                let outcome = await CLIBinaryStore.sync(bundleBinary: bundled) {
                    let daemon = DaemonManager()
                    daemon.resolvePathIfNeeded()
                    await daemon.stopDaemon()
                }
                if case .failed(let reason) = outcome {
                    cliStoreError = reason
                    NSLog("CLIBinaryStore: sync failed, falling back to bundle CLI: %@", reason)
                }
            }
```

Note: `swift run` / dev builds without a bundled CLI hit the `bundled == nil` path and keep today's PATH lookup — that is intended.

- [ ] **Step 3: Build + run the full desktop test suite**

```bash
cd WatchtowerDesktop && swift build > /tmp/t2-build.log 2>&1; echo "exit=$?"
cd WatchtowerDesktop && swift test > /tmp/t2-test.log 2>&1; echo "exit=$?"
```
Expected: both `exit=0`.

- [ ] **Step 4: Commit**

```bash
git add WatchtowerDesktop/Sources/Utilities/Constants.swift WatchtowerDesktop/Sources/App/AppState.swift
git commit -m "feat(desktop): resolve CLI path via binary store, sync store on launch"
```

---

### Task 3: Quit flow — QuitCoordinator + bounded daemon stop

**Files:**
- Create: `WatchtowerDesktop/Sources/App/QuitCoordinator.swift`
- Modify: `WatchtowerDesktop/Sources/Services/DaemonManager.swift` (replace `stopDaemonSync` with `stopForQuit`)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift:255-262` (drop `DaemonManager.stopDaemonSync()` from the `willTerminateNotification` observer; keep `terminateProcessesSync()`), and the `ensureDaemonRunning` doc comment at `AppState.swift:415-418` (now paired with the quit flow, not `stopDaemonSync`)
- Test: `WatchtowerDesktop/Tests/QuitCoordinatorTests.swift`

**Interfaces:**
- Consumes: `DaemonManager.runProcess` (existing private helper), `Constants.findCLIPath()`.
- Produces: `QuitCoordinator.shouldTerminate(isCapturing:confirmQuit:stopDaemon:reply:) -> NSApplication.TerminateReply` and `DaemonManager.stopForQuit(timeout:) async`. Task 4's app delegate calls both.

- [ ] **Step 1: Write the failing tests**

`WatchtowerDesktop/Tests/QuitCoordinatorTests.swift`:

```swift
import XCTest
import AppKit
@testable import WatchtowerDesktop

@MainActor
final class QuitCoordinatorTests: XCTestCase {
    func testNotCapturingSkipsConfirmAndTerminatesLater() async {
        var confirmAsked = false
        let stopped = expectation(description: "daemon stopped")
        let replied = expectation(description: "replied true")
        let reply = QuitCoordinator.shouldTerminate(
            isCapturing: false,
            confirmQuit: { confirmAsked = true; return true },
            stopDaemon: { stopped.fulfill() },
            reply: { ok in XCTAssertTrue(ok); replied.fulfill() })
        XCTAssertEqual(reply, .terminateLater)
        XCTAssertFalse(confirmAsked)
        await fulfillment(of: [stopped, replied], timeout: 5)
    }

    func testCapturingCancelBlocksQuitWithoutStopping() {
        var stoppedCalled = false
        let reply = QuitCoordinator.shouldTerminate(
            isCapturing: true,
            confirmQuit: { false },
            stopDaemon: { stoppedCalled = true },
            reply: { _ in XCTFail("must not reply when quit is cancelled") })
        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertFalse(stoppedCalled)
    }

    func testCapturingConfirmedProceeds() async {
        let replied = expectation(description: "replied")
        let reply = QuitCoordinator.shouldTerminate(
            isCapturing: true,
            confirmQuit: { true },
            stopDaemon: {},
            reply: { ok in XCTAssertTrue(ok); replied.fulfill() })
        XCTAssertEqual(reply, .terminateLater)
        await fulfillment(of: [replied], timeout: 5)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd WatchtowerDesktop && swift test --filter QuitCoordinatorTests > /tmp/t3.log 2>&1; echo "exit=$?"
```
Expected: `exit=1`, `cannot find 'QuitCoordinator' in scope`.

- [ ] **Step 3: Implement QuitCoordinator**

`WatchtowerDesktop/Sources/App/QuitCoordinator.swift`:

```swift
import AppKit

/// The one full-exit path (Cmd+Q and the tray's Quit item both land here via
/// applicationShouldTerminate). Injectable seams (`confirmQuit`, `stopDaemon`,
/// `reply`) follow the `openURL` convention so tests can drive every branch
/// without AppKit UI.
@MainActor
enum QuitCoordinator {
    static func shouldTerminate(
        isCapturing: Bool,
        confirmQuit: () -> Bool,
        stopDaemon: @escaping () async -> Void,
        reply: @escaping (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        if isCapturing && !confirmQuit() {
            return .terminateCancel
        }
        Task { @MainActor in
            await stopDaemon()
            // Always let termination proceed: a stuck daemon must never trap
            // the user in a quit — the next launch adopts or replaces it.
            reply(true)
        }
        return .terminateLater
    }
}
```

- [ ] **Step 4: Replace `stopDaemonSync` with a bounded async stop**

In `DaemonManager.swift`, delete `stopDaemonSync()` (lines 111-133) and add:

```swift
    /// Stop the daemon for app quit: `sync stop` (the daemon gets up to 10 s
    /// of SIGTERM grace from the CLI) with an outer watchdog so a hung CLI
    /// can never stall termination.
    nonisolated static func stopForQuit(timeout: Duration = .seconds(12)) async {
        guard let path = Constants.findCLIPath() else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await runProcess(path: path, arguments: ["sync", "stop"]) }
            group.addTask { try? await Task.sleep(for: timeout) }
            _ = await group.next()
            group.cancelAll()
        }
    }
```

In `AppState.swift`, in the `willTerminateNotification` observer remove the `DaemonManager.stopDaemonSync()` line (keep `terminateProcessesSync()`), and update the `ensureDaemonRunning` doc comment sentence "Paired with `DaemonManager.stopDaemonSync()` on app terminate" to "Paired with the QuitCoordinator daemon stop on app terminate".

- [ ] **Step 5: Run tests + grep for dangling references**

```bash
cd WatchtowerDesktop && swift test --filter QuitCoordinatorTests > /tmp/t3.log 2>&1; echo "exit=$?"
grep -rn "stopDaemonSync" WatchtowerDesktop/Sources WatchtowerDesktop/Tests
```
Expected: `exit=0`, 3 tests pass; grep prints nothing.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/App/QuitCoordinator.swift WatchtowerDesktop/Sources/Services/DaemonManager.swift WatchtowerDesktop/Sources/App/AppState.swift WatchtowerDesktop/Tests/QuitCoordinatorTests.swift
git commit -m "feat(desktop): route quit through QuitCoordinator with bounded daemon stop"
```

---

### Task 4: App delegate — activation policy, reopen, login launch, login item, quit wiring

**Files:**
- Create: `WatchtowerDesktop/Sources/App/TrayAppDelegate.swift`
- Modify: `WatchtowerDesktop/Sources/App/WatchtowerApp.swift` (add `@NSApplicationDelegateAdaptor`, set `managesLifecycle` for the survivor)
- Test: `WatchtowerDesktop/Tests/ActivationPolicyTests.swift`

**Interfaces:**
- Consumes: `QuitCoordinator.shouldTerminate`, `DaemonManager.stopForQuit` (Task 3), `NotificationDelegate.sharedAppState` (existing), `MeetingRecorderCenter.isCapturing` (existing).
- Produces: `TrayAppDelegate` (NSApplicationDelegate), `ActivationPolicyDecision.policy(hasVisibleMainWindow:) -> NSApplication.ActivationPolicy`, `TrayAppDelegate.isMainWindow(_:) -> Bool`.

- [ ] **Step 1: Write the failing test**

`WatchtowerDesktop/Tests/ActivationPolicyTests.swift`:

```swift
import XCTest
import AppKit
@testable import WatchtowerDesktop

final class ActivationPolicyTests: XCTestCase {
    func testMainWindowVisibleMeansRegular() {
        XCTAssertEqual(ActivationPolicyDecision.policy(hasVisibleMainWindow: true), .regular)
    }

    func testNoMainWindowMeansAccessory() {
        XCTAssertEqual(ActivationPolicyDecision.policy(hasVisibleMainWindow: false), .accessory)
    }

    @MainActor
    func testMainWindowPredicateKeysOnAutosaveName() {
        let main = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        main.setFrameAutosaveName("WatchtowerMainWindow")
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        other.setFrameAutosaveName("Settings")
        XCTAssertTrue(TrayAppDelegate.isMainWindow(main))
        XCTAssertFalse(TrayAppDelegate.isMainWindow(other))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd WatchtowerDesktop && swift test --filter ActivationPolicyTests > /tmp/t4.log 2>&1; echo "exit=$?"
```
Expected: `exit=1`, `cannot find 'ActivationPolicyDecision' in scope`.

- [ ] **Step 3: Implement TrayAppDelegate**

`WatchtowerDesktop/Sources/App/TrayAppDelegate.swift`:

```swift
import AppKit
import ServiceManagement

/// App is in the Dock while its main window is open; menu-bar-only otherwise.
enum ActivationPolicyDecision {
    static func policy(hasVisibleMainWindow: Bool) -> NSApplication.ActivationPolicy {
        hasVisibleMainWindow ? .regular : .accessory
    }
}

/// Owns the opinionated lifecycle: close-to-tray, login-item autostart
/// (straight to accessory), Dock reopen, and the single full-exit path.
/// A SingleInstanceGuard duplicate leaves `managesLifecycle` false and this
/// delegate inert — the duplicate's own grace-window exit(0) is the quit path.
final class TrayAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by WatchtowerApp.init only for the survivor instance.
    var managesLifecycle = false

    private static let loginItemRegisteredKey = "tray.loginItemRegistered"
    private var closeObserver: NSObjectProtocol?

    static func isMainWindow(_ window: NSWindow) -> Bool {
        window.frameAutosaveName == "WatchtowerMainWindow"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard managesLifecycle else { return }

        // Login-item launch: no window, straight to the tray. The launch
        // Apple event carries keyAELaunchedAsLogInItem in its propData.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let isLoginLaunch = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
        if isLoginLaunch {
            NSApp.setActivationPolicy(.accessory)
            for window in NSApp.windows where Self.isMainWindow(window) {
                window.close()
            }
        }

        registerLoginItemOnce()

        // Close-to-tray: when the main window goes away, leave the Dock but
        // keep the tray (the app itself) alive. Deferred one runloop turn so
        // NSApp.windows reflects the close.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow, Self.isMainWindow(window) else { return }
            DispatchQueue.main.async {
                let hasMain = NSApp.windows.contains { Self.isMainWindow($0) && $0.isVisible }
                NSApp.setActivationPolicy(ActivationPolicyDecision.policy(hasVisibleMainWindow: hasMain))
            }
        }
    }

    /// Dock icon / Finder reopen while living in the tray: back to a regular
    /// app. Returning true lets AppKit/SwiftUI restore or recreate the
    /// WindowGroup window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard managesLifecycle else { return true }
        if !flag {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard managesLifecycle else { return .terminateNow }
        return QuitCoordinator.shouldTerminate(
            isCapturing: NotificationDelegate.sharedAppState?.meetingRecorderCenter.isCapturing ?? false,
            confirmQuit: Self.confirmQuitDuringRecording,
            stopDaemon: { await DaemonManager.stopForQuit() },
            reply: { ok in sender.reply(toApplicationShouldTerminate: ok) }
        )
    }

    /// Register the login item exactly once. Never re-register: a user who
    /// disabled autostart in System Settings → Login Items must stay disabled,
    /// and a repeated register() would silently re-enable it.
    private func registerLoginItemOnce() {
        guard !UserDefaults.standard.bool(forKey: Self.loginItemRegisteredKey) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: Self.loginItemRegisteredKey)
        } catch {
            // Manual launch is unaffected; retry next launch.
            NSLog("TrayAppDelegate: login item registration failed: %@", error.localizedDescription)
        }
    }

    private static func confirmQuitDuringRecording() -> Bool {
        let alert = NSAlert()
        alert.messageText = "A meeting recording is in progress"
        alert.informativeText = "Quitting stops the capture. The audio recorded so far is kept and offered for transcription on next launch."
        alert.addButton(withTitle: "Stop Recording & Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
```

- [ ] **Step 4: Wire the adaptor into WatchtowerApp**

In `WatchtowerApp.swift` add to the `WatchtowerApp` struct:

```swift
    @NSApplicationDelegateAdaptor(TrayAppDelegate.self) private var trayDelegate
```

and in `init()`, on the survivor path only (right after `NSApplication.shared.setActivationPolicy(.regular)`):

```swift
        trayDelegate.managesLifecycle = true
```

Note the existing duplicate path calls `setActivationPolicy(.prohibited)` and exits — `managesLifecycle` stays false there, keeping the delegate inert.

- [ ] **Step 5: Run tests**

```bash
cd WatchtowerDesktop && swift test --filter ActivationPolicyTests > /tmp/t4.log 2>&1; echo "exit=$?"
```
Expected: `exit=0`, 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/App/TrayAppDelegate.swift WatchtowerDesktop/Sources/App/WatchtowerApp.swift WatchtowerDesktop/Tests/ActivationPolicyTests.swift
git commit -m "feat(desktop): app delegate — close-to-tray, login-item autostart, quit wiring"
```

---

### Task 5: MenuBarExtra tray scene

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/TrayMenuView.swift`
- Modify: `WatchtowerDesktop/Sources/App/WatchtowerApp.swift` (add `MenuBarExtra` scene; give the main `WindowGroup` the id `"main"`)
- Test: `WatchtowerDesktop/Tests/TrayMenuViewTests.swift`

**Interfaces:**
- Consumes: `DaemonManager` (`isRunning`, `checkStatus()`), `AppState.cliStoreError` (Task 2).
- Produces: `TrayMenuView` (SwiftUI). The `WindowGroup(id: "main")` id is what `openWindow(id: "main")` targets.

- [ ] **Step 1: Write the failing test**

`WatchtowerDesktop/Tests/TrayMenuViewTests.swift`:

```swift
import XCTest
import ViewInspector
import SwiftUI
@testable import WatchtowerDesktop

@MainActor
final class TrayMenuViewTests: XCTestCase {
    func testMenuOffersOpenAndQuit() throws {
        let view = TrayMenuView()
        let openButton = try view.inspect().find(button: "Open Watchtower")
        let quitButton = try view.inspect().find(button: "Quit Watchtower")
        XCTAssertNotNil(openButton)
        XCTAssertNotNil(quitButton)
    }

    func testStatusLineReflectsDaemonState() throws {
        XCTAssertEqual(TrayMenuView.statusText(isRunning: true), "Syncing in background")
        XCTAssertEqual(TrayMenuView.statusText(isRunning: false), "Sync daemon not running")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd WatchtowerDesktop && swift test --filter TrayMenuViewTests > /tmp/t5.log 2>&1; echo "exit=$?"
```
Expected: `exit=1`, `cannot find 'TrayMenuView' in scope`.

- [ ] **Step 3: Implement TrayMenuView**

`WatchtowerDesktop/Sources/Views/TrayMenuView.swift`:

```swift
import SwiftUI
import AppKit

/// Menu-bar tray content: status line + the only two actions the tray offers
/// (open the desktop window, quit Watchtower completely — daemon included).
struct TrayMenuView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppState.self) private var appState
    @State private var daemonManager = DaemonManager()

    static func statusText(isRunning: Bool) -> String {
        isRunning ? "Syncing in background" : "Sync daemon not running"
    }

    var body: some View {
        Group {
            Text(Self.statusText(isRunning: daemonManager.isRunning))
            if let storeError = appState.cliStoreError {
                Text("CLI store: \(storeError)")
            }
            Divider()
            Button("Open Watchtower") {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Quit Watchtower") {
                NSApp.terminate(nil)
            }
        }
        .onAppear { daemonManager.checkStatus() }
    }
}
```

Note: `testMenuOffersOpenAndQuit` needs the environment injected — if ViewInspector fails on the missing `AppState`/`openWindow` environment, inject with `.environment(AppState())` in the test per the existing test-suite pattern (check a neighboring ViewInspector test for the house idiom before inventing one).

- [ ] **Step 4: Add the scene and window id in WatchtowerApp**

In `WatchtowerApp.swift` `body`: change `WindowGroup {` to `WindowGroup(id: "main") {`, and after the `Settings { ... }` scene add:

```swift
        MenuBarExtra("Watchtower", systemImage: "binoculars", isInserted: .constant(!isDuplicate)) {
            TrayMenuView()
                .environment(appState)
        }
```

(`isInserted: .constant(!isDuplicate)` keeps the duplicate instance headless — no second tray icon during its grace window.)

- [ ] **Step 5: Run tests + full build**

```bash
cd WatchtowerDesktop && swift test --filter TrayMenuViewTests > /tmp/t5.log 2>&1; echo "exit=$?"
cd WatchtowerDesktop && swift build > /tmp/t5-build.log 2>&1; echo "exit=$?"
```
Expected: both `exit=0`.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/TrayMenuView.swift WatchtowerDesktop/Sources/App/WatchtowerApp.swift WatchtowerDesktop/Tests/TrayMenuViewTests.swift
git commit -m "feat(desktop): menu-bar tray — status, open window, quit"
```

---

### Task 6: Opinionated settings — remove the daemon Start/Stop toggle

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Settings/DaemonSettings.swift:17-28` (delete the Start/Stop `Button` `HStack`)

**Interfaces:**
- Consumes: nothing new. `DaemonManager.stopDaemon`/`startDaemon` instance methods stay — `AppState.ensureDaemonRunning` and `DaemonManager.restart()` still use them.
- Produces: read-only daemon status section.

- [ ] **Step 1: Delete the toggle**

In `DaemonSettings.swift` remove the `HStack { Button(daemonManager.isRunning ? "Stop Daemon" : "Start Daemon") ... }` block (the status dot, binary path row, and error section stay).

- [ ] **Step 2: Grep for orphaned test references, then build + test**

```bash
grep -rn "Stop Daemon\|Start Daemon" WatchtowerDesktop/Sources WatchtowerDesktop/Tests
cd WatchtowerDesktop && swift build > /tmp/t6.log 2>&1; echo "exit=$?"
cd WatchtowerDesktop && swift test > /tmp/t6-test.log 2>&1; echo "exit=$?"
```
Expected: grep finds nothing outside the deleted block; both `exit=0`. If a test asserts on the removed button, update that test to assert the button is gone (do not weaken unrelated assertions).

- [ ] **Step 3: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Settings/DaemonSettings.swift
git commit -m "feat(desktop): drop daemon start/stop toggle — lifecycle is app-owned"
```

---

### Task 7: Docs + full verification + manual checklist

**Files:**
- Modify: `docs/app-guide.md` (tray section — the guide is injected into the chat-bot system prompt and must reflect UI changes)
- Modify: `CLAUDE.md` (short feature note under Feature Notes: tray + lifecycle + CLI binary store, pointing at the spec)

**Interfaces:** none — documentation and verification only.

- [ ] **Step 1: Update `docs/app-guide.md`**

Add a "Menu bar & app lifecycle" subsection: the menu-bar icon is always present while Watchtower runs; closing the window keeps Watchtower syncing in the background (menu bar only); Cmd+Q or the tray's "Quit Watchtower" stops background sync completely; Watchtower starts at login into the menu bar (disable in System Settings → Login Items). Match the guide's existing tone and heading style — read the file first.

- [ ] **Step 2: Update `CLAUDE.md`**

Add a Feature Notes entry (≈5 lines): tray (`MenuBarExtra` + `TrayAppDelegate`), lifecycle matrix summary (close→tray, Cmd+Q/tray-quit→full exit incl. daemon stop via `QuitCoordinator`, login-item autostart to accessory), `CLIBinaryStore` (Application Support copy, SHA256 + atomic rename, `findCLIPath` store-first), Go unchanged. Reference the spec path.

- [ ] **Step 3: Full verification**

```bash
go build ./... && go vet ./... > /tmp/t7-go.log 2>&1; echo "exit=$?"
cd WatchtowerDesktop && swift build > /tmp/t7-build.log 2>&1; echo "exit=$?"
cd WatchtowerDesktop && swift test > /tmp/t7-test.log 2>&1; echo "exit=$?"
```
Expected: all `exit=0`. Go is untouched by this plan — if `git status` shows any Go file modified, that is a bug.

- [ ] **Step 4: Commit**

```bash
git add docs/app-guide.md CLAUDE.md
git commit -m "docs: app guide + CLAUDE.md notes for tray, lifecycle, CLI binary store"
```

- [ ] **Step 5: Manual checklist (run `make app-dev`, drive the real app)**

Record results in the PR description:

1. Launch app → tray icon present, window opens, daemon starts from `~/Library/Application Support/Watchtower/bin/watchtower` (`ps aux | grep watchtower` shows the store path).
2. Red-button close → app leaves Dock, tray stays, daemon still running.
3. Tray → Open Watchtower → window and Dock icon return.
4. Cmd+Q → app exits, `daemon.pid` gone, no watchtower processes left.
5. Relaunch, start a recording, Cmd+Q → confirm dialog; Cancel keeps recording; Stop & Quit exits and the `.caf` survives (offered on next launch).
6. `make app` while daemon runs from the store copy → daemon survives the rebuild (SecPolicyCreateSSL incident class is dead).
7. Recording started → close window to tray → reopen → recorder state intact (survives-navigation rule).
8. Login-item behavior: `osascript -e 'tell application "System Events" to get the name of every login item'` lists Watchtower after first launch.

---

## Final phase: review → PR → green CI → merge

Not a code task — process, per the standing workflow:

1. Run the `local-review` skill over the branch (final PR into main → it runs debate-review).
2. Address accepted findings; loop until convergence.
3. Push (`gh` account `vadimtrunov`), open PR to `main` with the manual-checklist results.
4. Wait for CI green — remember the dedupe-gate gotcha: "skipping" ≠ green; use workflow_dispatch if the pull_request webhook is dead.
5. Merge.
