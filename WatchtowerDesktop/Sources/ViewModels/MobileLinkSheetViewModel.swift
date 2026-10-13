import CoreGraphics
import Foundation
import WatchtowerSync

/// The QR sheet of Settings → Mobile (mobile POC spec §2.3): issues a code
/// on the link center, counts its 10 minutes down, offers New code, and
/// closes the public link at 0 (`.expired`) and when the sheet closes
/// (`.sheetClosed`). The open code itself lives on `MobileLinkCenter`; this
/// model only shows it. While phones wait for the owner's confirmation
/// (`MobileLinkCenter.pendingLinks`, mobile E2E spec §2.3), the sheet shows
/// them with their four-digit codes instead of the QR; Link and Refuse go to
/// the center.
@MainActor
@Observable
final class MobileLinkSheetViewModel: Identifiable {
    enum Phase: Equatable {
        case issuing
        case showing(LinkPayload)
        /// The countdown reached 0, or the center closed the code.
        case expired
        /// A phone used the code; its name.
        case linked(String)
        /// `issueCode()` refused (the spec's iCloud sentences).
        case failed(String)
    }

    private(set) var phase: Phase = .issuing
    /// Seconds left on the code on screen.
    private(set) var remainingSeconds = 0
    /// The QR of the code on screen, rendered once per code.
    private(set) var qrImage: CGImage?
    /// Why the last Link or Refuse failed; nil once one succeeds.
    private(set) var decisionError: String?

    /// The link requests waiting for the owner. They live on the center, so they survive the sheet.
    var pendingLinks: [MobileLinkCenter.PendingLink] { center.pendingLinks }

    @ObservationIgnored private let center: MobileLinkCenter
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    /// The close at 0, outside the countdown task: a New code waits for it,
    /// so the old close never lands on the new code's link.
    @ObservationIgnored private var expiryClose: Task<Void, Never>?
    /// The phones linked before the code was shown: a new one used it.
    @ObservationIgnored private var knownDevices: Set<String> = []
    @ObservationIgnored private var started = false
    /// A code is being issued: a second New code click is dropped.
    @ObservationIgnored private var issuing = false
    @ObservationIgnored private var closed = false

    init(
        center: MobileLinkCenter,
        now: @escaping () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.center = center
        self.now = now
        self.sleep = sleep
    }

    /// "9:59".
    var countdownText: String {
        String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    /// The first code, when the sheet appears.
    func start() async {
        guard !started else { return }
        started = true
        await issue()
    }

    /// New code (and Show a new code once it expired).
    func newCode() async {
        await issue()
    }

    /// Link: the phone is linked and gets its keys; the code is used.
    func confirm(_ link: MobileLinkCenter.PendingLink) async {
        await decide { try await $0.confirmLink(deviceID: link.id) }
    }

    /// Refuse: the phone reads `not_confirmed`.
    func refuse(_ link: MobileLinkCenter.PendingLink) async {
        await decide { try await $0.refuseLink(deviceID: link.id) }
    }

    private func decide(_ decision: (MobileLinkCenter) async throws -> Void) async {
        do {
            try await decision(center)
            decisionError = nil
        } catch {
            decisionError = error.localizedDescription
        }
    }

    /// The sheet closed: no more countdown, and the public link closes.
    func close() async {
        closed = true
        countdownTask?.cancel()
        countdownTask = nil
        await center.closeLink(reason: .sheetClosed)
    }

    private func issue() async {
        guard !issuing else { return }
        issuing = true
        defer { issuing = false }
        countdownTask?.cancel()
        countdownTask = nil
        await expiryClose?.value
        guard !closed else { return }
        phase = .issuing
        knownDevices = Set(center.devices.map(\.deviceID))
        do {
            let code = try await center.issueCode()
            // Closed while the code was being made: it must not stay open.
            guard !closed else {
                await center.closeLink(reason: .sheetClosed)
                return
            }
            qrImage = LinkQRCode.cgImage(for: code.url().absoluteString)
            phase = .showing(code)
            updateRemaining(code)
            startCountdown()
        } catch {
            guard !closed else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self, sleep] in
            while !Task.isCancelled {
                guard let self, await self.tick() else { return }
                await sleep(.seconds(1))
            }
        }
    }

    /// One countdown step; false once the code is no longer on screen. At 0
    /// it closes the link (the center's own expiry timer may have already).
    @discardableResult
    func tick() async -> Bool {
        guard case .showing(let code) = phase else { return false }
        if center.openCode?.nonce != code.nonce {
            if let linked = center.devices.first(where: { !knownDevices.contains($0.deviceID) }) {
                phase = .linked(linked.name)
                return false
            }
        }
        updateRemaining(code)
        guard remainingSeconds <= 0 || center.openCode?.nonce != code.nonce else { return true }
        if center.openCode == nil, center.lastCloseReason == .accountChanged {
            phase = .failed(MobileLinkError.accountChanged.localizedDescription)
            return false
        }
        phase = .expired
        let close = Task { [center] in await center.closeLink(reason: .expired) }
        expiryClose = close
        await close.value
        return false
    }

    private func updateRemaining(_ code: LinkPayload) {
        remainingSeconds = max(0, Int(code.exp - Int64(now().timeIntervalSince1970)))
    }
}
