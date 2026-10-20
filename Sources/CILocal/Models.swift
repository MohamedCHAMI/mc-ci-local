import Foundation

/// Why a run failed, read from its job annotations.
enum FailureKind: String, Codable {
    case billing      // GitHub never started a hosted job: payments failed / spending limit
    case runnerLost   // the self-hosted runner dropped (Mac asleep, network): safe to re-run
    case code         // a real failure in the workflow steps

    /// Classifies the annotation messages of a run's failed jobs.
    static func from(annotations: [String]) -> FailureKind {
        let text = annotations.joined(separator: "\n").lowercased()
        if text.contains("recent account payments have failed") || text.contains("spending limit") { return .billing }
        if text.contains("lost communication with the server") { return .runnerLost }
        return .code
    }
}

struct RunInfo: Identifiable, Decodable, Hashable {
    var databaseId: Int
    var displayTitle: String
    var status: String
    var conclusion: String?
    var headBranch: String
    var event: String
    var createdAt: String
    var url: String
    var workflowName: String
    var attempt: Int?
    /// Set after decoding, for failed runs only (see GH.failureKindSync).
    var failureKind: FailureKind?
    var billingBlocked: Bool { failureKind == .billing }
    var id: Int { databaseId }

    var symbol: String {
        if failureKind == .billing { return "creditcard.trianglebadge.exclamationmark" }
        if failureKind == .runnerLost { return "wifi.exclamationmark" }
        switch (status, conclusion ?? "") {
        case ("completed", "success"): return "checkmark.circle.fill"
        case ("completed", "failure"): return "xmark.circle.fill"
        case ("completed", "cancelled"): return "slash.circle"
        case ("completed", _): return "minus.circle"
        case ("in_progress", _): return "arrow.triangle.2.circlepath"
        default: return "clock"
        }
    }
    var tint: String {
        if failureKind == .billing || failureKind == .runnerLost { return "orange" }
        switch (status, conclusion ?? "") {
        case ("completed", "success"): return "green"
        case ("completed", "failure"): return "red"
        case ("in_progress", _): return "orange"
        default: return "gray"
        }
    }
    var isActive: Bool { status != "completed" }
    var failed: Bool { conclusion == "failure" }
}

struct WorkflowFile: Identifiable, Hashable {
    var name: String
    var runsOn: [String]
    /// What "Make Mac-safe" would change, and what it cannot fix (see WorkflowPatcher).
    var changes: [String] = []
    var warnings: [String] = []
    var id: String { name }
    var selfHosted: Bool { runsOn.contains { $0.contains("self-hosted") } }
    var needsFix: Bool { !changes.isEmpty }
}

extension RunInfo {
    /// Not picked up by a runner yet: cancelling it costs nothing.
    var isQueued: Bool { ["queued", "waiting", "pending", "requested"].contains(status) }
}

/// Branches whose pull request is merged. Their CI runs are history: main's own run covers
/// the merged code, so they are hidden, never re-run, and their queued runs are cancelled.
enum MergedBranches {
    /// Merged PR heads, minus the default branch and any branch that has an open PR again.
    static func compute(mergedHeads: [String], openHeads: [String], defaultBranch: String) -> Set<String> {
        Set(mergedHeads).subtracting(openHeads).subtracting([defaultBranch, ""])
    }

    static func isMerged(_ run: RunInfo, _ merged: Set<String>) -> Bool { merged.contains(run.headBranch) }

    /// Queued runs on merged branches: safe to cancel, they would only use runner time.
    static func cancellable(_ runs: [RunInfo], _ merged: Set<String>) -> [RunInfo] {
        runs.filter { $0.isQueued && isMerged($0, merged) }
    }

    /// Failed runs worth re-running: not billing-blocked and not on a merged branch.
    static func rerunnable(_ runs: [RunInfo], _ merged: Set<String>) -> [RunInfo] {
        runs.filter { $0.failed && !$0.billingBlocked && !isMerged($0, merged) }
    }

    /// Remote branches that still exist although their PR is merged, and are safe to delete:
    /// the tip is exactly the commit that was merged (nothing pushed since), and the branch
    /// is in `merged` (so it has no open PR and is not the default branch).
    static func leftovers(remote: [String: String], mergedHeadShas: [String: Set<String>], merged: Set<String>) -> [String] {
        remote.compactMap { name, sha in
            merged.contains(name) && (mergedHeadShas[name]?.contains(sha) ?? false) ? name : nil
        }.sorted()
    }
}

/// Picks the local check command from package.json scripts, so repos without a `check`
/// script (lint, typecheck and test split up) still run everything they define.
enum CheckCommand {
    static func detect(scripts: [String: String], hasTsconfig: Bool) -> String {
        if scripts["check"] != nil { return "npm run check" }
        var steps: [String] = []
        if scripts["lint"] != nil { steps.append("npm run -s lint") }
        if scripts["typecheck"] != nil { steps.append("npm run -s typecheck") }
        else if hasTsconfig { steps.append("npx tsc --noEmit") }
        if scripts["test"] != nil { steps.append("npm test --silent") }
        steps += scripts.keys.filter { $0.hasPrefix("test:") }.sorted().map { "npm run -s \($0)" }
        return steps.isEmpty ? "npm test" : steps.joined(separator: " && ")
    }

    /// Reads `<dir>/package.json`. Falls back to `npm run check` when it cannot be read.
    static func detect(in dir: String) -> String {
        let url = URL(fileURLWithPath: dir).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "npm run check" }
        let scripts = (json["scripts"] as? [String: String]) ?? [:]
        let ts = FileManager.default.fileExists(atPath: URL(fileURLWithPath: dir).appendingPathComponent("tsconfig.json").path)
        return detect(scripts: scripts, hasTsconfig: ts)
    }
}
