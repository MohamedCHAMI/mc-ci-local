import Foundation

struct RunnerConfig: Codable, Identifiable, Hashable {
    var name: String
    var repo: String      // owner/repo
    var dir: String       // runner folder containing run.sh
    var localPath: String? = nil  // local clone, used for the local check tab
    var id: String { repo }
}

enum Config {
    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CI Local")
    static let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CI Local")
    static let file = supportDir.appendingPathComponent("config.json")

    static func save(_ list: [RunnerConfig]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(list) { try? data.write(to: file) }
    }

    /// Saved runners; an empty list until repos are added with "Add repository…".
    static func load() -> [RunnerConfig] {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([RunnerConfig].self, from: data) else { return [] }
        return list
    }
}
