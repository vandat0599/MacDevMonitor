import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        TabView {
            Form {
                Section("Repositories") {
                    ForEach(settings.repoRoots, id: \.self) { root in
                        HStack {
                            Text(shortPath(root))
                            Spacer()
                            Button(role: .destructive) {
                                settings.repoRoots.removeAll { $0 == root }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Folder…") { addRoot(settings) }
                    Text("Worktrees and in-repo build folders are found up to a few levels below these folders.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Refresh") {
                    Stepper("Memory every \(Int(settings.refreshSeconds)) s", value: $settings.refreshSeconds, in: 2...60, step: 1)
                    Stepper("Full scan every \(Int(settings.fullScanMinutes)) min", value: $settings.fullScanMinutes, in: 5...240, step: 5)
                }
                Section("Behaviour") {
                    Toggle("Notify me about warnings", isOn: $settings.notificationsEnabled)
                    Toggle("Move deleted folders to the Trash instead of deleting them", isOn: $settings.moveToTrash)
                    Text("Open at login, notifications and other permissions are in the Permissions tab.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Warn when") {
                    Stepper("fseventsd is over \(settings.fseventsdWarnGB, specifier: "%.0f") GB (critical at \(settings.fseventsdCriticalGB, specifier: "%.0f") GB)",
                            value: $settings.fseventsdWarnGB, in: 1...16)
                    Stepper("fseventsd is critical over \(settings.fseventsdCriticalGB, specifier: "%.0f") GB",
                            value: $settings.fseventsdCriticalGB, in: 2...64)
                    Stepper("Any process uses over \(settings.largeProcessGB, specifier: "%.0f") GB", value: $settings.largeProcessGB, in: 2...64)
                    Stepper("Disk has under \(settings.diskWarnGB, specifier: "%.0f") GB free", value: $settings.diskWarnGB, in: 10...500, step: 10)
                    Stepper("A dev leftover runs over \(settings.stuckHours, specifier: "%.0f") h", value: $settings.stuckHours, in: 1...168)
                    Stepper("The Mac has been up \(settings.uptimeWarnDays, specifier: "%.0f") days", value: $settings.uptimeWarnDays, in: 3...60)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Thresholds", systemImage: "slider.horizontal.3") }

            ScrollView { PermissionsCard().padding(16) }
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 620, height: 520)
        .onChange(of: settings.repoRoots) { Task { await model.refreshFull() } }
    }

    private func addRoot(_ settings: AppSettings) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, !settings.repoRoots.contains(url.path) {
            settings.repoRoots.append(url.path)
        }
    }
}
