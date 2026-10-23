import MonitorCore
import SwiftUI

/// Dev Tools: every stack's caches, plus Xcode's build data, simulators and git worktrees, as tabs.
struct DevToolsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("", selection: $model.devToolsTab) {
                ForEach(DevToolsTab.allCases) { tab in
                    let count = model.issues.filter { issue in tab.issueIDs.contains(where: issue.id.hasPrefix) }.count
                    Text(count > 0 ? "\(tab.rawValue) (\(count))" : tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 620)
            .padding(.top, 14)
            .padding(.horizontal, 24)
            DevToolsTabContent(tab: model.devToolsTab)
        }
    }
}

struct DevToolsTabContent: View {
    var tab: DevToolsTab

    var body: some View {
        switch tab {
        case .tools: DevToolsCachesView()
        case .buildData: BuildDataView()
        case .simulators: SimulatorsView()
        case .worktrees: WorktreesView()
        }
    }
}

struct DevToolsCachesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Tools & Caches", subtitle: "Caches, build output, containers and repositories from every stack you work in: JavaScript, Python, JVM/Android, Rust, Go, Ruby, Dart, .NET, Docker, Git.")
                if let dev = model.snapshot.dev {
                    summary(dev)
                    servers
                    caches(dev)
                    projects(dev)
                    docker(dev.docker)
                    git(dev.git)
                } else {
                    ProgressView("Scanning developer tools…").frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
    }

    // MARK: Summary

    private func summary(_ dev: DevSnapshot) -> some View {
        let cacheTotal: Int64 = dev.caches.compactMap { $0.reclaimable ?? $0.size }.reduce(0, +)
        let ideTotal: Int64 = dev.oldIDEFolders.compactMap(\.size).reduce(0, +)
        let cacheBytes = cacheTotal + ideTotal
        let idle = dev.artifacts.filter { ($0.idleDays() ?? 0) >= 30 }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
            MetricCard(title: "Tool caches", value: ByteSize.format(cacheBytes), caption: "\(dev.caches.count) caches · \(dev.oldIDEFolders.count) old IDE folders",
                       symbol: "wrench.and.screwdriver", health: .good, progress: nil)
            MetricCard(title: "Project build folders", value: ByteSize.format(dev.artifacts.compactMap(\.size).reduce(0, +)),
                       caption: "\(dev.artifacts.count) folders · \(idle.count) in projects idle 30+ days",
                       symbol: "shippingbox", health: idle.isEmpty ? .good : .warning, progress: nil)
            MetricCard(title: "Docker", value: dockerValue(dev.docker), caption: dockerCaption(dev.docker),
                       symbol: "cube.transparent", health: .good, progress: nil)
            MetricCard(title: "Git", value: "\(dev.git.count) repos", caption: "\(dev.git.filter(\.stats.needsMaintenance).count) could be packed",
                       symbol: "point.3.connected.trianglepath.dotted", health: .good, progress: nil)
        }
    }

    private func dockerValue(_ docker: DockerStatus) -> String {
        switch docker.state {
        case .notInstalled: "—"
        case .notRunning: "Stopped"
        case .running: ByteSize.format(docker.usage.map(\.size).reduce(0, +))
        }
    }

    private func dockerCaption(_ docker: DockerStatus) -> String {
        switch docker.state {
        case .notInstalled: "Not installed"
        case .notRunning: docker.vmDiskBytes.map { "VM disk \(ByteSize.format($0)) · start Docker to see details" } ?? "Start Docker to see details"
        case .running: "\(ByteSize.format(docker.usage.map(\.reclaimable).reduce(0, +))) reclaimable"
        }
    }

    // MARK: Running servers

    @ViewBuilder
    private var servers: some View {
        let kinds: [DaemonKind] = [.virtualMachine, .androidEmulator, .database, .node, .gradle, .kotlin]
        let daemons = (model.snapshot.processes?.daemons ?? []).filter { kinds.contains($0.kind) }
        if !daemons.isEmpty {
            SectionCard(title: "Running dev servers & VMs", subtitle: "They hold memory while they run. Stop what you're not using.") {
                ForEach(daemons) { daemon in
                    HStack {
                        Chip(text: daemon.kind.rawValue, color: .blue)
                        Text(daemon.row.command).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).help(daemon.row.command)
                        Spacer()
                        Text(formatBytes(daemon.footprint)).monospacedDigit()
                        Text(ElapsedTime.format(daemon.row.elapsed)).monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                        Button("Stop…") {
                            model.request(.terminate(targets: [ProcessTarget(pid: daemon.row.pid, command: daemon.row.command)], label: daemon.kind.rawValue))
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Caches

    private func caches(_ dev: DevSnapshot) -> some View {
        SectionCard(title: "Tool caches", subtitle: "Downloads and build caches each tool rebuilds on its own. Recommended ones regenerate without you noticing.") {
            if dev.caches.isEmpty && dev.oldIDEFolders.isEmpty {
                Text("No developer caches found.").foregroundStyle(.secondary)
            }
            ForEach(DevEcosystem.allCases, id: \.self) { ecosystem in
                let entries = dev.caches.filter { $0.spec.ecosystem == ecosystem }
                if !entries.isEmpty {
                    Label(ecosystem.rawValue, systemImage: ecosystem.symbol).font(.callout.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(entries) { entry in cacheRow(entry) }
                }
            }
            if !dev.oldIDEFolders.isEmpty {
                Label("Old IDE versions", systemImage: "clock.arrow.circlepath").font(.callout.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(dev.oldIDEFolders) { folder in
                    HStack {
                        Text(folder.name)
                        Text(shortPath((folder.path as NSString).deletingLastPathComponent)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(formatBytes(folder.size)).monospacedDigit()
                        Button { model.reveal(folder.path) } label: { Image(systemName: "folder") }.buttonStyle(.borderless)
                        Button("Delete…") {
                            model.request(.cleanup(.deleteFolders([folder.path]), title: "Delete \(folder.name)?",
                                                   detail: "Left behind by an IDE version you've since updated.\n\n\(shortPath(folder.path))", confirmLabel: "Delete"))
                        }
                        .controlSize(.small)
                    }
                    .padding(.leading, 20)
                }
            }
        }
    }

    private func cacheRow(_ entry: DevCacheEntry) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.spec.title).font(.body.weight(.medium))
                    if entry.spec.recommended { Chip(text: "Recommended", color: .green) }
                    if entry.spec.safety == .review { Chip(text: entry.spec.safety.rawValue, color: .purple) }
                }
                Text(entry.spec.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.reclaimable.map(ByteSize.format) ?? "up to \(formatBytes(entry.size))").monospacedDigit()
                if let reclaimable = entry.reclaimable, let size = entry.size, reclaimable != size {
                    Text("of \(ByteSize.format(size))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button { model.reveal(entry.existingPaths[0]) } label: { Image(systemName: "folder") }.buttonStyle(.borderless)
            Button("Clean…") {
                var detail = entry.spec.detail
                if case .command(let tool, let arguments) = entry.spec.cleanup { detail += "\n\nRuns: \(tool) \(arguments.joined(separator: " "))" }
                else { detail += "\n\nDeletes:\n" + entry.existingPaths.map(shortPath).joined(separator: "\n") }
                model.request(.cleanup(.cleanDevCaches([entry.spec.id]), title: "Clean \(entry.spec.title)?", detail: detail, confirmLabel: "Clean"))
            }
            .controlSize(.small)
        }
        .padding(.leading, 20)
    }

    // MARK: Projects

    private func projects(_ dev: DevSnapshot) -> some View {
        let idle = dev.artifacts.filter { ($0.idleDays() ?? 0) >= 30 }
        return SectionCard(title: "Project build folders",
                           subtitle: "Build output inside projects under \(model.settings.repoRoots.map(shortPath).joined(separator: ", ")), each confirmed by its project file.") {
            if dev.artifacts.isEmpty {
                Text("No build folders found.").foregroundStyle(.secondary)
            } else {
                Table(dev.artifacts) {
                    TableColumn("Project") { a in Text(a.projectName).help(a.projectPath) }
                    TableColumn("Kind") { a in Text(a.kind.rawValue).foregroundStyle(.secondary) }.width(150)
                    TableColumn("Last change") { a in
                        let days = Int(a.idleDays() ?? 0)
                        if days >= 30 { Chip(text: "Idle \(days) days", color: .orange) }
                        else { Text(a.lastActivity.map { $0.formatted(.relative(presentation: .named)) } ?? "—").foregroundStyle(.secondary) }
                    }
                    .width(120)
                    TableColumn("Size") { a in Text(formatBytes(a.size)).monospacedDigit() }.width(70)
                    TableColumn("") { a in
                        HStack(spacing: 6) {
                            Button { model.reveal(a.path) } label: { Image(systemName: "folder") }.buttonStyle(.borderless)
                            Button("Delete…") {
                                model.request(.cleanup(.deleteFolders([a.path]), title: "Delete \(a.projectName)'s \(a.kind.rawValue)?",
                                                       detail: "Rebuild it later with \(a.kind.rebuildHint).\n\n\(shortPath(a.path))", confirmLabel: "Delete"))
                            }
                            .controlSize(.small)
                        }
                    }
                    .width(100)
                }
                .frame(height: min(CGFloat(dev.artifacts.count) * 26 + 34, 360))
                if !idle.isEmpty {
                    HStack {
                        Spacer()
                        Button("Delete \(idle.count) in Idle Projects (\(ByteSize.format(idle.compactMap(\.size).reduce(0, +))))…") {
                            model.request(.cleanup(.deleteIdleArtifacts(idle.map(\.path), idleDays: 30), title: "Delete build folders of \(idle.count) idle projects?",
                                                   detail: "Projects nobody changed for 30+ days. Each is re-checked first.\n\n" + idle.prefix(12).map { "• \($0.projectName) · \($0.kind.rawValue)" }.joined(separator: "\n"),
                                                   confirmLabel: "Delete"))
                        }
                    }
                }
            }
        }
    }

    // MARK: Docker

    private func docker(_ docker: DockerStatus) -> some View {
        SectionCard(title: "Docker", subtitle: docker.state == .running ? "From `docker system df`." : nil) {
            switch docker.state {
            case .notInstalled:
                Text("Docker isn't installed. Nothing to clean here.").foregroundStyle(.secondary)
            case .notRunning:
                Text("Docker is installed but not running. Start Docker Desktop (or Colima/OrbStack) and scan again to see images, volumes and build cache.")
                    .foregroundStyle(.secondary)
            case .running:
                ForEach(docker.usage) { usage in
                    HStack {
                        Text(usage.type).font(.body.weight(.medium))
                        Text("\(usage.total) total · \(usage.active) in use").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(ByteSize.format(usage.size)).monospacedDigit()
                        Text("\(ByteSize.format(usage.reclaimable)) reclaimable").font(.caption).foregroundStyle(.secondary).frame(width: 140, alignment: .trailing)
                    }
                }
                Divider()
                HStack {
                    ForEach(DockerCleanup.allCases, id: \.self) { cleanup in
                        Button(cleanup.title + "…") {
                            model.request(.cleanup(.docker([cleanup]), title: "Remove \(cleanup.title.lowercased())?",
                                                   detail: "Runs: docker \(cleanup.arguments.joined(separator: " "))" + (cleanup == .unusedVolumes ? "\n\nData stored in those volumes (databases, uploads) is deleted for good." : ""),
                                                   confirmLabel: "Remove"))
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Git

    private func git(_ repos: [GitRepoHealth]) -> some View {
        SectionCard(title: "Git repositories", subtitle: "`git gc` packs loose objects; no history or branches are lost.") {
            ForEach(repos) { repo in
                HStack {
                    Text(repo.name).font(.body.weight(.medium)).help(repo.repoPath)
                    if repo.stats.needsMaintenance {
                        Chip(text: "\(repo.stats.looseObjects) loose objects · ≈\(ByteSize.format(repo.stats.reclaimableEstimate)) to pack", color: .orange)
                    }
                    Spacer()
                    Text(".git \(formatBytes(repo.gitDirBytes))").monospacedDigit().foregroundStyle(.secondary)
                    Button("Pack…") {
                        model.request(.cleanup(.gitGC([repo.repoPath]), title: "Run git gc in \(repo.name)?",
                                               detail: "Packs objects and drops garbage older than two weeks. Can take a minute for large repositories.", confirmLabel: "Run"))
                    }
                    .controlSize(.small)
                    .disabled(!repo.stats.needsMaintenance)
                }
            }
        }
    }
}
