import MonitorCore
import SwiftUI

struct WorktreesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Worktrees", subtitle: "Git worktrees in \(model.settings.repoRoots.map(shortPath).joined(separator: ", ")). Change the folders in Settings.")

                HStack {
                    Toggle("Measure folder sizes (slower)", isOn: $model.includeWorktreeSizes)
                        .toggleStyle(.checkbox)
                        .onChange(of: model.includeWorktreeSizes) { Task { await model.refreshFull() } }
                    Spacer()
                    if let issue = model.issues.first(where: { $0.id == "worktrees" }), let fix = issue.fix {
                        Button("Prune All Stale…") { model.request(.fix(fix)) }
                    }
                }

                if let repos = model.snapshot.worktrees {
                    ForEach(repos.filter { $0.worktrees.count > 1 || $0.worktrees.contains(where: \.isStale) }) { repo in
                        repoCard(repo)
                    }
                    let single = repos.filter { $0.worktrees.count <= 1 }.count
                    if single > 0 {
                        Text("\(single) other repo\(single == 1 ? "" : "s") with no extra worktrees.").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Scanning repositories…").frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
    }

    private func repoCard(_ repo: RepoWorktrees) -> some View {
        let linked = repo.worktrees.filter { !$0.entry.isMain }
        let stale = linked.filter(\.isStale).count
        return SectionCard(title: (repo.repoPath as NSString).lastPathComponent,
                           subtitle: "\(shortPath(repo.repoPath)) · \(linked.count) worktree\(linked.count == 1 ? "" : "s")\(stale > 0 ? ", \(stale) stale" : "")") {
            ForEach(linked) { worktree in
                row(worktree, repo: repo.repoPath)
                if worktree.id != linked.last?.id { Divider() }
            }
        }
    }

    private func row(_ w: WorktreeInfo, repo: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text((w.entry.path as NSString).lastPathComponent).font(.body.weight(.medium))
                Text(w.entry.branch ?? (w.entry.detached ? "detached HEAD" : "—")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            chips(w)
            Text(formatBytes(w.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            if w.exists {
                Button { model.reveal(w.entry.path) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Show in Finder")
            }
            if w.isStale {
                Button(w.hasDeadLock ? "Unlock & Prune…" : "Prune…") {
                    model.request(.fix(.cleanWorktrees(prune: [repo], unlock: w.hasDeadLock ? [WorktreeRef(repo: repo, path: w.entry.path)] : [])))
                }
                .controlSize(.small)
            } else {
                Button("Remove…") { model.request(.removeWorktree(WorktreeRef(repo: repo, path: w.entry.path))) }
                    .controlSize(.small)
                    .disabled(!w.isSafeToRemove)
                    .help(w.isSafeToRemove ? "git worktree remove (the branch stays)"
                          : !w.usedByPIDs.isEmpty ? "A process is working in this folder, likely a running session"
                          : "Only clean worktrees with everything pushed can be removed here")
            }
        }
    }

    @ViewBuilder
    private func chips(_ w: WorktreeInfo) -> some View {
        HStack(spacing: 4) {
            if !w.exists { Chip(text: "Folder gone", color: .orange) }
            if w.entry.isLocked {
                Chip(text: w.lockPIDAlive == true ? "Locked · session live" : "Locked · session ended",
                     color: w.lockPIDAlive == true ? .blue : .orange)
            }
            if let dirty = w.dirtyFiles, dirty > 0 { Chip(text: "\(dirty) uncommitted", color: .red) }
            if let unpushed = w.unpushedCommits, unpushed > 0 { Chip(text: "\(unpushed) unpushed", color: .purple) }
            if !w.usedByPIDs.isEmpty {
                Chip(text: "In use · PID \(w.usedByPIDs.prefix(2).map(String.init).joined(separator: ", "))\(w.usedByPIDs.count > 2 ? "…" : "")", color: .blue)
            }
            if w.isSafeToRemove { Chip(text: "Clean", color: .green) }
        }
    }
}
