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
    
    public init() {}

    /// Performs asynchronous directory traversal using an AsyncStream for real-time progress streaming
    public func scanDirectory(at rootURL: URL) -> AsyncStream<ScannedItem> {
        AsyncStream { continuation in
            let scanTask = Task.detached(priority: .userInitiated) {
                let path = rootURL.path
                let paths = [UnsafeMutablePointer<CChar>(mutating: (path as NSString).utf8String), nil]
                
                paths.withUnsafeBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    
                    // FTS_PHYSICAL: Do not follow symlinks
                    // FTS_NOCHDIR: Avoid changing current working directory (crucial for multithread safety)
                    // FTS_XDEV: Stay strictly within current file system device boundary
                    guard let fts = fts_open(baseAddress, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
                        return
                    }
                    defer { fts_close(fts) }

                    while let node = fts_read(fts) {
                        // Cooperative cancellation check
                        if Task.isCancelled { break }

                        let info = Int32(node.pointee.fts_info)

                        // Skip error or unreadable nodes
                        if info == FTS_DNR || info == FTS_ERR || info == FTS_NS {
                            continue
                        }

                        // Collect metrics for regular files (FTS_F)
                        if info == FTS_F {
                            let statInfo = node.pointee.fts_statp.pointee
                            let fileSize = UInt64(statInfo.st_size)
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
        
        logger.info("Scan completed for \(targetURL.path). Found \(summary.totalFileCount) files (\(summary.totalScannedBytes) bytes).")
        return summary
    }
}
