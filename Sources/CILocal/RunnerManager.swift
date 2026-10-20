import Foundation
import SwiftUI

enum RunnerState {
    case stopped        // not running locally
    case starting       // running locally, GitHub not online yet
    case online         // running locally and GitHub shows online
    case orphaned       // GitHub shows online but no local process
}

@MainActor
final class RunnerManager: ObservableObject, Identifiable {
    @Published var config: RunnerConfig
    /// The repo (owner/repo). Fixed for the life of the runner, so it is safe to read off the main actor.
    nonisolated let id: String

    @Published private(set) var state: RunnerState = .stopped
    @Published private(set) var message = ""

    /// Branches whose PR is merged (see MergedBranches); refreshed every few minutes.
    @Published private(set) var mergedBranches: Set<String> = []

    private var process: Process?
    private var timer: Timer?
    private var mergedCheckedAt = Date.distantPast
    /// Re-run ids already retried, so a run that keeps losing the runner is not retried forever.
    private var retried: Set<Int> = []
    /// Queued run ids already cancelled because their branch is merged.
    private var cancelled: Set<Int> = []

    init(config: RunnerConfig) {
        self.config = config
        self.id = config.id
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    /// Stops the refresh timer. Call when the repo is removed from CI Local.
    func shutdown() {
        timer?.invalidate()
        timer = nil
    }

    var logURL: URL { Config.logDir.appendingPathComponent("\(config.name).log") }

    /// The runner's listener process, found by its path (it outlives a CI Local restart).
    nonisolated private static func listenerRunning(_ dir: String) -> Bool {
        Shell.run("/usr/bin/pgrep", ["-f", "\(dir)/bin/Runner.Listener"]).status == 0
    }

    private func isRunningLocally() async -> Bool {
        if let p = process, p.isRunning { return true }
        let dir = config.dir
        return await Task.detached { Self.listenerRunning(dir) }.value
    }

    func start() {
        Task {
            if await isRunningLocally() { await refresh(); return }
            launch()
        }
    }

    private func launch() {
        guard FileManager.default.isExecutableFile(atPath: config.dir + "/run.sh") else {
            message = "run.sh not found in \(config.dir)"; return
        }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["./run.sh"]
        p.currentDirectoryURL = URL(fileURLWithPath: config.dir)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        if let h = try? FileHandle(forWritingTo: logURL) {
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        do {
            try p.run()
            process = p
            message = "Starting…"
            state = .starting
        } catch {
            message = "Failed to start: \(error.localizedDescription)"
        }
        Task { await refresh() }
    }

    func stop() {
        // Listener runs as a grandchild of run.sh; SIGINT lets it deregister the session cleanly.
        let dir = config.dir
        Task.detached { _ = Shell.run("/usr/bin/pkill", ["-INT", "-f", "\(dir)/bin/Runner.Listener"]) }
        process?.interrupt()
        process = nil
        message = "Stopping…"
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refresh()
        }
    }

    func restart() {
        stop()
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            start()
        }
    }

    func refresh() async {
        let local = await isRunningLocally()
        let repo = config.repo
        let online: Bool? = await Task.detached {
            let r = Shell.run(Shell.gh, ["api", "repos/\(repo)/actions/runners",
                                         "--jq", ".runners[] | select(.status==\"online\") | .name"])
            guard r.status == 0 else { return nil }
            return !r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.value
        switch (local, online) {
        case (true, true?):
            state = .online; message = "Online"
            await refreshMergedBranches()
            await cancelQueuedOnMergedBranches()
            await rerunLostRunnerJobs()
        case (true, _): state = .starting; message = online == nil ? "Running (GitHub status unavailable)" : "Starting…"
        case (false, true?): state = .orphaned; message = "Online elsewhere"
        default: state = .stopped; message = "Stopped"
        }
    }

    /// Re-reads merged PR branches at most every 5 minutes. Keeps the last good value on error.
    func refreshMergedBranches(force: Bool = false) async {
        guard force || Date().timeIntervalSince(mergedCheckedAt) > 300 else { return }
        if let merged = await GH.mergedBranches(repo: config.repo) {
            mergedBranches = merged
            mergedCheckedAt = Date()
        }
    }

    /// A queued run on an already-merged branch would only spend runner time: main's run
    /// covers that code. Cancel it before the runner picks it up.
    private func cancelQueuedOnMergedBranches() async {
        let repo = config.repo
        let stale = MergedBranches.cancellable(await GH.runs(repo: repo), mergedBranches)
            .filter { !cancelled.contains($0.id) }
        for run in stale {
            cancelled.insert(run.id)
            _ = await GH.run(["run", "cancel", "\(run.id)", "--repo", repo])
        }
        if !stale.isEmpty { message = "Online · cancelled \(stale.count) queued run(s) on merged branches" }
    }

    /// When the Mac sleeps or drops off the network mid-job, GitHub fails the run with
    /// "runner lost communication". Once the runner is back online, retry those runs once.
    private func rerunLostRunnerJobs() async {
        let repo = config.repo
        let candidates = await GH.runs(repo: repo).filter {
            $0.failed && ($0.attempt ?? 1) == 1 && !retried.contains($0.id) && !MergedBranches.isMerged($0, mergedBranches)
        }
        guard !candidates.isEmpty else { return }
        let classified = await GH.classifyFailures(Array(candidates.prefix(5)), repo: repo)
        let lost = classified.filter { $0.failureKind == .runnerLost }
        for run in lost {
            retried.insert(run.id)
            _ = await GH.run(["run", "rerun", "\(run.id)", "--failed", "--repo", repo])
        }
        if !lost.isEmpty { message = "Online · re-ran \(lost.count) run(s) the runner lost" }
    }

    /// Re-runs failed runs, skipping billing-blocked runs (they fail again instantly) and
    /// runs on merged branches (main already covers that code).
    func rerunFailed() {
        let repo = config.repo
        message = "Re-running failed checks…"
        Task {
            await refreshMergedBranches(force: true)
            let failed = await GH.classifyFailures(await GH.runs(repo: repo).filter(\.failed), repo: repo)
            let ids = MergedBranches.rerunnable(failed, mergedBranches).map(\.id)
            for id in ids { _ = await GH.run(["run", "rerun", "\(id)", "--repo", repo]) }
            let skipped = failed.count - ids.count
            message = "Re-ran \(ids.count) failed run(s)" + (skipped > 0 ? ", skipped \(skipped) (billing or merged branch)" : "")
        }
    }
}
