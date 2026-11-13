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

    /// Reclaims clean inactive/file-backed pages in user space without root or password prompts.
    public static func reclaimUserSpaceMemory() async {
        await Task.detached(priority: .userInitiated) {
            malloc_zone_pressure_relief(nil, 0)

            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
            var vmStats = vm_statistics64()
            let kerr = withUnsafeMutablePointer(to: &vmStats) { pt in
                pt.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPt in
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, intPt, &count)
                }
            }
            guard kerr == KERN_SUCCESS else { return }

            let pageSize = Int(vm_kernel_page_size)
            let freeBytes = Int(vmStats.free_count) * pageSize
            let inactiveBytes = Int(vmStats.inactive_count) * pageSize

            // Target enough transient allocation to nudge the kernel pageout scanner to evict clean file cache
            let targetBytes = freeBytes + Int(Double(inactiveBytes) * 0.65)
            let chunkSize = 32 * 1024 * 1024
            let numChunks = max(4, min(40, targetBytes / chunkSize))
            var chunks: [UnsafeMutableRawPointer] = []
            chunks.reserveCapacity(numChunks)

            let wordsPerPageStep = max(1, pageSize / MemoryLayout<UInt64>.stride)
            let totalWords = chunkSize / MemoryLayout<UInt64>.stride

            for chunkIndex in 0..<numChunks {
                guard let ptr = mmap(nil, chunkSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0),
                      ptr != MAP_FAILED else {
                    break
                }
                let wordPtr = ptr.assumingMemoryBound(to: UInt64.self)
                var seed = UInt64(chunkIndex &+ 1) &* 0x9E3779B97F4A7C15
                var idx = 0
                while idx < totalWords {
                    for j in 0..<min(8, wordsPerPageStep) {
                        seed ^= seed >> 12
                        seed ^= seed << 25
                        seed ^= seed >> 27
                        wordPtr[idx + j] = seed &* 0x2545F4914F6CDD1D
                    }
                    idx += wordsPerPageStep
                }
                chunks.append(ptr)
            }

            for ptr in chunks {
                munmap(ptr, chunkSize)
            }
            chunks.removeAll()
            malloc_zone_pressure_relief(nil, 0)
        }.value
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
