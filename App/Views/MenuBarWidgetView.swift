//
//  MenuBarWidgetView.swift
//  SystemCleaner
//
//  Top menu bar telemetry popover with 1-click RAM cleanup, network rates,
//  disk quick-clean shortcut, and main window launcher.
//

import SwiftUI
import AppKit

struct MenuBarWidgetView: View {
    @ObservedObject var viewModel: CleanerViewModel
    @ObservedObject var telemetry: SystemTelemetryEngine
    @ObservedObject var daemonManager: DaemonManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    private let cardFill = Color.white.opacity(0.09)
    private let cardBorder = Color.white.opacity(0.11)
    private let labelColor = Color(red: 0.71, green: 0.79, blue: 0.94)
    private let accentBlue = Color(red: 0.21, green: 0.56, blue: 0.98)

    var body: some View {
        let snapshot = telemetry.snapshot
        let mem = snapshot.memory
        let memRatio = mem.totalBytes > 0 ? min(1.0, max(0.0, Double(mem.usedBytes) / Double(mem.totalBytes))) : 0.0
        let disk = snapshot.disk
        let diskUsedRatio = disk.totalBytes > 0 ? min(1.0, max(0.0, Double(disk.usedBytes) / Double(disk.totalBytes))) : 0.0

        VStack(spacing: 10) {
            // Top Grid: CPU/Thermal Left + RAM & Network Stacked Right
            HStack(alignment: .top, spacing: 10) {
                cpuThermalCard(snapshot: snapshot)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 10) {
                    ramCard(mem: mem, memRatio: memRatio)
                    networkCard(net: snapshot.network)
                }
                .frame(width: 176)
            }
            .fixedSize(horizontal: false, vertical: true)

            // Disk Summary Card
            diskCard(disk: disk, diskFreeBytes: snapshot.diskFreeBytes, usedRatio: diskUsedRatio)

            // RAM Cleanup Feedback Banner (when triggered)
            if let ramStatus = viewModel.ramCleanupStatusMessage {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.ramCleanupLastSuccess ? "bolt.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(viewModel.ramCleanupLastSuccess ? Color.cyan : Color.orange)
                    Text(ramStatus)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

            // Footer Bar
            footerBar
                .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 348)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.11, green: 0.22, blue: 0.47),
                    Color(red: 0.06, green: 0.13, blue: 0.31)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .preferredColorScheme(.dark)
        .onAppear {
            telemetry.startPolling()
            viewModel.refreshPermissionsAndDaemon()
        }
    }

    // MARK: - Left CPU & Thermal Card

    private func cpuThermalCard(snapshot: SystemTelemetryEngine.SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            metricRow(
                icon: "cpu",
                title: "CPU LOAD",
                value: String(format: "%.0f%%", snapshot.cpuUsagePercent)
            )

            metricRow(
                icon: "thermometer.medium",
                title: "CPU TEMP",
                value: snapshot.thermal.cpuTemperatureCelsius.map { String(format: "%.0f°C", $0) } ?? "---"
            )

            metricRow(
                icon: "fanblades",
                title: "FAN SPEED",
                value: snapshot.thermal.fanSpeedRPM.map { "\($0) RPM" } ?? "---"
            )

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    private func metricRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(labelColor)

                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Top-Right RAM Cleanup Card

    private func ramCard(mem: SystemTelemetryEngine.MemoryBreakdown, memRatio: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "memorychip")
                            .font(.system(size: 11, weight: .medium))
                        Text("RAM(\(ByteFormatter.formatMemory(mem.totalBytes)))")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(labelColor)

                    Text(ByteFormatter.formatMemory(mem.usedBytes))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }

                Spacer(minLength: 4)

                Button {
                    Task { await viewModel.cleanRAM(allowAdminPrompt: false) }
                } label: {
                    ZStack {
                        Circle()
                            .fill(accentBlue)
                            .frame(width: 34, height: 34)
                            .shadow(color: accentBlue.opacity(0.45), radius: 6, y: 2)

                        if viewModel.isCleaningRAM {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isCleaningRAM)
                .help("Free Up RAM")
            }

            // 10-segment memory pressure pill bar
            HStack(spacing: 3) {
                let totalSegments = 10
                let activeSegments = Int((memRatio * Double(totalSegments)).rounded())
                let barColor: Color = memRatio > 0.85 ? .orange : Color(red: 0.24, green: 0.62, blue: 1.0)

                ForEach(0..<totalSegments, id: \.self) { index in
                    Capsule()
                        .fill(index < activeSegments ? barColor : Color.black.opacity(0.28))
                        .frame(height: 5)
                }
            }
        }
        .padding(12)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Bottom-Right Network Card

    private func networkCard(net: SystemTelemetryEngine.NetworkThroughput) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .medium))
                Text("NETWORK")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(labelColor)

            HStack(spacing: 6) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.42, green: 0.72, blue: 1.0))
                    .frame(width: 12)
                Text(ByteFormatter.formatRate(net.uploadBytesPerSecond))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.30, green: 0.84, blue: 0.78))
                    .frame(width: 12)
                Text(ByteFormatter.formatRate(net.downloadBytesPerSecond))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Full-Width Disk Card

    private func diskCard(
        disk: SystemTelemetryEngine.DiskBreakdown,
        diskFreeBytes: UInt64,
        usedRatio: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 11, weight: .medium))
                        Text("\(disk.volumeName)(\(ByteFormatter.format(disk.totalBytes)))")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(labelColor)

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ByteFormatter.format(diskFreeBytes))
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .monospacedDigit()

                        Text("available")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(labelColor.opacity(0.85))
                    }
                }

                Spacer()

                Button {
                    openMainApp(section: .junkCleaner)
                    if viewModel.junkItems.isEmpty && !viewModel.isScanningJunk {
                        viewModel.startJunkScan()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(accentBlue)
                            .frame(width: 34, height: 34)
                            .shadow(color: accentBlue.opacity(0.45), radius: 6, y: 2)

                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .help("Open Junk Cleaner")
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(0.28))

                    Capsule()
                        .fill(usedRatio > 0.9 ? Color.red : Color(red: 0.24, green: 0.62, blue: 1.0))
                        .frame(width: max(8, geo.size.width * usedRatio))
                }
            }
            .frame(height: 6)
        }
        .padding(12)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        HStack {
            Button {
                telemetry.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .help("Refresh Telemetry")

            Spacer()

            Button {
                openMainApp(section: nil)
            } label: {
                Text("Open SystemCleaner")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(accentBlue, in: Capsule())
                    .shadow(color: accentBlue.opacity(0.35), radius: 6, y: 2)
            }
            .buttonStyle(.plain)

            Spacer()

            Menu {
                Toggle("Show RAM in Menu Bar", isOn: $viewModel.showRAMInMenuBar)

                Divider()

                Button("Open Maintenance & Helper") {
                    openMainApp(section: .maintenance)
                }

                Button("Full Disk Access Settings") {
                    PrivacyPermissionCoordinator.openSystemSettingsFullDiskAccess()
                }

                Divider()

                Button("Quit SystemCleaner", role: .destructive) {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.9))

                    if daemonManager.status == .enabled {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -1)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Widget Options")
        }
    }

    private func openMainApp(section: SidebarSection?) {
        if let section {
            viewModel.selectedSection = section
        }
        dismiss()
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
