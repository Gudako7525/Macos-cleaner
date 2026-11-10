//
//  CleanerDaemonImplementation.swift
//  com.cleaner.helper
//
//  Implements the privileged CleanerDaemonProtocol.
//

import Foundation
import os.log

public final class CleanerDaemonImplementation: NSObject, CleanerDaemonProtocol {
    private let logger = Logger(subsystem: "com.cleaner.helper", category: "DaemonImpl")
    private weak var progressDelegate: CleanerClientProgressProtocol?

    public func registerProgressDelegate(_ delegate: CleanerClientProgressProtocol) {
        self.progressDelegate = delegate
        logger.info("Progress delegate registered with daemon.")
    }

    public func performPrivilegedPurge(at paths: [String], reply: @escaping (Int32, UInt64) -> Void) {
        let fileManager = FileManager.default
        var bytesPurged: UInt64 = 0
        var exitCode: Int32 = 0

        for path in paths {
            do {
                if let attrs = try? fileManager.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? UInt64 {
                    bytesPurged += size
                }
                try fileManager.removeItem(atPath: path)
                progressDelegate?.didUpdateProgress(bytesProcessed: bytesPurged, currentPath: path)
            } catch {
                logger.error("Failed to remove \(path): \(error.localizedDescription)")
                progressDelegate?.didEncounterError(path: path, errorCode: -1, errorMessage: error.localizedDescription)
                exitCode = -1
            }
        }

        reply(exitCode, bytesPurged)
    }

    public func executeSystemMaintenance(routineIdentifier: String, reply: @escaping (Int32, String?) -> Void) {
        logger.info("Executing maintenance routine: \(routineIdentifier)")
        var status: Int32 = 0

        switch routineIdentifier {
        case MaintenanceRoutines.flushDNS:
            status = DarwinMaintenanceBridge.flushDNSCache()
        case MaintenanceRoutines.purgeRAM:
            status = DarwinMaintenanceBridge.purgeInactiveRAM()
        case MaintenanceRoutines.rebuildLS:
            status = DarwinMaintenanceBridge.rebuildLaunchServices()
        case MaintenanceRoutines.reindexSpotlight:
            status = DarwinMaintenanceBridge.triggerSpotlightReindex()
        default:
            reply(-1, "Unknown maintenance routine identifier: \(routineIdentifier)")
            return
        }

        reply(status, status == 0 ? nil : "Execution failed with exit code \(status)")
    }
}
