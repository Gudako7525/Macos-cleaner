//
//  CleanActionService.swift
//  SystemCleaner
//
//  Handles safe Move-to-Trash, permanent deletion (with optional root XPC escalation), and Finder integration.
//

import Foundation
import AppKit
import ServiceManagement

public enum CleanActionService {

    /// Moves URLs safely to the user's Trash, or cleans stale temp items when given $TMPDIR.
    public static func moveToTrash(_ items: [(url: URL, knownSize: UInt64)]) async -> CleanResult {
        let userResult = await Task.detached(priority: .userInitiated) { () -> (removed: Int, freed: UInt64, failed: [(url: URL, knownSize: UInt64, reason: String)]) in
            let fm = FileManager.default
            let tmpDirStandardized = (NSTemporaryDirectory() as NSString).standardizingPath
            var removed = 0
            var freed: UInt64 = 0
            var failed: [(url: URL, knownSize: UInt64, reason: String)] = []

            for item in items {
                let standardized = (item.url.path as NSString).standardizingPath
                guard fm.fileExists(atPath: standardized) else { continue }

                // Special handling for the $TMPDIR container: remove stale child entries without deleting $TMPDIR itself
                if standardized == tmpDirStandardized {
                    let staleCutoff = Date().addingTimeInterval(-24 * 60 * 60)
                    if let children = try? fm.contentsOfDirectory(
                        at: item.url,
                        includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey],
                        options: [.skipsHiddenFiles]
                    ) {
                        for child in children {
                            let vals = try? child.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey])
                            if vals?.isSymbolicLink == true { continue }
                            if let mod = vals?.contentModificationDate, mod < staleCutoff {
                                let childSize = AsyncDiskScanner.computeRecursiveSize(at: child)
                                if (try? fm.removeItem(at: child)) != nil {
                                    freed += childSize
                                }
                            }
                        }
                        removed += 1
                    }
                    continue
                }

                let size = item.knownSize > 0 ? item.knownSize : AsyncDiskScanner.computeRecursiveSize(at: item.url)
                do {
                    var trashedURL: NSURL?
                    try fm.trashItem(at: item.url, resultingItemURL: &trashedURL)
                    removed += 1
                    freed += size
                } catch {
                    // Fallback to direct user-level removal for cache/log directories that don't support .Trash
                    if (try? fm.removeItem(at: item.url)) != nil {
                        removed += 1
                        freed += size
                    } else {
                        failed.append((item.url, size, error.localizedDescription))
                    }
                }
            }

            return (removed, freed, failed)
        }.value

        guard !userResult.failed.isEmpty else {
            return CleanResult(removedCount: userResult.removed, freedBytes: userResult.freed, failures: [])
        }

        // If any system-owned cache/log files failed to delete in user space, escalate via Privileged Helper if active
        let daemonStatus = await MainActor.run { DaemonManager.shared.status }
        if daemonStatus == .enabled {
            let failedPaths = userResult.failed.map(\.url.path)
            let xpcOutcome = await purgeViaHelper(paths: failedPaths)
            if xpcOutcome.exitCode == 0 {
                return CleanResult(
                    removedCount: userResult.removed + failedPaths.count,
                    freedBytes: userResult.freed + xpcOutcome.bytesPurged,
                    failures: []
                )
            }
        }

        let failures = userResult.failed.map { CleanFailure(url: $0.url, reason: $0.reason) }
        return CleanResult(removedCount: userResult.removed, freedBytes: userResult.freed, failures: failures)
    }

    /// Permanently deletes items (useful for Trash contents or items that cannot be moved to Trash).
    public static func permanentlyDelete(
        _ items: [(url: URL, knownSize: UInt64)],
        allowPrivilegedHelper: Bool = true
    ) async -> CleanResult {
        let userResult = await Task.detached(priority: .userInitiated) { () -> (removed: Int, freed: UInt64, failed: [(url: URL, knownSize: UInt64, reason: String)]) in
            let fm = FileManager.default
            var removed = 0
            var freed: UInt64 = 0
            var failed: [(url: URL, knownSize: UInt64, reason: String)] = []

            for item in items {
                guard fm.fileExists(atPath: item.url.path) else { continue }
                let size = item.knownSize > 0 ? item.knownSize : AsyncDiskScanner.computeRecursiveSize(at: item.url)
                do {
                    try fm.removeItem(at: item.url)
                    removed += 1
                    freed += size
                } catch {
                    failed.append((item.url, size, error.localizedDescription))
                }
            }
            return (removed, freed, failed)
        }.value

        guard allowPrivilegedHelper, !userResult.failed.isEmpty else {
            let failures = userResult.failed.map { CleanFailure(url: $0.url, reason: $0.reason) }
            return CleanResult(removedCount: userResult.removed, freedBytes: userResult.freed, failures: failures)
        }

        // Check if helper daemon is active; if so, escalate remaining failures over XPC
        let daemonStatus = await MainActor.run { DaemonManager.shared.status }
        guard daemonStatus == .enabled else {
            let failures = userResult.failed.map { CleanFailure(url: $0.url, reason: $0.reason) }
            return CleanResult(removedCount: userResult.removed, freedBytes: userResult.freed, failures: failures)
        }

        let failedPaths = userResult.failed.map(\.url.path)
        let xpcOutcome = await purgeViaHelper(paths: failedPaths)

        if xpcOutcome.exitCode == 0 {
            return CleanResult(
                removedCount: userResult.removed + failedPaths.count,
                freedBytes: userResult.freed + xpcOutcome.bytesPurged,
                failures: []
            )
        } else {
            let failures = userResult.failed.map {
                CleanFailure(url: $0.url, reason: "\($0.reason) (Helper exit \(xpcOutcome.exitCode))")
            }
            return CleanResult(removedCount: userResult.removed, freedBytes: userResult.freed, failures: failures)
        }
    }

    private static func purgeViaHelper(paths: [String]) async -> (exitCode: Int32, bytesPurged: UInt64) {
        await withCheckedContinuation { continuation in
            do {
                let proxy = try XPCConnectionManager.shared.getRemoteProxy()
                proxy.performPrivilegedPurge(at: paths) { code, bytes in
                    continuation.resume(returning: (code, bytes))
                }
            } catch {
                continuation.resume(returning: (-1, 0))
            }
        }
    }

    @MainActor
    public static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor
    public static func openFolderPicker(canChooseMultiple: Bool = false) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = canChooseMultiple
        panel.prompt = "Select Folder"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}
