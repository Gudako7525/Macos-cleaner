//
//  DuplicateDetectionEngine.swift
//  SystemCleaner
//
//  Multi-stage duplicate finder with size grouping, partial hashing, and full chunked SHA-256 verification.
//

import Foundation
import CryptoKit
import Darwin

public actor DuplicateDetectionEngine {
    private let chunkSize = 1024 * 1024 // 1 MB chunk stream buffer
    private let partialSampleSize = 8 * 1024 // 8 KB head + 8 KB tail

    public init() {}

    /// Compares two file targets to verify binary equality without loading the full file into RAM
    public func verifyFullMatch(fileA: URL, fileB: URL) async throws -> Bool {
        guard let handleA = try? FileHandle(forReadingFrom: fileA),
              let handleB = try? FileHandle(forReadingFrom: fileB) else {
            return false
        }
        defer {
            try? handleA.close()
            try? handleB.close()
        }

        var hasherA = SHA256()
        var hasherB = SHA256()

        while true {
            try Task.checkCancellation()
            let dataA = handleA.readData(ofLength: chunkSize)
            let dataB = handleB.readData(ofLength: chunkSize)

            if dataA.isEmpty && dataB.isEmpty { break }
            if dataA != dataB { return false } // Fail fast on non-matching chunks

            hasherA.update(data: dataA)
            hasherB.update(data: dataB)

            if dataA.count < chunkSize { break }
        }

        return hasherA.finalize() == hasherB.finalize()
    }

    /// Multi-stage duplicate detection across the given root directories
    public func findDuplicates(
        in roots: [URL],
        minimumBytes: UInt64 = 100 * 1024,
        progressHandler: @escaping @Sendable (DuplicateScanProgress) -> Void
    ) async throws -> [DuplicateGroup] {
        // Stage 1: Enumerate regular files and bucket by exact byte size
        var filesBySize: [UInt64: [(url: URL, modifiedDate: Date)]] = [:]
        var examinedCount = 0

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

                    if info == FTS_D {
                        let name = URL(fileURLWithPath: currentPath).lastPathComponent
                        if name.hasPrefix(".") ||
                            name.hasSuffix(".app") ||
                            name.hasSuffix(".photoslibrary") ||
                            name.hasSuffix(".framework") ||
                            name.hasSuffix(".xcodeproj") ||
                            name == "Library" && URL(fileURLWithPath: currentPath).deletingLastPathComponent() == FileManager.default.homeDirectoryForCurrentUser {
                            fts_set(fts, node, FTS_SKIP)
                            continue
                        }
                    }

                    if info == FTS_F {
                        let statInfo = node.pointee.fts_statp.pointee
                        let fileSize = UInt64(max(0, statInfo.st_size))
                        examinedCount += 1

                        if examinedCount % 250 == 0 {
                            progressHandler(DuplicateScanProgress(
                                stage: .enumerating,
                                filesExamined: examinedCount,
                                candidateGroups: filesBySize.count,
                                currentPath: currentPath
                            ))
                        }

                        if fileSize >= minimumBytes {
                            let url = URL(fileURLWithPath: currentPath)
                            let modDate = Date(timeIntervalSince1970: TimeInterval(statInfo.st_mtimespec.tv_sec))
                            filesBySize[fileSize, default: []].append((url, modDate))
                        }
                    }
                }
            }
        }

        try Task.checkCancellation()

        // Filter to sizes with at least 2 files
        let sizeCandidates = filesBySize.filter { $0.value.count >= 2 }

        // Stage 2: Partial hash (first 8KB + last 8KB + size)
        var partialBuckets: [String: [(url: URL, size: UInt64, modifiedDate: Date)]] = [:]
        var processedCandidates = 0

        for (size, items) in sizeCandidates {
            try Task.checkCancellation()
            for item in items {
                processedCandidates += 1
                if processedCandidates % 50 == 0 {
                    progressHandler(DuplicateScanProgress(
                        stage: .partialHashing,
                        filesExamined: processedCandidates,
                        candidateGroups: sizeCandidates.count,
                        currentPath: item.url.path
                    ))
                }
                if let partial = computePartialHash(for: item.url, size: size) {
                    partialBuckets[partial, default: []].append((item.url, size, item.modifiedDate))
                }
            }
        }

        // Stage 3: Full streaming SHA-256 verification for matching partial hashes
        let fullCandidates = partialBuckets.filter { $0.value.count >= 2 }
        var fullBuckets: [String: [(url: URL, size: UInt64, modifiedDate: Date)]] = [:]
        var hashedCount = 0

        for (_, items) in fullCandidates {
            for item in items {
                try Task.checkCancellation()
                hashedCount += 1
                progressHandler(DuplicateScanProgress(
                    stage: .fullHashing,
                    filesExamined: hashedCount,
                    candidateGroups: fullCandidates.count,
                    currentPath: item.url.path
                ))
                if let digest = try computeFullSHA256(for: item.url) {
                    let key = "\(item.size):\(digest)"
                    fullBuckets[key, default: []].append(item)
                }
            }
        }

        let groups: [DuplicateGroup] = fullBuckets.compactMap { (key, items) in
            guard items.count >= 2, let first = items.first else { return nil }
            let sortedFiles = items
                .sorted { $0.modifiedDate < $1.modifiedDate }
                .enumerated()
                .map { index, item in
                    // Pre-select duplicates while keeping the oldest original unselected by default
                    DuplicateFileItem(
                        url: item.url,
                        modifiedDate: item.modifiedDate,
                        isSelected: index > 0
                    )
                }
            return DuplicateGroup(hash: key, byteSize: first.size, files: sortedFiles)
        }
        .sorted { $0.totalWastedBytes > $1.totalWastedBytes }

        progressHandler(DuplicateScanProgress(
            stage: .finished,
            filesExamined: examinedCount,
            candidateGroups: groups.count,
            currentPath: ""
        ))

        return groups
    }

    private func computePartialHash(for url: URL, size: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        var sizeCopy = size
        withUnsafeBytes(of: &sizeCopy) { hasher.update(bufferPointer: $0) }

        let headData = handle.readData(ofLength: partialSampleSize)
        hasher.update(data: headData)

        if size > UInt64(partialSampleSize * 2) {
            let tailOffset = size - UInt64(partialSampleSize)
            try? handle.seek(toOffset: tailOffset)
            let tailData = handle.readData(ofLength: partialSampleSize)
            hasher.update(data: tailData)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func computeFullSHA256(for url: URL) throws -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            if chunk.count < chunkSize { break }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
