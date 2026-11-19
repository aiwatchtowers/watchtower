import Foundation

/// What the Companies zone of the Connections overview reads (company
/// screens spec §4.1): the stored companies (`company list --json`), the
/// wizard draft as a "Setup in progress" line (`company draft show --json`
/// while one exists), and the zone's company-code field. On `AppState`, so
/// the field and the last read survive leaving the tab. Go owns every file;
/// this only reads. The strings are `CompanyConnectionsPresentation`'s.
///
/// Failures: `company list` failing (no binary, a non-zero exit, an
/// unreadable answer) is the zone's read-failed state, never "no company";
/// the draft's own read failing leaves the setup line out (the wizard says
/// why when it opens) and never hides the companies. Two reads racing
/// (appear and a flow ending): the last one started wins.
@MainActor
@Observable
package final class CompaniesZoneModel {
    package private(set) var companies: [CompanyRef] = []
    package private(set) var errors: [CompanyFileError] = []
    /// Each company's Slack client id: the view names its app from the
    /// matching Slack setup record ("Watchtower (A0…)").
    package private(set) var slackClientIDs: [String: String] = [:]
    package private(set) var draft: CompanySetupDraftRef?
    /// `company list` itself failed: the read-failed state.
    package private(set) var listError: String?
    /// No read has finished yet: the zone shows its loading line.
    package private(set) var hasRead = false

    /// **Connect with a company code** opened the field (or the port is busy).
    package private(set) var codeFieldOpen = false
    package var code = "" {
        didSet { if code != oldValue { codeError = nil } }
    }

    /// The field's error under it; nothing started.
    package private(set) var codeError: String?
    /// The pasted code is being read.
    package private(set) var pasting = false

    @ObservationIgnored private let makeStreamer: @MainActor () -> (any CLILineStreaming)?
    @ObservationIgnored private var generation = 0

    package init(makeStreamer: @escaping @MainActor () -> (any CLILineStreaming)?) {
        self.makeStreamer = makeStreamer
    }

    /// The zone over `accounts` (every vendor's rows).
    package func zone(accounts: [AccountRef], portBusy: Bool) -> CompaniesZoneState {
        CompanyConnectionsPresentation.zone(
            companies: companies, errors: errors, draft: draft, accounts: accounts,
            portBusy: portBusy, loading: !hasRead, listError: listError)
    }

    // MARK: - Reading

    /// Re-reads the companies and the draft; a newer call's answer wins.
    package func reload() async {
        generation += 1
        let mine = generation
        let listed = await lastJSON(["company", "list", "--json"], as: ListAnswer.self)
        guard mine == generation else { return }
        switch listed {
        case .failure(let failure):
            listError = failure.message
        case .success(let answer):
            // The whole snapshot lands at once, and only if no newer read started meanwhile.
            let draftRef = await readDraft(state: answer.draft.state)
            guard mine == generation else { return }
            listError = nil
            draft = draftRef
            companies = answer.companies.map(\.ref)
            slackClientIDs = answer.companies.reduce(into: [:]) { out, c in
                if let id = c.vendors?["slack"]?.clientID, !id.isEmpty { out[c.slug] = id }
            }
            errors = answer.errors.map { CompanyFileError(file: $0.file, error: $0.error) }
        }
        hasRead = true
    }

    private func readDraft(state: String) async -> CompanySetupDraftRef? {
        switch state {
        case "unreadable":
            return .unreadable
        case "ok":
            guard case .success(let show) = await lastJSON(["company", "draft", "show", "--json"], as: CompanyDraftShow.self)
            else { return nil }
            switch show.state {
            case "unreadable": return .unreadable
            case "ok": return show.draft.map(Self.inProgress)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// "Setup in progress: Acme, at Atlassian (step 4 of 8)." — the wizard's
    /// own steps and rail names.
    static func inProgress(_ draft: CompanyDraft) -> CompanySetupDraftRef {
        typealias Wizard = CompanySetupWizardModel
        let ticked = CompanyVendor.allCases.filter { draft.services.contains($0.rawValue) }
        let steps: [Wizard.Step] = [.services] + ticked.map(Wizard.Step.vendor) + [.denyList, .publish]
        let step = Wizard.Step(draftName: draft.step).flatMap { steps.contains($0) ? $0 : nil } ?? .services
        return .inProgress(company: draft.company, step: Wizard.railName(step),
                           index: steps.firstIndex(of: step) ?? 0, count: steps.count)
    }

    /// A model held with its code field open, for the design shots
    /// (`CompanySetupShotFixtures`): it runs no CLI.
    package static func preview(code: String = "", codeError: String? = nil) -> CompaniesZoneModel {
        let model = CompaniesZoneModel { nil }
        model.codeFieldOpen = true
        model.code = code
        model.codeError = codeError
        return model
    }

    // MARK: - The code field

    package func openCodeField() {
        codeFieldOpen = true
    }

    /// **Connect**: hands the text to the connect flow (`paste`, which opens
    /// the confirm); its error stays under the field and nothing starts.
    package func submitCode(_ paste: (String) async -> String?) async {
        guard !pasting else { return }
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pasting = true
        let error = await paste(text)
        pasting = false
        codeError = error
        if error == nil {
            code = ""
            codeFieldOpen = false
        }
    }

    // MARK: - CLI

    private func lastJSON<T: Decodable>(_ args: [String], as type: T.Type) async -> Result<T, Failure> {
        guard let streamer = makeStreamer() else { return .failure(Failure(CLIRunnerError.binaryNotFound.localizedDescription)) }
        var last: String?
        do {
            for try await line in streamer.lines(args: args, stdin: nil)
            where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                last = line
            }
        } catch let CLIRunnerError.nonZeroExit(_, stderr) {
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(Failure(text.isEmpty ? Self.noAnswer : text))
        } catch {
            return .failure(Failure(error.localizedDescription))
        }
        guard let last, let value = try? JSONDecoder().decode(T.self, from: Data(last.utf8)) else {
            return .failure(Failure(Self.noAnswer))
        }
        return .success(value)
    }

    package struct Failure: Error, Equatable {
        package let message: String
        init(_ message: String) { self.message = message }
    }

    static let noAnswer = "watchtower gave no readable answer"

    // MARK: - `company list --json`

    private struct ListAnswer: Decodable {
        struct Vendor: Decodable {
            var teamID: String?
            var clientID: String?
            var domain: String?
            var site: String?
            var tenantID: String?
            enum CodingKeys: String, CodingKey {
                case teamID = "team_id", clientID = "client_id", domain, site, tenantID = "tenant_id"
            }
        }

        struct Company: Decodable {
            var slug: String
            var company: String
            var forced: Bool
            var personal: Bool
            var vendors: [String: Vendor]?

            /// What identifies each app in a group caption (Slack's app is named by the view, which knows the setup record).
            var ref: CompanyRef {
                var out: [CompanyVendor: String] = [:]
                for (name, block) in vendors ?? [:] {
                    guard let vendor = CompanyVendor(rawValue: name) else { continue }
                    out[vendor] = switch vendor {
                    case .google: block.domain ?? ""
                    case .atlassian: block.site ?? ""
                    case .microsoft: block.tenantID ?? ""
                    case .slack, .linear: ""
                    }
                }
                return CompanyRef(slug: slug, name: company, forced: forced, personal: personal, vendors: out)
            }
        }

        struct LoadError: Decodable {
            var file: String
            var error: String
        }

        struct Draft: Decodable { var state: String }

        var companies: [Company]
        var errors: [LoadError]
        var draft: Draft
    }
}
