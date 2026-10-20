import Foundation

/// Thin async wrappers over `gh`. Everything runs off the main thread.
enum GH {
    static var path: String { Shell.gh }

    static func run(_ args: [String]) async -> (status: Int32, out: String) {
        await Task.detached { Shell.run(path, args) }.value
    }

    static func runs(repo: String) async -> [RunInfo] {
        let r = await run(["run", "list", "--repo", repo, "--limit", "25", "--json",
                           "databaseId,displayTitle,status,conclusion,headBranch,event,createdAt,url,workflowName,attempt"])
        guard r.status == 0, let data = r.out.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([RunInfo].self, from: data)) ?? []
    }

    static func workflows(repo: String) async -> [WorkflowFile] {
        let list = await run(["api", "repos/\(repo)/contents/.github/workflows", "--jq", ".[].name"])
        var result: [WorkflowFile] = []
        for name in list.out.split(separator: "\n").map(String.init) where name.hasSuffix(".yml") || name.hasSuffix(".yaml") {
            let raw = await run(["api", "-H", "Accept: application/vnd.github.raw",
                                 "repos/\(repo)/contents/.github/workflows/\(name)"])
            let lines = raw.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("runs-on:") }
                .map { String($0.dropFirst("runs-on:".count)).trimmingCharacters(in: .whitespaces) }
            let patch = WorkflowPatcher.patch(raw.out)
            result.append(WorkflowFile(name: name, runsOn: lines, changes: patch.changes, warnings: patch.warnings))
        }
        return result
    }

    private static func lines(_ args: [String]) async -> [String]? {
        let r = await run(args)
        guard r.status == 0 else { return nil }
        return r.out.split(separator: "\n").map(String.init)
    }

    /// Branches whose PR is merged (see MergedBranches). nil when GitHub could not be read,
    /// so a network error never makes every branch look merged or unmerged.
    static func mergedBranches(repo: String) async -> Set<String>? {
        guard let merged = await lines(["pr", "list", "--repo", repo, "--state", "merged", "--limit", "200",
                                        "--json", "headRefName", "--jq", ".[].headRefName"]),
              let open = await lines(["pr", "list", "--repo", repo, "--state", "open", "--limit", "200",
                                      "--json", "headRefName", "--jq", ".[].headRefName"]),
              let base = await lines(["api", "repos/\(repo)", "--jq", ".default_branch"])?.first
        else { return nil }
        return MergedBranches.compute(mergedHeads: merged, openHeads: open, defaultBranch: base)
    }

    /// Remote branch name → tip SHA.
    static func remoteBranches(repo: String) async -> [String: String] {
        let rows = await lines(["api", "--paginate", "repos/\(repo)/branches", "--jq", ".[] | \"\\(.name) \\(.commit.sha)\""]) ?? []
        return pairs(rows).reduce(into: [:]) { $0[$1.0] = $1.1 }
    }

    /// Merged PR head branch → head SHAs that were merged.
    static func mergedHeadShas(repo: String) async -> [String: Set<String>] {
        let rows = await lines(["pr", "list", "--repo", repo, "--state", "merged", "--limit", "200",
                                "--json", "headRefName,headRefOid", "--jq", ".[] | \"\\(.headRefName) \\(.headRefOid)\""]) ?? []
        return pairs(rows).reduce(into: [:]) { $0[$1.0, default: []].insert($1.1) }
    }

    private static func pairs(_ rows: [String]) -> [(String, String)] {
        rows.compactMap { row in
            let parts = row.split(separator: " ", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    /// Deletes remote branches. Returns how many were deleted.
    static func deleteBranches(_ names: [String], repo: String) async -> Int {
        var n = 0
        for b in names where await run(["api", "-X", "DELETE", "repos/\(repo)/git/refs/heads/\(b)"]).status == 0 { n += 1 }
        return n
    }

    /// GitHub's "Automatically delete head branches" repo setting.
    static func autoDeleteOnMerge(repo: String) async -> Bool? {
        await lines(["api", "repos/\(repo)", "--jq", ".delete_branch_on_merge"])?.first.map { $0 == "true" }
    }

    static func setAutoDeleteOnMerge(_ on: Bool, repo: String) async -> Bool {
        await run(["api", "-X", "PATCH", "repos/\(repo)", "-F", "delete_branch_on_merge=\(on)"]).status == 0
    }

    /// Failure kind per run id and attempt (a finished attempt never changes).
    @MainActor private static var kindCache: [String: FailureKind] = [:]

    /// Reads the annotations of the run's failed jobs: GitHub states plainly when it
    /// refused to start a job (billing) or lost the self-hosted runner.
    nonisolated static func failureKindSync(repo: String, id: Int) -> FailureKind {
        let jobs = Shell.run(path, ["api", "repos/\(repo)/actions/runs/\(id)/jobs",
                                           "--jq", ".jobs[] | select(.conclusion == \"failure\") | .id"])
        var messages: [String] = []
        for job in jobs.out.split(separator: "\n") {
            messages.append(Shell.run(path, ["api", "repos/\(repo)/check-runs/\(job)/annotations",
                                                    "--jq", ".[].message"]).out)
        }
        return FailureKind.from(annotations: messages)
    }

    @MainActor static func classifyFailures(_ runs: [RunInfo], repo: String) async -> [RunInfo] {
        var out = runs
        for i in out.indices where out[i].failed {
            let id = out[i].id
            let key = "\(id)#\(out[i].attempt ?? 1)"
            if kindCache[key] == nil {
                kindCache[key] = await Task.detached { failureKindSync(repo: repo, id: id) }.value
            }
            out[i].failureKind = kindCache[key]
        }
        return out
    }

    /// Opens a PR that makes the workflows safe for the local self-hosted runner (see WorkflowPatcher). Returns the PR URL.
    static func openSwitchPR(repo: String) async throws -> String {
        func out(_ args: [String]) async -> String {
            await run(args).out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let base = await out(["api", "repos/\(repo)", "--jq", ".default_branch"])
        let sha = await out(["api", "repos/\(repo)/git/ref/heads/\(base)", "--jq", ".object.sha"])
        guard !base.isEmpty, !sha.isEmpty else { throw InstallError.failed("Could not read \(repo) default branch") }
        // Timestamped so a second run never collides with an earlier, unmerged branch.
        let stamp = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"; return f.string(from: Date()) }()
        let branch = "ci-local/self-hosted-runner-\(stamp)"
        let mk = await run(["api", "-X", "POST", "repos/\(repo)/git/refs",
                            "-f", "ref=refs/heads/\(branch)", "-f", "sha=\(sha)"])
        guard mk.status == 0 else { throw InstallError.failed("Branch \(branch) could not be created.") }

        var changed = 0
        var report: [String] = []
        let names = await out(["api", "repos/\(repo)/contents/.github/workflows?ref=\(branch)", "--jq", ".[].name"])
        for name in names.split(separator: "\n").map(String.init) where name.hasSuffix(".yml") || name.hasSuffix(".yaml") {
            let p = "repos/\(repo)/contents/.github/workflows/\(name)"
            let raw = await run(["api", "-H", "Accept: application/vnd.github.raw", "\(p)?ref=\(branch)"]).out
            let patch = WorkflowPatcher.patch(raw)
            if !patch.warnings.isEmpty || patch.changed {
                report.append("### `\(name)`")
                report += patch.changes.map { "- \($0)" }
                report += patch.warnings.map { "- ⚠️ \($0)" }
            }
            guard patch.changed else { continue }
            let text = patch.text
            let fileSha = await out(["api", "\(p)?ref=\(branch)", "--jq", ".sha"])
            let b64 = Data(text.utf8).base64EncodedString()
            let put = await run(["api", "-X", "PUT", p, "-f", "message=ci: run \(name) on the local self-hosted runner",
                                 "-f", "content=\(b64)", "-f", "sha=\(fileSha)", "-f", "branch=\(branch)"])
            guard put.status == 0 else { throw InstallError.failed("Could not update \(name)") }
            changed += 1
        }
        guard changed > 0 else {
            _ = await run(["api", "-X", "DELETE", "repos/\(repo)/git/refs/heads/\(branch)"])
            throw InstallError.failed("Nothing to change: workflows are already Mac-safe.")
        }
        let body = """
        Makes the workflows run for free on the self-hosted Mac runner while GitHub-hosted minutes are billing-blocked: hosted `runs-on` → `[self-hosted, mac-local]`, GNU `sed -i` → portable form, and jobs that write `.env` delete it afterwards (the Mac workspace persists between runs).

        \(report.joined(separator: "\n"))

        Review the ⚠️ items by hand before merging. Created by CI Local.
        """
        let pr = await run(["pr", "create", "--repo", repo, "--head", branch, "--base", base,
                            "--title", "ci: run workflows on the local self-hosted runner", "--body", body])
        guard pr.status == 0 else { throw InstallError.failed("PR creation failed: \(pr.out.suffix(200))") }
        return pr.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
