import SwiftUI

struct AddRepoView: View {
    @ObservedObject var model: AppModel
    @State private var repos: [RepoInfo] = []
    @State private var manual = ""
    @State private var busy = false
    @State private var loading = true
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var available: [RepoInfo] {
        let have = Set(model.runners.map { $0.config.repo.lowercased() })
        return repos.filter { !have.contains($0.nameWithOwner.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Add a repository").font(.headline); Spacer(); Button("Close") { dismiss() } }
            Text("Registers a free self-hosted runner (label mac-local). Private repos only.")
                .font(.caption).foregroundStyle(.secondary)

            if loading {
                ProgressView("Loading your private repos…")
            } else {
                List(available) { r in
                    HStack {
                        Text(r.nameWithOwner)
                        Spacer()
                        Button("Add") { add(r.nameWithOwner) }.disabled(busy)
                    }
                }
                .frame(minHeight: 200)
            }

            HStack {
                TextField("owner/repo", text: $manual).textFieldStyle(.roundedBorder)
                Button("Add") { add(manual.trimmingCharacters(in: .whitespaces)) }
                    .disabled(busy || !manual.contains("/"))
            }
            if busy { ProgressView("Installing runner…") }
            if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
        }
        .padding(16)
        .frame(width: 440, height: 440)
        .task {
            repos = await Task.detached { Installer.privateRepos() }.value
            loading = false
        }
    }

    private func add(_ repo: String) {
        busy = true; error = nil
        Task {
            do {
                try await model.addRunner(repo: repo)
                manual = ""
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
