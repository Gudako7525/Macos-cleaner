//
//  CleanerDaemonImplementation.swift
//  com.cleaner.helper
//
//  Implements the privileged CleanerDaemonProtocol with path safety checks.
//

import Foundation
import os.log

public final class CleanerDaemonImplementation: NSObject, CleanerDaemonProtocol {
    private let logger = Logger(subsystem: "com.cleaner.helper", category: "DaemonImpl")
    private var progressDelegate: CleanerClientProgressProtocol?

    private static let protectedPrefixes: [String] = [
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/Library/Apple",
        "/private/var/db/SystemPolicy"
    ]

    public func clearProgressDelegate() {
        progressDelegate = nil
    }

    public func registerProgressDelegate(_ delegate: CleanerClientProgressProtocol) {
        self.progressDelegate = delegate
        logger.info("Progress delegate registered with daemon.")
    }

    public func performPrivilegedPurge(at paths: [String], reply: @escaping (Int32, UInt64) -> Void) {
        let fileManager = FileManager.default
        var bytesPurged: UInt64 = 0
        var exitCode: Int32 = 0

        for rawPath in paths {
            let standardizedPath = (rawPath as NSString).standardizingPath
            guard isAllowedPurgePath(standardizedPath) else {
                logger.error("Blocked attempt to purge protected path: \(standardizedPath, privacy: .public)")
                progressDelegate?.didEncounterError(
                    path: standardizedPath,
                    errorCode: EPERM,
                    errorMessage: "Refused to delete protected system path."
                )
                exitCode = EPERM
                continue
            }

            do {
                let itemSize = computeSize(atPath: standardizedPath, fileManager: fileManager)
                try fileManager.removeItem(atPath: standardizedPath)
                bytesPurged += itemSize
                progressDelegate?.didUpdateProgress(bytesProcessed: bytesPurged, currentPath: standardizedPath)
            } catch {
                logger.error("Failed to remove \(standardizedPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                progressDelegate?.didEncounterError(
                    path: standardizedPath,
                    errorCode: -1,
                    errorMessage: error.localizedDescription
                )
                exitCode = -1
            }
        }

        reply(exitCode, bytesPurged)
    }

    public func executeSystemMaintenance(routineIdentifier: String, reply: @escaping (Int32, String?) -> Void) {
        logger.info("Executing maintenance routine: \(routineIdentifier, privacy: .public)")
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

    private func isAllowedPurgePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/", !path.contains("..") else {
            return false
        }
        let components = (path as NSString).pathComponents
        guard components.count >= 3 else {
            return false
        }
        for prefix in Self.protectedPrefixes {
            if path == prefix || path.hasPrefix(prefix + "/") {
                return false
            }
        }
        return true
    }

    private func computeSize(atPath path: String, fileManager: FileManager) -> UInt64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return 0
        }
        if !isDirectory.boolValue {
            if let attrs = try? fileManager.attributesOfItem(atPath: path),
               let size = attrs[.size] as? UInt64 {
                return size
            }
            return 0
        }

        var total: UInt64 = 0
        let rootURL = URL(fileURLWithPath: path)
        if let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) {
            for case let fileURL as URL in enumerator {
                if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                   values.isRegularFile == true,
                   let size = values.fileSize {
                    total += UInt64(max(0, size))
                }
            }
        }
        return total
    }
}
