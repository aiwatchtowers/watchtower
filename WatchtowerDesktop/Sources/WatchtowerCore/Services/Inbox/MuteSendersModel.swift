import Foundation

/// What one **Mute N Senders** press did.
package enum MuteSendersResult: Equatable {
    /// Every ticked sender was muted.
    case done(Int)
    /// `done` of `of` were muted before the first failure stopped the press.
    case partial(done: Int, of: Int, error: String)
}

/// Mail waiting's **Mute Senders…** panel (spec "Waiting for me and Mail
/// waiting"): the ten busiest unmuted senders that have an address, none
/// ticked when it opens, and one button whose title follows the count.
/// A press writes one mute per ticked sender, in row order, through `mute`
/// (the Desktop's one rules writer, INBOX-05) and stops at the first failure;
/// the senders it muted leave the panel, the rest stay ticked.
@MainActor
package final class MuteSendersModel: ObservableObject {
    /// The panel's cap.
    package static let limit = 10

    @Published package private(set) var rows: [MailSenderRow] = []
    /// The ticked senders' addresses.
    @Published package var selected: Set<String> = []
    /// Why the senders could not be read; nil after a read that landed.
    @Published package private(set) var loadError: String?
    /// "Muted N of M. <error>" under the button after a press that stopped.
    @Published package private(set) var failureLine: String?
    @Published package private(set) var isLoading = false
    @Published package private(set) var isApplying = false

    private let loadRows: () async throws -> [MailSenderRow]
    private let mute: (String) async throws -> Void

    /// `load` reads the busiest unmuted senders (ask for one more than
    /// `limit`: a sender without an address is dropped); `mute` writes one
    /// sender's mute and throws when it could not.
    package init(load: @escaping () async throws -> [MailSenderRow], mute: @escaping (String) async throws -> Void) {
        loadRows = load
        self.mute = mute
    }

    /// "Mute Senders" with none ticked, "Mute 1 Sender", "Mute N Senders".
    package var buttonTitle: String {
        switch selected.count {
        case 0: "Mute Senders"
        case 1: "Mute 1 Sender"
        case let n: "Mute \(n) Senders"
        }
    }

    package var canApply: Bool { !selected.isEmpty && !isApplying }

    /// Reads the senders; nothing is ticked.
    package func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await loadRows()
            rows = Array(loaded.filter { !$0.address.isEmpty }.prefix(Self.limit))
            loadError = nil
        } catch {
            rows = []
            loadError = error.localizedDescription
        }
        selected = []
        failureLine = nil
    }

    /// Mutes the ticked senders in row order, each once, stopping at the
    /// first failure.
    package func apply() async -> MuteSendersResult {
        let ticked = rows.map(\.address).filter(selected.contains)
        guard !ticked.isEmpty, !isApplying else { return .done(0) }
        isApplying = true
        defer { isApplying = false }
        failureLine = nil
        var muted: Set<String> = []
        defer {
            rows.removeAll { muted.contains($0.address) }
            selected.subtract(muted)
        }
        for address in ticked {
            do {
                try await mute(address)
                muted.insert(address)
            } catch {
                let message = error.localizedDescription
                failureLine = "Muted \(muted.count) of \(ticked.count). \(message)"
                return .partial(done: muted.count, of: ticked.count, error: message)
            }
        }
        return .done(muted.count)
    }
}
