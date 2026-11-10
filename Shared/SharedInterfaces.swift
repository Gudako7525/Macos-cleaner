//
//  SharedInterfaces.swift
//  SystemCleaner
//
//  Shared contract for NSXPCConnection between Main App and Helper Daemon.
//

import Foundation

/// Progress updates streamed back from the privileged helper daemon to the UI client
@objc(CleanerClientProgressProtocol)
public protocol CleanerClientProgressProtocol: AnyObject {
    func didUpdateProgress(bytesProcessed: UInt64, currentPath: String)
    func didEncounterError(path: String, errorCode: Int32, errorMessage: String)
}

/// Operations exposed by the privileged daemon over the secure XPC boundary
@objc(CleanerDaemonProtocol)
public protocol CleanerDaemonProtocol: AnyObject {
    /// Privileged file-system purge (runs with root permissions)
    func performPrivilegedPurge(
        at paths: [String],
        reply: @escaping (Int32, UInt64) -> Void
    )
    
    /// Triggers Darwin-level system maintenance routines
    func executeSystemMaintenance(
        routineIdentifier: String,
        reply: @escaping (Int32, String?) -> Void
    )
    
    /// Establishes the progress callback delegate
    func registerProgressDelegate(
        _ delegate: CleanerClientProgressProtocol
    )
}

public enum MaintenanceRoutines {
    public static let flushDNS = "flushDNS"
    public static let purgeRAM = "purgeRAM"
    public static let rebuildLS = "rebuildLaunchServices"
    public static let reindexSpotlight = "reindexSpotlight"
}
