//
//  SystemCleanerTests.swift
//  SystemCleanerTests
//
//  Unit tests using the Swift Testing framework.
//

import Foundation
import Testing
@testable import SystemCleaner

struct SystemCleanerTests {

    @Test func diskScannerCountsFilesAndBytes() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemCleanerTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileA = tempDir.appendingPathComponent("a.bin")
        let fileB = tempDir.appendingPathComponent("b.bin")
        try Data(repeating: 0xAA, count: 1024).write(to: fileA)
        try Data(repeating: 0xBB, count: 2048).write(to: fileB)

        let scanner = AsyncDiskScanner()
        let summary = try await scanner.aggregateScan(at: tempDir)

        #expect(summary.totalFileCount == 2)
        #expect(summary.totalScannedBytes == 3072)
    }

    @Test func duplicateEngineFindsExactMatchesAndIgnoresDifferentContent() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DupTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        let differentSameSize = Data((0..<4096).map { UInt8(($0 + 7) % 251) })

        let dup1 = tempDir.appendingPathComponent("copy1.dat")
        let dup2 = tempDir.appendingPathComponent("copy2.dat")
        let unique = tempDir.appendingPathComponent("unique.dat")

        try payload.write(to: dup1)
        try payload.write(to: dup2)
        try differentSameSize.write(to: unique)

        let engine = DuplicateDetectionEngine()
        let groups = try await engine.findDuplicates(in: [tempDir], minimumBytes: 1024) { _ in }

        #expect(groups.count == 1)
        #expect(groups.first?.files.count == 2)
        #expect(groups.first?.byteSize == 4096)
        #expect(groups.first?.totalWastedBytes == 4096)
    }

    @Test func telemetryReportsValidMemoryAndDiskTotals() {
        let engine = SystemTelemetryEngine()
        let mem = engine.fetchMemoryBreakdown()
        let disk = engine.fetchDiskBreakdown()

        #expect(mem.totalBytes > 0)
        #expect(mem.usedBytes <= mem.totalBytes)
        #expect(disk.totalBytes > 0)
    }

    @Test func emptyRemnantQueryReturnsEmpty() {
        let remnants = AppRemnantScanner.scanRemnants(bundleIdentifier: "", appName: "")
        #expect(remnants.isEmpty)
    }

    @Test func networkRateFormattingAndThermalTelemetryAreSafe() {
        #expect(ByteFormatter.formatRate(0) == "0 KB/s")
        #expect(ByteFormatter.formatRate(512 * 1024) == "512 KB/s")
        #expect(ByteFormatter.formatRate(2 * 1024 * 1024) == "2.0 MB/s")
        #expect(!ByteFormatter.formatMemory(8 * 1024 * 1024 * 1024).isEmpty)

        let engine = SystemTelemetryEngine()
        let net = engine.fetchNetworkThroughput()
        let thermal = engine.fetchThermalTelemetry()
        let disk = engine.fetchDiskBreakdown()

        #expect(net.uploadBytesPerSecond == 0)
        #expect(net.downloadBytesPerSecond == 0)
        #expect(!disk.volumeName.isEmpty)
        if let temp = thermal.cpuTemperatureCelsius {
            #expect(temp > 0 && temp < 150)
        }
    }
}
