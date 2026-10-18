import XCTest
@testable import WatchtowerCore

/// The wire shape of `watchtower linear accounts --json` and `linear teams
/// --json` (`cmd/linear.go`): the Swift decoder pins the keys.
final class LinearAccountTests: XCTestCase {
    func testDecodesTheAccountsJSONAndDropsRemovedOnes() throws {
        let json = """
            [
              {"id": 1, "label": "", "org_name": "Acme", "url": "https://linear.app/acme",
               "status": "ok", "enabled": true, "error": "", "auth": "api_key"},
              {"id": 2, "label": "Side", "org_name": "Beta", "url": "", "status": "revoked",
               "enabled": false, "error": "token revoked", "auth": "oauth"},
              {"id": 3, "label": "", "org_name": "Gone", "url": "", "status": "removed",
               "enabled": false, "error": "", "auth": ""}
            ]
            """
        let accounts = try LinearAccount.decodeList(Data(json.utf8))
        XCTAssertEqual(accounts.map(\.id), [1, 2])
        XCTAssertEqual(accounts[0].displayName, "Acme")
        XCTAssertTrue(accounts[0].usesAPIKey)
        XCTAssertEqual(accounts[0].authLabel, "Personal API key")
        XCTAssertEqual(accounts[1].displayName, "Side", "a label wins over the workspace name")
        XCTAssertFalse(accounts[1].isOK)
        XCTAssertEqual(accounts[1].authLabel, "Signed in with Linear")
    }

    /// The CLI prints `[]`, never `null`, for no accounts.
    func testEmptyListDecodes() throws {
        XCTAssertEqual(try LinearAccount.decodeList(Data("[]\n".utf8)), [])
        XCTAssertEqual(try LinearTeam.decodeList(Data("[]".utf8)), [])
    }

    func testAuthLabelsForMissingAndBrokenCredentials() {
        XCTAssertEqual(LinearAccount(id: 1, auth: "").authLabel, "Not signed in")
        XCTAssertEqual(LinearAccount(id: 1, auth: "error").authLabel, "Credential unreadable — sign in again")
        XCTAssertEqual(LinearAccount(id: 7).displayName, "Linear workspace 7")
    }

    func testDecodesTeams() throws {
        let json = #"[{"key": "ENG", "name": "Engineering", "selected": true}, {"key": "OPS", "name": "Ops", "selected": false}]"#
        let teams = try LinearTeam.decodeList(Data(json.utf8))
        XCTAssertEqual(teams, [
            LinearTeam(key: "ENG", name: "Engineering", selected: true),
            LinearTeam(key: "OPS", name: "Ops", selected: false)
        ])
    }
}
