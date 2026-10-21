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

    func testOldSettingsFileKeepsItsValuesAndGetsNewDefaults() throws {
        let old = #"{"driveDir":"/x/My Drive/CI Local Backups","enabled":true,"githubEnabled":false,"githubOwner":"me","dbEnvFile":"/s/db.env","scanDir":"/apps","extraPaths":["/a"],"hour":5}"#
        let s = try JSONDecoder().decode(BackupSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.driveDir, "/x/My Drive/CI Local Backups")
        XCTAssertTrue(s.enabled)
        XCTAssertFalse(s.githubEnabled)
        XCTAssertEqual(s.hour, 5)
        XCTAssertEqual(s.gitRemotes, [])
        XCTAssertEqual(s.repoURL, "")
    }

    func testGitURLs() {
        for ok in ["https://gitlab.com/me/repo.git", "ssh://git@bitbucket.org/me/repo.git", "git@gitea.example.com:me/repo.git",
                   "git@ssh.dev.azure.com:v3/org/proj/repo"] {
            XCTAssertTrue(BackupStore.isGitURL(ok), ok)
        }
        for bad in ["", "repo", "--upload-pack=touch /tmp/x", "https://", "git@host", "a b@host:x"] {
            XCTAssertFalse(BackupStore.isGitURL(bad), bad)
        }
    }

    func testCloudRepoURLs() {
        for ok in ["s3:s3.amazonaws.com/bucket/ci", "b2:bucket:ci", "azure:container:/ci", "gs:bucket:/ci",
                   "sftp:me@nas:/backups", "rclone:onedrive:ci", "rest:https://host:8000/"] {
            XCTAssertTrue(BackupStore.isRepoURL(ok), ok)
        }
        XCTAssertFalse(BackupStore.isRepoURL("/Users/me/backups"))
        XCTAssertFalse(BackupStore.isRepoURL("s3:"))
    }

    func testEnvExportsCloudRepoAndGitRemotes() {
        var s = BackupSettings()
        s.repoURL = "b2:bucket:ci"
        s.gitRemotes = ["https://gitlab.com/me/a.git", "git@host:me/b.git"]
        let env = BackupStore.env(s)
        XCTAssertTrue(env.contains("REPO_URL='b2:bucket:ci'"))
        XCTAssertTrue(env.contains("GIT_REMOTES='https://gitlab.com/me/a.git\ngit@host:me/b.git'"))
    }
}
