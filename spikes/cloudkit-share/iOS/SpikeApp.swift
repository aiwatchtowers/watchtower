// Throwaway S0 spike harness, iOS app entry, push plumbing and the button screen.

import CloudKit
import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        let state = application.applicationState
        SpikeLog.shared.line("app: launched (state=\(state == .background ? "background" : "foreground"))")
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        SpikeLog.shared.line("app: registered for remote notifications")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        SpikeLog.shared.line("app: remote notification registration FAILED: \(error)")
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let receivedAt = Date()
        let state = application.applicationState
        Task { @MainActor in
            await Harness.shared.handlePush(userInfo, state: state, receivedAt: receivedAt)
            completionHandler(.newData)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in await Harness.shared.reportAlert(notification, path: "willPresent (foreground)") }
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            await Harness.shared.reportAlert(response.notification, path: "tapped")
            completionHandler()
        }
    }
}

@main
struct CKSpikeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var harness = Harness.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(harness)
                .onOpenURL { harness.open($0) }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var harness: Harness

    var body: some View {
        NavigationStack {
            List {
                Section("Link (scan the Mac's QR with the Camera app)") {
                    if let link = harness.link {
                        Text("owner_user: \(link.ownerUser)").font(.caption.monospaced())
                    } else {
                        Text("No link yet").foregroundStyle(.secondary)
                    }
                    Button("Paste link from clipboard") { harness.pasteLink() }
                    button("Accept shares (second Apple ID only)") { await harness.acceptShares(item: "accept") }
                }
                Section("Second Apple ID iPhone (participant)") {
                    button("a: Sync shared + send 64 MiB asset") { await harness.itemA() }
                    button("b: Register silent shared-DB push") { await harness.itemBRegister() }
                    button("c: Check access (after close-link)") { await harness.itemC(item: "c") }
                    button("c (F2): Re-accept + check") { await harness.itemCF2() }
                    button("d: whoami — different Apple ID") { await harness.itemD(sameAppleIDAsMac: false) }
                }
                Section("Mac's Apple ID iPhone") {
                    button("d: whoami — same Apple ID") { await harness.itemD(sameAppleIDAsMac: true) }
                    button("e: Subscribe visible alerts") { await harness.itemESubscribe() }
                    button("e: Read delivered alerts") { await harness.itemEReadDelivered() }
                }
                Section("Log") {
                    HStack {
                        Button("Copy") { UIPasteboard.general.string = harness.lines.joined(separator: "\n") }
                        Spacer()
                        ShareLink(item: harness.logURL) { Text("Share file") }
                        Spacer()
                        Button("Clear", role: .destructive) { harness.clearLog() }
                    }
                    .buttonStyle(.borderless)
                    ForEach(Array(harness.lines.suffix(300).enumerated().reversed()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(line.contains("FAIL") || line.contains("ERROR") ? .red : .primary)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(harness.busy ? "CKSpike — running…" : "CKSpike")
        }
    }

    private func button(_ title: String, _ action: @escaping () async -> Void) -> some View {
        Button(title) { harness.run(action) }.disabled(harness.busy)
    }
}
