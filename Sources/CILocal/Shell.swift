import Foundation

/// Runs command-line tools. Never call from the main actor: `run` blocks until the process exits.
enum Shell {
    /// `gh` from Homebrew on Apple Silicon or Intel, else whatever PATH resolves.
    static let gh: String = {
        for p in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return "/usr/bin/env"
    }()

    /// Arguments for `gh`, prefixed with "gh" when it is reached through /usr/bin/env.
    static func ghArgs(_ args: [String]) -> [String] { gh == "/usr/bin/env" ? ["gh"] + args : args }

    /// Runs a tool and returns its exit status and stdout. stderr is discarded so a chatty
    /// tool can never fill an unread pipe and block forever.
    static func run(_ path: String, _ args: [String], cwd: String? = nil) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = path == gh ? ghArgs(args) : args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Same as `run`, off the calling actor.
    static func runAsync(_ path: String, _ args: [String], cwd: String? = nil) async -> (status: Int32, out: String) {
        await Task.detached { run(path, args, cwd: cwd) }.value
    }
}
