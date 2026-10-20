import Foundation
import SwiftUI

/// Runs the repo's checks (see CheckCommand) in a local clone and streams the output.
@MainActor
final class LocalCheck: ObservableObject {
    @Published var output = ""
    @Published var running = false
    @Published var exitCode: Int32?
    @Published var command = ""
    private var process: Process?

    func run(in dir: String) {
        guard !running else { return }
        output = ""; exitCode = nil; running = true
        command = CheckCommand.detect(in: dir)
        output = "$ \(command)\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "\(command) 2>&1"]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let s = String(decoding: d, as: UTF8.self)
            Task { @MainActor in self?.output += s }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in self?.running = false; self?.exitCode = proc.terminationStatus }
        }
        do { try p.run(); process = p } catch { output = "Failed to start: \(error)"; running = false }
    }

    func cancel() { process?.terminate() }

    static func installHook(in dir: String) -> String {
        let hooks = dir + "/.githooks"
        let file = hooks + "/pre-push"
        if FileManager.default.fileExists(atPath: file) {
            _ = Shell.run("/usr/bin/git", ["-C", dir, "config", "core.hooksPath", ".githooks"])
            return "A pre-push hook already exists (left unchanged). Enabled it with core.hooksPath."
        }
        try? FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        # Local CI (CI Local): run the checks before every push. Bypass: SKIP_CHECK=1 git push
        [ -n "$SKIP_CHECK" ] && exit 0
        \(CheckCommand.detect(in: dir)) || { echo "pre-push: check failed, push blocked." >&2; exit 1; }
        """
        do {
            try script.write(toFile: file, atomically: true, encoding: .utf8)
            _ = Shell.run("/bin/chmod", ["+x", file])
            _ = Shell.run("/usr/bin/git", ["-C", dir, "config", "core.hooksPath", ".githooks"])
            return "Installed .githooks/pre-push (untracked: commit it to share)."
        } catch { return "Could not write hook: \(error.localizedDescription)" }
    }
}
