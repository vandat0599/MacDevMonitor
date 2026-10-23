import MonitorCore
import SwiftUI

extension PermissionStatus {
    var label: String {
        switch self {
        case .granted: "Granted"
        case .denied: "Not allowed"
        case .notDetermined: "Not asked yet"
        case .needsApproval: "Needs approval"
        case .off: "Off"
        case .unavailable: "Not available"
        case .unknown: "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .granted: .green
        case .denied: .red
        case .notDetermined, .needsApproval: .orange
        case .off, .unavailable, .unknown: .secondary
        }
    }
}

/// Every permission the app relies on, why, and a button to grant it.
struct PermissionsCard: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Bool?

    init(startExpanded: Bool? = nil) {
        _expanded = State(initialValue: startExpanded)
    }

    var body: some View {
        let permissions = model.permissions
        let isExpanded = Binding(get: { expanded ?? permissions.missingRequired }, set: { expanded = $0 })
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: permissions.missingRequired ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                        .font(.title2)
                        .foregroundStyle(permissions.missingRequired ? .orange : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Permissions").font(.headline)
                        Text(summary).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                ForEach(permissions.items) { item in
                    Divider()
                    PermissionRow(item: item)
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .task { await permissions.refresh(repoRoots: model.settings.repoRoots) }
    }

    private var summary: String {
        let permissions = model.permissions
        if permissions.items.isEmpty { return "Checking…" }
        let base = "\(permissions.grantedCount) of \(permissions.actionableCount) granted"
        return permissions.missingRequired ? base + " · a required one is missing, so some scans are incomplete" : base + " · everything required is in place"
    }
}

private struct PermissionRow: View {
    @Environment(AppModel.self) private var model
    var item: PermissionItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.symbol).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title).font(.body.weight(.medium))
                    if item.kind != .adminPassword {
                        Chip(text: item.required ? "Required" : "Optional", color: item.required ? .purple : .secondary)
                    }
                }
                Text(item.why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = model.permissions.errors[item.kind] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 12)
            if item.kind == .adminPassword {
                Chip(text: "Asked each time", color: .blue)
            } else {
                Chip(text: item.status.label, color: item.status.color)
            }
            if let action = model.permissions.actionLabel(for: item) {
                Button(action) {
                    Task { await model.permissions.request(item.kind, repoRoots: model.settings.repoRoots) }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}
