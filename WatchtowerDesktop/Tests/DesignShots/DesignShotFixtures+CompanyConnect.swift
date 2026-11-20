import Foundation
import SwiftUI
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

private typealias Copy = CompanySetupMockCopy
private typealias Flow = CompanyConnectFlowModel

/// The employee's connect sheet (screens spec §3.1–§3.3), rendered by the
/// production `CompanyConnectSheet` over a model held in each state.
@MainActor
enum CompanyConnectShots {
    private static let vendors: [CompanyVendor] = [.slack, .google, .atlassian, .microsoft, .linear]

    private static func rows(connected: Set<CompanyVendor> = [], states: [Flow.RowState]? = nil) -> [Flow.VendorRow] {
        zip(vendors, Copy.vendorRows).enumerated().map { index, pair in
            Flow.VendorRow(vendor: pair.0, title: pair.1.0, detail: pair.1.1, connected: connected.contains(pair.0),
                           ticked: !connected.contains(pair.0), state: states?[index] ?? .pending)
        }
    }

    private static func model(_ phase: Flow.Phase, _ variant: Flow.Variant = .link, rows: [Flow.VendorRow]) -> Flow {
        Flow.preview(phase, variant: variant, company: "Acme", slug: "acme", rows: rows,
                     host: SlackConnectListenerHost(streamer: FakeCLILineStream()))
    }

    private static let changes = [
        Flow.Change(vendor: "atlassian", field: "client_id", old: "9f3a…c21", new: "7b20…e04"),
        Flow.Change(vendor: "google", field: "client_id", old: "1234-abcd…", new: "5678-efgh…")
    ]

    /// Each scene's name (`company-connect-<name>`) and its model.
    static var scenes: [(String, () -> CompanyConnectFlowModel)] {
        [
            ("confirm", { model(.confirm, rows: rows()) }),
            ("confirm-code", { model(.confirm, .code, rows: rows()) }),
            ("confirm-again", { model(.confirm, .again, rows: rows(connected: [.slack, .google])) }),
            ("confirm-mdm", { model(.confirm, .mdm, rows: rows()) }),
            ("chain", { model(.chain, rows: rows(states: [.connected(label: "alice"), .waiting, .pending, .pending, .pending])) }),
            ("chain-failed", {
                model(.chain, rows: rows(states: [.connected(label: "alice"), .cancelled, .waiting, .pending, .pending]))
            }),
            ("done", {
                model(.done, rows: rows(states: [.connected(label: "alice"), .cancelled, .connected(label: ""),
                                                 .connected(label: ""), .skipped("")]))
            }),
            ("replace", { model(.replace(changes), rows: rows()) })
        ]
    }
}

/// The loopback listener's pages as Go writes them: the texts come from
/// Go's fixture `cmd/testdata/company/pages.json` (`TestCompanyPages_Fixture`).
struct CompanyPagesFixture: Decodable {
    struct Page: Decodable {
        let heading: String
        let message: String?
        let messageAcme: String?
        let hint: String?
        let reasons: [String: String]?

        private enum CodingKeys: String, CodingKey {
            case heading, message, hint, reasons
            case messageAcme = "message_acme"
        }
    }

    let open: Page
    let refused: Page
    let newer: Page
    let busy: Page
    let notTaken: Page

    private enum CodingKeys: String, CodingKey {
        case open, refused, newer, busy
        case notTaken = "not_taken"
    }

    static func load() throws -> Self {
        let url = URL(fileURLWithPath: #filePath) // …/WatchtowerDesktop/Tests/DesignShots/<this file>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("cmd/testdata/company/pages.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
