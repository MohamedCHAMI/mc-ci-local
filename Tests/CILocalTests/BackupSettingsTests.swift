import XCTest
@testable import CILocal

final class BackupSettingsTests: XCTestCase {
    func testEnvQuotesEveryValueForBash() {
        var s = BackupSettings()
        s.driveDir = "/Users/me/Library/CloudStorage/GoogleDrive-a@b.com/My Drive/CI Local Backups"
        s.githubOwner = "it's-me"
        s.extraPaths = ["/tmp/one", "/tmp/two words"]
        let env = BackupStore.env(s)
        XCTAssertTrue(env.contains("DRIVE_DIR='/Users/me/Library/CloudStorage/GoogleDrive-a@b.com/My Drive/CI Local Backups'"))
        XCTAssertTrue(env.contains("GITHUB_OWNER='it'\\''s-me'"))
        XCTAssertTrue(env.contains("EXTRA_PATHS='/tmp/one\n/tmp/two words'"))
        XCTAssertTrue(env.contains("GITHUB_ENABLED=1"))
    }

    func testEnvSurvivesBashSourcing() throws {
        var s = BackupSettings()
        s.driveDir = "/tmp/a b/$(touch /tmp/cilocal-pwned)"
        s.githubOwner = "o'k"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("backup-test.env")
        try BackupStore.env(s).write(to: file, atomically: true, encoding: .utf8)
        let r = Shell.run("/bin/bash", ["-c", ". \"$1\"; printf '%s|%s' \"$DRIVE_DIR\" \"$GITHUB_OWNER\"", "_", file.path])
        XCTAssertEqual(r.out, "/tmp/a b/$(touch /tmp/cilocal-pwned)|o'k")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/cilocal-pwned"))
    }
}
