//
//  DarwinMaintenanceBridge.swift
//  com.cleaner.helper
//
//  Executes low-level Darwin maintenance operations using native system binaries.
//

import Foundation

public final class DarwinMaintenanceBridge {

    /// Flushes mDNSResponder cache and re-registers the networking state
    public static func flushDNSCache() -> Int32 {
        _ = runTool(path: "/usr/bin/dscacheutil", arguments: ["-flushcache"])
        return runTool(path: "/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"])
    }

    /// Invokes the kernel inactive page allocator drain
    public static func purgeInactiveRAM() -> Int32 {
        return runTool(path: "/usr/sbin/purge", arguments: [])
    }

    /// Rebuilds LaunchServices database to eliminate broken file associations and duplicate context entries
    public static func rebuildLaunchServices() -> Int32 {
        let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        return runTool(
            path: lsregisterPath,
            arguments: ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"]
        )
    }

    /// Forces Spotlight re-indexing on root APFS volume
    public static func triggerSpotlightReindex() -> Int32 {
        return runTool(path: "/usr/bin/mdutil", arguments: ["-E", "/"])
    }

    private static func runTool(path: String, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
