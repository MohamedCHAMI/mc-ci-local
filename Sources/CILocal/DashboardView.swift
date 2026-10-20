import SwiftUI
import AppKit

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var selection: String?
    @State private var showAdd = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(model.runners) { r in RunnerRow(runner: r).tag(r.id) }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                ToolbarItem { Button { showAdd = true } label: { Label("Add repository", systemImage: "plus") } }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                            set: { model.setLaunchAtLogin($0) }))
                    Button("Start all") { model.runners.forEach { $0.start() } }
                    Button("Stop all") { model.runners.forEach { $0.stop() } }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            if let r = model.runners.first(where: { $0.id == selection }) {
                RunnerDetail(model: model, runner: r).id(r.id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(model.runners.isEmpty ? "No repositories yet. Click + to add one."
                                               : "Select a repository").foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 540)
        .sheet(isPresented: $showAdd) { AddRepoView(model: model) }
        .onAppear { if selection == nil { selection = model.runners.first?.id } }
    }
}

struct RunnerRow: View {
    @ObservedObject var runner: RunnerManager
    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading) {
                Text(runner.config.name)
                Text(runner.message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var color: Color {
        switch runner.state {
        case .online: return .green
        case .starting: return .orange
        case .orphaned: return .yellow
        case .stopped: return .red
        }
    }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case runs = "Runs", log = "Runner log", workflows = "Workflows", local = "Local check"
    var id: String { rawValue }
}

struct RunnerDetail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var runner: RunnerManager
    @State private var tab: DetailTab = .runs
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    Text(runner.config.name).font(.title2.bold())
                    Text(runner.config.repo).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if runner.state == .stopped {
                    Button { runner.start() } label: { Label("Start", systemImage: "play.fill") }
                } else {
                    Button { runner.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    Button { runner.restart() } label: { Label("Restart", systemImage: "arrow.clockwise") }
                }
                Button { open("https://github.com/\(runner.config.repo)/actions") } label: {
                    Label("Actions", systemImage: "safari")
                }
                Button(role: .destructive) { confirmRemove = true } label: { Label("Remove", systemImage: "trash") }
            }
            Picker("", selection: $tab) {
                ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            Group {
                switch tab {
                case .runs: RunsView(runner: runner)
                case .log: LogView(runner: runner)
                case .workflows: WorkflowsView(runner: runner)
                case .local: LocalCheckView(model: model, runner: runner)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .confirmationDialog("Remove \(runner.config.name)?", isPresented: $confirmRemove) {
            Button("Remove and unregister runner", role: .destructive) { model.removeRunner(runner) }
        } message: { Text("Stops the runner and unregisters it from GitHub. Workflows still set to self-hosted will queue until you change them.") }
    }

    private func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
}

struct RunsView: View {
    @ObservedObject var runner: RunnerManager
    @State private var runs: [RunInfo] = []
    @State private var loading = true
    @State private var note = ""
    @State private var showMerged = false
    @State private var leftovers: [String] = []
    @State private var confirmDelete = false
    @State private var autoDelete: Bool?

    private var merged: Set<String> { runner.mergedBranches }
    private var visible: [RunInfo] { showMerged ? runs : runs.filter { !MergedBranches.isMerged($0, merged) } }
    private var hiddenCount: Int { runs.count - visible.count }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Recent workflow runs").font(.headline)
                Spacer()
                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                Toggle("Show merged branches", isOn: $showMerged).toggleStyle(.checkbox)
                    .help("Runs on branches whose PR is merged are history: main's run covers that code.")
                Button("Re-run all failed") { rerunFailed() }
                    .disabled(MergedBranches.rerunnable(runs, merged).isEmpty)
                Button { Task { await load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
            }
            if loading && runs.isEmpty { ProgressView() }
            List(visible) { r in
                HStack {
                    Image(systemName: r.symbol).foregroundStyle(tint(r.tint)).frame(width: 20)
                    VStack(alignment: .leading) {
                        Text(r.displayTitle).lineLimit(1)
                        Text("\(r.workflowName) · \(r.headBranch) · \(r.event) · \(r.createdAt.prefix(16).replacingOccurrences(of: "T", with: " "))")
                            .font(.caption).foregroundStyle(.secondary)
                        if MergedBranches.isMerged(r, merged) {
                            Text("Branch merged into main: history only, not re-run.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if r.failureKind == .billing {
                            Text("Not started: GitHub billing blocks hosted runners. Fix it in the Workflows tab.")
                                .font(.caption).foregroundStyle(.orange)
                        } else if r.failureKind == .runnerLost {
                            Text("Runner lost connection (Mac asleep or offline), not a code error. Re-run it.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    if r.isActive { Button("Cancel") { act(["run", "cancel", "\(r.id)"], "Cancelled") } }
                    else if !r.billingBlocked && !MergedBranches.isMerged(r, merged) {
                        Button("Re-run") { act(["run", "rerun", "\(r.id)"], "Re-run queued") }
                    }
                    Button { if let u = URL(string: r.url) { NSWorkspace.shared.open(u) } } label: {
                        Image(systemName: "arrow.up.right.square")
                    }.buttonStyle(.borderless)
                }
            }
            HStack {
                if hiddenCount > 0 && !showMerged {
                    Text("\(hiddenCount) run(s) on merged branches hidden.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !leftovers.isEmpty {
                    Button("Delete \(leftovers.count) merged branch(es)…") { confirmDelete = true }
                }
                if let autoDelete {
                    Toggle("Auto-delete branches on merge", isOn: Binding(
                        get: { autoDelete },
                        set: { on in Task { if await GH.setAutoDeleteOnMerge(on, repo: runner.config.repo) { self.autoDelete = on } } }))
                    .toggleStyle(.checkbox)
                    .help("GitHub repo setting: delete the PR branch as soon as the PR is merged.")
                }
            }
            Text("Orange = not a code error: card icon is GitHub billing (re-running cannot fix it), Wi-Fi icon is a lost runner (re-run once it is online; CI Local does this automatically). Queued runs on merged branches are cancelled automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Delete \(leftovers.count) merged branch(es) on GitHub?", isPresented: $confirmDelete) {
            Button("Delete branches", role: .destructive) { deleteLeftovers() }
        } message: {
            Text("Their pull requests are merged and nothing was pushed to them since, so no work is lost. Each merged PR can restore its branch on GitHub.\n\n" + leftovers.prefix(15).joined(separator: "\n") + (leftovers.count > 15 ? "\n…" : ""))
        }
        .task {
            await loadBranches()
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    private func load(force: Bool = false) async {
        if force { await runner.refreshMergedBranches(force: true); await loadBranches() }
        let fetched = await GH.runs(repo: runner.config.repo)
        runs = fetched
        loading = false
        runs = await GH.classifyFailures(fetched, repo: runner.config.repo)
    }

    private func loadBranches() async {
        let repo = runner.config.repo
        await runner.refreshMergedBranches()
        leftovers = MergedBranches.leftovers(remote: await GH.remoteBranches(repo: repo),
                                             mergedHeadShas: await GH.mergedHeadShas(repo: repo),
                                             merged: runner.mergedBranches)
        autoDelete = await GH.autoDeleteOnMerge(repo: repo)
    }

    private func act(_ args: [String], _ done: String) {
        Task {
            _ = await GH.run(args + ["--repo", runner.config.repo])
            note = done
            await load()
        }
    }

    private func rerunFailed() {
        let ids = MergedBranches.rerunnable(runs, merged).map(\.id)
        Task {
            for id in ids { _ = await GH.run(["run", "rerun", "\(id)", "--repo", runner.config.repo]) }
            note = "Re-ran \(ids.count) run(s)"
            await load()
        }
    }

    private func deleteLeftovers() {
        let names = leftovers
        Task {
            let n = await GH.deleteBranches(names, repo: runner.config.repo)
            note = "Deleted \(n) of \(names.count) merged branch(es)"
            await load(force: true)
        }
    }

    private func tint(_ s: String) -> Color {
        switch s { case "green": return .green; case "red": return .red; case "orange": return .orange; default: return .gray }
    }
}

struct LogView: View {
    @ObservedObject var runner: RunnerManager
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Live runner output").font(.headline)
                Spacer()
                Button("Open in editor") { NSWorkspace.shared.open(runner.logURL) }
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([runner.logURL]) }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "No output yet." : text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(8).background(.black.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: text) { _ in proxy.scrollTo("end") }
            }
        }
        .task {
            while !Task.isCancelled {
                if let h = try? FileHandle(forReadingFrom: runner.logURL) {
                    let size = (try? h.seekToEnd()) ?? 0
                    try? h.seek(toOffset: size > 20_000 ? size - 20_000 : 0)
                    text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
                    try? h.close()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

struct WorkflowsView: View {
    @ObservedObject var runner: RunnerManager
    @State private var files: [WorkflowFile] = []
    @State private var loading = true
    @State private var confirm = false
    @State private var busy = false
    @State private var result: String?
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Workflow runners").font(.headline)
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                Button("Make Mac-safe (open PR)") { confirm = true }
                    .disabled(busy || !files.contains(where: \.needsFix))
            }
            if loading { ProgressView() }
            List(files) { f in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Image(systemName: f.selfHosted ? "desktopcomputer" : "cloud")
                            .foregroundStyle(f.selfHosted && !f.needsFix ? .green : .orange)
                        Text(f.name)
                        Spacer()
                        Text(f.runsOn.isEmpty ? "no runs-on" : f.runsOn.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(f.changes, id: \.self) { Text("→ \($0)").font(.caption).foregroundStyle(.blue) }
                    ForEach(f.warnings, id: \.self) { Text("⚠️ \($0)").font(.caption).foregroundStyle(.orange) }
                }
                .padding(.vertical, 2)
            }
            if busy { ProgressView("Creating PR…") }
            if let result {
                if isError { Text(result).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
                else if let u = URL(string: result) { Link("Open PR: \(result)", destination: u) }
            }
            Text("Reads .github/workflows on the default branch. → = fixed by the PR (hosted runners, GNU sed, .env cleanup). ⚠️ = check by hand.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await load() }
        .confirmationDialog("Open a PR on \(runner.config.repo)?", isPresented: $confirm) {
            Button("Create branch + PR") { create() }
        } message: { Text("Creates a ci-local/self-hosted-runner-<date> branch and a pull request with the → changes listed here. Nothing is merged.") }
    }

    private func load() async {
        files = await GH.workflows(repo: runner.config.repo)
        loading = false
    }

    private func create() {
        busy = true; result = nil
        Task {
            do { result = try await GH.openSwitchPR(repo: runner.config.repo); isError = false }
            catch { result = error.localizedDescription; isError = true }
            busy = false
        }
    }
}

struct LocalCheckView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var runner: RunnerManager
    @StateObject private var check = LocalCheck()
    @State private var hookNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(runner.config.localPath ?? "No local folder chosen").font(.callout)
                    .foregroundStyle(runner.config.localPath == nil ? .secondary : .primary)
                Spacer()
                Button("Choose folder…") { choose() }
            }
            HStack {
                if check.running { Button("Cancel") { check.cancel() } }
                else { Button { if let p = runner.config.localPath { check.run(in: p) } } label: {
                    Label("Run checks", systemImage: "play.fill") }
                    .disabled(runner.config.localPath == nil) }
                Button("Install pre-push hook") {
                    if let p = runner.config.localPath { hookNote = LocalCheck.installHook(in: p) }
                }.disabled(runner.config.localPath == nil)
                if check.running { ProgressView().controlSize(.small) }
                if let code = check.exitCode {
                    Label(code == 0 ? "Passed" : "Failed (exit \(code))",
                          systemImage: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(code == 0 ? .green : .red)
                }
            }
            if let p = runner.config.localPath {
                Text("Runs: \(CheckCommand.detect(in: p))").font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            if !hookNote.isEmpty { Text(hookNote).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                Text(check.output.isEmpty ? "Output appears here." : check.output)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .padding(8).background(.black.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = "Choose the local clone of \(runner.config.repo)"
        if p.runModal() == .OK, let u = p.url { model.setLocalPath(runner, u.path) }
    }
}
