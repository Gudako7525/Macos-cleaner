//
//  AsyncDiskScanner.swift
//  SystemCleaner
//
//  High-performance directory traversal engine using POSIX fts(3) and Swift Concurrency.
//

import Foundation
import Darwin
import os.log

public struct ScannedItem: Identifiable, Sendable {
    public let id = UUID()
    public let url: URL
    public let byteSize: UInt64
    public let isDirectory: Bool
}

public struct ScanSummary: Sendable {
    public var totalScannedBytes: UInt64 = 0
    public var totalFileCount: UInt64 = 0
    public var items: [ScannedItem] = []
}

public actor AsyncDiskScanner {
    private let logger = Logger(subsystem: "com.cleaner.app", category: "ScannerEngine")

    private static let excludedUserCacheNames: Set<String> = [
        "com.apple.bird",
        "com.apple.CloudKit",
        "com.apple.HomeKit",
        "com.apple.iCloudHelper",
        "CloudKit",
        "com.apple.nsurlsessiond"
    ]

    public init() {}

    /// Performs asynchronous directory traversal using an AsyncStream for real-time progress streaming
    public func scanDirectory(at rootURL: URL) -> AsyncStream<ScannedItem> {
        AsyncStream { continuation in
            let scanTask = Task.detached(priority: .userInitiated) {
                let path = rootURL.path
                guard let cPath = strdup(path) else {
                    continuation.finish()
                    return
                }
                defer { free(cPath) }

                let paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
                paths.withUnsafeBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress,
                          let fts = fts_open(baseAddress, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
                        return
                    }
                    defer { fts_close(fts) }

                    while let node = fts_read(fts) {
                        if Task.isCancelled { break }

                        let info = Int32(node.pointee.fts_info)
                        if info == FTS_DNR || info == FTS_ERR || info == FTS_NS {
                            continue
                        }

                        if info == FTS_F {
                            let statInfo = node.pointee.fts_statp.pointee
                            let fileSize = UInt64(max(0, statInfo.st_size))
                            let currentPath = String(cString: node.pointee.fts_path)
                            let fileURL = URL(fileURLWithPath: currentPath)

                            let item = ScannedItem(
                                url: fileURL,
                                byteSize: fileSize,
                                isDirectory: false
                            )
                            continuation.yield(item)
                        }
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                scanTask.cancel()
            }
        }
    }

    /// Scans a directory and returns an aggregated result summary
    public func aggregateScan(at targetURL: URL) async throws -> ScanSummary {
        var summary = ScanSummary()

        for await item in scanDirectory(at: targetURL) {
            try Task.checkCancellation()
            summary.totalScannedBytes += item.byteSize
            summary.totalFileCount += 1
            summary.items.append(item)
        }

        logger.info("Scan completed for \(targetURL.path, privacy: .public). Found \(summary.totalFileCount) files (\(summary.totalScannedBytes) bytes).")
        return summary
    }

    /// Computes total recursive file size of a file or directory using fts(3)
    public nonisolated static func computeRecursiveSize(at url: URL) -> UInt64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

        if !isDir.boolValue {
            if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
                return UInt64(max(0, values.totalFileAllocatedSize ?? values.fileSize ?? 0))
            }
            return 0
        }

        guard let cPath = strdup(url.path) else { return 0 }
        defer { free(cPath) }

        var total: UInt64 = 0
        let paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        paths.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let fts = fts_open(baseAddress, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
                return
            }
            defer { fts_close(fts) }

            while let node = fts_read(fts) {
                if Task.isCancelled { break }
                let info = Int32(node.pointee.fts_info)
                if info == FTS_F {
                    let statInfo = node.pointee.fts_statp.pointee
                    let blocksSize = UInt64(max(0, statInfo.st_blocks)) * 512
                    let logicalSize = UInt64(max(0, statInfo.st_size))
                    total += blocksSize > 0 ? min(blocksSize, logicalSize == 0 ? 0 : max(blocksSize, logicalSize)) : logicalSize
                }
            }
        }
        return total
    }

    /// Scans a specific JunkCategory into top-level inspectable items
    public func scanJunkCategory(
        _ category: JunkCategory,
        progressHandler: @escaping @Sendable (String) -> Void
    ) async throws -> [JunkItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)

        var targetItems: [JunkItem] = []

        switch category {
        case .userCaches:
            let cachesDir = library.appendingPathComponent("Caches", isDirectory: true)
            let items = try scanTopLevelEntries(
                in: cachesDir,
                category: category,
                excludedNames: Self.excludedUserCacheNames,
                progressHandler: progressHandler
            )
            targetItems.append(contentsOf: items)

        case .applicationLogs:
            let logsDir = library.appendingPathComponent("Logs", isDirectory: true)
            targetItems.append(contentsOf: try scanTopLevelEntries(
                in: logsDir,
                category: category,
                excludedNames: [],
                progressHandler: progressHandler
            ))

        case .browserCaches:
            let browserPaths: [(name: String, url: URL)] = [
                ("Safari Cache", library.appendingPathComponent("Caches/com.apple.Safari", isDirectory: true)),
                ("Google Chrome Cache", library.appendingPathComponent("Caches/Google/Chrome", isDirectory: true)),
                ("Firefox Cache", library.appendingPathComponent("Caches/Firefox", isDirectory: true)),
                ("Arc Cache", library.appendingPathComponent("Caches/company.thebrowser.Browser", isDirectory: true)),
                ("Brave Cache", library.appendingPathComponent("Caches/BraveSoftware/Brave-Browser", isDirectory: true)),
                ("Microsoft Edge Cache", library.appendingPathComponent("Caches/Microsoft Edge", isDirectory: true))
            ]
            for entry in browserPaths {
                try Task.checkCancellation()
                progressHandler(entry.url.path)
                guard fm.fileExists(atPath: entry.url.path) else { continue }
                let size = Self.computeRecursiveSize(at: entry.url)
                if size > 0 {
                    let modDate = (try? entry.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    targetItems.append(JunkItem(
                        url: entry.url,
                        name: entry.name,
                        category: .browserCaches,
                        byteSize: size,
                        modifiedDate: modDate,
                        isDirectory: true,
                        isSelected: true
                    ))
                }
            }

        case .developerJunk:
            let devPaths: [(name: String, url: URL, defaultSelect: Bool)] = [
                ("Xcode DerivedData", library.appendingPathComponent("Developer/Xcode/DerivedData", isDirectory: true), true),
                ("Xcode Caches", library.appendingPathComponent("Caches/com.apple.dt.Xcode", isDirectory: true), true),
                ("CoreSimulator Caches", library.appendingPathComponent("Developer/CoreSimulator/Caches", isDirectory: true), true),
                ("Swift Package Manager Cache", library.appendingPathComponent("Caches/org.swift.swiftpm", isDirectory: true), true),
                ("Xcode Device Support", library.appendingPathComponent("Developer/Xcode/iOS DeviceSupport", isDirectory: true), false)
            ]
            for entry in devPaths {
                try Task.checkCancellation()
                progressHandler(entry.url.path)
                guard fm.fileExists(atPath: entry.url.path) else { continue }
                let size = Self.computeRecursiveSize(at: entry.url)
                if size > 0 {
                    let modDate = (try? entry.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    targetItems.append(JunkItem(
                        url: entry.url,
                        name: entry.name,
                        category: .developerJunk,
                        byteSize: size,
                        modifiedDate: modDate,
                        isDirectory: true,
                        isSelected: entry.defaultSelect
                    ))
                }
            }

        case .oldDownloads:
            let downloadsDir = home.appendingPathComponent("Downloads", isDirectory: true)
            let installerExtensions: Set<String> = ["dmg", "pkg", "iso", "zip", "tar", "gz", "xip"]
            let cutoffDate = Date().addingTimeInterval(-14 * 24 * 60 * 60)
            if let contents = try? fm.contentsOfDirectory(
                at: downloadsDir,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                for url in contents {
                    try Task.checkCancellation()
                    let ext = url.pathExtension.lowercased()
                    guard installerExtensions.contains(ext) else { continue }
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
                    let modDate = values?.contentModificationDate ?? Date()
                    guard modDate < cutoffDate else { continue }
                    progressHandler(url.path)
                    let isDir = values?.isDirectory ?? false
                    let size = isDir ? Self.computeRecursiveSize(at: url) : UInt64(max(0, values?.fileSize ?? 0))
                    if size > 0 {
                        targetItems.append(JunkItem(
                            url: url,
                            category: .oldDownloads,
                            byteSize: size,
                            modifiedDate: modDate,
                            isDirectory: isDir,
                            isSelected: false
                        ))
                    }
                }
            }

        case .userTrash:
            let trashDir = home.appendingPathComponent(".Trash", isDirectory: true)
            targetItems.append(contentsOf: try scanTopLevelEntries(
                in: trashDir,
                category: category,
                excludedNames: [],
                includeHidden: true,
                progressHandler: progressHandler
            ))
        }

        return targetItems.sorted { $0.byteSize > $1.byteSize }
    }

    private func scanTopLevelEntries(
        in directory: URL,
        category: JunkCategory,
        excludedNames: Set<String>,
        includeHidden: Bool = false,
        progressHandler: @escaping @Sendable (String) -> Void
    ) throws -> [JunkItem] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }

        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        guard let children = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .isSymbolicLinkKey],
            options: options
        ) else {
            return []
        }

        var results: [JunkItem] = []
        for child in children {
            try Task.checkCancellation()
            let name = child.lastPathComponent
            if name == ".DS_Store" || excludedNames.contains(name) { continue }

            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }

            progressHandler(child.path)
            let size = Self.computeRecursiveSize(at: child)
            guard size > 0 else { continue }

            results.append(JunkItem(
                url: child,
                category: category,
                byteSize: size,
                modifiedDate: values?.contentModificationDate,
                isDirectory: values?.isDirectory ?? false,
                isSelected: category.defaultSelected
            ))
        }
        return results
    }

    /// Scans directories for large regular files exceeding minimumBytes
    public func scanLargeFiles(
        in roots: [URL],
        minimumBytes: UInt64,
        progressHandler: @escaping @Sendable (String, Int) -> Void
    ) async throws -> [LargeFileItem] {
        var found: [LargeFileItem] = []
        var visitedCount = 0

        for root in roots {
            try Task.checkCancellation()
            guard let cPath = strdup(root.path) else { continue }
            defer { free(cPath) }

            let paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
            paths.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress,
                      let fts = fts_open(baseAddress, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
                    return
                }
                defer { fts_close(fts) }

                while let node = fts_read(fts) {
                    if Task.isCancelled { break }
                    let info = Int32(node.pointee.fts_info)
                    if info == FTS_DNR || info == FTS_ERR || info == FTS_NS { continue }

                    let currentPath = String(cString: node.pointee.fts_path)

                    // Skip bundle internals (.app, .photoslibrary, .xcodeproj, etc.) and ~/Library
                    if info == FTS_D {
                        let name = URL(fileURLWithPath: currentPath).lastPathComponent
                        if name.hasSuffix(".app") ||
                            name.hasSuffix(".photoslibrary") ||
                            name.hasSuffix(".framework") ||
                            name == "Library" && URL(fileURLWithPath: currentPath).deletingLastPathComponent() == FileManager.default.homeDirectoryForCurrentUser ||
                            name == ".Trash" {
                            fts_set(fts, node, FTS_SKIP)
                            continue
                        }
                    }

                    if info == FTS_F {
                        visitedCount += 1
                        let statInfo = node.pointee.fts_statp.pointee
                        let fileSize = UInt64(max(0, statInfo.st_size))

                        if visitedCount % 250 == 0 {
                            progressHandler(currentPath, visitedCount)
                        }

                        if fileSize >= minimumBytes {
                            let url = URL(fileURLWithPath: currentPath)
                            let modDate = Date(timeIntervalSince1970: TimeInterval(statInfo.st_mtimespec.tv_sec))
                            found.append(LargeFileItem(
                                url: url,
                                byteSize: fileSize,
                                modifiedDate: modDate,
                                isSelected: false
                            ))
                        }
                    }
                }
            }
        }

        return found.sorted { $0.byteSize > $1.byteSize }
    }
}
