import Foundation

struct RepoInfo: Identifiable, Hashable {
    var nameWithOwner: String
    var id: String { nameWithOwner }
}

enum InstallError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let m) = self { return m } else { return nil } }
}

/// Downloads, registers and removes GitHub Actions runners using `gh`.
enum Installer {
    static var gh: String { Shell.gh }
    static let runnersDir = NSHomeDirectory() + "/actions-runners"

    /// Private repos only: a self-hosted runner must never run code from outside contributors.
    static func privateRepos() -> [RepoInfo] {
        let r = Shell.run(gh, ["repo", "list", "--limit", "200", "--json", "nameWithOwner,isPrivate",
                                      "--jq", ".[] | select(.isPrivate) | .nameWithOwner"])
        return r.out.split(separator: "\n").map { RepoInfo(nameWithOwner: String($0)) }
            .sorted { $0.nameWithOwner < $1.nameWithOwner }
    }

    static func install(repo: String) throws -> RunnerConfig {
        let short = repo.split(separator: "/").last.map(String.init) ?? repo
        let dir = runnersDir + "/" + short
        let fm = FileManager.default

        let priv = Shell.run(gh, ["api", "repos/\(repo)", "--jq", ".private"])
        guard priv.out.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw InstallError.failed("\(repo) is not a private repo (or gh has no access). Refusing to add a runner.")
        }

        if !fm.fileExists(atPath: dir + "/config.sh") {
            let tag = Shell.run(gh, ["api", "repos/actions/runner/releases/latest", "--jq", ".tag_name"])
                .out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard tag.hasPrefix("v") else { throw InstallError.failed("Could not read latest runner version") }
            let v = String(tag.dropFirst())
            let arch = Shell.run("/usr/bin/uname", ["-m"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
            let osArch = arch == "arm64" ? "arm64" : "x64"
            let tgz = Config.supportDir.appendingPathComponent("runner-\(v)-\(osArch).tar.gz").path
            if !fm.fileExists(atPath: tgz) {
                let url = "https://github.com/actions/runner/releases/download/v\(v)/actions-runner-osx-\(osArch)-\(v).tar.gz"
                let d = Shell.run("/usr/bin/curl", ["-fsSL", "-o", tgz, url])
                guard d.status == 0 else { throw InstallError.failed("Download failed") }
            }
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let x = Shell.run("/usr/bin/tar", ["xzf", tgz, "-C", dir])
            guard x.status == 0 else { throw InstallError.failed("Extract failed") }
        }

        let tok = Shell.run(gh, ["api", "-X", "POST", "repos/\(repo)/actions/runners/registration-token",
                                        "--jq", ".token"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tok.isEmpty else { throw InstallError.failed("No registration token. Need admin access on \(repo).") }
        let c = Shell.run(dir + "/config.sh", ["--unattended", "--url", "https://github.com/\(repo)",
                                                      "--token", tok, "--name", "mac-\(short)",
                                                      "--labels", "mac-local", "--work", "_work", "--replace"])
        guard c.status == 0 else { throw InstallError.failed("config.sh failed: \(c.out.suffix(300))") }
        return RunnerConfig(name: short, repo: repo, dir: dir)
    }

    static func unregister(_ cfg: RunnerConfig) {
        let tok = Shell.run(gh, ["api", "-X", "POST", "repos/\(cfg.repo)/actions/runners/remove-token",
                                        "--jq", ".token"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tok.isEmpty { _ = Shell.run(cfg.dir + "/config.sh", ["remove", "--token", tok]) }
    }
}
