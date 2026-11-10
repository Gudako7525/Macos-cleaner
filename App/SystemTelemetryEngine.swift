//
//  SystemTelemetryEngine.swift
//  SystemCleaner
//
//  Direct Mach kernel telemetry: low-overhead CPU, unified memory, and APFS disk polling.
//

import Foundation
import Darwin
import os.log

public final class SystemTelemetryEngine: ObservableObject {
    private var previousCpuInfo: processor_info_array_t?
    private var previousCpuInfoCount: mach_msg_type_number_t = 0
    private var cpuLock = os_unfair_lock_s()

    public struct SystemSnapshot: Sendable {
        public let cpuUsagePercent: Double
        public let memoryUsedBytes: UInt64
        public let memoryTotalBytes: UInt64
        public let diskFreeBytes: UInt64
        public let diskTotalBytes: UInt64
    }

    public init() {}

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

        var totalTicks: Int32 = 0
        var idleTicks: Int32 = 0

        if let prevInfo = previousCpuInfo {
            for i in 0..<Int(processorCount) {
                let offset = Int32(CPU_STATE_MAX) * Int32(i)
                let user = info[Int(offset + CPU_STATE_USER)] - prevInfo[Int(offset + CPU_STATE_USER)]
                let system = info[Int(offset + CPU_STATE_SYSTEM)] - prevInfo[Int(offset + CPU_STATE_SYSTEM)]
                let nice = info[Int(offset + CPU_STATE_NICE)] - prevInfo[Int(offset + CPU_STATE_NICE)]
                let idle = info[Int(offset + CPU_STATE_IDLE)] - prevInfo[Int(offset + CPU_STATE_IDLE)]

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
        return (Double(activeTicks) / Double(totalTicks)) * 100.0
    }

    /// Reads memory metrics using 64-bit Mach VM statistics (dynamic Apple Silicon 16KB page support)
    public func fetchMemoryMetrics() -> (used: UInt64, total: UInt64) {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStats = vm_statistics64()
        
        let kerr = withUnsafeMutablePointer(to: &vmStats) { pt in
            pt.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPt in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPt, &count)
            }
        }

        guard kerr == KERN_SUCCESS else {
            return (0, 0)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(vmStats.active_count) * pageSize
        let wired = UInt64(vmStats.wire_count) * pageSize
        let speculative = UInt64(vmStats.speculative_count) * pageSize
        let compressor = UInt64(vmStats.compressor_page_count) * pageSize

        let total = ProcessInfo.processInfo.physicalMemory
        let used = active + wired + speculative + compressor

        return (used, total)
    }

    /// Reads APFS Volume usage via POSIX statvfs
    public func fetchDiskSpace(at path: String = "/") -> (free: UInt64, total: UInt64) {
        var stats = statvfs()
        guard statvfs(path, &stats) == 0 else {
            return (0, 0)
        }
        
        let blockSize = UInt64(stats.f_frsize)
        let free = UInt64(stats.f_bavail) * blockSize
        let total = UInt64(stats.f_blocks) * blockSize
        return (free, total)
    }
}
