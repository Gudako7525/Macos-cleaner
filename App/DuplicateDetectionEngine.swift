//
//  DuplicateDetectionEngine.swift
//  SystemCleaner
//
//  Multi-stage duplicate finder with chunked hashing and fail-fast binary checks.
//

import Foundation
import CryptoKit

public actor DuplicateDetectionEngine {
    private let chunkSize = 1024 * 1024 // 1 MB chunk stream buffer

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
}
