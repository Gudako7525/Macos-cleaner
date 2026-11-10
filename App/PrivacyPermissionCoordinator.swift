//
//  PrivacyPermissionCoordinator.swift
//  SystemCleaner
//
//  Full Disk Access (FDA) verification and macOS System Settings deep-linking.
//

import Foundation
import AppKit

public enum TCCAccessStatus {
    case granted
    case denied
}

public struct PrivacyPermissionCoordinator {
    
    /// Tests reading a protected TCC file path to determine if Full Disk Access is granted
    public static func verifyFullDiskAccess() -> TCCAccessStatus {
        let testPath = ("~/Library/Safari/CloudTabs.db" as NSString).expandingTildeInPath
        let fileManager = FileManager.default
        
        if fileManager.isReadableFile(atPath: testPath) {
            return .granted
        }
        
        let alternativeTest = ("~/Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist" as NSString).expandingTildeInPath
        if fileManager.isReadableFile(atPath: alternativeTest) {
            return .granted
        }

        return .denied
    }

    /// Deep link to macOS System Settings -> Privacy & Security -> Full Disk Access
    public static func openSystemSettingsFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
