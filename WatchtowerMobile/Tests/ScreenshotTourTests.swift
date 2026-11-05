import CryptoKit
import SwiftUI
import UIKit
import WatchtowerHostedRelay
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The design pass's screenshot tour (design pass spec §6.2): every screen
/// of the demo seed rendered to PNGs in light and dark mode, for a
/// before/after comparison by eye. Opt-in: `make mobile-shots` sets
/// WATCHTOWER_SHOTS_DIR, and every other run reports the tour skipped. It
/// asserts no pixels, only that every file was written.
@MainActor
final class ScreenshotTourTests: XCTestCase {
    /// One screen of the tour: its review number, a file-name slug, the
    /// source file, how it is reached, and whether it gets an end shot.
    struct Shot {
        enum Reached: String {
            case fullApp = "full app"
            case bareStack = "bare stack"
            case sheet
            case leaf = "leaf view"
        }

        let number: String
        let slug: String
        let source: String
        let reached: Reached
        var hasEnd = false
        let make: @MainActor (AppEnvironment) -> AnyView
    }

    /// `make mobile-shots SHOTS_ONLY=relay-phase4` runs `testTheRelayPhase4Shots` alone (a frame or two of a
    /// new screen in minutes, not the whole tour's half hour); the plain run is the whole tour, which covers them too.
    private static let onlyRelayPhase4 = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_ONLY"] == "relay-phase4"

    func testTheRelayPhase4Shots() async throws {
        guard let path = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_DIR"], Self.onlyRelayPhase4 else {
            throw XCTSkip("Only with make mobile-shots SHOTS_ONLY=relay-phase4")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (root, _) = try makeDemoRoot()
        let host = ScreenshotHost(directory: dir, env: root.env, linking: root.linking)
        let rows = try await captureRelayPhase4(host: host)
        let written = try FileManager.default.contentsOfDirectory(atPath: path)
            .filter { name in rows.contains { name.hasPrefix($0.number + "-") } && name.hasSuffix(".png") }
        XCTAssertEqual(written.count, 3 * rows.count)
    }

    func testTheTour() async throws {
        guard let path = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_DIR"], !Self.onlyRelayPhase4 else {
            throw XCTSkip("Screenshot tour: run make mobile-shots")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try ScreenshotHost.clear(dir)
        let (root, demo) = try makeDemoRoot()
        try await poll(timeout: 20, { Self.isHydrated(root.env) }, "the demo seed hydrated")
        let host = ScreenshotHost(directory: dir, env: root.env, linking: root.linking)
        let shots = Self.designSystemShots() + Self.workbenchShots() + Self.calendarShots() + Self.onboardingShots()
        for shot in shots {
            let end = shot.hasEnd ? "\(shot.number)e-\(shot.slug)" : nil
            try await host.capture("\(shot.number)-\(shot.slug)", shot.make(root.env), endName: end)
        }
        let asleepRows = try await captureMacAsleep(root.env, demo: demo, host: host)
        let recorderRows = try await captureRecorder(into: dir, linking: root.linking)
        let outboxRows = try await captureOutbox(into: dir, linking: root.linking)
        let relayRows = try await captureRelayLinking(host: host)
        let onRelayRows = try await captureHubOnRelay(into: dir, linking: root.linking)
        let phase4Rows = try await captureRelayPhase4(host: host)
        try ScreenshotHost.writeIndex(
            Self.indexRows(shots) + asleepRows + recorderRows + outboxRows + relayRows + onRelayRows + phase4Rows, to: dir)

        let pngs = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "png" }
        XCTAssertEqual(
            pngs.count,
            2 * (shots.count + shots.filter(\.hasEnd).count + asleepRows.count + recorderRows.count + outboxRows.count)
                + 3 * (relayRows.count + onRelayRows.count + phase4Rows.count)
        )
        for png in pngs {
            XCTAssertGreaterThan(try png.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0, png.lastPathComponent)
        }
    }

    // MARK: - The demo

    /// The primary demo Mac's transport and the defaults holding its seq
    /// ceiling, for a later save in the hub's name.
    private struct DemoHub {
        let transport: InMemoryCloudTransport
        let defaults: UserDefaults
    }

    private func makeDemoRoot() throws -> (AppRoot, DemoHub) {
        let defaults = try makeDefaults()
        var primary: InMemoryCloudTransport?
        let env = AppEnvironment(backend: .inMemoryDemo, defaults: defaults)
        for hub in DemoSeed.hubs {
            // The demo Mac allows typing; the phone's own toggle is on, so the
            // workchat shows its composer.
            defaults.set(true, forKey: "hub.\(hub.hubID).device.typingRequested")
            let transport = InMemoryCloudTransport()
            if hub == DemoSeed.primary {
                primary = transport
            }
            let session = try HubSession(
                transport: transport,
                replicaPath: try makeReplicaPath(),
                backend: .inMemoryDemo,
                hubID: hub.hubID,
                defaults: defaults,
                recordingsDirectory: try makeRecordingsDirectory()
            )
            addTeardownBlock { @MainActor in session.stop() }
            env.add(session)
        }
        env.activate(DemoSeed.primary.hubID)
        let demo = DemoHub(transport: try XCTUnwrap(primary), defaults: defaults)
        return (try AppRoot.demo(env, defaults: defaults), demo)
    }

    /// 01s, 09s (mockup 8): the primary Mac's heartbeat 40 min old, so the
    /// Mac is asleep: Now's chip and working times "as of", the workchat's
    /// banner and composer note. Last of the app shots: the Mac stays asleep.
    private func captureMacAsleep(_ env: AppEnvironment, demo: DemoHub, host: ScreenshotHost) async throws -> [ScreenshotHost.IndexRow] {
        let stale = Date().addingTimeInterval(-2_400)
        let beat = try XCTUnwrap(DemoSeed.records(now: stale).first { $0.recordName == HeartbeatPayload.recordName })
        let sealing = DemoSeed.hubTransport(inner: demo.transport, seq: DemoSeed.hubSeq(defaults: demo.defaults, now: Date()))
        try await sealing.save([beat])
        _ = await env.refresh(.pull)
        try await poll(timeout: 20, { env.macReachability(now: Date()) != .online }, "the demo Mac fell asleep")
        try await host.capture("01s-now-mac-asleep", Self.app(.now)(env))
        try await host.capture("09s-session-10-mac-asleep", NavigationStack {
            WorkchatView(replica: env.workbenchReplica, sessionID: 10, store: env.store, requester: env.chatRequests)
        })
        return [
            ScreenshotHost.IndexRow(number: "01s", view: "NowView", source: "Features/Now/NowView.swift", reached: "full app, Mac asleep"),
            ScreenshotHost.IndexRow(
                number: "09s", view: "WorkchatView", source: "Features/Workbench/WorkchatView.swift", reached: "bare stack, Mac asleep"
            )
        ]
    }

    // MARK: - Linking over Relay (relay client Phase 3 Task 10, mockup section 7)

    /// A link flow over a scripted relay account and a fake host holding the demo Macs plus "Work Mac" on Relay,
    /// with the demo's finishing link to "build-box" in `state` (nil: none).
    private func relayLinking(_ state: PromotedLink.State?, now: Date) throws -> (LinkingViewModel, FakeRelayOps, FakeLinkHost) {
        let clock = FakeLinkClock(now: now)
        let relay = FakeRelayOps(clock: clock)
        let host = FakeLinkHost(log: LinkEventLog())
        for hub in DemoSeed.hubs {
            host.seed(DemoSeed.link(for: hub, now: now))
        }
        host.seed(DemoSeed.Relay.workLink(now: now))
        host.noteHeartbeat(now, hubID: DemoSeed.Relay.workLink(now: now).hubID)
        let store = LinkStore(defaults: try makeDefaults())
        if let state {
            let link = DemoSeed.Relay.finishingLink(state, now: now)
            store.promoted = [link.hubID: link]
        }
        let device = DemoSeed.device
        let linking = LinkingViewModel(
            access: FakeLinkAccess(log: LinkEventLog()), store: store,
            identity: DeviceIdentity(deviceID: device.deviceID, name: device.name, model: device.model, appVersion: device.appVersion),
            keys: InMemoryPhoneKeyStore(), clock: clock, relay: relay
        )
        linking.host = host
        relay.slots = [DemoSeed.Relay.workMac, DemoSeed.Relay.unknownMac, DemoSeed.Relay.finishingMac]
        return (linking, relay, host)
    }

    /// R01–R21, each light, dark and narrow (iPhone SE, the largest Dynamic Type size).
    private func captureRelayLinking(host: ScreenshotHost) async throws -> [ScreenshotHost.IndexRow] {
        let now = Date()
        let onboarding = "Features/Onboarding/"
        var rows: [ScreenshotHost.IndexRow] = []
        func shot(
            _ number: String,
            _ slug: String,
            _ source: String,
            _ reached: String,
            _ view: some View,
            settle: Duration = .milliseconds(600),
            narrowScroll: CGFloat? = nil
        ) async throws {
            try await host.captureThree("\(number)-\(slug)", view, settle: settle, narrowScroll: narrowScroll)
            let name = URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent
            rows.append(ScreenshotHost.IndexRow(number: number, view: name, source: source, reached: "\(reached), light/dark/narrow"))
        }
        for (number, slug, failure) in [
            ("R01", "link-needs-relay", LinkFailure.needsRelay(macName: "build-box")),
            ("R02", "link-relay-unreachable", .relayUnreachable),
            ("R03", "link-mac-on-relay", .macOnRelay(macName: "Work Mac"))
        ] {
            try await shot(number, slug, onboarding + "LinkedView.swift", "leaf view", LinkFailureView(failure: failure))
        }
        for (number, slug, notice) in [
            ("R04", "link-finish-in-background", LinkNotice.finishingInBackground(macName: "build-box")),
            ("R05", "notice-mac-on-relay", .macOnRelay(macName: "Work Mac"))
        ] {
            host.env.navigation.tab = .now
            try await shot(number, slug, "App/AppRootView.swift", "full app with the notice", TabsWithNotice(notice: notice))
        }

        let slots = onboarding + "RelaySlotsView.swift"
        let (slotsLinking, slotsRelay, _) = try relayLinking(.needsOwner(.slotsFull), now: now)
        await slotsLinking.manageSlots(for: DemoSeed.Relay.finishingHubID)
        try await shot(
            "R06", "relay-slots-full", slots,
            "sheet with its own Cancel (no back chevron: the mockup's 7.3 frames draw it pushed)",
            RelaySlotsView {}.environment(slotsLinking)
        )
        let finishingRow = try XCTUnwrap(
            RelaySlotsModel(state: slotsLinking.relaySlots, links: slotsLinking.links, promoted: slotsLinking.promotedLinks)
                .rows.first { $0.id == DemoSeed.Relay.finishingMac }
        )
        try await shot(
            "R07", "relay-slots-finishing-mac", slots, "sheet, Remove on the finishing link. \(Self.alertGap)",
            RelaySlotsView(asking: RelaySlotsModel.ask(for: finishingRow)) {}.environment(slotsLinking), settle: .seconds(2)
        )
        slotsRelay.park("removeSlot")
        slotsRelay.fail("removeSlot", with: HostedRelayPairing.Refusal.unreachable)
        let removal = Task { await slotsLinking.removeFromSlots(DemoSeed.Relay.workMac) }
        try await poll({ slotsRelay.isParked("removeSlot") }, "the removal is running")
        try await shot("R08", "relay-slots-removing", slots, "sheet, a removal running", RelaySlotsView {}.environment(slotsLinking))
        slotsRelay.release("removeSlot")
        await removal.value
        try await shot("R09", "relay-slots-remove-error", slots, "sheet, the removal failed", RelaySlotsView {}.environment(slotsLinking))

        try await captureRelayMacs(now: now) { number, slug, reached, view, settle in
            // The finishing row comes after the linked Macs: the narrow frame scrolls to the end of the list, where it
            // is (at the largest Dynamic Type size it falls below the first screen).
            try await shot(
                number, slug, "Features/Settings/MacsView.swift", "\(reached), narrow scrolled to the finishing row", view,
                settle: settle, narrowScroll: Self.toTheEnd
            )
        }
        try await shot(
            "R21", "link-mac-not-on-relay", onboarding + "LinkedView.swift", "leaf view",
            LinkFailureView(failure: .macNotOnRelay(macName: "build-box"))
        )
        return rows
    }

    /// R10–R20: Settings → Macs with the demo's finishing link in each state.
    private func captureRelayMacs(
        now: Date, shot: (_ number: String, _ slug: String, _ reached: String, _ view: AnyView, _ settle: Duration) async throws -> Void
    ) async throws {
        let (busy, busyRelay, _) = try relayLinking(.confirmed, now: now)
        busyRelay.park("vouch")
        let attempt = Task { await busy.tryAgain(DemoSeed.Relay.finishingHubID) }
        try await poll({ busyRelay.isParked("vouch") }, "the attempt is running")
        try await shot(
            "R10", "macs-finishing-row", "bare stack, an attempt running",
            AnyView(NavigationStack { MacsView() }.environment(busy)), .milliseconds(600)
        )
        busyRelay.release("vouch")
        await attempt.value

        let (failed, _, failedHost) = try relayLinking(.promoted, now: now)
        failedHost.prepareError = CocoaError(.fileReadCorruptFile)
        await failed.resumePromotedLinks()
        try await shot(
            "R11", "macs-finishing-row-error", "bare stack, the last attempt failed",
            AnyView(NavigationStack { MacsView() }.environment(failed)), .milliseconds(600)
        )

        for (index, reason) in PromotedLink.Reason.allCases.enumerated() {
            let (linking, _, _) = try relayLinking(.needsOwner(reason), now: now)
            try await shot(
                String(format: "R%02d", 12 + index), "macs-needs-owner-\(reason.rawValue)", "bare stack",
                AnyView(NavigationStack { MacsView() }.environment(linking)), .milliseconds(600)
            )
        }
        let (cancel, _, _) = try relayLinking(.needsOwner(.slotExpired), now: now)
        let row = try XCTUnwrap(MacsModel.finishingRows(cancel.promotedLinks, running: [], failed: []).first)
        try await shot(
            "R20", "macs-finishing-cancel-confirm", "bare stack, Cancel pressed. \(Self.alertGap)",
            AnyView(NavigationStack { MacsView(cancelling: row) }.environment(cancel)), .seconds(2)
        )
    }

    // MARK: - Relay client Phase 4 (mockup section 8, S01 upward)

    /// A link flow whose Macs are `links` (the fake host's), for Settings → Macs.
    private func macsLinking(_ links: [LinkRecord], now: Date) throws -> LinkingViewModel {
        let clock = FakeLinkClock(now: now)
        let host = FakeLinkHost(log: LinkEventLog())
        for link in links {
            host.seed(link)
            host.noteHeartbeat(now, hubID: link.hubID)
        }
        let device = DemoSeed.device
        let linking = LinkingViewModel(
            access: FakeLinkAccess(log: LinkEventLog()), store: LinkStore(defaults: try makeDefaults()),
            identity: DeviceIdentity(deviceID: device.deviceID, name: device.name, model: device.model, appVersion: device.appVersion),
            keys: InMemoryPhoneKeyStore(), clock: clock, relay: FakeRelayOps(clock: clock)
        )
        linking.host = host
        return linking
    }

    /// S01–S07, S41, S55: Settings → Macs' Relay card in each state and the Macs' transport lines, each light, dark
    /// and narrow. The card is handed to the view (`MacsView(card:)`) over a never-started account center, which is
    /// what turns the rows' transport lines on.
    private func captureRelayPhase4(host: ScreenshotHost) async throws -> [ScreenshotHost.IndexRow] {
        let now = Date()
        let env = host.env
        let defaults = try makeDefaults()
        env.relayAccount = RelayAccountCenter(
            link: RelayAccountLink(hasIdentity: { false }, account: { nil }, events: { nil }),
            store: FakeSubscriptionStore(), defaults: defaults
        ) { [] }
        defer { env.relayAccount = nil }
        let source = "Features/Settings/MacsView.swift"
        var rows: [ScreenshotHost.IndexRow] = []
        func shot(_ number: String, _ slug: String, _ reached: String, _ view: some View) async throws {
            try await host.captureThree("\(number)-\(slug)", view, narrowScroll: Self.toTheEnd)
            rows.append(ScreenshotHost.IndexRow(number: number, view: "MacsView", source: source, reached: "\(reached), light/dark/narrow"))
        }
        func macLink(_ id: String, _ name: String, relay: Bool = false) -> LinkRecord {
            var record = LinkRecord(
                hubID: id, macName: name, scope: .private, ownerName: "", userRecordName: "", nonce: id,
                dataShareURL: nil, relayShareURL: nil, deviceID: DemoSeed.device.deviceID, linkedAt: now
            )
            if relay { record.setRelay(mac: DemoSeed.Relay.workMac) }
            return record
        }
        let origin = try RelayOrigin("https://relay.example.com")
        let twoMacs = try macsLinking([macLink("p4-work", "Work Mac"), macLink("p4-home", "Home Mac")], now: now)
        let cards: [(String, String, RelayAccountCenter.Phase, Bool)] = [
            ("S01", "relay-card-not-subscribed", .free(ended: false), false),
            ("S02", "relay-card-loading", .checking, false),
            ("S03", "relay-card-error", .unknown, false),
            ("S04", "relay-card-active", .paying(grace: false, macs: ["a", "b"]), false),
            ("S05", "relay-card-grace", .paying(grace: true, macs: ["a", "b"]), false),
            ("S06", "relay-card-ended", .free(ended: true), false),
            ("S41", "relay-card-moved", .moved, false),
            ("S55", "relay-card-purchase-not-confirmed", .free(ended: false), true)
        ]
        for (number, slug, phase, unconfirmed) in cards {
            let card = try XCTUnwrap(RelayCardModel(
                availability: .available(origin), phase: phase, unconfirmedPurchase: unconfirmed
            ))
            try await shot(number, slug, "bare stack, the Relay card", NavigationStack { MacsView(card: card) }.environment(twoMacs))
        }

        let home = macLink("p4-home", "Home Mac")
        var thisPhone = macLink("p4-this", "Work Mac", relay: true)
        thisPhone.switchedBy = DemoSeed.device.deviceID
        var another = macLink("p4-other", "Work Mac", relay: true)
        another.switchedBy = "another-phone"
        var ended = macLink("p4-ended", "build-box")
        ended.switchedBy = TransportFollowerPolicy.lapseReason
        var switching = macLink("p4-lab", "Lab Mac")
        switching.relayUpgrade = RelayUpgradeRecord(step: .vouching)
        let at = Calendar.current.startOfDay(for: now).addingTimeInterval(10 * 3_600 + 42 * 60)
        thisPhone.switchedAt = at
        another.switchedAt = at
        ended.switchedAt = at
        let lines = try macsLinking([home, thisPhone, another, ended, switching], now: now)
        try await shot(
            "S07", "macs-transport-lines", "bare stack, iCloud / Relay / lapse / switching rows",
            NavigationStack { MacsView() }.environment(lines)
        )
        rows += try await captureConnection(host: host, origin: origin, now: now) { macLink($0, $1, relay: $2) }
        rows += try await captureSubscription(host: host)
        rows += try await captureBanners(host: host, origin: origin, now: now)
        return rows
    }

    /// S30–S36, S34b, S36b, S47, S50, S51, S53: Now's Relay banner in each state of Task 1's table, each light, dark and narrow, handed to
    /// the view (`NowView(banner:)`). The outage frames sit on the outbox demo, for the Waiting to send row under them.
    private func captureBanners(host: ScreenshotHost, origin: RelayOrigin, now: Date) async throws -> [ScreenshotHost.IndexRow] {
        func banner(
            availability: RelayAvailability? = nil,
            phase: RelayAccountCenter.Phase = .paying(grace: false, macs: []),
            updateRequired: Bool = false,
            wasPaying: Bool = false,
            route: HubRoute? = .cloudKit(.private),
            relayOnly: Bool = false,
            hubOnRelay: Bool = false,
            outageMinutes: Double? = nil,
            request: TransportRequestRecord? = nil,
            macName: String = "Work Mac"
        ) throws -> RelayBannerModel {
            let lastUpdate = Calendar.current.startOfDay(for: now).addingTimeInterval(10 * 3_600 + 41 * 60)
            return try XCTUnwrap(RelayBannerModel.banner(
                availability: availability ?? .available(origin), phase: phase, unconfirmedPurchase: false, updateRequired: updateRequired,
                wasPaying: wasPaying, route: route, relayOnly: relayOnly, hubOnRelayAt: hubOnRelay ? now : nil,
                unansweredSince: outageMinutes.map { now.addingTimeInterval(-$0 * 60) }, request: request, pressRefusal: nil,
                lastUpdate: lastUpdate, macName: macName, now: now
            ))
        }
        let onRelay = HubRoute.hostedRelay(macDeviceID: DemoSeed.Relay.workMac)
        func refused() -> TransportRequestRecord {
            TransportRequestRecord(target: .cloudKit, controlID: "c", reason: nil, at: now, refusal: .unavailable)
        }
        let plain: [(String, String, RelayBannerModel)] = [
            ("S30", "banner-free-mac-on-relay", try banner(phase: .free(ended: false), hubOnRelay: true)),
            ("S51", "banner-mac-on-relay-no-relay", try banner(availability: .off(.notConfigured), hubOnRelay: true)),
            ("S47", "banner-relay-only-ended", try banner(phase: .free(ended: true), route: onRelay, relayOnly: true, macName: "build-box")),
            ("S53", "banner-relay-only-moved", try banner(phase: .moved, route: onRelay, relayOnly: true, macName: "build-box")),
            ("S33", "banner-moved", try banner(phase: .moved, wasPaying: true)),
            ("S34", "banner-ended", try banner(phase: .free(ended: true), wasPaying: true)),
            ("S34b", "banner-ended-mac-not-moved", try banner(
                phase: .free(ended: true), wasPaying: true, route: onRelay,
                request: TransportRequestRecord(target: .cloudKit, controlID: "c", reason: TransportFollowerPolicy.lapseReason, at: now)
            )),
            ("S35", "banner-update-the-app", try banner(updateRequired: true, wasPaying: true)),
            ("S36b", "banner-switching-relay-answers", try banner(
                route: onRelay, request: TransportRequestRecord(target: .cloudKit, controlID: "c", reason: nil, at: now)
            ))
        ]
        let waiting: [(String, String, RelayBannerModel)] = [
            ("S31", "banner-relay-unavailable", try banner(route: onRelay, outageMinutes: 3)),
            ("S32", "banner-relay-unavailable-offer", try banner(route: onRelay, outageMinutes: 12)),
            ("S36", "banner-switching", try banner(
                route: onRelay, outageMinutes: 12,
                request: TransportRequestRecord(target: .cloudKit, controlID: "c", reason: nil, at: now)
            )),
            ("S50", "banner-refused", try banner(route: onRelay, outageMinutes: 12, request: refused()))
        ]
        var rows: [ScreenshotHost.IndexRow] = []
        func shots(_ frames: [(String, String, RelayBannerModel)], on host: ScreenshotHost, reached: String) async throws {
            for (number, slug, model) in frames {
                // At the largest type a sentence fills the narrow screen: the frame scrolls to its second line and links.
                let hasMore = model.secondLine != nil || !model.actions.isEmpty
                let scroll: CGFloat? = hasMore ? (model.text.count > 100 ? 620 : 340) : nil
                try await host.captureThree("\(number)-\(slug)", NowView(banner: model), narrowScroll: scroll)
                rows.append(ScreenshotHost.IndexRow(
                    number: number, view: "NowView", source: "Features/Now/NowView.swift", reached: "\(reached), light/dark/narrow"
                ))
            }
        }
        try await shots(plain, on: host, reached: "NowView, demo hub")
        let (env, _) = try await outboxDemoEnv()
        let outboxHost = ScreenshotHost(directory: host.directory, env: env, linking: host.linking)
        try await shots(waiting, on: outboxHost, reached: "NowView, outbox demo")
        return rows
    }

    /// S20–S29, S42–S46, S57: the subscription screen in each state of Task 1's table, each light, dark and narrow, handed to
    /// the view (`RelaySubscriptionView(model:)`).
    private func captureSubscription(host: ScreenshotHost) async throws -> [ScreenshotHost.IndexRow] {
        let product = RelayProduct(id: "relay", displayPrice: "$4.99")
        let config = RelayConfig(
            origin: nil, termsURL: URL(string: "https://example.com/terms"), privacyURL: URL(string: "https://example.com/privacy")
        )
        let frames: [(String, String, RelayAccountCenter.PurchaseState)] = [
            ("S20", "subscription-loaded", .ready(product)),
            ("S21", "subscription-loading", .loadingProduct),
            ("S22", "subscription-error", .productFailed),
            ("S23", "subscription-buying", .buying),
            ("S24", "subscription-confirming", .confirming),
            ("S44", "subscription-restoring", .restoring),
            ("S45", "subscription-none-found", .noSubscriptionFound),
            ("S46", "subscription-account-failed", .accountFailed),
            ("S25", "subscription-pending", .pending),
            ("S26", "subscription-not-reached", .boughtNotConfirmed),
            ("S27", "subscription-refused", .refused),
            ("S28", "subscription-transfer-limit", .transferLimit),
            ("S42", "subscription-no-purchases", .notImplemented),
            ("S43", "subscription-app-too-old", .updateRequired),
            ("S29", "subscription-done", .done),
            ("S57", "subscription-store-failed", .storeFailed)
        ]
        // A Restore pressed before any load found a price.
        let noPrice: [(String, String, RelayAccountCenter.PurchaseState)] = [
            ("S45b", "subscription-none-found-no-price", .noSubscriptionFound),
            ("S57b", "subscription-store-failed-no-price", .storeFailed)
        ]
        var rows: [ScreenshotHost.IndexRow] = []
        for (number, slug, purchase, price) in frames.map({ ($0.0, $0.1, $0.2, Optional(product)) }) + noPrice.map({ ($0.0, $0.1, $0.2, nil) }) {
            let model = RelaySubscriptionModel(
                purchase: purchase, unconfirmed: nil, phase: .free(ended: false), config: config, product: price
            )
            try await host.captureThree(
                "\(number)-\(slug)", NavigationStack { RelaySubscriptionView(model: model) }, narrowScroll: Self.toTheEnd
            )
            rows.append(ScreenshotHost.IndexRow(
                number: number, view: "RelaySubscriptionView", source: "Features/Settings/RelaySubscriptionView.swift",
                reached: "bare stack, the subscription screen, light/dark/narrow"
            ))
        }
        return rows
    }

    /// S08–S19, S49, S52, S54, S56: a Mac's Connection section in each state of Task 1's table, each light, dark and narrow,
    /// handed to the view (`MacDetailView(model:)`).
    private func captureConnection(
        host: ScreenshotHost, origin: RelayOrigin, now: Date, makeLink: (String, String, Bool) -> LinkRecord
    ) async throws -> [ScreenshotHost.IndexRow] {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32)).publicKey.rawRepresentation
        let device = DemoSeed.device.deviceID
        func grant(ordered: Bool = true) -> DeviceGrant {
            DeviceGrant(
                deviceID: device, hubID: "p4-work", name: "iPhone", scope: .private, linked: true, typingAllowed: true,
                startSessionsAllowed: true, orderedActions: ordered ? 1 : nil, transports: ["cloudkit", "relay"],
                relayDeviceID: RelayIDs.deviceID(publicKey: key), relayAuthPub: WireBytes.base64URL(key)
            )
        }
        let at = Calendar.current.startOfDay(for: now).addingTimeInterval(10 * 3_600 + 42 * 60)
        var iCloud = makeLink("p4-work", "Work Mac", false)
        iCloud.switchedBy = device
        iCloud.switchedAt = at
        var onRelay = makeLink("p4-work", "Work Mac", true)
        onRelay.switchedBy = device
        onRelay.switchedAt = at
        let freshICloud = makeLink("p4-work", "Work Mac", false)
        var relayOnly = makeLink("p4-work", "build-box", true)
        relayOnly.hubTransports = ["relay"]
        let paying = RelayAccountCenter.Phase.paying(grace: false, macs: [])
        let free = RelayAccountCenter.Phase.free(ended: false)
        func request(_ refusal: TransportRequestRefusal? = nil) -> TransportRequestRecord {
            TransportRequestRecord(target: .cloudKit, controlID: "c", reason: nil, at: now, refusal: refusal)
        }
        func facts(
            step: RelayUpgradeStep? = nil, refusal: RelayUpgradeRefusal? = nil, request: TransportRequestRecord? = nil, reachable: Bool = true
        ) -> SessionTransportFacts {
            SessionTransportFacts(upgradeStep: step, upgradeRefusal: refusal, request: request, macReachable: reachable)
        }
        func model(
            _ link: LinkRecord,
            phase: RelayAccountCenter.Phase = paying,
            grant given: DeviceGrant? = nil,
            unconfirmed: Bool = false,
            _ session: SessionTransportFacts? = nil
        ) -> MacTransportModel {
            MacTransportModel(
                link: link, grant: given ?? grant(), phase: phase, unconfirmedPurchase: unconfirmed,
                availability: .available(origin), session: session ?? facts(), macName: link.macName, ownDeviceID: device, now: now
            )
        }
        let frames: [(String, String, MacTransportModel)] = [
            ("S08", "connection-relay-chosen", model(onRelay)),
            ("S09", "connection-icloud-chosen", model(iCloud)),
            ("S10", "connection-free-phone", model(freshICloud, phase: free)),
            ("S11", "connection-too-soon", model(freshICloud, facts(refusal: .tooSoon(retryAt: now.addingTimeInterval(240))))),
            ("S12", "connection-mac-needs-update", model(freshICloud, grant: grant(ordered: false))),
            ("S12b", "connection-relay-route-mac-needs-update", model(onRelay, grant: grant(ordered: false))),
            ("S13", "connection-relay-only", model(relayOnly)),
            ("S13b", "connection-relay-only-lapse", model(relayOnly, phase: free)),
            ("S54", "connection-relay-no-answer", model(freshICloud, phase: .unknown)),
            ("S56", "connection-purchase-not-confirmed", model(freshICloud, phase: free, unconfirmed: true)),
            ("S14", "connection-slots-full", model(freshICloud, phase: .paying(grace: false, macs: ["a", "b", "c"]))),
            ("S49", "connection-request-refused", model(onRelay, facts(request: request(.unavailable)))),
            ("S52", "connection-no-answer", model(onRelay, facts(request: request(.macNoAnswer)))),
            ("S52b", "connection-no-answer-lapse", model(onRelay, phase: free, facts(request: request(.lapseNoAnswer)))),
            ("S15", "connection-upgrade-running", model(freshICloud, facts(step: .vouching))),
            ("S16", "connection-waiting-closed-mac", model(freshICloud, facts(step: .requested, reachable: false))),
            ("S17", "connection-toward-icloud", model(onRelay, facts(request: request()))),
            ("S18", "connection-refusal", model(freshICloud, facts(refusal: .readerNotConfirmed))),
            ("S19", "connection-checking", model(freshICloud, phase: .checking)),
            ("S19b", "connection-checking-relay-route", model(onRelay, phase: .checking))
        ]
        let linking = try macsLinking([makeLink("p4-work", "Work Mac", false)], now: now)
        var rows: [ScreenshotHost.IndexRow] = []
        for (number, slug, frame) in frames {
            try await host.captureThree(
                "\(number)-\(slug)", NavigationStack { MacDetailView(hubID: "p4-work", model: frame) }.environment(linking),
                narrowScroll: Self.toTheEnd
            )
            rows.append(ScreenshotHost.IndexRow(
                number: number, view: "MacDetailView", source: "Features/Settings/MacDetailView.swift",
                reached: "bare stack, the Connection section, light/dark/narrow"
            ))
        }
        return rows
    }

    /// A narrow scroll past any list's end: `captureThree` stops at the end.
    static let toTheEnd: CGFloat = 100_000

    /// R07/R20's INDEX note: the confirmation alert is presented but not in the PNG.
    static let alertGap = "The alert is not captured (iOS 26 draws it outside drawHierarchy); its copy is asserted in "
        + "RelaySlotsModelTests and MacsModelTests; the owner checks it on a device"

    private static func isHydrated(_ env: AppEnvironment) -> Bool {
        env.activeSession.isBootstrapped && !env.workbenchReplica.snapshot.workbenches.isEmpty
            && !env.calendarReplica.snapshot.events.isEmpty && !env.phoneRecordings.snapshot.recordings.isEmpty
    }

    /// 26b–26d: the recorder over a fake engine and clock, recording,
    /// paused and saved. The demo environment's recorder never starts (no
    /// microphone on the simulator), so it shows 26 (idle) only.
    private func captureRecorder(into dir: URL, linking: LinkingViewModel) async throws -> [ScreenshotHost.IndexRow] {
        let engine = FakeAudioEngine()
        let clock = FakeClock()
        let defaults = try makeDefaults()
        let session = try HubSession(
            transport: InMemoryCloudTransport(),
            replicaPath: try makeReplicaPath(),
            backend: .inMemoryDemo,
            defaults: defaults,
            recordingsDirectory: try makeRecordingsDirectory()
        ) { uploader in
            PhoneRecorderController(
                uploader: uploader, engine: engine, notificationCenter: NotificationCenter(),
                now: { clock.now }, tickInterval: nil
            )
        }
        addTeardownBlock { @MainActor in session.stop() }
        try await poll(timeout: 20, { session.isBootstrapped }, "the recorder environment booted")
        let env = AppEnvironment.single(session, defaults: defaults)
        let host = ScreenshotHost(directory: dir, env: env, linking: linking)
        let recorder = env.recorder
        await recorder.recordVoiceNote()
        for step in 0..<48 {
            engine.levelValue = Float(step % 8) / 8
            clock.advance(1)
            await recorder.tick()
        }
        try await host.capture("26b-recorder-recording", RecordingView())
        recorder.pause()
        try await host.capture("26c-recorder-paused", RecordingView())
        recorder.resume()
        clock.advance(60)
        await recorder.stop()
        try await host.capture("26d-recorder-saved", RecordingView())
        return ["26b", "26c", "26d"].map {
            ScreenshotHost.IndexRow(
                number: $0, view: "RecordingView", source: "Features/Recording/RecordingView.swift",
                reached: "leaf view, fake audio engine"
            )
        }
    }

    /// 37–38r (relay client mockup 5a): the demo outbox state on its own demo session — three actions waiting to
    /// send behind a stopped flush, two Not delivered (one withdrawn after 24 h, one refused) — on Now, then the
    /// list, its Dismiss All confirmation, and a retry running under the last one's "Unlock your iPhone" error.
    /// A demo session with three actions waiting to send and two not delivered (mockup 5a).
    private func outboxDemoEnv() async throws -> (AppEnvironment, HubSession) {
        let clock = MutableClock()
        let transport = RefusingTransport()
        let defaults = try makeDefaults()
        let session = try HubSession(
            transport: transport,
            replicaPath: try makeReplicaPath(),
            backend: .inMemoryDemo,
            keys: try DemoSeed.phoneKeys(),
            defaults: defaults,
            recordingsDirectory: try makeRecordingsDirectory(),
            now: { clock.now } // swiftlint:disable:this trailing_closure
        )
        addTeardownBlock { @MainActor in session.stop() }
        try await poll(timeout: 20, { session.isBootstrapped && !session.workbenchReplica.snapshot.workbenches.isEmpty }, "the outbox demo booted")
        await session.outboxWork?.value
        let now = Date()
        try await DemoSeed.loadOutboxDemo(
            outbox: session.outbox, now: now,
            setClock: { clock.advance($0.timeIntervalSince(clock.now)) },
            refuse: { await transport.refuse($0) })
        try await poll(timeout: 20, {
            let backlog = session.outboxBacklog
            return backlog.queued == 3 && backlog.undelivered == 2 && backlog.lastFlushStopped
                && OutboxItem.rows(session.workbenchReplica.snapshot.pending, .undelivered).count == 2
        }, "the outbox demo state landed")
        return (AppEnvironment.single(session, defaults: defaults), session)
    }

    private func captureOutbox(into dir: URL, linking: LinkingViewModel) async throws -> [ScreenshotHost.IndexRow] {
        let (env, session) = try await outboxDemoEnv()
        let host = ScreenshotHost(directory: dir, env: env, linking: linking)
        let first = try XCTUnwrap(OutboxItem.rows(session.workbenchReplica.snapshot.pending, .undelivered).first).id

        try await host.capture("37-now-outbox", Self.app(.now)(env))
        try await host.capture("38-not-delivered-list", NavigationStack { NotDeliveredView() })
        try await host.capture("38c-not-delivered-dismiss-confirm", NavigationStack { NotDeliveredView(confirming: true) })
        try await host.capture("38r-not-delivered-retry-error", NavigationStack {
            NotDeliveredView(retrying: [first], errors: [first: NotDeliveredModel.lockedRetryError])
        })
        let source = "Features/Now/NotDeliveredView.swift"
        return [
            ScreenshotHost.IndexRow(number: "37", view: "NowView", source: "Features/Now/NowView.swift", reached: "full app, outbox demo"),
            ScreenshotHost.IndexRow(number: "38", view: "NotDeliveredView", source: source, reached: "bare stack, outbox demo"),
            ScreenshotHost.IndexRow(number: "38c", view: "NotDeliveredView", source: source, reached: "bare stack, Dismiss All confirmation"),
            ScreenshotHost.IndexRow(number: "38r", view: "NotDeliveredView", source: source, reached: "bare stack, a retry over a failed one")
        ]
    }

    /// R30 (relay client mockup 7.7, R32): Not delivered with a move the hub's switch to Relay left behind ("<Mac>
    /// runs over Relay now") above a Phase 1 row refused for good, on its own demo session, in light, dark and narrow.
    private func captureHubOnRelay(into dir: URL, linking: LinkingViewModel) async throws -> [ScreenshotHost.IndexRow] {
        let transport = RefusingTransport()
        let defaults = try makeDefaults()
        let session = try HubSession(
            transport: transport,
            replicaPath: try makeReplicaPath(),
            backend: .inMemoryDemo,
            keys: try DemoSeed.phoneKeys(),
            defaults: defaults,
            recordingsDirectory: try makeRecordingsDirectory()
        )
        addTeardownBlock { @MainActor in session.stop() }
        try await poll(timeout: 20, { session.isBootstrapped && !session.workbenchReplica.snapshot.workbenches.isEmpty }, "the demo booted")
        await session.outboxWork?.value
        try await session.outbox.enableOrderedActions()
        await transport.refuse(.unreachable)
        let workbench = DemoSeed.acmeID
        _ = try await session.outbox.enqueue(
            kind: .boardTargetStatus, entityRecordName: SliceKind.workbenchTarget.recordName(id: "416"),
            params: try BoardTargetStatusParams(workbenchID: workbench, status: .done, fromStatus: .todo).wireParams())
        _ = try await session.outbox.flush()
        try await session.outbox.listUnechoedAsUndelivered(reason: .hubOnRelay)
        await transport.refuse(.permanent(code: "zone_gone"))
        _ = try await session.outbox.enqueue(
            kind: .askAnswer, entityRecordName: SliceKind.ownerAsk.recordName(id: "109"),
            params: try AskAnswerParams(
                workbenchID: workbench, answer: OwnerAskAnswer(answers: [.init(id: "q1", labels: ["Archive Now"])])
            ).wireParams())
        _ = try await session.outbox.flush()
        try await poll(timeout: 20, { OutboxItem.rows(session.workbenchReplica.snapshot.pending, .undelivered).count == 2 }, "both listed")
        let env = AppEnvironment.single(session, defaults: defaults)
        let host = ScreenshotHost(directory: dir, env: env, linking: linking)
        // The narrow frame scrolls past the title and the footer to the two rows (mockup 7.7's SE frame shows them).
        try await host.captureThree("R30-not-delivered-hub-on-relay", NavigationStack { NotDeliveredView() }, narrowScroll: 480)
        return [
            ScreenshotHost.IndexRow(
                number: "R30", view: "NotDeliveredView", source: "Features/Now/NotDeliveredView.swift",
                reached: "bare stack, a hub-on-relay row over a refused one, light/dark/narrow")
        ]
    }

    private static func indexRows(_ shots: [Shot]) -> [ScreenshotHost.IndexRow] {
        shots.flatMap { shot in
            let view = URL(fileURLWithPath: shot.source).deletingPathExtension().lastPathComponent
            let row = ScreenshotHost.IndexRow(number: shot.number, view: view, source: shot.source, reached: shot.reached.rawValue)
            let end = ScreenshotHost.IndexRow(
                number: "\(shot.number)e", view: view, source: shot.source,
                reached: "\(shot.reached.rawValue), scrolled to the end"
            )
            return shot.hasEnd ? [row, end] : [row]
        }
    }

    // MARK: - How a screen is reached

    /// A tab of the full app, with the Calendar stack at `path`.
    private static func app(_ tab: RootTabView.Tab, path: [CalendarRoute] = []) -> @MainActor (AppEnvironment) -> AnyView {
        { env in
            env.navigation.tab = tab
            env.navigation.calendarPath = path
            return AnyView(RootTabView())
        }
    }

    /// A Workbench push (target, session, ask) or a pushed form, in a bare
    /// stack without the tab bar.
    private static func stack<Content: View>(
        _ content: @escaping @MainActor (AppEnvironment) -> Content
    ) -> @MainActor (AppEnvironment) -> AnyView {
        { env in AnyView(NavigationStack { content(env) }) }
    }

    /// A sheet (which owns its stack) or an onboarding leaf view.
    private static func leaf<Content: View>(
        _ content: @escaping @MainActor (AppEnvironment) -> Content
    ) -> @MainActor (AppEnvironment) -> AnyView {
        { env in AnyView(content(env)) }
    }

    // MARK: - The tour table (the review's screen numbers)

    /// DS1–DS8: the design system's parts in the redesign mockups' states
    /// (`docs/design/mobile/mockups.html`, the screen number in each slug),
    /// for a side-by-side check against the mockups.
    static func designSystemShots() -> [Shot] {
        let gallery = "../Tests/Support/DesignSystemGallery.swift"
        let pages: [(String, String, @MainActor () -> AnyView)] = [
            ("DS1", "now-m1", { AnyView(DesignSystemGallery.nowPage) }),
            ("DS2", "workchat-working-m3", { AnyView(DesignSystemGallery.workchatWorkingPage) }),
            ("DS3", "workchat-waiting-m4", { AnyView(DesignSystemGallery.workchatWaitingPage) }),
            ("DS4", "board-m5", { AnyView(DesignSystemGallery.boardPage) }),
            ("DS5", "calendar-m7", { AnyView(DesignSystemGallery.calendarPage) }),
            ("DS6", "mac-asleep-m8", { AnyView(DesignSystemGallery.workchatAsleepPage) }),
            ("DS7", "parts-bars-m9-12", { AnyView(DesignSystemGallery.actionsPage) }),
            ("DS8", "settings-m16", { AnyView(DesignSystemGallery.settingsPage) })
        ]
        return pages.map { number, slug, page in
            Shot(number: number, slug: slug, source: gallery, reached: .leaf) { _ in page() }
        }
    }

    static func workbenchShots() -> [Shot] {
        let acme = DemoSeed.acmeID
        let source = "Features/Workbench/"
        return [
            Shot(number: "01", slug: "now", source: "Features/Now/NowView.swift", reached: .fullApp, hasEnd: true, make: app(.now)),
            Shot(number: "02", slug: "workbench-list", source: source + "WorkbenchListView.swift", reached: .fullApp, make: app(.workbench)),
            Shot(number: "03", slug: "calendar", source: "Features/Calendar/AgendaView.swift", reached: .fullApp, hasEnd: true, make: app(.calendar)),
            Shot(number: "05", slug: "workbench-sessions", source: source + "WorkbenchView.swift", reached: .bareStack, make: stack {
                WorkbenchView(replica: $0.workbenchReplica, writer: $0.boardWriter, workbenchID: acme, segment: .sessions)
            }),
            Shot(number: "06", slug: "workbench-board", source: source + "BoardView.swift", reached: .bareStack, make: stack {
                WorkbenchView(replica: $0.workbenchReplica, writer: $0.boardWriter, workbenchID: acme, segment: .board)
            }),
            Shot(number: "07", slug: "target-415", source: source + "BoardTargetDetailView.swift", reached: .bareStack, hasEnd: true, make: stack {
                BoardTargetDetailView(replica: $0.workbenchReplica, writer: $0.boardWriter, targetID: 415)
            }),
            Shot(number: "08", slug: "target-400-group", source: source + "BoardTargetDetailView.swift", reached: .bareStack, make: stack {
                BoardTargetDetailView(replica: $0.workbenchReplica, writer: $0.boardWriter, targetID: 400)
            })
        ] + sessionShots() + askShots() + [
            Shot(number: "18", slug: "start-session", source: source + "StartSessionSheet.swift", reached: .sheet, make: leaf { _ in
                StartSessionSheet(workbenchID: acme, target: nil, fixed: false) { _ in }
            }),
            Shot(number: "19", slug: "new-target", source: source + "NewBoardTargetSheet.swift", reached: .sheet, make: leaf {
                NewBoardTargetSheet(replica: $0.workbenchReplica, writer: $0.boardWriter, workbenchID: acme)
            })
        ]
    }

    /// The workchat (mockups 3, 4, 8): 09 waiting (inline asks), 09w
    /// working (the timer, a sent line), 10 needs approval, 11 finished,
    /// 12 failed; 12r the report and timeline behind the actions menu.
    static func sessionShots() -> [Shot] {
        let workchat = "Features/Workbench/WorkchatView.swift"
        let shots = [("09", 11, "waiting"), ("09w", 10, "working"), ("10", 12, "needs-approval"), ("11", 13, "finished"), ("12", 16, "failed")]
            .map { number, id, slug in
                Shot(number: number, slug: "session-\(id)-\(slug)", source: workchat, reached: .bareStack, make: stack {
                    WorkchatView(replica: $0.workbenchReplica, sessionID: id, store: $0.store, requester: $0.chatRequests)
                })
            }
        return shots + [
            Shot(number: "12r", slug: "session-11-report", source: "Features/Workbench/SessionReportView.swift", reached: .bareStack, make: stack {
                SessionReportView(replica: $0.workbenchReplica, sessionID: 11, store: $0.store, requester: $0.reportRequests)
            })
        ]
    }

    /// 13 question, 14 review, 15 check, 16 answered, 17 withdrawn.
    static func askShots() -> [Shot] {
        [("13", 109, "question"), ("14", 110, "review"), ("15", 111, "check"), ("16", 105, "answered"), ("17", 107, "withdrawn")]
            .map { number, id, slug in
                Shot(number: number, slug: "ask-\(id)-\(slug)", source: "Features/Asks/AskView.swift", reached: .bareStack, make: stack {
                    AskView(replica: $0.workbenchReplica, drafts: $0.askDrafts, answerer: $0.askAnswerer, askID: id)
                })
            }
    }

    static func calendarShots() -> [Shot] {
        let event = "Features/Calendar/EventDetailView.swift"
        return [
            Shot(number: "20", slug: "event-upcoming", source: event, reached: .fullApp, hasEnd: true,
                 make: app(.calendar, path: [.event("demo-evt-roadmap")])),
            Shot(number: "21", slug: "event-past-recap", source: event, reached: .fullApp, make: app(.calendar, path: [.event("demo-evt-standup")])),
            Shot(number: "22", slug: "event-phone-recording", source: event, reached: .fullApp,
                 make: app(.calendar, path: [.event(DemoSeed.recordedEventID)])),
            Shot(number: "23", slug: "recordings", source: "Features/Recordings/RecordingsListView.swift", reached: .fullApp,
                 make: app(.calendar, path: [.recordings])),
            Shot(number: "24", slug: "recap", source: "Features/Recordings/RecapView.swift", reached: .fullApp,
                 make: app(.calendar, path: [.recap(501)])),
            Shot(number: "25", slug: "transcript", source: "Features/Recordings/RecapView.swift", reached: .bareStack, make: stack { _ in
                RecapView(transcriptID: 501, initialTab: .transcript)
            }),
            Shot(number: "26", slug: "recorder-idle", source: "Features/Recording/RecordingView.swift", reached: .leaf,
                 make: leaf { _ in RecordingView() }),
            Shot(number: "27", slug: "settings", source: "Features/Settings/SettingsView.swift", reached: .bareStack,
                 make: stack { _ in SettingsView() })
        ]
    }

    static func onboardingShots() -> [Shot] {
        let source = "Features/Onboarding/"
        let mac = DemoSeed.macName
        return [
            Shot(number: "28", slug: "welcome", source: source + "WelcomeView.swift", reached: .leaf, make: leaf { _ in WelcomeView() }),
            Shot(number: "29", slug: "scan", source: source + "ScanView.swift", reached: .leaf, make: leaf { _ in
                ScanView(onCode: { _ in }, onCancel: {})
            }),
            Shot(number: "30", slug: "checking", source: source + "LinkSteps.swift", reached: .leaf, make: leaf { _ in
                LinkStepsView(model: LinkStepsModel(waitingFor: nil, startedAt: nil, now: Date()))
            }),
            Shot(number: "31", slug: "waiting", source: source + "LinkSteps.swift", reached: .leaf, make: leaf { _ in
                LinkStepsView(model: LinkStepsModel(waitingFor: mac, startedAt: Date(), now: Date()))
            }),
            Shot(number: "31b", slug: "waiting-hint", source: source + "LinkSteps.swift", reached: .leaf, make: leaf { _ in
                LinkStepsView(model: LinkStepsModel(waitingFor: mac, startedAt: Date().addingTimeInterval(-25), now: Date()))
            }),
            Shot(number: "32", slug: "too-many-macs", source: source + "LinkedView.swift", reached: .leaf, make: leaf { _ in
                LinkFailureView(failure: .tooManyMacs)
            }),
            Shot(number: "33", slug: "failure", source: source + "LinkedView.swift", reached: .leaf, make: leaf { _ in
                LinkFailureView(failure: .expired)
            }),
            Shot(number: "34", slug: "linked", source: source + "LinkedView.swift", reached: .leaf, make: leaf { _ in LinkedView(macName: mac) }),
            Shot(number: "36", slug: "mac-switcher", source: "Features/Hubs/HubListSheet.swift", reached: .sheet, make: leaf { _ in
                HubListSheet { _ in }
            }),
            Shot(number: "35", slug: "mac-not-showing", source: source + "MacNotShowingView.swift", reached: .bareStack, make: stack { _ in
                MacNotShowingView()
            })
        ]
    }

    /// Review focus 1: an end shot finds only a scroll view taller than its
    /// bounds; a screen that fits has none, and its end shot is the screen
    /// at rest.
    func testTheEndVariantFindsOnlyAScrollViewTallerThanItsBounds() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let fits = UIScrollView(frame: root.bounds)
        fits.contentSize = CGSize(width: 100, height: 80)
        root.addSubview(fits)
        XCTAssertNil(ScreenshotHost.tallScrollView(in: root), "content that fits has no end to scroll to")

        let tall = UIScrollView(frame: root.bounds)
        tall.contentSize = CGSize(width: 100, height: 300)
        fits.addSubview(tall)
        XCTAssertTrue(ScreenshotHost.tallScrollView(in: root) === tall)
        XCTAssertEqual(ScreenshotHost.endOffset(of: tall), 200)
    }

    /// Phases 1–2 review: a list under a navigation bar and a tab bar
    /// scrolls when its content plus its insets is taller than its bounds,
    /// even when the content alone fits.
    func testAnEndShotCountsTheScrollViewsInsets() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let inset = UIScrollView(frame: root.bounds)
        inset.contentSize = CGSize(width: 100, height: 80)
        inset.contentInset = UIEdgeInsets(top: 30, left: 0, bottom: 0, right: 0)
        root.addSubview(inset)
        XCTAssertTrue(ScreenshotHost.tallScrollView(in: root) === inset, "80 + 30 is taller than 100")
        XCTAssertEqual(ScreenshotHost.endOffset(of: inset), -20, "10 pt past the resting offset of -30")
    }
}

/// The outbox demo's transport: the in-memory one, whose conditional saves are refused while a refusal is set.
private actor RefusingTransport: ConditionalTransport {
    private let inner = InMemoryCloudTransport()
    private var refusal: TransportRefusal?

    func refuse(_ refusal: TransportRefusal?) {
        self.refusal = refusal
    }

    func save(_ records: [CloudRecord]) async throws {
        try await inner.save(records)
    }

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        try await inner.delete(recordNames: recordNames, in: zone)
    }

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        try await inner.changes(in: zone, since: token)
    }

    func save(_ items: [ConditionalSave]) async throws -> [SaveOutcome] {
        if let refusal {
            return items.map { _ in .refused(refusal) }
        }
        return try await inner.save(items)
    }

    func delete(_ items: [ConditionalDelete]) async throws -> [DeleteOutcome] {
        try await inner.delete(items)
    }
}
