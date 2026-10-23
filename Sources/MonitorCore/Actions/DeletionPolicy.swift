import Foundation

/// The only folders the app will ever delete: build data and caches that tools recreate on demand.
public struct DeletionPolicy: Sendable {
    public var home: String
    public var claudeTemp: String

    public init(home: String = NSHomeDirectory(), claudeTemp: String = DerivedDataReader.claudeTempRoot) {
        self.home = home
        self.claudeTemp = claudeTemp
    }

    public func isAllowed(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return false }
        // standardizingPath turns an existing /private/tmp/x into /tmp/x, so compare both sides in that form.
        let standardized = Self.tmpForm((path as NSString).standardizingPath)
        let claudeTemp = Self.tmpForm(claudeTemp)
        let derivedDataRoot = home + "/Library/Developer/Xcode/DerivedData"
        let deviceSupportRoot = home + "/Library/Developer/Xcode/iOS DeviceSupport"

        if DevCacheCatalog.allPaths(home: home).contains(standardized) { return true }
        if VersionedFolders.parents(home: home).contains(where: { isDirectChild(standardized, of: $0) }),
           VersionedFolders.isVersioned((standardized as NSString).lastPathComponent) { return true }
        if isDirectChild(standardized, of: home + "/Library/Logs/DiagnosticReports") { return true }
        if standardized.hasPrefix(home + "/"), !standardized.hasPrefix(home + "/Library/"),
           ProjectArtifactKind.kind(ofFolderAt: standardized) != nil { return true }
        if isDirectChild(standardized, of: derivedDataRoot) { return true }
        if isDirectChild(standardized, of: deviceSupportRoot) { return true }
        if standardized.hasPrefix(claudeTemp + "/") { return true }
        if (standardized as NSString).lastPathComponent == "DerivedData",
           standardized.hasPrefix(home + "/"),
           standardized != derivedDataRoot,
           !standardized.hasPrefix(home + "/Library/") {
            return true
        }
        return false
    }

    static func tmpForm(_ path: String) -> String {
        if path == "/private/tmp" { return "/tmp" }
        if path.hasPrefix("/private/tmp/") { return String(path.dropFirst("/private".count)) }
        return path
    }

    private func isDirectChild(_ path: String, of parent: String) -> Bool {
        (path as NSString).deletingLastPathComponent == parent && path != parent
    }
}
