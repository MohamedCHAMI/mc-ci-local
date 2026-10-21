import SwiftUI
import AppKit

struct BackupView: View {
    @ObservedObject var backup: BackupManager
    @State private var newRemote = ""
    @State private var newRepoURL = ""

    private var destinationLabel: String {
        if !backup.settings.repoURL.isEmpty { return backup.settings.repoURL }
        return backup.settings.driveDir.isEmpty ? "Not chosen" : backup.settings.driveDir
    }

    var body: some View {
        Form {
            Section("GitHub") {
                if let account = backup.githubAccount {
                    LabeledContent("Connected", value: account)
                    Toggle("Mirror every repository (code, branches, tags)", isOn: $backup.settings.githubEnabled)
                    TextField("Owner (empty = \(account))", text: $backup.settings.githubOwner)
                } else {
                    Text("Not connected.").foregroundStyle(.secondary)
                }
                HStack {
                    Button(backup.githubAccount == nil ? "Connect GitHub…" : "Switch account…") { backup.connectGitHub() }
                    Button("Check again") { Task { await backup.refreshConnections() } }
                }
            }

            Section("Other Git providers") {
                Text("GitLab, Bitbucket, Gitea, Azure DevOps or any server: paste a clone URL. "
                     + "It uses this Mac's Git login (SSH key or Keychain).")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(backup.settings.gitRemotes, id: \.self) { url in
                    HStack {
                        Text(url).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { backup.settings.gitRemotes.removeAll { $0 == url } }
                    }
                }
                HStack {
                    TextField("https://gitlab.com/me/repo.git or git@host:me/repo.git", text: $newRemote)
                        .onSubmit(addRemote)
                    Button("Add", action: addRemote).disabled(!BackupStore.isGitURL(newRemote))
                }
            }

            Section("Where backups go") {
                LabeledContent("Destination", value: destinationLabel)
                Text("A synced folder (its app uploads it) or cloud storage that restic writes to directly.")
                    .font(.caption).foregroundStyle(.secondary)
                let roots = BackupStore.syncRoots()
                if roots.isEmpty {
                    Text("No sync app found. Install Google Drive, iCloud Drive, Dropbox or OneDrive, connect a disk, or use cloud storage below.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(roots, id: \.path) { root in
                        Button("Use \(root.name)") { backup.use(root: root.path) }
                    }
                }
                HStack {
                    Button("Choose folder…") { chooseDriveFolder() }
                    if !backup.settings.driveDir.isEmpty && backup.settings.repoURL.isEmpty {
                        Button("Show in Finder") { reveal(backup.settings.driveDir) }
                    }
                }
                if backup.settings.repoURL.isEmpty && !backup.settings.driveDir.isEmpty && !backup.driveMounted {
                    Label("This folder is not available right now. Open its sync app or connect the disk.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                HStack {
                    TextField("Cloud storage: s3:…, b2:bucket:path, azure:…, gs:…, sftp:user@host:/path, rclone:remote:path",
                              text: $newRepoURL)
                        .onSubmit(useRepoURL)
                    Button("Use", action: useRepoURL).disabled(!BackupStore.isRepoURL(newRepoURL))
                }
                if !backup.settings.repoURL.isEmpty {
                    Text(backup.hasCloudCredentials
                         ? "Credentials are read from ~/.secrets/backup-cloud.env."
                         : "Add the provider's keys to ~/.secrets/backup-cloud.env (e.g. AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, B2_ACCOUNT_ID / B2_ACCOUNT_KEY).")
                        .font(.caption)
                        .foregroundStyle(backup.hasCloudCredentials ? Color.secondary : Color.orange)
                }
            }

            Section("What is saved") {
                LabeledContent("Database dump") {
                    Text(backup.hasDatabaseFile ? "On" : "Off: add SUPABASE_DB_URL to the file below")
                        .foregroundStyle(backup.hasDatabaseFile ? Color.primary : Color.orange)
                }
                TextField("Database settings file", text: $backup.settings.dbEnvFile)
                TextField(".env and signing keys found under", text: $backup.settings.scanDir)
                LabeledContent("Always", value: "~/.secrets")
                ForEach(backup.settings.extraPaths, id: \.self) { p in
                    HStack {
                        Text(p).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { backup.settings.extraPaths.removeAll { $0 == p } }
                    }
                }
                Button("Add folder…") { addFolder() }
            }

            Section("Schedule and encryption") {
                if !backup.resticInstalled {
                    Label("restic is not installed. Run: brew install restic", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if backup.settings.enabled {
                    Toggle("Back up every day", isOn: $backup.settings.enabled)
                    Stepper("After \(backup.settings.hour):00", value: $backup.settings.hour, in: 0...23)
                } else {
                    Button("Turn on daily backups") { backup.enable() }
                        .disabled(!backup.settings.hasDestination || !backup.resticInstalled)
                }
                if backup.hasPassword {
                    Text("Backups are encrypted with the password in ~/.secrets/restic-backup.pass. "
                         + "Copy it into your password manager: without it, the backups cannot be restored.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Show password file in Finder") { reveal(BackupStore.passwordFile) }
                }
            }

            Section("Status") {
                if let s = backup.status {
                    Label(s.message, systemImage: s.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(s.ok ? .green : .red)
                    LabeledContent("Finished", value: s.finishedAt)
                } else {
                    Text("No backup yet.").foregroundStyle(.secondary)
                }
                if let e = backup.error { Text(e).foregroundStyle(.red) }
                HStack {
                    Button(backup.running ? "Backing up…" : "Back up now") { backup.runNow() }
                        .disabled(backup.running || !backup.settings.enabled)
                    Button("Open log") { NSWorkspace.shared.open(BackupStore.log) }
                    Button("Restore…") { backup.openRestoreTerminal() }.disabled(!backup.hasPassword)
                }
                Text("CI jobs on this Mac can save release files with:\n\"\(BackupStore.script.path)\" --paths <dir>")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 640)
        .task { await backup.refreshConnections() }
    }

    private func useRepoURL() {
        let url = newRepoURL.trimmingCharacters(in: .whitespaces)
        guard BackupStore.isRepoURL(url) else { return }
        backup.settings.repoURL = url
        newRepoURL = ""
    }

    private func addRemote() {
        let url = newRemote.trimmingCharacters(in: .whitespaces)
        guard BackupStore.isGitURL(url), !backup.settings.gitRemotes.contains(url) else { return }
        backup.settings.gitRemotes.append(url)
        newRemote = ""
    }

    private func chooseDriveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = BackupStore.syncRoots().first.map { URL(fileURLWithPath: $0.path) }
        if panel.runModal() == .OK, let url = panel.url {
            backup.settings.repoURL = ""
            backup.settings.driveDir = url.path
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !backup.settings.extraPaths.contains(url.path) {
                backup.settings.extraPaths.append(url.path)
            }
        }
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
