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
/// Refuse (`{"confirm":…,"code":…,"moves_to_relay":…,"request":…}` on the
/// child's stdin), then linked or refused. Every `sas` line means "answer this one":
/// a new or reprinted line replaces the code and the warning and asks again,
/// also after Link.
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

    /// Q6 (#2191): the warning under the code when Link moves the Mac from
    /// iCloud to Relay. A hub without a name reads "this Mac".
    nonisolated static func relayMoveWarning(_ mac: String) -> String {
        let name = mac.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Linking this iPhone moves \(name.isEmpty ? "this Mac" : name) to Relay. "
            + "iPhones linked over iCloud without Relay lose their connection until they subscribe."
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
    /// Set on a `sas` line whose `moves_to_relay` is true (Task 4's hub
    /// decides it); cleared by `start()` and every step after the code.
    private(set) var relayMoveWarning: String?

    /// What one `sas` line asks: the owner's answer names exactly these.
    struct Question: Equatable {
        let code: String
        /// False when the line has no key (an older CLI).
        let movesToRelay: Bool
        /// The waiting request's opaque id; empty from an older CLI or hub.
        let request: String
    }

    /// The question on screen (only in `.sas`). Link and Refuse capture it
    /// when the sheet is drawn and hand it back to `confirm`.
    private(set) var question: Question?

    var countdownText: String { Self.expiresText(remainingSeconds) }
    /// The code is on screen: the QR shows, with its countdown.
    var showsCode: Bool {
        switch step {
        case .qr, .waiting: qrImage != nil
        default: false
        }
    }

    @ObservationIgnored private let streamer: (any HubPairStreaming)?
    @ObservationIgnored private let macName: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var session: HubPairSession?
    @ObservationIgnored private(set) var reader: Task<Void, Never>?
    @ObservationIgnored private var countdown: Task<Void, Never>?
    @ObservationIgnored private var expiresAt: Date?
    @ObservationIgnored private var phone = ""
    /// The question of the last answer sent, while its outcome is awaited.
    @ObservationIgnored private var answered: Question?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var closed = false

    init(
        streamer: (any HubPairStreaming)?,
        macName: String = "",
        now: @escaping () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.streamer = streamer
        self.macName = macName
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
        question = nil
        answered = nil
        relayMoveWarning = nil
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

    /// Link (true) or Refuse (false) for `shown`, the question the owner saw
    /// when the sheet was drawn. Sends nothing unless `shown` is still the
    /// question on screen: a click queued behind a newer `sas` line, or a
    /// second click, answers nothing. If the phone's request changed after
    /// the answer, the hub answers `code_changed`, the CLI prints the current
    /// `sas` line and waits, and the sheet asks again (see `receive`).
    func confirm(_ ok: Bool, answering shown: Question) {
        guard case .sas = step, question == shown, let session else { return }
        session.send(Self.answerLine(confirm: ok, shown))
        answered = shown
        markConfirmed()
    }

    /// `{"code":…,"confirm":…,"moves_to_relay":…,"request":…}` on the
    /// child's stdin (one line), every key copied from the `sas` line the
    /// owner answered, with a no as well. `request` is empty when the line
    /// had none or an empty one (an older CLI or hub); the CLI then decides
    /// whether the answer can stand.
    ///
    /// Built by hand, so it cannot fail: two literal Bools and two strings
    /// quoted by `jsonString`, which escapes every character JSON requires.
    nonisolated static func answerLine(confirm: Bool, _ shown: Question) -> String {
        "{\"code\":\(jsonString(shown.code)),\"confirm\":\(confirm),"
            + "\"moves_to_relay\":\(shown.movesToRelay),\"request\":\(jsonString(shown.request))}"
    }

    /// A JSON string literal: quotes, backslash and control characters escaped.
    nonisolated static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// The step after an answer was sent: waiting for the phone, no code, no
    /// warning (the design shots call it directly).
    func markConfirmed() {
        qrImage = nil
        relayMoveWarning = nil
        question = nil
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
        /// Absent from an older CLI: no warning.
        let movesToRelay: Bool? // swiftlint:disable:this discouraged_optional_boolean
        /// The waiting request's opaque id (Task 4); a replacement has a new one.
        let request: String?

        enum CodingKeys: String, CodingKey {
            case event, url, name, code, reason, request
            case expiresAt = "expires_at"
            case movesToRelay = "moves_to_relay"
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
            relayMoveWarning = nil
            question = nil
            qrImage = LinkQRCode.cgImage(for: raw)
            step = .qr(url, expires: expires)
            startCountdown()
        case "waiting":
            if case .qr = step { step = .waiting }
        case "sas":
            // The latest line is current: a new line replaces the code and the
            // warning, and after an answer it asks again (`code_changed`, or a
            // yes the CLI could not bind). A reprint of exactly the question
            // already answered (same code, move and non-empty request) keeps
            // waiting: that answer is still on its way.
            phone = line.name ?? ""
            let asked = Question(code: line.code ?? "", movesToRelay: line.movesToRelay == true, request: line.request ?? "")
            if case .waiting = step, !asked.request.isEmpty, asked == answered { return }
            countdown?.cancel()
            question = asked
            relayMoveWarning = asked.movesToRelay ? Self.relayMoveWarning(macName) : nil
            step = .sas(code: asked.code, phone: phone)
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
        relayMoveWarning = nil
        question = nil
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
        finish(.refused("expired_code"))
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
