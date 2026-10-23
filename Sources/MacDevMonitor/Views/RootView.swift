import MonitorCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(DashboardSection.allCases, selection: Binding<DashboardSection?>(
                get: { model.selectedSection },
                set: { model.selectedSection = $0 ?? .overview })) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .badge(model.issueCount(for: section))
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            SectionContent(section: model.selectedSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { ActionBanner() }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refreshFull(forceSizes: true) }
                } label: {
                    Label("Scan Now", systemImage: "arrow.clockwise")
                }
                .disabled(model.isFullScanning)
                .help("Rescan everything now")
            }
        }
        .alert(model.confirmation?.title ?? "", isPresented: Binding(
            get: { model.confirmation != nil },
            set: { if !$0 { model.confirmation = nil } }
        ), presenting: model.confirmation) { confirmation in
            Button(confirmation.confirmLabel, role: confirmation.destructive ? .destructive : nil) { model.confirm(confirmation.id) }
            Button("Cancel", role: .cancel) { model.confirmation = nil }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }
}

struct SectionContent: View {
    var section: DashboardSection

    var body: some View {
        switch section {
        case .overview: OverviewView()
        case .deepClean: DeepCleanView()
        case .memory: MemoryView()
        case .processes: ProcessesView()
        case .devTools: DevToolsView()
        case .applications: ApplicationsView()
        case .worktrees: WorktreesView()
        case .buildData: BuildDataView()
        case .simulators: SimulatorsView()
        case .storage: StorageView()
        case .systemStorage: SystemStorageView()
        case .activity: ActivityView()
        }
    }
}

/// Shows the action in progress, then its result for a few seconds.
struct ActionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let running = model.runningAction {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(running + "…")
                }
                .bannerStyle()
            } else if let entry = model.banner {
                HStack(spacing: 8) {
                    Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(entry.succeeded ? .green : .orange)
                    VStack(alignment: .leading) {
                        Text(entry.summary + (entry.freedBytes.map { $0 > 0 ? " · freed \(ByteSize.format($0))" : "" } ?? ""))
                            .font(.body.weight(.medium))
                        if let first = entry.details.first { Text(first).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .bannerStyle()
                .onTapGesture { model.banner = nil }
            }
        }
        .animation(.snappy, value: model.runningAction)
        .animation(.snappy, value: model.banner)
    }
}

private extension View {
    func bannerStyle() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 6, y: 2)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
