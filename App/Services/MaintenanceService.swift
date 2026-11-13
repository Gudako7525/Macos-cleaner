//
//  MaintenanceService.swift
//  SystemCleaner
//
//  Executes system maintenance routines via the SMAppService XPC helper when active,
//  or via user-space / explicit macOS administrator authorization fallback.
//

import Foundation
import AppKit

public struct MaintenanceTaskInfo: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let icon: String
    public let requiresRoot: Bool
    public let adminCommand: String

    public static let allTasks: [MaintenanceTaskInfo] = [
        MaintenanceTaskInfo(
            id: MaintenanceRoutines.flushDNS,
            title: "Flush DNS Cache",
            description: "Clears mDNSResponder and directory service caches to fix stale DNS lookups.",
            icon: "network",
            requiresRoot: true,
            adminCommand: "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder"
        ),
        MaintenanceTaskInfo(
            id: MaintenanceRoutines.purgeRAM,
            title: "Purge Inactive Memory",
            description: "Drains disk cache and inactive memory pages back to the free pool.",
            icon: "memorychip",
            requiresRoot: true,
            adminCommand: "/usr/sbin/purge"
        ),
        MaintenanceTaskInfo(
            id: MaintenanceRoutines.rebuildLS,
            title: "Rebuild LaunchServices",
            description: "Resets duplicate 'Open With' entries and repairs file type associations.",
            icon: "arrow.triangle.2.circlepath",
            requiresRoot: false,
            adminCommand: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain user"
        ),
        MaintenanceTaskInfo(
            id: MaintenanceRoutines.reindexSpotlight,
            title: "Reindex Spotlight",
            description: "Rebuilds the Spotlight metadata index on the root APFS volume.",
            icon: "magnifyingglass.circle",
            requiresRoot: true,
            adminCommand: "/usr/bin/mdutil -E /"
        )
    ]
}

public enum MaintenanceService {

    public struct Outcome: Sendable {
        public let success: Bool
        public let message: String
    }

    public static func run(_ task: MaintenanceTaskInfo, allowAdminPromptFallback: Bool = true) async -> Outcome {
        let daemonEnabled = await MainActor.run { DaemonManager.shared.status == .enabled }

        if daemonEnabled {
            return await runViaXPC(routineID: task.id, title: task.title)
        }

        // User-domain LaunchServices rebuild runs directly without root
        if !task.requiresRoot {
            return await runUserSpaceLaunchServices()
        }

        guard allowAdminPromptFallback else {
            return Outcome(
                success: false,
                message: "Root Helper is not active. Enable the helper daemon or run with administrator authorization."
            )
        }

        return await runWithAdministratorPrompt(command: task.adminCommand, title: task.title)
    }

    private static func runViaXPC(routineID: String, title: String) async -> Outcome {
        await withCheckedContinuation { continuation in
            do {
                let proxy = try XPCConnectionManager.shared.getRemoteProxy()
                proxy.executeSystemMaintenance(routineIdentifier: routineID) { code, err in
                    if code == 0 {
                        continuation.resume(returning: Outcome(success: true, message: "\(title) completed via Root Helper."))
                    } else {
                        continuation.resume(returning: Outcome(success: false, message: err ?? "Failed with exit code \(code)."))
                    }
                }
            } catch {
                continuation.resume(returning: Outcome(success: false, message: "XPC error: \(error.localizedDescription)"))
            }
        }
    }

    private static func runUserSpaceLaunchServices() async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: lsregisterPath)
            process.arguments = ["-kill", "-r", "-domain", "local", "-domain", "user"]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return Outcome(success: true, message: "LaunchServices database rebuilt for current user.")
                }
                return Outcome(success: false, message: "lsregister exited with code \(process.terminationStatus).")
            } catch {
                return Outcome(success: false, message: error.localizedDescription)
            }
        }.value
    }

    @MainActor
    private static func runWithAdministratorPrompt(command: String, title: String) -> Outcome {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            return Outcome(success: false, message: "Unable to create authorization script.")
        }

        var errorDict: NSDictionary?
        script.executeAndReturnError(&errorDict)
        if let err = errorDict {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "Authorization cancelled or failed."
            return Outcome(success: false, message: msg)
        }
        return Outcome(success: true, message: "\(title) completed successfully.")
    }
}
