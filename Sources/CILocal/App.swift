import SwiftUI
import ServiceManagement

@main
struct CILocalApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: model.iconName)
        }
        .menuBarExtraStyle(.menu)

        Window("CI Local", id: "main") {
            DashboardView(model: model)
        }
        Window("Add repository", id: "add-repo") {
            AddRepoView(model: model)
        }
        .windowResizability(.contentSize)
        Window("Backups & connections", id: "backups") {
            BackupView(backup: model.backup)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var runners: [RunnerManager] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// GitHub + Google Drive backups; also runs the daily schedule while the app is open.
    let backup = BackupManager()
    private var observers: [Any] = []

    init() {
        // One instance only: two copies would start, cancel and re-run the same runs twice.
        let me = NSRunningApplication.current
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != me }) {
            NSLog("CI Local is already running; quitting this copy.")
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        runners = Config.load().map { RunnerManager(config: $0) }
        // Start every runner when the app opens, so waking the Mac needs no manual step.
        runners.forEach { $0.start() }
        runners.forEach(watch)
    }

    var iconName: String {
        if runners.contains(where: { $0.state == .online }) { return "checkmark.circle.fill" }
        if runners.contains(where: { $0.state == .starting }) { return "arrow.triangle.2.circlepath.circle" }
        return "xmark.circle"
    }

    private func watch(_ r: RunnerManager) {
        observers.append(r.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
    }

    func addRunner(repo: String) async throws {
        guard !runners.contains(where: { $0.config.repo.lowercased() == repo.lowercased() }) else { return }
        let cfg = try await Task.detached { try Installer.install(repo: repo) }.value
        let r = RunnerManager(config: cfg)
        runners.append(r)
        watch(r)
        Config.save(runners.map(\.config))
        r.start()
    }

    func setLocalPath(_ r: RunnerManager, _ path: String) {
        r.config.localPath = path
        Config.save(runners.map(\.config))
    }

    func removeRunner(_ r: RunnerManager) {
        r.stop()
        r.shutdown()
        let cfg = r.config
        runners.removeAll { $0.id == r.id }
        Config.save(runners.map(\.config))
        Task.detached {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            Installer.unregister(cfg)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Launch at login failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct MenuView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(model.runners) { r in
            Section(r.config.name) {
                Text("\(label(r.state)) — \(r.message)")
                if r.state == .stopped {
                    Button("Start") { r.start() }
                } else {
                    Button("Stop") { r.stop() }
                    Button("Restart") { r.restart() }
                }
                Button("Re-run failed checks") { r.rerunFailed() }
                Button("Open log") { NSWorkspace.shared.open(r.logURL) }
                Button("Refresh") { Task { await r.refresh() } }
                Button("Remove this repo") { model.removeRunner(r) }
            }
        }
        Divider()
        Button("Open dashboard…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button("Add repository…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "add-repo")
        }
        Button("Backups & connections…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "backups")
        }
        Toggle("Launch at login", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }))
        Button("Edit runners config") { NSWorkspace.shared.open(Config.file) }
        Button("Quit (stops runners)") {
            model.runners.forEach { $0.stop() }
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func label(_ s: RunnerState) -> String {
        switch s {
        case .online: return "🟢 Online"
        case .starting: return "🟡 Starting"
        case .orphaned: return "🟠 Online (not managed)"
        case .stopped: return "🔴 Stopped"
        }
    }
}
