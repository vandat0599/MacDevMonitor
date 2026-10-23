import Foundation
import Testing
@testable import MonitorCore

@Suite struct PermissionStatusTests {
    @Test func notificationAuthorizationStatuses() {
        // UNAuthorizationStatus raw values: notDetermined 0, denied 1, authorized 2, provisional 3, ephemeral 4.
        #expect(PermissionStatus.notification(rawValue: 0) == .notDetermined)
        #expect(PermissionStatus.notification(rawValue: 1) == .denied)
        #expect(PermissionStatus.notification(rawValue: 2) == .granted)
        #expect(PermissionStatus.notification(rawValue: 3) == .granted)
        #expect(PermissionStatus.notification(rawValue: 4) == .granted)
    }

    @Test func appleEventsPermissionCodes() {
        #expect(PermissionStatus.appleEvents(osStatus: 0) == .granted)
        #expect(PermissionStatus.appleEvents(osStatus: -1743) == .denied)
        #expect(PermissionStatus.appleEvents(osStatus: -1744) == .notDetermined)
        #expect(PermissionStatus.appleEvents(osStatus: -600) == .unknown)
    }

    @Test func loginItemStatuses() {
        // SMAppService.Status raw values: notRegistered 0, enabled 1, requiresApproval 2, notFound 3.
        #expect(PermissionStatus.loginItem(rawValue: 0) == .off)
        #expect(PermissionStatus.loginItem(rawValue: 1) == .granted)
        #expect(PermissionStatus.loginItem(rawValue: 2) == .needsApproval)
        #expect(PermissionStatus.loginItem(rawValue: 3) == .unavailable)
    }

    @Test func folderAccessFromReadErrors() {
        #expect(PermissionStatus.folderAccess(error: nil) == .granted)
        #expect(PermissionStatus.folderAccess(error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)) == .denied)
        #expect(PermissionStatus.folderAccess(error: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))) == .denied)
        #expect(PermissionStatus.folderAccess(error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)) == .unavailable)
    }

    @Test func protectedFoldersContainingRepoRoots() {
        let home = "/Users/me"
        #expect(ProtectedFolders.containing(["/Users/me/Documents/GitHub", "/Users/me/Desktop/x", "/Users/me/code"], home: home)
                == ["/Users/me/Desktop", "/Users/me/Documents"])
        #expect(ProtectedFolders.containing(["/Users/me/Documents"], home: home) == ["/Users/me/Documents"])
        #expect(ProtectedFolders.containing(["/Users/me/DocumentsArchive"], home: home).isEmpty)
    }
}
