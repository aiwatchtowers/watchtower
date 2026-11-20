import Foundation
import Observation

/// Connecting a company's services on this Mac (#1887, screens spec §3.1–§3.3):
/// a company link the listener took, a pasted company code, the MDM company's
/// **Connect all**, a stored company's **Connect the rest** and **Re-login**.
/// The confirm lists one row per vendor; **Connect** stores the bundle
/// (`company confirm`) and starts the chain in the listener child
/// (`company_connect`), whose `company_vendor` / `company_done` events move
/// the rows. A bundle that changes a stored company's apps asks Replace /
/// Keep current first. Held on `AppState.companyConnect`: closing the sheet
/// keeps the chain running (A10). One flow at a time, sharing the guard with
/// the Slack connect flow (`externalBusy`). Owns every string of the sheet.
@MainActor
@Observable
package final class CompanyConnectFlowModel {
    /// Where the confirm came from: its title and body.
    package enum Variant: Equatable, Sendable {
        case link, code
        /// A link for a stored company with connected services (§3.1).
        case again
        /// The organization's company: **Connect all** on its card.
        case mdm
    }

    /// One changed client value of a stored company (`company inspect`'s
    /// `changes`, ids already shortened by Go; a secret has no values).
    package struct Change: Equatable, Sendable {
        package let vendor: String
        package let field: String
        package let old: String
        package let new: String

        package init(vendor: String, field: String, old: String, new: String) {
            self.vendor = vendor
            self.field = field
            self.old = old
            self.new = new
        }

        /// "Atlassian app: 9f3a…c21 → 7b20…e04" (§3.3).
        package var line: String {
            let label = Self.labels["\(vendor).\(field)"] ?? "\(vendor.capitalized) \(field)"
            if old.isEmpty && new.isEmpty { return "\(label) changed" }
            return "\(label): \(old) → \(new.isEmpty ? "removed" : new)"
        }

        private static let labels = [
            "slack.client_id": "Slack app",
            "google.client_id": "Google client",
            "google.client_secret": "Google client secret",
            "atlassian.client_id": "Atlassian app",
            "atlassian.client_secret": "Atlassian app secret",
            "atlassian.site": "Atlassian site",
            "microsoft.client_id": "Microsoft app",
            "microsoft.tenant_id": "Microsoft tenant",
            "linear.client_id": "Linear app"
        ]
    }

    package enum Phase: Equatable, Sendable {
        case idle
        case confirm
        case replace([Change])
        case chain
        case done
        /// The flow could not go on (the CLI failed, the listener is down,
        /// another connection runs): the message and **Close**.
        case problem(String)
    }

    /// A vendor's place in the chain.
    package enum RowState: Equatable, Sendable {
        case pending, waiting
        case connected(label: String)
        case cancelled
        case failed(String)
        case skipped(String)
    }

    /// The mark a row shows in the chain and done lists.
    package enum RowMark: Equatable, Sendable { case pending, running, done, failed, skipped }

    /// One vendor of the bundle.
    package struct VendorRow: Equatable, Sendable, Identifiable {
        package var id: CompanyVendor { vendor }
        package let vendor: CompanyVendor
        package let title: String
        /// What identifies the company's app: the workspace, domain, site.
        package let detail: String
        /// Already connected (a link again): shown with the Connected chip.
        package let connected: Bool
        /// Forbidden by the organization's policy (`AllowedSources`).
        package let forbidden: Bool
        package var ticked: Bool
        package var state: RowState = .pending

        package init(
            vendor: CompanyVendor,
            title: String,
            detail: String,
            connected: Bool = false,
            forbidden: Bool = false,
            ticked: Bool,
            state: RowState = .pending
        ) {
            self.vendor = vendor
            self.title = title
            self.detail = detail
            self.connected = connected
            self.forbidden = forbidden
            self.ticked = ticked
            self.state = state
        }

        /// The confirm's checkbox can change.
        package var enabled: Bool { !connected && !forbidden }
    }

    package private(set) var phase: Phase = .idle
    package private(set) var variant: Variant = .link
    package private(set) var company = ""
    package private(set) var slug = ""
    package private(set) var rows: [VendorRow] = []
    /// The sheet is on screen; closing it during the chain keeps the chain.
    package private(set) var isPresented = false
    /// A CLI call of this flow runs (reading the bundle, storing it).
    package private(set) var working = false
    /// The confirm's line under the rows when **Connect** could not start.
    package private(set) var connectError: String?

    /// A flow was opened or a refused link brings the running one back:
    /// AppState shows Connections and brings the window forward.
    @ObservationIgnored package var onShow: (() -> Void)?
    /// A bundle was stored or replaced: the Companies zone re-reads.
    @ObservationIgnored package var onCompaniesChanged: (() -> Void)?
    /// A chain ended: the accounts re-read and the daemon picks them up.
    @ObservationIgnored package var onChainEnded: (() -> Void)?
    /// Another sign-in holds the shared guard (the Slack connect flow, a
    /// legacy sign-in): no chain may start.
    @ObservationIgnored package var externalBusy: () -> Bool = { false }

    @ObservationIgnored private let host: SlackConnectListenerHost
    @ObservationIgnored private let makeStreamer: @MainActor () -> (any CLILineStreaming)?
    @ObservationIgnored private let makeFlowID: () -> String
    /// The bundle of a link or code until it is stored.
    @ObservationIgnored private var wire: String?
    /// The company link this flow answers (company_dismiss or company_connect).
    @ObservationIgnored private var linkFlow: String?
    /// The running chain's flow id.
    @ObservationIgnored private var chainFlow: String?
    /// `company_connect` sent, no vendor event yet: a `busy` naming another
    /// flow refuses it.
    @ObservationIgnored private var awaitingStart = false

    package init(
        host: SlackConnectListenerHost,
        makeStreamer: @escaping @MainActor () -> (any CLILineStreaming)?,
        makeFlowID: @escaping () -> String = { UUID().uuidString }
    ) {
        self.host = host
        self.makeStreamer = makeStreamer
        self.makeFlowID = makeFlowID
        host.onCompanyEvent = { [weak self] in self?.handle($0) }
        host.onCompanyChildEnded = { [weak self] in self?.childEnded() }
    }

    // MARK: - State

    /// A flow is open or its CLI runs: a new link, code or chain is refused.
    package var isRunning: Bool {
        if working { return true }
        switch phase {
        case .confirm, .replace, .chain: return true
        case .idle, .done, .problem: return false
        }
    }

    /// The vendor the chain waits for (the Companies card's "Connecting… Google").
    package var currentVendor: CompanyVendor? {
        guard phase == .chain else { return nil }
        return rows.first { $0.state == .waiting }?.vendor
    }

    package var showsSheet: Bool { isPresented && phase != .idle }

    /// **Connect**: something is ticked and nothing runs yet.
    package var canConnect: Bool {
        phase == .confirm && !working && rows.contains { $0.ticked && $0.enabled }
    }

    /// A model held in one state with its sheet up, for the design shots
    /// (`CompanySetupShotFixtures`): it runs no CLI.
    package static func preview(
        _ phase: Phase,
        variant: Variant = .link,
        company: String,
        slug: String,
        rows: [VendorRow],
        host: SlackConnectListenerHost
    ) -> CompanyConnectFlowModel {
        let model = CompanyConnectFlowModel(host: host) { nil }
        model.phase = phase
        model.variant = variant
        model.company = company
        model.slug = slug
        model.rows = rows
        model.isPresented = true
        return model
    }

    // MARK: - Entry points

    /// A pasted company code or link (the Companies zone's field, Slack's
    /// connect field, A20). Nil when the confirm (or the replace warning)
    /// opened; else the field's error, and nothing starts.
    package func paste(_ text: String) async -> String? {
        guard let wire = Self.wire(fromInput: text) else { return Self.codeInvalid }
        guard !isRunning, !externalBusy() else { return Self.anotherRunning }
        return await open(wire: wire, slug: nil, variant: .code, linkFlow: nil)
    }

    /// **Connect all** on the organization's company card: the MDM confirm.
    package func connectAll(slug: String) async {
        guard !isRunning else { return reshow() }
        if let error = await open(wire: nil, slug: slug, variant: .mdm, linkFlow: nil) { show(.problem(error)) }
    }

    /// **Connect the rest**: the confirm's same-bundle variant (A4) — the
    /// connected services listed with their chip, the rest ticked.
    package func connectRest(slug: String) async {
        guard !isRunning else { return reshow() }
        if let error = await open(wire: nil, slug: slug, variant: .again, linkFlow: nil) { show(.problem(error)) }
    }

    /// **Re-login** after a Replace: the chain over the changed vendors.
    package func relogin(slug: String, vendors: [CompanyVendor]) async {
        await startStored(slug: slug) { rows in rows.map(\.vendor).filter(vendors.contains) }
    }

    // MARK: - Sheet buttons

    package func toggle(_ vendor: CompanyVendor) {
        guard phase == .confirm, let index = rows.firstIndex(where: { $0.vendor == vendor }), rows[index].enabled else {
            return
        }
        rows[index].ticked.toggle()
        connectError = nil
    }

    /// The confirm's **Connect**: stores a link's or code's bundle, then
    /// starts the chain over the ticked vendors.
    package func connect() async {
        guard canConnect else { return }
        guard !externalBusy() else {
            connectError = Self.anotherRunning
            return
        }
        let vendors = rows.filter { $0.ticked && $0.enabled }.map(\.vendor)
        if let wire {
            working = true
            let result = await runConfirm(wire: wire, replace: false)
            working = false
            switch result {
            case .failure(let failure):
                dismissLink()
                // Go may have stored the file before a later step failed
                // (marking accounts): the zone re-reads either way.
                onCompaniesChanged?()
                show(.problem(Self.couldNotStore(failure.message)))
                return
            case .success(let confirmed) where confirmed.result == "needs_replace":
                // Another confirm stored a different bundle meanwhile.
                if let error = await open(wire: wire, slug: nil, variant: variant, linkFlow: linkFlow) {
                    show(.problem(error))
                }
                return
            case .success(let confirmed):
                // The chain signs in through the company Go stored, under
                // the slug it stored it (not the one read before).
                if !confirmed.slug.isEmpty { slug = confirmed.slug }
                self.wire = nil
                onCompaniesChanged?()
            }
        }
        startChain(vendors)
    }

    /// **Replace** (§3.3): stores the bundle and marks the changed vendors'
    /// accounts Re-login; nothing else runs.
    package func replace() async {
        guard case .replace = phase, !working, let wire else { return }
        working = true
        let result = await runConfirm(wire: wire, replace: true)
        working = false
        dismissLink()
        self.wire = nil
        // A failure may come after the file was written (marking accounts):
        // the zone re-reads either way.
        onCompaniesChanged?()
        switch result {
        case .failure(let failure):
            show(.problem(Self.couldNotStore(failure.message)))
        case .success:
            finish()
        }
    }

    /// **Keep current**, the replace warning's default: nothing is stored.
    package func keepCurrent() {
        guard case .replace = phase, !working else { return }
        dismissLink()
        finish()
    }

    /// The confirm's **Cancel**: nothing is stored.
    package func cancel() {
        guard phase == .confirm, !working else { return }
        dismissLink()
        finish()
    }

    /// **Skip this service**: ends the waiting vendor's step only.
    package func skipCurrent() {
        guard let flow = chainFlow, let vendor = currentVendor else { return }
        host.send(.companySkip(flow: flow, vendor: vendor))
    }

    /// **Stop**: ends the wait and skips every vendor left.
    package func stop() {
        guard let flow = chainFlow else { return }
        host.send(.companyStop(flow: flow))
    }

    /// **Done** / **Close**.
    package func finish() {
        switch phase {
        case .confirm, .replace, .done, .problem:
            phase = .idle
            isPresented = false
            rows = []
            connectError = nil
            wire = nil
        case .idle, .chain:
            break
        }
    }

    /// The sheet went away (Esc, the close gesture): the confirm cancels,
    /// the warning keeps the current setup, the chain runs on hidden.
    package func close() {
        switch phase {
        case .confirm: cancel()
        case .replace: keepCurrent()
        case .chain: isPresented = false
        case .done, .problem, .idle: finish()
        }
    }

    // MARK: - Reading the bundle

    /// Reads a bundle (`wire`) or a stored company (`slug`) and opens the
    /// confirm or the replace warning. Nil on success, else the error.
    private func open(wire: String?, slug: String?, variant: Variant, linkFlow: String?) async -> String? {
        working = true
        let result = await runInspect(wire: wire, slug: slug)
        working = false
        let inspected: Inspected
        switch result {
        case .failure(let failure):
            if let linkFlow { host.send(.companyDismiss(flow: linkFlow)) }
            return Self.couldNotRead(failure.message)
        case .success(let value):
            inspected = value
        }
        if let refused = inspected.refused {
            if let linkFlow { host.send(.companyDismiss(flow: linkFlow)) }
            // A pasted code is the field's error; a stored company names Go's reason.
            return wire == nil ? Self.couldNotRead(Self.refusedReason(refused)) : Self.codeInvalid
        }
        apply(inspected)
        self.wire = wire
        self.linkFlow = linkFlow
        connectError = nil
        if inspected.state == "changed" && !inspected.forced {
            self.variant = variant
            show(.replace(inspected.changes))
        } else {
            self.variant = variant == .link && rows.contains(where: \.connected) ? .again : variant
            show(.confirm)
        }
        return nil
    }

    /// Re-login: the stored company's rows, then the
    /// chain straight away over `pick`'s vendors (forbidden ones never run).
    private func startStored(slug: String, pick: ([VendorRow]) -> [CompanyVendor]) async {
        guard !isRunning else { return reshow() }
        guard !externalBusy() else { return show(.problem(Self.anotherRunning)) }
        working = true
        let result = await runInspect(wire: nil, slug: slug)
        working = false
        switch result {
        case .failure(let failure):
            show(.problem(Self.couldNotRead(failure.message)))
        case .success(let inspected):
            if let refused = inspected.refused {
                return show(.problem(Self.couldNotRead(Self.refusedReason(refused))))
            }
            apply(inspected)
            // Nothing left to run (all connected or locked): no sheet.
            let vendors = pick(rows.filter { !$0.forbidden })
            guard !vendors.isEmpty else { return finish() }
            startChain(vendors)
        }
    }

    private func apply(_ inspected: Inspected) {
        company = inspected.company
        slug = inspected.slug
        rows = Self.chainOrder.compactMap { vendor in
            guard inspected.vendors.contains(vendor.rawValue) else { return nil }
            let connected = inspected.connected[vendor.rawValue] == true
            let forbidden = inspected.forbidden.contains(vendor.rawValue)
            return VendorRow(
                vendor: vendor,
                title: Self.title(vendor, details: inspected.details[vendor.rawValue]),
                detail: Self.detail(vendor, details: inspected.details[vendor.rawValue], slug: inspected.slug,
                                    company: inspected.company),
                connected: connected,
                forbidden: forbidden,
                ticked: !connected && !forbidden
            )
        }
    }

    // MARK: - The chain

    private func startChain(_ vendors: [CompanyVendor]) {
        let flow = linkFlow ?? makeFlowID()
        linkFlow = nil
        let chain = Self.chainOrder.filter(vendors.contains)
        rows = rows.filter { chain.contains($0.vendor) }.map { row in
            var row = row
            row.state = .pending
            return row
        }
        // The chain runs in the listener child; with port 18551 held by
        // another app there is none (a pasted code still stored the bundle).
        if host.state == .portBusy {
            // Retry the listener now, so the next press works once the port is free.
            host.ensureRunning()
            return show(.problem(Self.portBusy(company)))
        }
        chainFlow = flow
        awaitingStart = true
        show(.chain)
        host.ensureRunning()
        if !host.send(.companyConnect(flow: flow, slug: slug, vendors: chain)) {
            chainFlow = nil
            awaitingStart = false
            show(.problem(Self.listenerDown))
        }
    }

    private func handle(_ event: SlackConnectEvent) {
        switch event {
        case let .companyLink(flow, bundle):
            link(flow: flow, wire: bundle)
        case let .companyVendor(step):
            guard step.flow == chainFlow, let index = rows.firstIndex(where: { $0.vendor == step.vendor }) else { return }
            awaitingStart = false
            rows[index].state = Self.rowState(step.state, label: step.label, message: step.message)
        case let .companyDone(flow, states):
            guard flow == chainFlow else { return }
            // A vendor whose own event was missed takes its end state here.
            for (vendor, state) in states {
                guard let index = rows.firstIndex(where: { $0.vendor == vendor }),
                      [.pending, .waiting].contains(rows[index].state) else { continue }
                rows[index].state = Self.rowState(state, label: "", message: "")
            }
            chainEnded()
        case let .busy(flow):
            // Our company_connect's answer: another flow holds the child.
            // (A busy naming our chain answers someone else's start.)
            guard awaitingStart, let ours = chainFlow, flow != ours else { return }
            // Go refused before it released the company link this chain
            // answered: release it, or every later link waits behind it.
            host.send(.companyDismiss(flow: ours))
            chainFlow = nil
            awaitingStart = false
            show(.problem(Self.anotherRunning))
        case .listening, .portBusy, .link, .linkBusy, .browser, .connected, .failed:
            break
        }
    }

    /// A company link reached the listener: the confirm, unless a flow is
    /// open here or in Slack's connect flow (the shared guard) — then the
    /// link is answered at once and the running sheet stays.
    private func link(flow: String, wire: String) {
        guard !isRunning, !externalBusy() else {
            host.send(.companyDismiss(flow: flow))
            reshow()
            return
        }
        // Busy from now on, not from when the read starts: a link right
        // behind this one is refused.
        working = true
        Task { [weak self] in
            guard let self else { return }
            if let error = await open(wire: wire, slug: nil, variant: .link, linkFlow: flow) { show(.problem(error)) }
        }
    }

    /// The listener child ended: a running chain is gone with it (no
    /// resume); what it connected stays.
    private func childEnded() {
        guard phase == .chain, chainFlow != nil else { return }
        for index in rows.indices where rows[index].state == .pending || rows[index].state == .waiting {
            rows[index].state = .failed(Self.listenerDownReason)
        }
        chainEnded()
    }

    /// The done phase. A Slack sign-in that finished just as Skip arrived is
    /// stored although the chain says skipped: Go's view of the company's
    /// accounts upgrades such a row, so the sheet matches Connections. Only
    /// a skipped row: a cancelled or failed one ended by the person's or
    /// the vendor's answer, whatever other account of the vendor is ok.
    /// The read is best effort — if it fails, the chain's own states stand.
    private func chainEnded() {
        chainFlow = nil
        awaitingStart = false
        phase = .done
        onChainEnded?()
        guard rows.contains(where: { if case .skipped = $0.state { true } else { false } }) else { return }
        let slug = slug
        Task { [weak self] in
            guard let self else { return }
            let result = await runInspect(wire: nil, slug: slug)
            guard case .success(let inspected) = result else {
                if case .failure(let failure) = result { print("[CompanyConnect] re-reading \(slug) after the chain: \(failure.message)") }
                return
            }
            guard phase == .done, self.slug == slug else { return }
            for index in rows.indices where inspected.connected[rows[index].vendor.rawValue] == true {
                if case .skipped = rows[index].state { rows[index].state = .connected(label: "") }
            }
        }
    }

    private func show(_ next: Phase) {
        phase = next
        isPresented = true
        onShow?()
    }

    /// A refused link or press while a flow is open: its sheet comes back.
    private func reshow() {
        guard phase != .idle else { return }
        isPresented = true
        onShow?()
    }

    private func dismissLink() {
        if let flow = linkFlow { host.send(.companyDismiss(flow: flow)) }
        linkFlow = nil
    }

    private static func rowState(_ state: CompanyChainState, label: String, message: String) -> RowState {
        switch state {
        case .waiting: .waiting
        case .connected: .connected(label: label)
        case .cancelled: .cancelled
        case .failed: .failed(message)
        case .skipped: .skipped(message)
        }
    }

    // MARK: - The CLI

    struct Inspected: Decodable, Equatable {
        struct Details: Decodable, Equatable {
            let domain: String
            let site: String
            let confluence: Bool

            private enum CodingKeys: String, CodingKey { case domain, site, confluence }

            init(from decoder: Decoder) throws {
                let box = try decoder.container(keyedBy: CodingKeys.self)
                domain = try box.decodeIfPresent(String.self, forKey: .domain) ?? ""
                site = try box.decodeIfPresent(String.self, forKey: .site) ?? ""
                confluence = try box.decodeIfPresent(Bool.self, forKey: .confluence) ?? false
            }
        }

        let refused: String?
        let company: String
        let slug: String
        let state: String
        let forced: Bool
        let vendors: [String]
        let connected: [String: Bool]
        let changes: [Change]
        let forbidden: [String]
        let details: [String: Details]

        private enum CodingKeys: String, CodingKey {
            case refused, company, slug, state, forced, vendors, connected, changes, forbidden, details
        }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            refused = try box.decodeIfPresent(String.self, forKey: .refused)
            company = try box.decodeIfPresent(String.self, forKey: .company) ?? ""
            slug = try box.decodeIfPresent(String.self, forKey: .slug) ?? ""
            state = try box.decodeIfPresent(String.self, forKey: .state) ?? ""
            forced = try box.decodeIfPresent(Bool.self, forKey: .forced) ?? false
            vendors = try box.decodeIfPresent([String].self, forKey: .vendors) ?? []
            connected = try box.decodeIfPresent([String: Bool].self, forKey: .connected) ?? [:]
            changes = try box.decodeIfPresent([Change].self, forKey: .changes) ?? []
            forbidden = try box.decodeIfPresent([String].self, forKey: .forbidden) ?? []
            details = try box.decodeIfPresent([String: Details].self, forKey: .details) ?? [:]
        }
    }

    /// `company confirm --json`: stored | unchanged | needs_replace, and
    /// the slug the company is stored under.
    struct Confirmed: Decodable {
        let result: String
        let slug: String
    }

    static func inspectArgs(slug: String?) -> [String] {
        ["company", "inspect", "--json"] + (slug.map { ["--slug", $0] } ?? [])
    }

    static func confirmArgs(source: Variant, replace: Bool) -> [String] {
        ["company", "confirm", "--json", "--source", source == .code ? "code" : "link"] + (replace ? ["--replace"] : [])
    }

    private func runInspect(wire: String?, slug: String?) async -> Result<Inspected, CLIFailure> {
        await run(Self.inspectArgs(slug: slug), stdin: wire)
    }

    private func runConfirm(wire: String, replace: Bool) async -> Result<Confirmed, CLIFailure> {
        await run(Self.confirmArgs(source: variant, replace: replace), stdin: wire)
    }

    struct CLIFailure: Error {
        let message: String
    }

    /// One CLI run whose last stdout line is the JSON answer. The bundle
    /// (it carries the company's client secrets) goes on stdin only.
    private func run<T: Decodable>(_ args: [String], stdin: String?) async -> Result<T, CLIFailure> {
        guard let streamer = makeStreamer() else {
            return .failure(CLIFailure(message: CLIRunnerError.binaryNotFound.localizedDescription))
        }
        var last: String?
        do {
            for try await line in streamer.lines(args: args, stdin: stdin.map { Data(($0 + "\n").utf8) })
            where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                last = line
            }
        } catch let CLIRunnerError.nonZeroExit(_, stderr) {
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(CLIFailure(message: text.isEmpty ? Self.noAnswer : text))
        } catch {
            return .failure(CLIFailure(message: error.localizedDescription))
        }
        guard let last else { return .failure(CLIFailure(message: Self.noAnswer)) }
        do {
            return .success(try JSONDecoder().decode(T.self, from: Data(last.utf8)))
        } catch {
            // A Go/Swift contract drift, not a missing answer.
            print("[CompanyConnect] \(args.prefix(2).joined(separator: " ")): unreadable answer: \(error)")
            return .failure(CLIFailure(message: Self.unreadableAnswer))
        }
    }

    // MARK: - Input

    /// The bundle of a pasted company link (`…/company/connect?b=<wire>`) or
    /// code (the wire, maybe wrapped over lines); nil when the text is
    /// neither. Go checks the bundle itself (`company inspect`).
    package static func wire(fromInput text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("/") {
            guard let url = URLComponents(string: trimmed), url.path == "/company/connect",
                  let values = url.queryItems?.filter({ $0.name == "b" }), values.count == 1,
                  let value = values[0].value else { return nil }
            return isWire(value) ? value : nil
        }
        let code = String(trimmed.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        return isWire(code) ? code : nil
    }

    /// Looks like a company bundle: base64url of a JSON object ("eyJ" is
    /// `{"`), so a Slack `T…:…` code never reads as one.
    package static func isCompanyInput(_ text: String) -> Bool { wire(fromInput: text) != nil }

    private static func isWire(_ value: String) -> Bool {
        value.hasPrefix("eyJ") && value.unicodeScalars.allSatisfy { scalar in
            (scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)) || scalar == "-" || scalar == "_"
        }
    }

    // MARK: - Strings (screens spec §3)

    /// The chain's order (spec §3 step 2), the confirm's too.
    package static let chainOrder: [CompanyVendor] = [.slack, .google, .atlassian, .microsoft, .linear]

    package static let blocked = "Blocked by your organization"
    package static let alreadyConnected = "Connected"
    package static let confirmCaption = "Each service opens its own sign-in page in your browser, one after another."
    package static let chainCaption = "You can close this window: the chain goes on and Connections shows where it is."
    package static let chainDoneBody = "The first sync starts now. What is not connected waits in Connections with a Connect button."
    package static let replaceBody = "Keep your current setup unless your admin told you the apps changed. Replacing asks "
        + "you to log in again to what changed."
    package static let replaceCaption = "Nothing leaves this Mac either way."
    package static let chainNext = "Next"
    package static let chainDenied = "You did not allow Watchtower. Connect it later from Connections."
    package static let notConnected = "Not connected"
    package static let skipped = "Skipped"
    /// The code field's error (the Companies zone's words).
    package static let codeInvalid = CompanyConnectionsPresentation.codeInvalid
    package static let pasteDuringOnboarding = "That is a company code. Finish this setup first, then paste it in "
        + "Connections → Companies."
    package static let anotherRunning = "Another connection is running in Watchtower. Try again once it ends."
    static let listenerDown = "Watchtower's connect listener stopped. Open Connections and try again."
    static func portBusy(_ company: String) -> String {
        "\(company) is saved, but its services cannot connect while port 18551 is busy. Quit the app that holds it, "
            + "then use Connect the rest in Connections."
    }
    static let listenerDownReason = "Watchtower's connect listener stopped"
    static let noAnswer = "Watchtower's command line gave no answer"
    static let unreadableAnswer = "Watchtower's command line answered in a form this app does not read; update Watchtower"

    package static let cancelTitle = "Cancel"
    package static let connectTitle = "Connect"
    package static let stopTitle = "Stop"
    package static let skipTitle = "Skip this service"
    package static let doneTitle = "Done"
    package static let closeTitle = "Close"
    package static let replaceTitle = "Replace"
    package static let keepCurrentTitle = "Keep current"

    /// Go's refusal of a stored company (`company inspect --slug`'s `refused`).
    static func refusedReason(_ code: String) -> String {
        switch code {
        case "personal": "it holds your own Google project, not a company's apps"
        case "newer_version": "it needs a newer Watchtower"
        default: "it is damaged (\(code))"
        }
    }

    static func couldNotRead(_ reason: String) -> String { "Watchtower could not read this company setup: \(clean(reason))." }
    static func couldNotStore(_ reason: String) -> String { "Watchtower could not store this company setup: \(clean(reason))." }

    /// The sheet's title in the current phase.
    package var title: String? {
        switch phase {
        case .confirm: variant == .mdm ? "\(company) — Connect all" : "Connect \(company)?"
        case .replace: "\(company)'s link changes its apps"
        case .chain: "Connecting \(company)"
        case .done:
            rows.allSatisfy { if case .connected = $0.state { true } else { false } }
                ? "\(company) is connected" : "\(company) is partly connected"
        case .idle, .problem: nil
        }
    }

    /// The text under the title.
    package var body: String? {
        switch phase {
        case .confirm:
            switch variant {
            case .link, .again: "A link asks Watchtower to connect your accounts through \(company)'s apps. "
                + "Connect only if you opened this link yourself."
            case .code: "This code connects your accounts through \(company)'s apps."
            case .mdm: "Your organization set up \(company)'s apps on this Mac."
            }
        case .replace: Self.replaceBody
        case .done: Self.chainDoneBody
        case let .problem(message): message
        case .idle, .chain: nil
        }
    }

    /// The confirm's MDM badge.
    package var managed: Bool { phase == .confirm && variant == .mdm }

    /// The caption under the rows.
    package var caption: String? {
        switch phase {
        case .confirm: Self.confirmCaption
        case .replace: Self.replaceCaption
        case .chain: Self.chainCaption
        case .idle, .done, .problem: nil
        }
    }

    /// The confirm row's detail: the app's identity, or the policy lock.
    package func confirmDetail(_ row: VendorRow) -> String { row.forbidden ? Self.blocked : row.detail }

    /// The chain / done row's mark and line.
    package func progress(_ row: VendorRow) -> (mark: RowMark, detail: String?) {
        let done = phase == .done
        switch row.state {
        case .pending:
            if done { return (.failed, Self.notConnected) }
            let next = rows.first { $0.state == .pending }?.vendor == row.vendor
            return (.pending, next ? Self.chainNext : nil)
        case .waiting:
            return (.running, "Finish in your browser: \(Self.brand(row.vendor)) asks you to allow Watchtower.")
        case let .connected(label):
            if done { return (.done, nil) }
            return (.done, label.isEmpty ? Self.alreadyConnected : "Connected as \(label)")
        case .cancelled:
            return (.failed, done ? Self.notConnected : Self.chainDenied)
        case let .failed(message):
            let reason = Self.clean(message)
            return (.failed, done ? Self.notConnected
                : "Could not connect: \(reason.isEmpty ? "the sign-in did not finish" : reason). Connect it later from Connections.")
        case let .skipped(message):
            return (.skipped, done || message.isEmpty ? Self.skipped : message)
        }
    }

    private static func clean(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func brand(_ vendor: CompanyVendor) -> String {
        switch vendor {
        case .slack: "Slack"
        case .google: "Google"
        case .atlassian: "Atlassian"
        case .microsoft: "Microsoft"
        case .linear: "Linear"
        }
    }

    static func title(_ vendor: CompanyVendor, details: Inspected.Details?) -> String {
        switch vendor {
        case .slack: "Slack"
        case .google: "Gmail and Calendar"
        case .atlassian: details?.confluence == true ? "Jira and Confluence" : "Jira"
        case .microsoft: "Outlook"
        case .linear: "Linear"
        }
    }

    static func detail(_ vendor: CompanyVendor, details: Inspected.Details?, slug: String, company: String) -> String {
        switch vendor {
        case .slack: "workspace \(slug)"
        case .google: details.map(\.domain).flatMap { $0.isEmpty ? nil : $0 } ?? "Google Workspace"
        case .atlassian: details.flatMap { URL(string: $0.site)?.host } ?? "Atlassian Cloud"
        case .microsoft: "Microsoft 365"
        case .linear: "\(company)'s Linear app"
        }
    }
}

extension CompanyConnectFlowModel.Change: Decodable {}
