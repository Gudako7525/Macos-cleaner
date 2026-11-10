//
//  ContentView.swift
//  SystemCleaner
//
//  Main user interface with scanning progress, live telemetry, and maintenance triggers.
//

import SwiftUI

public struct ContentView: View {
    @StateObject private var daemonManager = DaemonManager.shared
    @StateObject private var telemetry = SystemTelemetryEngine()
    
    @State private var cpuPercent: Double = 0.0
    @State private var ramUsed: UInt64 = 0
    @State private var ramTotal: UInt64 = 0
    @State private var diskFree: UInt64 = 0
    @State private var diskTotal: UInt64 = 0
    
    @State private var isScanning = false
    @State private var scannedBytes: UInt64 = 0
    @State private var scannedFiles: UInt64 = 0
    @State private var currentScanPath: String = ""
    @State private var maintenanceMessage: String = ""
    
    private let scanner = AsyncDiskScanner()
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    public var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SystemCleaner")
                        .font(.system(size: 22, weight: .bold))
                    Text("Optimized for macOS 14/15 on Apple Silicon")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                
                // Helper Daemon Status Pill
                HStack(spacing: 6) {
                    Circle()
                        .fill(daemonManager.status == .enabled ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(daemonManager.status == .enabled ? "Helper Active" : "Helper Unregistered")
                        .font(.caption2)
                        .bold()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
            }
            .padding(.horizontal)
            .padding(.top, 16)

            Divider()

            // Telemetry Cards
            HStack(spacing: 12) {
                MetricCard(
                    title: "CPU Load",
                    value: String(format: "%.1f%%", cpuPercent),
                    icon: "cpu"
                )
                MetricCard(
                    title: "Memory",
                    value: formatBytes(ramUsed),
                    subtitle: "of " + formatBytes(ramTotal),
                    icon: "memorychip"
                )
                MetricCard(
                    title: "Disk Free",
                    value: formatBytes(diskFree),
                    subtitle: "of " + formatBytes(diskTotal),
                    icon: "internaldrive"
                )
            }
            .padding(.horizontal)

            Divider()

            // Scanner Section
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Junk & Cache Scan")
                        .font(.headline)
                    Spacer()
                    if isScanning {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
                
                if !currentScanPath.isEmpty {
                    Text(currentScanPath)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Text("Reclaimable:")
                        .foregroundColor(.secondary)
                    Text(formatBytes(scannedBytes))
                        .font(.system(.title3, design: .monospaced))
                        .bold()
                    Spacer()
                    Text("\(scannedFiles) files")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Button(action: startScan) {
                        Label(isScanning ? "Scanning..." : "Scan User Caches", systemImage: "magnifyingglass")
                    }
                    .disabled(isScanning)
                    
                    Button(action: registerDaemon) {
                        Label("Enable Root Helper", systemImage: "lock.shield")
                    }
                    .disabled(daemonManager.status == .enabled)

                    Spacer()

                    Button(action: purgeRAM) {
                        Label("Purge Inactive RAM", systemImage: "bolt.fill")
                    }
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
            .padding(.horizontal)

            if !maintenanceMessage.isEmpty {
                Text(maintenanceMessage)
                    .font(.caption)
                    .foregroundColor(.blue)
            }

            Spacer()
        }
        .frame(minWidth: 540, minHeight: 400)
        .onReceive(timer) { _ in
            refreshTelemetry()
        }
        .onAppear {
            refreshTelemetry()
        }
    }

    private func refreshTelemetry() {
        cpuPercent = telemetry.fetchCPUUsage()
        let mem = telemetry.fetchMemoryMetrics()
        ramUsed = mem.used
        ramTotal = mem.total
        let disk = telemetry.fetchDiskSpace()
        diskFree = disk.free
        diskTotal = disk.total
    }

    private func startScan() {
        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        isScanning = true
        scannedBytes = 0
        scannedFiles = 0

        Task {
            for await item in await scanner.scanDirectory(at: cachesURL) {
                scannedBytes += item.byteSize
                scannedFiles += 1
                currentScanPath = item.url.path
            }
            isScanning = false
        }
    }

    private func registerDaemon() {
        do {
            try daemonManager.register()
            maintenanceMessage = "Helper registered successfully via SMAppService."
        } catch {
            maintenanceMessage = "Registration failed: \(error.localizedDescription)"
        }
    }

    private func purgeRAM() {
        Task {
            do {
                let proxy = try XPCConnectionManager.shared.getRemoteProxy()
                proxy.executeSystemMaintenance(routineIdentifier: MaintenanceRoutines.purgeRAM) { code, err in
                    DispatchQueue.main.async {
                        self.maintenanceMessage = (code == 0) ? "RAM purged successfully." : "Error: \(err ?? "Unknown")"
                        self.refreshTelemetry()
                    }
                }
            } catch {
                maintenanceMessage = "XPC Error: \(error.localizedDescription)"
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.headline)
            if let sub = subtitle {
                Text(sub)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}
