import SwiftUI
import AppKit

struct BackupView: View {
    @ObservedObject var backup: BackupManager

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

            Section("Google Drive") {
                if BackupStore.driveRoots().isEmpty {
                    Text("Google Drive for desktop is not running or not signed in.").foregroundStyle(.secondary)
                    Button("Get Google Drive for desktop") {
                        NSWorkspace.shared.open(URL(string: "https://www.google.com/drive/download/")!)
                    }
                } else {
                    LabeledContent("Folder", value: backup.settings.driveDir.isEmpty ? "Not chosen" : backup.settings.driveDir)
                    HStack {
                        Button("Use default folder") { backup.useDefaultDrive() }
                        Button("Choose…") { chooseDriveFolder() }
                        if !backup.settings.driveDir.isEmpty {
                            Button("Show in Finder") { reveal(backup.settings.driveDir) }
                        }
                    }
                    if !backup.settings.driveDir.isEmpty && !backup.driveMounted {
                        Label("Drive is not mounted right now. Open Google Drive for desktop.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
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
                        .disabled(backup.settings.driveDir.isEmpty || !backup.resticInstalled)
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

    private func chooseDriveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = BackupStore.driveRoots().first.map { URL(fileURLWithPath: $0) }
        if panel.runModal() == .OK, let url = panel.url { backup.settings.driveDir = url.path }
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
