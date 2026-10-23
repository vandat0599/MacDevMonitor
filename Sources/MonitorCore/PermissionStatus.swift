import Foundation

public enum PermissionStatus: Sendable, Hashable {
    case granted
    case denied
    case notDetermined
    case needsApproval
    case off
    /// Not something the user can grant here (no app bundle, target not found, folder missing).
    case unavailable
    case unknown

    /// From `UNAuthorizationStatus.rawValue`; provisional and ephemeral both deliver notifications.
    public static func notification(rawValue: Int) -> PermissionStatus {
        switch rawValue {
        case 0: .notDetermined
        case 1: .denied
        case 2, 3, 4: .granted
        default: .unknown
        }
    }

    /// From `AEDeterminePermissionToAutomateTarget`.
    public static func appleEvents(osStatus: Int32) -> PermissionStatus {
        switch osStatus {
        case 0: .granted
        case -1743: .denied
        case -1744: .notDetermined
        default: .unknown
        }
    }

    /// From `SMAppService.Status.rawValue`.
    public static func loginItem(rawValue: Int) -> PermissionStatus {
        switch rawValue {
        case 0: .off
        case 1: .granted
        case 2: .needsApproval
        default: .unavailable
        }
    }

    /// From the error (if any) listing a TCC-protected folder.
    public static func folderAccess(error: Error?) -> PermissionStatus {
        guard let error = error as NSError? else { return .granted }
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError { return .unavailable }
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return .denied }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) || error.code == Int(EACCES) { return .denied }
        return .unknown
    }
}

/// Home folders macOS guards with a per-app "Files and Folders" permission.
public enum ProtectedFolders {
    public static let names = ["Desktop", "Documents", "Downloads"]

    /// The protected folders that contain (or are) any of the repo roots, sorted.
    public static func containing(_ roots: [String], home: String = NSHomeDirectory()) -> [String] {
        let protected = names.map { home + "/" + $0 }
        return protected.filter { folder in roots.contains { $0 == folder || $0.hasPrefix(folder + "/") } }.sorted()
    }
}
