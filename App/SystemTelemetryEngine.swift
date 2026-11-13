//
//  SystemTelemetryEngine.swift
//  SystemCleaner
//
//  Direct Mach kernel telemetry: low-overhead CPU, unified memory, APFS disk,
//  BSD network throughput, and safe AppleSMC thermal/fan polling.
//

import Foundation
import Darwin
import IOKit
import os.log

public final class SystemTelemetryEngine: ObservableObject {
    private var previousCpuInfo: processor_info_array_t?
    private var previousCpuInfoCount: mach_msg_type_number_t = 0
    private var cpuLock = os_unfair_lock_s()

    private var previousNetBytesIn: UInt64 = 0
    private var previousNetBytesOut: UInt64 = 0
    private var previousNetTimestamp: TimeInterval = 0
    private var netLock = os_unfair_lock_s()

    private var pollingTask: Task<Void, Never>?

    public struct MemoryBreakdown: Sendable {
        public let usedBytes: UInt64
        public let activeBytes: UInt64
        public let wiredBytes: UInt64
        public let compressedBytes: UInt64
        public let cachedFilesBytes: UInt64
        public let freeBytes: UInt64
        public let totalBytes: UInt64

        public static let empty = MemoryBreakdown(
            usedBytes: 0,
            activeBytes: 0,
            wiredBytes: 0,
            compressedBytes: 0,
            cachedFilesBytes: 0,
            freeBytes: 0,
            totalBytes: 0
        )
    }

    public struct DiskBreakdown: Sendable {
        public let volumeName: String
        public let freeBytes: UInt64
        public let availableImportantBytes: UInt64
        public let totalBytes: UInt64

        public var usedBytes: UInt64 {
            totalBytes > availableImportantBytes ? totalBytes - availableImportantBytes : 0
        }

        public static let empty = DiskBreakdown(
            volumeName: "Macintosh HD",
            freeBytes: 0,
            availableImportantBytes: 0,
            totalBytes: 0
        )
    }

    public struct NetworkThroughput: Sendable {
        public let uploadBytesPerSecond: UInt64
        public let downloadBytesPerSecond: UInt64

        public static let empty = NetworkThroughput(
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0
        )
    }

    public struct ThermalTelemetry: Sendable {
        public let cpuTemperatureCelsius: Double?
        public let fanSpeedRPM: Int?

        public static let empty = ThermalTelemetry(
            cpuTemperatureCelsius: nil,
            fanSpeedRPM: nil
        )
    }

    public struct SystemSnapshot: Sendable {
        public let cpuUsagePercent: Double
        public let memory: MemoryBreakdown
        public let disk: DiskBreakdown
        public let network: NetworkThroughput
        public let thermal: ThermalTelemetry

        public var memoryUsedBytes: UInt64 { memory.usedBytes }
        public var memoryTotalBytes: UInt64 { memory.totalBytes }
        public var diskFreeBytes: UInt64 { disk.availableImportantBytes > 0 ? disk.availableImportantBytes : disk.freeBytes }
        public var diskTotalBytes: UInt64 { disk.totalBytes }

        public static let empty = SystemSnapshot(
            cpuUsagePercent: 0,
            memory: .empty,
            disk: .empty,
            network: .empty,
            thermal: .empty
        )
    }

    @Published public private(set) var snapshot: SystemSnapshot = .empty
    @Published public private(set) var cpuHistory: [Double] = []
    @Published public private(set) var memoryHistory: [Double] = []

    private let maxHistoryPoints = 24

    public init() {}

    deinit {
        pollingTask?.cancel()
        os_unfair_lock_lock(&cpuLock)
        if let prev = previousCpuInfo {
            let size = vm_size_t(previousCpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prev), size)
            previousCpuInfo = nil
            previousCpuInfoCount = 0
        }
        os_unfair_lock_unlock(&cpuLock)
    }

    @MainActor
    public func startPolling(intervalSeconds: Double = 1.5) {
        guard pollingTask == nil else { return }
        refreshNow()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
                if Task.isCancelled { break }
                self?.refreshNow()
            }
        }
    }

    @MainActor
    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    @MainActor
    public func refreshNow() {
        let cpu = fetchCPUUsage()
        let mem = fetchMemoryBreakdown()
        let disk = fetchDiskBreakdown()
        let net = fetchNetworkThroughput()
        let thermal = fetchThermalTelemetry()

        snapshot = SystemSnapshot(
            cpuUsagePercent: cpu,
            memory: mem,
            disk: disk,
            network: net,
            thermal: thermal
        )

        cpuHistory.append(cpu)
        if cpuHistory.count > maxHistoryPoints {
            cpuHistory.removeFirst(cpuHistory.count - maxHistoryPoints)
        }

        let memPct = mem.totalBytes > 0 ? (Double(mem.usedBytes) / Double(mem.totalBytes)) * 100.0 : 0.0
        memoryHistory.append(memPct)
        if memoryHistory.count > maxHistoryPoints {
            memoryHistory.removeFirst(memoryHistory.count - maxHistoryPoints)
        }
    }

    /// Queries host CPU core load delta via Mach host_processor_info API
    public func fetchCPUUsage() -> Double {
        os_unfair_lock_lock(&cpuLock)
        defer { os_unfair_lock_unlock(&cpuLock) }

        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )

        guard result == KERN_SUCCESS, let info = processorInfo else {
            return 0.0
        }

        var totalTicks: UInt64 = 0
        var idleTicks: UInt64 = 0

        if let prevInfo = previousCpuInfo {
            for i in 0..<Int(processorCount) {
                let offset = Int(CPU_STATE_MAX) * i
                let user = UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)]) &- UInt32(bitPattern: prevInfo[offset + Int(CPU_STATE_USER)]))
                let system = UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)]) &- UInt32(bitPattern: prevInfo[offset + Int(CPU_STATE_SYSTEM)]))
                let nice = UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)]) &- UInt32(bitPattern: prevInfo[offset + Int(CPU_STATE_NICE)]))
                let idle = UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)]) &- UInt32(bitPattern: prevInfo[offset + Int(CPU_STATE_IDLE)]))

                totalTicks += (user + system + nice + idle)
                idleTicks += idle
            }
        }

        if let prev = previousCpuInfo {
            let size = vm_size_t(previousCpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prev), size)
        }

        previousCpuInfo = info
        previousCpuInfoCount = processorInfoCount

        guard totalTicks > 0 else { return 0.0 }
        let activeTicks = totalTicks - idleTicks
        return min(100.0, max(0.0, (Double(activeTicks) / Double(totalTicks)) * 100.0))
    }

    /// Reads memory metrics using 64-bit Mach VM statistics (dynamic Apple Silicon 16KB page support)
    public func fetchMemoryMetrics() -> (used: UInt64, total: UInt64) {
        let breakdown = fetchMemoryBreakdown()
        return (breakdown.usedBytes, breakdown.totalBytes)
    }

    public func fetchMemoryBreakdown() -> MemoryBreakdown {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStats = vm_statistics64()

        let kerr = withUnsafeMutablePointer(to: &vmStats) { pt in
            pt.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPt in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPt, &count)
            }
        }

        guard kerr == KERN_SUCCESS else {
            return .empty
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(vmStats.active_count) * pageSize
        let inactive = UInt64(vmStats.inactive_count) * pageSize
        let wired = UInt64(vmStats.wire_count) * pageSize
        let speculative = UInt64(vmStats.speculative_count) * pageSize
        let compressor = UInt64(vmStats.compressor_page_count) * pageSize
        let external = UInt64(vmStats.external_page_count) * pageSize
        let purgeable = UInt64(vmStats.purgeable_count) * pageSize

        let total = ProcessInfo.processInfo.physicalMemory
        let cachedFiles = external + purgeable
        // Include reclaimable file-backed/inactive cache in usedBytes so /usr/sbin/purge and VM pressure reclamation visibly drop used RAM
        let rawUsed = active + inactive + wired + speculative + compressor
        let used = min(total, rawUsed)
        let free = total > used ? total - used : 0

        return MemoryBreakdown(
            usedBytes: used,
            activeBytes: active,
            wiredBytes: wired,
            compressedBytes: compressor,
            cachedFilesBytes: cachedFiles,
            freeBytes: free,
            totalBytes: total
        )
    }

    /// Reads APFS Volume usage via POSIX statvfs
    public func fetchDiskSpace(at path: String = "/") -> (free: UInt64, total: UInt64) {
        let disk = fetchDiskBreakdown(at: path)
        return (disk.freeBytes, disk.totalBytes)
    }

    public func fetchDiskBreakdown(at path: String = "/") -> DiskBreakdown {
        var stats = statvfs()
        guard statvfs(path, &stats) == 0 else {
            return .empty
        }

        let blockSize = UInt64(stats.f_frsize)
        let free = UInt64(stats.f_bavail) * blockSize
        let total = UInt64(stats.f_blocks) * blockSize

        var availableImportant = free
        var volumeName = "Macintosh HD"
        let rootURL = URL(fileURLWithPath: path)
        if let values = try? rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeNameKey]) {
            if let important = values.volumeAvailableCapacityForImportantUsage {
                availableImportant = UInt64(max(0, important))
            }
            if let name = values.volumeName, !name.isEmpty {
                volumeName = name
            }
        }

        return DiskBreakdown(
            volumeName: volumeName,
            freeBytes: free,
            availableImportantBytes: availableImportant,
            totalBytes: total
        )
    }

    /// Reads live aggregate upload/download throughput across active non-loopback interfaces via getifaddrs
    public func fetchNetworkThroughput() -> NetworkThroughput {
        os_unfair_lock_lock(&netLock)
        defer { os_unfair_lock_unlock(&netLock) }

        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPtr) == 0, let firstAddr = ifaddrsPtr else {
            return .empty
        }
        defer { freeifaddrs(ifaddrsPtr) }

        var totalBytesIn: UInt64 = 0
        var totalBytesOut: UInt64 = 0

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = cursor {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp && isRunning && !isLoopback,
               let addr = current.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_LINK),
               let dataPtr = current.pointee.ifa_data {
                let networkData = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                totalBytesIn &+= UInt64(networkData.ifi_ibytes)
                totalBytesOut &+= UInt64(networkData.ifi_obytes)
            }
            cursor = current.pointee.ifa_next
        }

        let now = ProcessInfo.processInfo.systemUptime
        defer {
            previousNetBytesIn = totalBytesIn
            previousNetBytesOut = totalBytesOut
            previousNetTimestamp = now
        }

        guard previousNetTimestamp > 0 else {
            return .empty
        }

        let elapsed = now - previousNetTimestamp
        guard elapsed > 0.1 else {
            return .empty
        }

        let deltaIn = totalBytesIn >= previousNetBytesIn ? totalBytesIn - previousNetBytesIn : 0
        let deltaOut = totalBytesOut >= previousNetBytesOut ? totalBytesOut - previousNetBytesOut : 0

        return NetworkThroughput(
            uploadBytesPerSecond: UInt64(Double(deltaOut) / elapsed),
            downloadBytesPerSecond: UInt64(Double(deltaIn) / elapsed)
        )
    }

    /// Reads CPU temperature and fan speed from AppleSMC when exposed by the host hardware
    public func fetchThermalTelemetry() -> ThermalTelemetry {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return .empty }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            return .empty
        }
        defer { IOServiceClose(connection) }

        let tempKeys = ["Tp09", "Tp01", "Tp05", "TC0P", "TC0D", "TC0E", "TC0F"]
        var cpuTemp: Double?
        for key in tempKeys {
            if let value = readSMCValue(connection: connection, key: key), value > 5.0 && value < 125.0 {
                cpuTemp = value
                break
            }
        }

        var fanRPM: Int?
        if let rawFan = readSMCValue(connection: connection, key: "F0Ac"), rawFan >= 0 && rawFan < 12_000 {
            fanRPM = Int(rawFan.rounded())
        }

        return ThermalTelemetry(cpuTemperatureCelsius: cpuTemp, fanSpeedRPM: fanRPM)
    }

    private func readSMCValue(connection: io_connect_t, key: String) -> Double? {
        guard key.utf8.count == 4 else { return nil }
        let keyCode = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }

        var input = SMCKeyData()
        input.key = keyCode
        input.data8 = 9 // kSMCGetKeyInfo

        var output = SMCKeyData()
        let structSize = MemoryLayout<SMCKeyData>.size
        var outputSize = structSize

        guard IOConnectCallStructMethod(connection, 2, &input, structSize, &output, &outputSize) == KERN_SUCCESS else {
            return nil
        }

        let dataSize = output.keyInfo.dataSize
        let dataType = output.keyInfo.dataType
        guard dataSize > 0 && dataSize <= 32 else { return nil }

        input = SMCKeyData()
        input.key = keyCode
        input.keyInfo.dataSize = dataSize
        input.data8 = 5 // kSMCReadKey

        output = SMCKeyData()
        outputSize = structSize
        guard IOConnectCallStructMethod(connection, 2, &input, structSize, &output, &outputSize) == KERN_SUCCESS else {
            return nil
        }

        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(dataSize))) }
        let typeStr = fourCharCodeToString(dataType)

        switch typeStr {
        case "flt " where bytes.count == 4:
            let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            let val = Double(Float(bitPattern: bits))
            return val.isFinite ? val : nil
        case "sp78" where bytes.count >= 2:
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / 256.0
        case "fpe2" where bytes.count >= 2:
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw) / 4.0
        case "ui16" where bytes.count >= 2:
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case "ui8 " where bytes.count >= 1:
            return Double(bytes[0])
        default:
            return nil
        }
    }

    private func fourCharCodeToString(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}

private struct SMCKeyDataVers {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCKeyDataPLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyDataKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCKeyDataVers()
    var pLimitData = SMCKeyDataPLimit()
    var keyInfo = SMCKeyDataKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}
