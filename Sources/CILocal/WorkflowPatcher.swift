import Foundation

/// Rewrites a GitHub Actions workflow so it runs safely on the self-hosted Mac runner.
/// Pure text transforms (no YAML parser): every change is listed, and anything that
/// cannot be fixed automatically is returned as a warning for the PR body.
enum WorkflowPatcher {
    static let selfHosted = "[self-hosted, mac-local]"

    struct Result: Equatable {
        var text: String
        var changes: [String]
        var warnings: [String]
        var changed: Bool { !changes.isEmpty }
    }

    static func patch(_ original: String) -> Result {
        var lines = original.components(separatedBy: "\n")
        var changes: [String] = []
        var warnings: [String] = []

        // 1. Hosted Ubuntu runners: `ubuntu-latest`, "ubuntu-24.04", [ubuntu-22.04] → self-hosted.
        let runsOn = try! NSRegularExpression(pattern: #"^(\s*runs-on:\s*)(\[\s*)?(["']?)(ubuntu-[\w.-]+)\3(\s*\])?\s*$"#)
        for i in lines.indices {
            let line = lines[i]
            let range = NSRange(line.startIndex..., in: line)
            if let m = runsOn.firstMatch(in: line, range: range),
               let prefix = Range(m.range(at: 1), in: line), let label = Range(m.range(at: 4), in: line) {
                lines[i] = String(line[prefix]) + selfHosted
                changes.append("runs-on \(line[label]) → \(selfHosted)")
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("runs-on:"),
                      line.contains("${{"), line.contains("matrix") {
                warnings.append("`\(line.trimmingCharacters(in: .whitespaces))` picks the runner from a matrix: set the matrix values to self-hosted labels by hand.")
            }
        }

        // 2. GNU `sed -i 'expr' file` fails on macOS (BSD sed needs a backup suffix).
        //    `sed -i.bak` works on both; delete the backup right after.
        let sedFile = try! NSRegularExpression(pattern: #"\bsed -i ('[^']*'|"[^"]*") ([^\s;&|]+)\s*$"#)
        for i in lines.indices where lines[i].contains("sed -i ") {
            let line = lines[i]
            let range = NSRange(line.startIndex..., in: line)
            if let m = sedFile.firstMatch(in: line, range: range),
               let all = Range(m.range, in: line), let expr = Range(m.range(at: 1), in: line), let file = Range(m.range(at: 2), in: line) {
                lines[i] = line.replacingCharacters(in: all, with: "sed -i.bak \(line[expr]) \(line[file]) && rm -f \(line[file]).bak")
                changes.append("portable sed -i for \(line[file]) (macOS sed needs a backup suffix)")
            } else {
                lines[i] = line.replacingOccurrences(of: "sed -i ", with: "sed -i.bak ")
                changes.append("portable sed -i (leaves *.bak files: delete them in a later step)")
                warnings.append("A `sed -i` line edits several files or uses a pipe: it now writes `*.bak` backups, make sure they are not deployed.")
            }
        }

        // 3. A self-hosted workspace persists between runs: jobs that write .env must delete it.
        for job in jobBlocks(lines).reversed() {
            let body = lines[job.start..<job.end]
            let writesEnv = body.contains { $0.range(of: #">>?\s*\.env\b"#, options: .regularExpression) != nil }
            // `.env` itself, not `.env.bak` (the sed fix above deletes only the backup).
            let cleans = body.contains { $0.range(of: #"\brm\b.*(\s|/)\.env(\s|$)"#, options: .regularExpression) != nil }
            guard writesEnv, !cleans, let indent = stepIndent(lines, job) else { continue }
            var insertAt = job.end
            while insertAt > job.start, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
            let pad = String(repeating: " ", count: indent)
            lines.insert(contentsOf: [
                "",
                "\(pad)# The self-hosted workspace persists between runs: never leave secrets on disk.",
                "\(pad)- name: Remove .env",
                "\(pad)  if: always()",
                "\(pad)  run: rm -f .env .env.bak",
            ], at: insertAt)
            changes.append("job `\(job.name)`: delete .env after every run")
        }

        // 4. Things that only work on Linux runners and cannot be rewritten safely.
        let linuxOnly: [(String, String)] = [
            (#"\bapt(-get)?\s+install\b"#, "uses apt: install the tools with Homebrew on the Mac instead"),
            (#"^\s*services:\s*$"#, "uses service containers (Linux/Docker only): run them with docker compose on the Mac"),
            (#"^\s*container:"#, "runs inside a container (Linux only)"),
            (#"\breadlink -f\b|\bdate -d\b|\bgrep -P\b|\bxargs -r\b|\bbase64 -w\b"#, "uses GNU-only command flags that differ on macOS"),
        ]
        for (pattern, message) in linuxOnly where lines.contains(where: { $0.range(of: pattern, options: .regularExpression) != nil }) {
            warnings.append("Workflow \(message).")
        }
        if lines.contains(where: { $0.range(of: #"(?i)(deploy|release|publish)"#, options: .regularExpression) != nil })
            && lines.contains(where: { $0.contains("secrets.") }) {
            warnings.append("Deploys with secrets from your Mac: check its scripts do not leave secret-bearing files behind (e.g. archives in /tmp).")
        }

        return Result(text: lines.joined(separator: "\n"), changes: changes, warnings: warnings)
    }

    struct JobBlock { var name: String; var start: Int; var end: Int }

    /// Jobs are the keys indented one level under the top-level `jobs:` key.
    static func jobBlocks(_ lines: [String]) -> [JobBlock] {
        guard let jobsLine = lines.firstIndex(where: { $0.hasPrefix("jobs:") }) else { return [] }
        var blocks: [JobBlock] = []
        var jobIndent: Int?
        var i = jobsLine + 1
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                let indent = line.prefix { $0 == " " }.count
                if indent == 0 { break }  // next top-level key
                if jobIndent == nil { jobIndent = indent }
                if indent == jobIndent, trimmed.hasSuffix(":") {
                    if var last = blocks.popLast() { last.end = i; blocks.append(last) }
                    blocks.append(JobBlock(name: String(trimmed.dropLast()), start: i, end: lines.count))
                }
            }
            i += 1
        }
        if var last = blocks.popLast() {
            var end = i
            while end > last.start, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            last.end = end
            blocks.append(last)
        }
        return blocks
    }

    /// Indentation of the `- ` step items under the job's `steps:` key.
    static func stepIndent(_ lines: [String], _ job: JobBlock) -> Int? {
        guard let steps = lines[job.start..<job.end].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "steps:" }) else { return nil }
        return lines[(steps + 1)..<job.end].first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
            .map { line in line.prefix { $0 == " " }.count }
    }
}
