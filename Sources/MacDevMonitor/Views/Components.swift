import MonitorCore
import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case deepClean = "Deep Clean"
    case memory = "Memory"
    case storage = "Storage"
    case devTools = "Dev Tools"
    case applications = "Applications"
    case activity = "Activity"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .deepClean: "sparkles"
        case .memory: "memorychip"
        case .devTools: "wrench.and.screwdriver"
        case .applications: "square.grid.2x2"
        case .storage: "internaldrive"
        case .activity: "clock.arrow.circlepath"
        }
    }

    /// Issue id prefixes shown as this section's badge.
    var issueIDs: [String] {
        switch self {
        case .overview, .deepClean, .activity, .applications: []
        case .memory: ["fseventsd", "free-memory", "swap", "uptime", "large-", "stuck", "zombies"]
        case .devTools: DevToolsTab.allCases.flatMap(\.issueIDs)
        case .storage: ["disk"]
        }
    }

    /// Where a page named in core code ("Simulators", "Build Data", …) now lives.
    static func destination(forPage page: String) -> (DashboardSection, DevToolsTab?)? {
        if let tab = DevToolsTab.allCases.first(where: { $0.rawValue == page }) { return (.devTools, tab) }
        if let section = allCases.first(where: { $0.rawValue == page }) { return (section, nil) }
        return nil
    }
}

/// The tabs inside Dev Tools.
enum DevToolsTab: String, CaseIterable, Identifiable, Hashable {
    case tools = "Tools & Caches"
    case buildData = "Build Data"
    case simulators = "Simulators"
    case worktrees = "Worktrees"

    var id: String { rawValue }

    var issueIDs: [String] {
        switch self {
        case .tools: []
        case .buildData: ["derived-data"]
        case .simulators: ["simulators"]
        case .worktrees: ["worktrees"]
        }
    }
}

extension Severity {
    var color: Color {
        switch self {
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }
}

enum Health {
    case good, warning, critical

    var color: Color {
        switch self {
        case .good: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

struct MetricCard: View {
    var title: String
    var value: String
    var caption: String
    var symbol: String
    var health: Health
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(health == .good ? Color.primary : health.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let progress { MeterBar(value: progress, color: health.color) }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            Circle().fill(health.color).frame(width: 8, height: 8).padding(12)
        }
    }
}

/// A thin filled bar; ProgressView ignores tint on macOS.
struct MeterBar: View {
    var value: Double
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 6)
    }
}

struct IssueCard: View {
    var issue: HealthIssue

    var body: some View {
        IssueRow(issue: issue)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(issue.severity.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(issue.severity.color.opacity(0.25)))
    }
}

struct IssueRow: View {
    @Environment(AppModel.self) private var model
    var issue: HealthIssue
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: issue.severity.symbol)
                .foregroundStyle(issue.severity.color)
                .font(compact ? .body : .title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title).font(compact ? .callout.weight(.medium) : .body.weight(.medium))
                if !compact {
                    Text(issue.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let fix = issue.fix {
                Button(issue.fixLabel ?? "Fix") { model.request(.fix(fix)) }
                    .controlSize(compact ? .small : .regular)
                    .disabled(model.runningAction != nil)
            }
        }
        .padding(.vertical, compact ? 2 : 6)
    }
}

struct SectionCard<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct Chip: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.green)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// Header shared by each section: title, one-line explanation, and the scan state.
struct PageHeader: View {
    @Environment(AppModel.self) private var model
    var title: String
    var subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isFullScanning {
                ProgressView().controlSize(.small)
                Text("Scanning…").font(.callout).foregroundStyle(.secondary)
            } else if let last = model.lastFullScan {
                Text("Scanned \(last.formatted(.relative(presentation: .named)))")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

func formatBytes(_ bytes: Int64?) -> String {
    bytes.map(ByteSize.format) ?? "—"
}

func shortPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}
