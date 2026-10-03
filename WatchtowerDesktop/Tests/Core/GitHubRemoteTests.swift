import XCTest
@testable import WatchtowerCore

final class GitHubRemoteTests: XCTestCase {
    func testGitHubRemotesGiveTheRepositoryURL() {
        let repo = URL(string: "https://github.com/acme/app")
        for remote in [
            "https://github.com/acme/app.git",
            "https://github.com/acme/app",
            "https://github.com/acme/app/",
            "git@github.com:acme/app.git", // leak-check:allow
            "git@github.com:acme/app", // leak-check:allow
            "ssh://git@github.com/acme/app.git", // leak-check:allow
            "  https://GitHub.com/acme/app.git\n"
        ] {
            XCTAssertEqual(GitHubRemote.repositoryURL(remote: remote), repo, remote)
        }
    }

    func testOtherRemotesGiveNothing() {
        for remote in [
            "",
            "https://gitlab.com/acme/app.git",
            "git@gitlab.com:acme/app.git", // leak-check:allow
            "https://github.com/acme",
            "https://github.com/acme/app/extra",
            "/Users/someone/repos/app.git",
            "file:///tmp/app.git",
            "github.com"
        ] {
            XCTAssertNil(GitHubRemote.repositoryURL(remote: remote), remote)
        }
    }

    func testThePullRequestURL() throws {
        let repo = try XCTUnwrap(URL(string: "https://github.com/acme/app"))
        XCTAssertEqual(GitHubRemote.pullRequestURL(repository: repo, number: 147).absoluteString,
                       "https://github.com/acme/app/pull/147")
    }
}
