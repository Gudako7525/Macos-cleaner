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

    /// Moves URLs safely to the user's Trash. Returns detailed CleanResult.
    public static func moveToTrash(_ items: [(url: URL, knownSize: UInt64)]) async -> CleanResult {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var removed = 0
            var freed: UInt64 = 0
            var failures: [CleanFailure] = []

            for item in items {
                do {
                    guard fm.fileExists(atPath: item.url.path) else { continue }
                    let size = item.knownSize > 0 ? item.knownSize : AsyncDiskScanner.computeRecursiveSize(at: item.url)
                    var trashedURL: NSURL?
                    try fm.trashItem(at: item.url, resultingItemURL: &trashedURL)
                    removed += 1
                    freed += size
                } catch {
                    failures.append(CleanFailure(url: item.url, reason: error.localizedDescription))
                }
            }

            return CleanResult(removedCount: removed, freedBytes: freed, failures: failures)
        }.value
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
