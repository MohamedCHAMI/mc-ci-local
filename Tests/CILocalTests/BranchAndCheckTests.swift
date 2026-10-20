import XCTest
@testable import CILocal

final class MergedBranchesTests: XCTestCase {
    private func run(_ id: Int, _ branch: String, status: String = "completed", conclusion: String? = "success",
                     kind: FailureKind? = nil) -> RunInfo {
        var r = RunInfo(databaseId: id, displayTitle: "t", status: status, conclusion: conclusion, headBranch: branch,
                        event: "pull_request", createdAt: "2026-10-20T10:00:00Z", url: "", workflowName: "CI", attempt: 1)
        r.failureKind = kind
        return r
    }

    func testComputeDropsDefaultBranchAndReopenedBranches() {
        let merged = MergedBranches.compute(mergedHeads: ["brand/logo", "fix/a", "main", "fix/a"],
                                            openHeads: ["fix/a"], defaultBranch: "main")
        XCTAssertEqual(merged, ["brand/logo"])
    }

    func testCancellableOnlyQueuedRunsOnMergedBranches() {
        let runs = [run(1, "brand/logo", status: "queued", conclusion: nil),
                    run(2, "brand/logo", status: "in_progress", conclusion: nil),
                    run(3, "feat/open", status: "queued", conclusion: nil),
                    run(4, "brand/logo")]
        XCTAssertEqual(MergedBranches.cancellable(runs, ["brand/logo"]).map(\.id), [1])
    }

    func testRerunnableSkipsMergedAndBillingRuns() {
        let runs = [run(1, "brand/logo", conclusion: "failure"),
                    run(2, "feat/open", conclusion: "failure", kind: .billing),
                    run(3, "feat/open", conclusion: "failure", kind: .code),
                    run(4, "main", conclusion: "success")]
        XCTAssertEqual(MergedBranches.rerunnable(runs, ["brand/logo"]).map(\.id), [3])
    }

    func testLeftoversOnlyWhenTipIsTheMergedCommit() {
        let remote = ["main": "m1", "brand/logo": "abc", "fix/pushed-after-merge": "new", "feat/open": "o1"]
        let heads: [String: Set<String>] = ["brand/logo": ["abc"], "fix/pushed-after-merge": ["old"]]
        let merged: Set<String> = ["brand/logo", "fix/pushed-after-merge"]
        XCTAssertEqual(MergedBranches.leftovers(remote: remote, mergedHeadShas: heads, merged: merged), ["brand/logo"])
    }
}

final class CheckCommandTests: XCTestCase {
    func testPrefersCheckScript() {
        XCTAssertEqual(CheckCommand.detect(scripts: ["check": "x", "lint": "eslint"], hasTsconfig: true), "npm run check")
    }

    func testComposesLintTypecheckAndAllTestScripts() {
        let cmd = CheckCommand.detect(scripts: ["lint": "eslint", "build": "next build",
                                                "test:b": "node --test b", "test:a": "node --test a"], hasTsconfig: true)
        XCTAssertEqual(cmd, "npm run -s lint && npx tsc --noEmit && npm run -s test:a && npm run -s test:b")
    }

    func testFallsBackToNpmTest() {
        XCTAssertEqual(CheckCommand.detect(scripts: ["build": "x"], hasTsconfig: false), "npm test")
    }
}
