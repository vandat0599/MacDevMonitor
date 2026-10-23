import Foundation
import Testing
@testable import MonitorCore

@Suite struct DeletionPolicyTests {
    let policy = DeletionPolicy(home: "/Users/me", claudeTemp: "/private/tmp/claude-501")

    @Test func allowsBuildDataAndCaches() {
        #expect(policy.isAllowed("/Users/me/Library/Developer/Xcode/DerivedData/App-abc"))
        #expect(policy.isAllowed("/Users/me/Library/Developer/Xcode/DerivedData/ModuleCache.noindex"))
        #expect(policy.isAllowed("/Users/me/Documents/GitHub/app/.claude/worktrees/x/Spotlight-Core/DerivedData"))
        #expect(policy.isAllowed("/private/tmp/claude-501/dd-sim-app"))
        #expect(policy.isAllowed("/Users/me/Library/Developer/Xcode/iOS DeviceSupport/iPhone17,1 26.4"))
    }

    @Test func refusesEverythingElse() {
        #expect(!policy.isAllowed("/"))
        #expect(!policy.isAllowed("/Users/me"))
        #expect(!policy.isAllowed("/Users/me/Library/Developer/Xcode/DerivedData"))
        #expect(!policy.isAllowed("/private/tmp/claude-501"))
        #expect(!policy.isAllowed("/Users/me/Documents/GitHub/app"))
        #expect(!policy.isAllowed("/Users/me/Library/Developer/Xcode/Archives/2026-10-01"))
        #expect(!policy.isAllowed("/Users/me/Library/Developer/Xcode/DerivedData/../../../Documents"))
        #expect(!policy.isAllowed("/Users/me/Documents/DerivedDataBackup"))
        #expect(!policy.isAllowed("relative/DerivedData"))
    }
}
