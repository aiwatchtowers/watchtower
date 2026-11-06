import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The argument contract of `watchtower inbox folders …` and the decoding of
/// its pinned `--json` keys (cmd/inbox_folders.go), plus the error mapping.
final class InboxFoldersCLITests: XCTestCase {
    private func folderJSON(id: Int64, kind: String = "owner", parent: String = "1", automations: String = "[]") -> String {
        #"{"id":\#(id),"kind":"\#(kind)","slug":"f\#(id)","title":"F\#(id)","icon":"flag","parent_id":\#(parent),"#
            + #""position":2,"hidden":true,"automation_ids":\#(automations)}"#
    }

    private func cli(_ stdout: String) -> (InboxFoldersCLI, FakeCLIRunner) {
        let runner = FakeCLIRunner(stdout: Data(stdout.utf8))
        return (InboxFoldersCLI(runner: runner), runner)
    }

    // MARK: - Arguments

    func testArgumentsPerVerb() {
        XCTAssertEqual(InboxFoldersCLI.args(.list), ["inbox", "folders", "list", "--json"])
        XCTAssertEqual(
            InboxFoldersCLI.args(.write(.create(title: "Release", icon: "flag", parent: 3, position: 0), expectRevision: 4)),
            ["inbox", "folders", "create", "--title", "Release", "--icon", "flag", "--parent", "3", "--position", "0",
             "--expect-revision", "4", "--json"])
        XCTAssertEqual(
            InboxFoldersCLI.args(.write(.create(title: "R", icon: nil, parent: nil, position: nil), expectRevision: 1)),
            ["inbox", "folders", "create", "--title", "R", "--expect-revision", "1", "--json"],
            "parent and position default on the CLI side")
        XCTAssertEqual(
            InboxFoldersCLI.args(.write(.update(5, title: "New", icon: "", visibility: .shown), expectRevision: 2)),
            ["inbox", "folders", "update", "5", "--title", "New", "--icon", "", "--hidden=false",
             "--expect-revision", "2", "--json"])
        XCTAssertEqual(
            InboxFoldersCLI.args(.write(.update(5, title: nil, icon: nil, visibility: .hidden), expectRevision: 2)),
            ["inbox", "folders", "update", "5", "--hidden=true", "--expect-revision", "2", "--json"])
        XCTAssertEqual(
            InboxFoldersCLI.args(.write(.move(5, parent: 1, position: 3), expectRevision: 9)),
            ["inbox", "folders", "move", "5", "--parent", "1", "--position", "3", "--expect-revision", "9", "--json"])
        XCTAssertEqual(InboxFoldersCLI.args(.write(.delete(5), expectRevision: 9)),
                       ["inbox", "folders", "delete", "5", "--expect-revision", "9", "--json"])
        XCTAssertEqual(
            InboxFoldersCLI.args(.write(.route(automationID: 12, to: .folder(5)), expectRevision: 9)),
            ["inbox", "folders", "route", "12", "--folder", "5", "--expect-revision", "9", "--json"])
        XCTAssertEqual(
            InboxFoldersCLI.args(.write(.route(automationID: 12, to: .newFolder(title: "Release", icon: "bolt", parent: 3)),
                                        expectRevision: 9)),
            ["inbox", "folders", "route", "12", "--new-title", "Release", "--new-icon", "bolt", "--parent", "3",
             "--expect-revision", "9", "--json"])
    }

    func testEveryWriteSendsTheRevision() async throws {
        let (cli, runner) = cli(#"{"revision":5,"folder":\#(folderJSON(id: 4))}"#)
        _ = try await cli.create(title: "A", expectRevision: 4)
        _ = try await cli.update(4, title: "B", expectRevision: 4)
        _ = try await cli.move(4, parent: 1, position: 0, expectRevision: 4)
        for args in runner.invocations {
            XCTAssertEqual(Array(args.suffix(3)), ["--expect-revision", "4", "--json"], args.joined(separator: " "))
        }
    }

    // MARK: - Decoding the pinned keys

    func testListDecodesTheTreeAndItsRoutes() async throws {
        let folders = [folderJSON(id: 1, kind: "root", parent: "null"), folderJSON(id: 2, kind: "approvals"),
                       folderJSON(id: 4, automations: "[7,9]")]
        let stdout = #"{"revision":3,"folders":["# + folders.joined(separator: ",") + "]}"
        let (cli, _) = cli(stdout)

        let result = try await cli.list()
        let tree = result.tree

        XCTAssertEqual(tree.revision, 3)
        XCTAssertEqual(tree.folders.map(\.kind), [.root, .approvals, .owner])
        XCTAssertNil(tree.root.parentID)
        XCTAssertEqual(tree.folder(4), InboxFolder(id: 4, kind: .owner, parentID: 1, slug: "f4", title: "F4",
                                                   icon: "flag", position: 2, hidden: true))
        XCTAssertEqual(tree.routes, [7: 4, 9: 4])
        XCTAssertEqual(result.folders[2].automationIDs, [7, 9])
    }

    func testWriteDeleteAndRouteResults() async throws {
        let write = try await cli(#"{"revision":5,"folder":\#(folderJSON(id: 4))}"#).0
            .update(4, visibility: .hidden, expectRevision: 4)
        XCTAssertEqual(write.revision, 5)
        XCTAssertEqual(write.folder.folder.id, 4)

        let delete = try await cli(#"""
            {"revision":6,"moved":{"folders":2,"automations":1,"artifacts":3,"renamed":[{"id":8,"from":"Notes","to":"Notes (2)"}]}}
            """#).0.delete(4, expectRevision: 5)
        XCTAssertEqual(delete.revision, 6)
        let renamed = [InboxFoldersCLI.DeleteResult.Renamed(id: 8, from: "Notes", to: "Notes (2)")]
        XCTAssertEqual(delete.moved, .init(folders: 2, automations: 1, artifacts: 3, renamed: renamed))

        let route = try await cli(#"{"revision":7,"automation_id":12,"folder":\#(folderJSON(id: 9)),"created":true}"#).0
            .route(automationID: 12, to: .newFolder(title: "F9", icon: nil, parent: nil), expectRevision: 6)
        XCTAssertEqual(route.revision, 7)
        XCTAssertEqual(route.automationID, 12)
        XCTAssertEqual(route.folder.folder.id, 9)
        XCTAssertTrue(route.created)
    }

    func testTheJSONIsTheLastStdoutLine() async throws {
        let (cli, _) = cli("a warning first\n{\"revision\":5,\"folder\":\(folderJSON(id: 4))}\n\n")
        let result = try await cli.update(4, title: "x", expectRevision: 4)
        XCTAssertEqual(result.revision, 5)
    }

    func testUndecodableOutputIsAFailure() async {
        let answers = [
            "",
            "Updated folder #4 \"x\" (revision 5)",
            #"{"revision":5}"#,
            #"{"revision":5,"folder":{"id":4,"kind":"owner","slug":"f","title":"F","icon":"","position":0,"hidden":false,"automation_ids":[]}}"#,
            #"{"revision":5,"folder":\#(folderJSON(id: 4, kind: "shelf"))}"#,
            #"{"revision":6,"moved":{"folders":0,"automations":0,"artifacts":0,"renamed":null}}"#
        ]
        for (index, answer) in answers.enumerated() {
            let (cli, _) = cli(answer)
            do {
                if index == answers.count - 1 {
                    _ = try await cli.delete(4, expectRevision: 5)
                } else {
                    _ = try await cli.update(4, title: "x", expectRevision: 4)
                }
                XCTFail("answer \(index) was taken as success")
            } catch {
                XCTAssertEqual(error as? InboxFoldersCLIError, .unexpectedAnswer, "answer \(index)")
            }
        }
        XCTAssertEqual(InboxFoldersCLIError.unexpectedAnswer.localizedDescription, "Unexpected answer from watchtower")
    }

    // MARK: - Errors

    func testConflictPhraseMapsToMenuChanged() async {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(
            code: 1, stderr: "the Inbox menu changed — reload it and try again (revision 6, you had 5)\n"))
        do {
            _ = try await InboxFoldersCLI(runner: runner).delete(4, expectRevision: 5)
            XCTFail("expected a conflict")
        } catch {
            XCTAssertEqual(error as? InboxFoldersCLIError, .menuChanged)
        }
        XCTAssertEqual(runner.invocations.count, 1, "never retried")
    }

    func testRefusalMapsToRefusedWithoutErrorLead() async {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(
            code: 1, stderr: "warning: config has an unknown key\na folder named \"Release\" already exists here\n"))
        do {
            _ = try await InboxFoldersCLI(runner: runner).create(title: "Release", expectRevision: 1)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? InboxFoldersCLIError, .refused("a folder named \"Release\" already exists here"))
            XCTAssertEqual(error.localizedDescription, "a folder named \"Release\" already exists here")
        }
        XCTAssertEqual(InboxFoldersCLI.map(CLIRunnerError.nonZeroExit(code: 2, stderr: "")),
                       .refused("watchtower exited with code 2"))
    }

    /// A refusal that quotes a title holding the phrase is not a conflict:
    /// only a message that starts with it is.
    func testTitleContainingTheConflictPhraseIsARefusal() {
        let message = #"a folder named "the Inbox menu changed" already exists here"#
        XCTAssertEqual(InboxFoldersCLI.map(CLIRunnerError.nonZeroExit(code: 1, stderr: message + "\n")),
                       .refused(message))
        XCTAssertEqual(InboxFoldersCLI.map(CLIRunnerError.nonZeroExit(
            code: 1, stderr: "warning: slow disk\nthe Inbox menu changed — reload it and try again (revision 2, you had 1)\n")),
                       .menuChanged, "the conflict is the last line")
    }

    func testMissingBinaryMapsToCLIUnavailable() async {
        do {
            _ = try await InboxFoldersCLI(runner: nil).list()
            XCTFail("no runner")
        } catch {
            XCTAssertEqual(error as? InboxFoldersCLIError, .cliUnavailable)
        }
        let runner = FakeCLIRunner(error: CLIRunnerError.binaryNotFound)
        do {
            _ = try await InboxFoldersCLI(runner: runner).delete(4, expectRevision: 1)
            XCTFail("binary not found")
        } catch {
            XCTAssertEqual(error as? InboxFoldersCLIError, .cliUnavailable)
        }
        XCTAssertEqual(InboxFoldersCLIError.cliUnavailable.localizedDescription, "The watchtower CLI isn't available")
    }
}
