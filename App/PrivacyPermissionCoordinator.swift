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

    /// Tests reading protected TCC directories and files to determine if Full Disk Access is granted.
    public static func verifyFullDiskAccess() -> TCCAccessStatus {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path

        // Probe TCC-protected directories via contentsOfDirectory / open(O_RDONLY)
        let protectedDirectories = [
            (home as NSString).appendingPathComponent("Library/Safari"),
            (home as NSString).appendingPathComponent("Library/Mail"),
            (home as NSString).appendingPathComponent("Library/Messages"),
            (home as NSString).appendingPathComponent("Library/Cookies"),
            "/Library/Application Support/com.apple.TCC"
        ]

        var testedAtLeastOne = false
        for dirPath in protectedDirectories where fileManager.fileExists(atPath: dirPath) {
            testedAtLeastOne = true
            if (try? fileManager.contentsOfDirectory(atPath: dirPath)) != nil {
                return .granted
            }
        }

        // Probe TCC-protected files via low-level POSIX open()
        let protectedFiles = [
            (home as NSString).appendingPathComponent("Library/Safari/Bookmarks.plist"),
            (home as NSString).appendingPathComponent("Library/Safari/CloudTabs.db"),
            (home as NSString).appendingPathComponent("Library/Messages/chat.db"),
            "/Library/Preferences/com.apple.TimeMachine.plist",
            "/Library/Application Support/com.apple.TCC/TCC.db"
        ]

        for filePath in protectedFiles where fileManager.fileExists(atPath: filePath) {
            testedAtLeastOne = true
            let fd = open(filePath, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return .granted
            }
        }

        return testedAtLeastOne ? .denied : .granted
    }

    /// Returns true if the app is currently running from Xcode DerivedData rather than /Applications
    public static var isRunningFromDerivedData: Bool {
        Bundle.main.bundleURL.path.contains("/DerivedData/")
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
