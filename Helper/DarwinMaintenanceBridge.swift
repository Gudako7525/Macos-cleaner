//
//  DarwinMaintenanceBridge.swift
//  com.cleaner.helper
//
//  Executes low-level Darwin maintenance operations using native POSIX and system binaries.
//

import Foundation
import Darwin

public final class DarwinMaintenanceBridge {
    
    /// Flushes mDNSResponder cache and re-registers the networking state
    public static func flushDNSCache() -> Int32 {
        var pid: pid_t = 0
        let dscacheArgs: [String] = ["/usr/bin/dscacheutil", "-flushcache"]
        let argv: [UnsafeMutablePointer<CChar>?] = dscacheArgs.map { strdup($0) } + [nil]
        defer { for ptr in argv where ptr != nil { free(ptr) } }
        
        let spawnStatus = posix_spawn(&pid, argv[0], nil, nil, argv, environ)
        if spawnStatus == 0 {
            var exitStatus: Int32 = 0
            waitpid(pid, &exitStatus, 0)
        }

        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killProcess.arguments = ["-HUP", "mDNSResponder"]
        try? killProcess.run()
        killProcess.waitUntilExit()
        
        return killProcess.terminationStatus
    }

    /// Invokes the kernel inactive page allocator drain
    public static func purgeInactiveRAM() -> Int32 {
        var pid: pid_t = 0
        let args: [String] = ["/usr/sbin/purge"]
        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { for ptr in argv where ptr != nil { free(ptr) } }
        
        let status = posix_spawn(&pid, argv[0], nil, nil, argv, environ)
        guard status == 0 else { return status }
        
        var exitCode: Int32 = 0
        waitpid(pid, &exitCode, 0)
        return exitCode
    }

    /// Rebuilds LaunchServices database to eliminate broken file associations and duplicate context entries
    public static func rebuildLaunchServices() -> Int32 {
        let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregisterPath)
        process.arguments = ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"]
        
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    /// Forces Spotlight re-indexing on root APFS volume
    public static func triggerSpotlightReindex() -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        process.arguments = ["-E", "/"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
