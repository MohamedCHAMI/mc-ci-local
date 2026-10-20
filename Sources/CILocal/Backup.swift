import Foundation
import AppKit

/// What to back up and where. Saved as JSON for the app and exported as backup.env for backup.sh.
struct BackupSettings: Codable, Equatable {
    var enabled = false
    var driveDir = ""             // folder inside Google Drive, e.g. ".../My Drive/CI Local Backups"
    var githubEnabled = true
    var githubOwner = ""          // empty = the signed-in gh account
    var dbEnvFile = NSHomeDirectory() + "/.secrets/chessvox-db-backup.env"
    var scanDir = NSHomeDirectory() + "/Desktop/Works/Apps"
    var extraPaths: [String] = []
    var hour = 3                  // daily run, local time
}

/// Last result written by backup.sh.
struct BackupStatus: Codable {
    var finishedAt: String
    var ok: Bool
    var message: String
    var snapshot: String
}

enum BackupStore {
    static let settingsFile = Config.supportDir.appendingPathComponent("backup.json")
    static let envFile = Config.supportDir.appendingPathComponent("backup.env")
    static let statusFile = Config.supportDir.appendingPathComponent("backup-status.json")
    static let script = Config.supportDir.appendingPathComponent("backup.sh")
    static let log = Config.logDir.appendingPathComponent("backup.log")
    static let passwordFile = NSHomeDirectory() + "/.secrets/restic-backup.pass"

    static func load() -> BackupSettings {
        guard let data = try? Data(contentsOf: settingsFile),
              let s = try? JSONDecoder().decode(BackupSettings.self, from: data) else { return BackupSettings() }
        return s
    }

    static func save(_ s: BackupSettings) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) { try? data.write(to: settingsFile) }
        try? env(s).write(to: envFile, atomically: true, encoding: .utf8)
    }

    /// backup.env, sourced by backup.sh. Every value is single-quoted.
    static func env(_ s: BackupSettings) -> String {
        [
            "DRIVE_DIR=\(quote(s.driveDir))",
            "GITHUB_ENABLED=\(s.githubEnabled ? 1 : 0)",
            "GITHUB_OWNER=\(quote(s.githubOwner))",
            "DB_ENV_FILE=\(quote(s.dbEnvFile))",
            "SCAN_DIR=\(quote(s.scanDir))",
            "EXTRA_PATHS=\(quote(s.extraPaths.joined(separator: "\n")))",
        ].joined(separator: "\n") + "\n"
    }

    static func quote(_ v: String) -> String { "'" + v.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func status() -> BackupStatus? {
        guard let data = try? Data(contentsOf: statusFile) else { return nil }
        return try? JSONDecoder().decode(BackupStatus.self, from: data)
    }

    /// Google Drive for desktop mounts each account under ~/Library/CloudStorage/GoogleDrive-<email>/My Drive.
    static func driveRoots() -> [String] {
        let base = NSHomeDirectory() + "/Library/CloudStorage"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        return names.filter { $0.hasPrefix("GoogleDrive-") }.sorted()
            .map { "\(base)/\($0)/My Drive" }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Copies the bundled script next to the settings so CI jobs and the scheduler use one stable path.
    static func installScript() {
        let candidates = [Bundle.main.url(forResource: "backup", withExtension: "sh"),
                          Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/backup.sh")]
        guard let src = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else { return }
        try? FileManager.default.removeItem(at: script)
        try? FileManager.default.copyItem(at: src, to: script)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    /// Creates the encryption password once (32 random bytes, base64), readable only by this user.
    static func ensurePassword() throws {
        guard !FileManager.default.fileExists(atPath: passwordFile) else { return }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(domain: "Backup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not generate a password"])
        }
        let dir = (passwordFile as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: passwordFile, contents: Data(Data(bytes).base64EncodedString().utf8),
                                       attributes: [.posixPermissions: 0o600])
    }
}

@MainActor
final class BackupManager: ObservableObject {
    @Published var settings: BackupSettings { didSet { if settings != oldValue { BackupStore.save(settings) } } }
    @Published private(set) var status: BackupStatus?
    @Published private(set) var running = false
    @Published private(set) var githubAccount: String?   // nil = not connected
    @Published private(set) var resticInstalled = false
    @Published private(set) var error: String?
    private var timer: Timer?

    init() {
        settings = BackupStore.load()
        status = BackupStore.status()
        BackupStore.installScript()
        BackupStore.save(settings)
        // Check every 10 minutes whether today's run is due; catches up after sleep.
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runIfDue() }
        }
        Task { await refreshConnections() }
    }

    var hasPassword: Bool { FileManager.default.fileExists(atPath: BackupStore.passwordFile) }
    var hasDatabaseFile: Bool { FileManager.default.fileExists(atPath: settings.dbEnvFile) }
    var driveMounted: Bool {
        !settings.driveDir.isEmpty
            && FileManager.default.fileExists(atPath: (settings.driveDir as NSString).deletingLastPathComponent)
    }

    func refreshConnections() async {
        let gh = await Shell.runAsync(Shell.gh, ["api", "user", "--jq", ".login"])
        githubAccount = gh.status == 0 ? gh.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        resticInstalled = ["/opt/homebrew/bin/restic", "/usr/local/bin/restic"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
        status = BackupStore.status()
    }

    /// Picks the first Google Drive account and a "CI Local Backups" folder inside it.
    func useDefaultDrive() {
        guard let root = BackupStore.driveRoots().first else { return }
        settings.driveDir = root + "/CI Local Backups"
    }

    func enable() {
        do {
            try BackupStore.ensurePassword()
            error = nil
            settings.enabled = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func runNow() {
        guard !running else { return }
        running = true
        error = nil
        let script = BackupStore.script.path
        Task {
            let r = await Shell.runAsync("/bin/bash", [script])
            running = false
            status = BackupStore.status()
            if r.status != 0, status?.ok != false { error = "Backup failed. See the backup log." }
        }
    }

    private func runIfDue() {
        guard settings.enabled, !running else { return }
        let cal = Calendar.current
        let now = Date()
        guard cal.component(.hour, from: now) >= settings.hour else { return }
        if let last = status.flatMap({ ISO8601DateFormatter().date(from: $0.finishedAt) }),
           cal.isDate(last, inSameDayAs: now), status?.ok == true { return }
        // A failed run retries at the next check, at most once an hour.
        if let last = status.flatMap({ ISO8601DateFormatter().date(from: $0.finishedAt) }),
           status?.ok == false, now.timeIntervalSince(last) < 3600 { return }
        runNow()
    }

    /// Opens Terminal for the interactive browser login gh needs.
    func connectGitHub() {
        Terminal.run("gh auth login --web --git-protocol https && echo && echo 'Done. You can close this window.'")
    }

    /// Opens Terminal with the restore commands ready, so nothing destructive runs from the app.
    func openRestoreTerminal() {
        let repo = BackupStore.quote(settings.driveDir + "/restic")
        let pass = BackupStore.quote(BackupStore.passwordFile)
        Terminal.run("export RESTIC_REPOSITORY=\(repo) RESTIC_PASSWORD_FILE=\(pass); restic snapshots; "
                     + "echo; echo 'Restore example: restic restore latest --target ~/Restore'")
    }
}

enum Terminal {
    /// Runs a command in a new Terminal window via a temporary .command file.
    static func run(_ command: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cilocal-\(UUID().uuidString).command")
        let body = "#!/bin/bash\nexport PATH=/opt/homebrew/bin:/usr/local/bin:$PATH\n\(command)\nrm -f \"$0\"\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
}
