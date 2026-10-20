import XCTest
@testable import CILocal

/// Hits the real GitHub API through `gh`. Skipped unless CI_LOCAL_LIVE=1:
///   CI_LOCAL_LIVE=1 swift test --filter LiveGitHubTests
/// The Mac-safe PR test only touches the throwaway private repo below.
final class LiveGitHubTests: XCTestCase {
    static let sandbox = "MohamedCHAMI/mc-ci-local-sandbox"

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CI_LOCAL_LIVE"] == "1", "set CI_LOCAL_LIVE=1 to run")
    }

    private func gh(_ args: [String]) -> String {
        Shell.run(Shell.gh, args).out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs from 2026-10-20 whose annotations GitHub keeps.
    func testClassifiesRealFailedRuns() {
        // Deploy job GitHub refused to start: "recent account payments have failed".
        XCTAssertEqual(GH.failureKindSync(repo: "MohamedCHAMI/chessvox", id: 39455352537), .billing)
        // A real step failure on the Mac runner.
        XCTAssertEqual(GH.failureKindSync(repo: "MohamedCHAMI/chessvox-mobile", id: 39423933400), .code)
        // Attempt 1 of this run lost the Mac runner (attempt 2 passed, so read that job's annotations directly).
        let lost = gh(["api", "repos/MohamedCHAMI/chessvox-mobile/check-runs/118727950706/annotations", "--jq", ".[].message"])
        XCTAssertEqual(FailureKind.from(annotations: [lost]), .runnerLost)
    }

    func testMacSafePullRequestOnSandbox() async throws {
        let files = await GH.workflows(repo: Self.sandbox)
        let deploy = try XCTUnwrap(files.first { $0.name == "deploy.yml" })
        let clean = try XCTUnwrap(files.first { $0.name == "clean.yml" })
        XCTAssertTrue(deploy.needsFix)
        XCTAssertFalse(clean.needsFix)

        let url = try await GH.openSwitchPR(repo: Self.sandbox)
        let number = try XCTUnwrap(url.split(separator: "/").last.flatMap { Int($0) }, url)

        // Only the workflow that needed it changed, with all three fixes.
        XCTAssertEqual(gh(["pr", "view", "\(number)", "-R", Self.sandbox, "--json", "files", "--jq", "[.files[].path]|join(\",\")"]),
                       ".github/workflows/deploy.yml")
        let diff = gh(["pr", "diff", "\(number)", "-R", Self.sandbox])
        XCTAssertTrue(diff.contains("+    runs-on: [self-hosted, mac-local]"))
        XCTAssertEqual(diff.components(separatedBy: "+    runs-on: [self-hosted, mac-local]").count - 1, 2)
        XCTAssertTrue(diff.contains("sed -i.bak 's/^ *//' .env && rm -f .env.bak"))
        XCTAssertTrue(diff.contains("+        run: rm -f .env .env.bak"))
        let body = gh(["pr", "view", "\(number)", "-R", Self.sandbox, "--json", "body", "--jq", ".body"])
        XCTAssertTrue(body.contains("⚠️ Deploys with secrets"))

        // Merged: the repo is Mac-safe, so a second run changes nothing and leaves no branch behind.
        XCTAssertEqual(Shell.run(Shell.gh, ["pr", "merge", "\(number)", "-R", Self.sandbox, "--merge", "--delete-branch"]).status, 0)
        let after = await GH.workflows(repo: Self.sandbox)
        XCTAssertFalse(after.contains { $0.needsFix })
        do {
            _ = try await GH.openSwitchPR(repo: Self.sandbox)
            XCTFail("expected nothing to change")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already Mac-safe"), error.localizedDescription)
        }
        XCTAssertFalse(gh(["api", "repos/\(Self.sandbox)/branches", "--jq", ".[].name"]).contains("ci-local/"))
    }
}
