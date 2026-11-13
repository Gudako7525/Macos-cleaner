//
//  DashboardView.swift
//  SystemCleaner
//
//  Live system telemetry dashboard, disk breakdown, and quick actions.
//

import SwiftUI
import ServiceManagement

struct DashboardView: View {
    @ObservedObject var viewModel: CleanerViewModel
    @ObservedObject var telemetry: SystemTelemetryEngine
    @ObservedObject var daemonManager: DaemonManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerBanner

                // Live Telemetry Metric Cards
                HStack(spacing: 14) {
                    TelemetryCard(
                        title: "CPU Load",
                        value: String(format: "%.1f%%", telemetry.snapshot.cpuUsagePercent),
                        subtitle: "\(ProcessInfo.processInfo.activeProcessorCount) active cores",
                        icon: "cpu",
                        accent: telemetry.snapshot.cpuUsagePercent > 80 ? .red : .blue,
                        history: telemetry.cpuHistory
                    )

                    let mem = telemetry.snapshot.memory
                    let memPercent = mem.totalBytes > 0 ? (Double(mem.usedBytes) / Double(mem.totalBytes)) * 100.0 : 0
                    TelemetryCard(
                        title: "Unified Memory",
                        value: ByteFormatter.format(mem.usedBytes),
                        subtitle: String(format: "%.0f%% of %@", memPercent, ByteFormatter.format(mem.totalBytes)),
                        icon: "memorychip",
                        accent: memPercent > 85 ? .orange : .purple,
                        history: telemetry.memoryHistory
                    )

                    let disk = telemetry.snapshot.disk
                    TelemetryCard(
                        title: "APFS Available",
                        value: ByteFormatter.format(telemetry.snapshot.diskFreeBytes),
                        subtitle: "of \(ByteFormatter.format(disk.totalBytes)) total",
                        icon: "internaldrive",
                        accent: .green,
                        history: []
                    )
                }

                // Memory & Disk Visual Breakdown
                HStack(spacing: 14) {
                    memoryBreakdownCard
                    diskBreakdownCard
                }

                // Quick Actions
                quickActionsSection

                // System Permissions & Helper Status
                permissionsSection
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
    }

    private var headerBanner: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("System Overview")
                    .font(.title2.bold())
                Text("Native macOS telemetry, safe junk cleanup, and maintenance utilities.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.totalSessionReclaimedBytes > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Freed \(ByteFormatter.format(viewModel.totalSessionReclaimedBytes)) this session")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.green.opacity(0.12), in: Capsule())
            }
        }
    }

    private var memoryBreakdownCard: some View {
        let mem = telemetry.snapshot.memory
        let total = max(1, Double(mem.totalBytes))
        let activeRatio = Double(mem.activeBytes) / total
        let wiredRatio = Double(mem.wiredBytes) / total
        let compressedRatio = Double(mem.compressedBytes) / total

        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Memory Allocation")
                        .font(.headline)
                    Spacer()
                    Button {
                        Task { await viewModel.cleanRAM(allowAdminPrompt: false) }
                    } label: {
                        if viewModel.isCleaningRAM {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Clean RAM", systemImage: "bolt.fill")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isCleaningRAM)

                    Text(ByteFormatter.format(mem.totalBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                GeometryReader { geo in
                    HStack(spacing: 1) {
                        Rectangle().fill(.blue)
                            .frame(width: max(0, geo.size.width * activeRatio))
                        Rectangle().fill(.orange)
                            .frame(width: max(0, geo.size.width * wiredRatio))
                        Rectangle().fill(.purple)
                            .frame(width: max(0, geo.size.width * compressedRatio))
                        Rectangle().fill(Color.secondary.opacity(0.2))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .frame(height: 10)

                HStack(spacing: 14) {
                    LegendDot(color: .blue, label: "Active", value: ByteFormatter.format(mem.activeBytes))
                    LegendDot(color: .orange, label: "Wired", value: ByteFormatter.format(mem.wiredBytes))
                    LegendDot(color: .purple, label: "Compressed", value: ByteFormatter.format(mem.compressedBytes))
                    LegendDot(color: .cyan, label: "Cached", value: ByteFormatter.format(mem.cachedFilesBytes))
                    Spacer()
                }
                .font(.caption)

                if let ramMsg = viewModel.ramCleanupStatusMessage {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.ramCleanupLastSuccess ? "bolt.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(viewModel.ramCleanupLastSuccess ? .green : .orange)
                        Text(ramMsg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
        }
    }

    private var diskBreakdownCard: some View {
        let disk = telemetry.snapshot.disk
        let total = max(1, Double(disk.totalBytes))
        let usedRatio = min(1.0, max(0.0, Double(disk.usedBytes) / total))

        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Macintosh HD Storage")
                        .font(.headline)
                    Spacer()
                    Text(String(format: "%.1f%% used", usedRatio * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.2))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(usedRatio > 0.9 ? Color.red : Color.accentColor)
                            .frame(width: geo.size.width * usedRatio)
                    }
                }
                .frame(height: 10)

                HStack(spacing: 16) {
                    LegendDot(color: .accentColor, label: "Used", value: ByteFormatter.format(disk.usedBytes))
                    LegendDot(color: .green, label: "Available", value: ByteFormatter.format(telemetry.snapshot.diskFreeBytes))
                    Spacer()
                }
                .font(.caption)
            }
            .padding(6)
        }
    }

    private var quickActionsSection: some View {
        GroupBox("Quick Actions") {
            HStack(spacing: 12) {
                Button {
                    viewModel.selectedSection = .junkCleaner
                    viewModel.startJunkScan()
                } label: {
                    Label("Scan Junk & Caches", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    viewModel.selectedSection = .largeFiles
                    viewModel.startLargeFilesScan()
                } label: {
                    Label("Find Large Files", systemImage: "doc.badge.ellipsis")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.selectedSection = .duplicates
                    viewModel.startDuplicateScan()
                } label: {
                    Label("Scan Duplicates", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await viewModel.cleanRAM(allowAdminPrompt: false) }
                } label: {
                    Label(viewModel.isCleaningRAM ? "Cleaning RAM..." : "Free Up RAM", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isCleaningRAM)

                Button {
                    viewModel.selectedSection = .uninstaller
                    Task { await viewModel.loadInstalledApps() }
                } label: {
                    Label("App Uninstaller", systemImage: "trash.square")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
            .padding(6)
        }
    }

    private var permissionsSection: some View {
        GroupBox("Permissions & Background Helper") {
            VStack(spacing: 10) {
                HStack {
                    Image(systemName: viewModel.fullDiskAccess == .granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(viewModel.fullDiskAccess == .granted ? .green : .orange)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Full Disk Access")
                            .font(.subheadline.weight(.semibold))
                        Text(viewModel.fullDiskAccess == .granted
                             ? "Granted — SystemCleaner can inspect Safari, Mail, and protected app caches."
                             : (PrivacyPermissionCoordinator.isRunningFromDerivedData
                                ? "Not granted — Note: You are running a debug build from Xcode. Grant Full Disk Access to /Applications/SystemCleaner.app and launch from /Applications."
                                : "Not granted — Enable SystemCleaner in System Settings → Privacy & Security → Full Disk Access."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if viewModel.fullDiskAccess == .denied {
                        Button("Grant in Settings") {
                            PrivacyPermissionCoordinator.openSystemSettingsFullDiskAccess()
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("Refresh") {
                        viewModel.refreshPermissionsAndDaemon()
                    }
                    .buttonStyle(.borderless)
                }

                Divider()

                HStack {
                    Image(systemName: daemonManager.status == .enabled ? "lock.shield.fill" : "lock.slash")
                        .foregroundStyle(daemonManager.status == .enabled ? .green : .secondary)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Privileged Maintenance Helper (SMAppService)")
                            .font(.subheadline.weight(.semibold))
                        Text(daemonManager.statusDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Manage") {
                        viewModel.selectedSection = .maintenance
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(6)
        }
    }
}

private struct TelemetryCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let accent: Color
    let history: [Double]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .foregroundStyle(accent)
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if history.count > 1 {
                    SparklineView(values: history, color: accent)
                        .frame(height: 22)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

private struct SparklineView: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let maxVal = max(100.0, values.max() ?? 100.0)
            Path { path in
                for (index, val) in values.enumerated() {
                    let x = geo.size.width * CGFloat(index) / CGFloat(max(1, values.count - 1))
                    let y = geo.size.height * (1.0 - CGFloat(min(maxVal, max(0, val)) / maxVal))
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct LegendDot: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(label): \(value)")
                .foregroundStyle(.secondary)
        }
    }
}
