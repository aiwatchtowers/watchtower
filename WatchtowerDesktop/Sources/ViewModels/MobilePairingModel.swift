import CoreGraphics
import Foundation
import WatchtowerCore

/// One `watchtower hub pair --json --stream` child: its stdout lines (ending
/// at EOF), a line to its stdin, its exit once reaped, and a stop (SIGTERM to
/// its group, idempotent).
struct HubPairSession: Sendable {
    let lines: AsyncStream<String>
    let send: @Sendable (String) -> Void
    /// The failure text when the child exited non-zero, else nil.
    let failure: @Sendable () async -> String?
    let stop: @Sendable () -> Void
}

/// Starts the pairing stream. Production: `HubPairCLIStreamer`.
@MainActor
protocol HubPairStreaming {
    func startPairing() async throws -> HubPairSession
}

/// The pairing sheet of Settings → Mobile over `hub pair --json --stream`
/// (go hub plan 3 Task 23, Plan 1a Task 15): the QR from the `qr` event and
/// its countdown, waiting, the four-digit code to check (`sas`) with Link and
/// Refuse (`{"confirm":…}` on the child's stdin), then linked or refused.
/// A code that reaches 0 ends the stream and says it expired; New code and
/// Show a new code start a new stream. Closing the sheet stops the child.
@MainActor
@Observable
final class MobilePairingModel: Identifiable {
    enum Step: Equatable {
        case starting
        case qr(URL, expires: Date)
        case waiting
        case sas(code: String, phone: String)
        case linked(String)
        case refused(String)
        case failed(String)
    }

    // MARK: Copy (mockups §11–§13, today's MobileLinkSheet strings)

    nonisolated static let title = "Use Watchtower on iPhone"
    nonisolated static let startingText = "Making a code…"
    nonisolated static let scanText = "Scan it with the iPhone camera or the Watchtower app."
    nonisolated static let waitingText = "Waiting for your phone…"
    nonisolated static let checkCodeText = "Check that your iPhone shows the same code"
    nonisolated static let linkedDetail = "It shows this Mac's board and sessions now."
    nonisolated static let newCodeTitle = "New code"
    nonisolated static let showNewCodeTitle = "Show a new code"
    nonisolated static let tryAgainTitle = "Try again"
    nonisolated static let doneTitle = "Done"
    nonisolated static let cancelTitle = "Cancel"
    nonisolated static let linkTitle = "Link"
    nonisolated static let refuseTitle = "Refuse"
    nonisolated static let qrAccessibilityLabel = "Link code"
    nonisolated static let unknownRefusal = "The phone could not be linked."

    nonisolated static func expiresText(_ seconds: Int) -> String {
        "Expires in \(String(format: "%d:%02d", seconds / 60, seconds % 60))"
    }

    nonisolated static func linkQuestion(_ phone: String) -> String { "Link \u{201C}\(phone)\u{201D}?" }
    nonisolated static func linkedTitle(_ phone: String) -> String { "Linked \(phone)" }

    /// The sentence for a `refused` reason (`wire.Refused*`).
    nonisolated static func refusalText(_ reason: String) -> String {
        switch reason {
        case "used_code": "This code was already used."
        case "expired_code": "This code expired."
        case "unknown_code": "The phone sent a code this Mac does not know."
        case "not_confirmed": "Not linked: the code was not confirmed."
        case "too_many_requests": "Too many phones tried this code."
        default: unknownRefusal
        }
    }

    /// The one action after a refusal: a new code for a known reason, else Try again.
    nonisolated static func refusalAction(_ reason: String) -> String {
        refusalText(reason) == unknownRefusal ? tryAgainTitle : showNewCodeTitle
    }

    private(set) var step: Step = .starting
    /// The QR of the code on screen (kept while waiting), rendered once per code.
    private(set) var qrImage: CGImage?
    private(set) var remainingSeconds = 0

    var countdownText: String { Self.expiresText(remainingSeconds) }
    /// The code is on screen: the QR shows, with its countdown.
    var showsCode: Bool {
        switch step {
        case .qr, .waiting: qrImage != nil
        default: false
        }
    }

    @ObservationIgnored private let streamer: (any HubPairStreaming)?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var session: HubPairSession?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var countdown: Task<Void, Never>?
    @ObservationIgnored private var expiresAt: Date?
    @ObservationIgnored private var phone = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var closed = false

    init(
        streamer: (any HubPairStreaming)?,
        now: @escaping () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.streamer = streamer
        self.now = now
        self.sleep = sleep
    }

    /// Starts a pairing (the sheet appeared, New code, Show a new code, Try again).
    func start() async {
        stopSession()
        guard !closed else { return }
        generation += 1
        let run = generation
        step = .starting
        qrImage = nil
        phone = ""
        guard let streamer else {
            step = .failed(CLIRunnerError.binaryNotFound.localizedDescription)
            return
        }
        let started: HubPairSession
        do {
            started = try await streamer.startPairing()
        } catch {
            if run == generation { step = .failed(error.localizedDescription) }
            return
        }
        guard run == generation, !closed else {
            started.stop()
            return
        }
        session = started
        reader = Task { [weak self] in
            for await line in started.lines {
                guard let self, run == self.generation else { return }
                self.receive(line)
            }
            let failure = await started.failure()
            guard let self, run == self.generation else { return }
            self.streamEnded(failure)
        }
    }

    /// Link (true) or Refuse (false) for the code on screen.
    func confirm(_ ok: Bool) async {
        guard case .sas = step, let session else { return }
        session.send(ok ? #"{"confirm":true}"# : #"{"confirm":false}"#)
        qrImage = nil
        step = .waiting
    }

    /// The sheet closed: the stream stops, nothing more is shown.
    func cancel() {
        closed = true
        generation += 1
        stopSession()
    }

    private func stopSession() {
        countdown?.cancel()
        countdown = nil
        reader?.cancel()
        reader = nil
        session?.stop()
        session = nil
    }

    // MARK: - The stream

    private struct Line: Decodable {
        let event: String
        let url: String?
        let expiresAt: String?
        let name: String?
        let code: String?
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case event, url, name, code, reason
            case expiresAt = "expires_at"
        }
    }

    /// One line of the stream (the design shots feed their own).
    func receive(_ text: String) {
        guard let data = text.data(using: .utf8), let line = try? JSONDecoder().decode(Line.self, from: data) else { return }
        switch line.event {
        case "qr":
            guard let raw = line.url, let url = URL(string: raw) else { return }
            let expires = line.expiresAt.flatMap(MobileHubCLI.date) ?? now().addingTimeInterval(600)
            expiresAt = expires
            qrImage = LinkQRCode.cgImage(for: raw)
            step = .qr(url, expires: expires)
            startCountdown()
        case "waiting":
            if case .qr = step { step = .waiting }
        case "sas":
            phone = line.name ?? ""
            countdown?.cancel()
            step = .sas(code: line.code ?? "", phone: phone)
        case "linked":
            finish(.linked(phone))
        case "refused":
            finish(.refused(line.reason ?? ""))
        default:
            break
        }
    }

    /// The stream ended without linked or refused: the CLI's failure, or the
    /// generic refusal (the design shots end their own).
    func streamEnded(_ failure: String?) {
        switch step {
        case .linked, .refused, .failed: return
        default: finish(.failed(failure ?? Self.unknownRefusal))
        }
    }

    private func finish(_ last: Step) {
        step = last
        countdown?.cancel()
        countdown = nil
        session = nil
    }

    private func startCountdown() {
        countdown?.cancel()
        let run = generation
        countdown = Task { [weak self, sleep] in
            while !Task.isCancelled {
                guard let self, run == self.generation, self.tick() else { return }
                await sleep(.seconds(1))
            }
        }
    }

    /// One countdown step; false once the code is gone. At 0 the stream
    /// stops and the code reads as expired.
    @discardableResult
    func tick() -> Bool {
        guard showsCode, let expiresAt else { return false }
        remainingSeconds = max(0, Int(expiresAt.timeIntervalSince(now()).rounded(.down)))
        guard remainingSeconds <= 0 else { return true }
        stopSession()
        step = .refused("expired_code")
        return false
    }
}

/// `hub pair --json --stream` through the app's `watchtower` binary, over
/// `CodeCLIProcess` (its own process group, reaped).
struct HubPairCLIStreamer: HubPairStreaming {
    nonisolated static let args = ["hub", "pair", "--json", "--stream"]
    let binaryPath: String

    func startPairing() async throws -> HubPairSession {
        let environment = await Constants.resolvedEnvironmentAsync()
        let process = try CodeCLIProcess.launch(executable: binaryPath, arguments: Self.args, environment: environment)
        let output = process.output
        let lines = AsyncStream<String> { continuation in
            let reader = Task.detached {
                var splitter = NDJSONLineSplitter()
                for await chunk in output {
                    for line in splitter.append(chunk) { continuation.yield(line) }
                }
                if let tail = splitter.finish() { continuation.yield(tail) }
                continuation.finish()
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
        return HubPairSession(
            lines: lines,
            send: { process.sendLine($0) },
            failure: {
                let exit = await process.exitStatus
                guard !exit.succeeded else { return nil }
                return MobileHubCLI.reason(CLIRunnerError.nonZeroExit(code: exit.status, stderr: exit.stderr))
            },
            stop: { process.terminateGroup() }
        )
    }
}
