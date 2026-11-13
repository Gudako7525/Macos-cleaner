//
//  PrivacyPermissionCoordinator.swift
//  SystemCleaner
//
//  Full Disk Access (FDA) verification and macOS System Settings deep-linking.
//

import Foundation
import AppKit

public enum TCCAccessStatus: Sendable {
    case granted
    case denied
}

public struct PrivacyPermissionCoordinator {

    /// Tests reading protected TCC paths to determine if Full Disk Access is granted
    public static func verifyFullDiskAccess() -> TCCAccessStatus {
        let fileManager = FileManager.default
        let candidatePaths = [
            ("~/Library/Safari/Bookmarks.plist" as NSString).expandingTildeInPath,
            ("~/Library/Safari/CloudTabs.db" as NSString).expandingTildeInPath,
            ("~/Library/Messages/chat.db" as NSString).expandingTildeInPath,
            ("/Library/Preferences/com.apple.TimeMachine.plist")
        ]

        for path in candidatePaths where fileManager.fileExists(atPath: path) {
            if fileManager.isReadableFile(atPath: path) {
                return .granted
            } else {
                return .denied
            }
        }

        // Fallback directory read probe in ~/Library/Mail
        let mailPath = ("~/Library/Mail" as NSString).expandingTildeInPath
        if fileManager.fileExists(atPath: mailPath) {
            if (try? fileManager.contentsOfDirectory(atPath: mailPath)) != nil {
                return .granted
            }
            return .denied
        }

        return .denied
    }

    /// Deep link to macOS System Settings -> Privacy & Security -> Full Disk Access
    public static func openSystemSettingsFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Deep link to macOS System Settings -> General -> Login Items & Extensions
    public static func openSystemSettingsLoginItems() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
