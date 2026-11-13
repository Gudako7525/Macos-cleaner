//
//  MaintenanceView.swift
//  SystemCleaner
//
//  macOS maintenance routines, SMAppService privileged daemon controls, and TCC permissions.
//

import SwiftUI
import ServiceManagement

struct MaintenanceView: View {
    @ObservedObject var viewModel: CleanerViewModel
    @ObservedObject var daemonManager: DaemonManager

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System Maintenance")
                        .font(.title2.bold())
                    Text("Run macOS maintenance routines via the SMAppService privileged helper or administrator authorization.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(MaintenanceTaskInfo.allTasks) { task in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: task.icon)
                                        .font(.title2)
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 28)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(task.title)
                                            .font(.headline)
                                        Text(task.requiresRoot ? "Privileged" : "User Domain")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }

                                Text(task.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                HStack {
                                    Spacer()
                                    Button {
                                        Task { await viewModel.runMaintenance(task) }
                                    } label: {
                                        if viewModel.runningMaintenanceID == task.id {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Text("Run")
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(viewModel.runningMaintenanceID != nil)
                                }
                            }
                            .padding(6)
                        }
                    }
                }

                if let statusMsg = viewModel.maintenanceStatusMessage {
                    HStack(spacing: 8) {
                        Image(systemName: viewModel.maintenanceLastSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(viewModel.maintenanceLastSuccess ? .green : .orange)
                        Text(statusMsg)
                            .font(.callout)
                        Spacer()
                    }
                    .padding(12)
                    .background(
                        (viewModel.maintenanceLastSuccess ? Color.green : Color.orange).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }

                GroupBox("Privileged Helper Daemon (com.cleaner.helper)") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Circle()
                                .fill(daemonManager.status == .enabled ? .green : (daemonManager.status == .requiresApproval ? .orange : .secondary))
                                .frame(width: 10, height: 10)
                            Text("Status: \(daemonManager.statusDescription)")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Button("Refresh") {
                                daemonManager.syncStatus()
                            }
                            .buttonStyle(.borderless)
                        }

                        Text("When the background daemon is registered and approved, privileged maintenance commands and root-owned deletions run seamlessly over authenticated NSXPCConnection without repeated password prompts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Button("Enable Helper") {
                                viewModel.registerDaemon()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(daemonManager.status == .enabled)

                            if daemonManager.status == .requiresApproval {
                                Button("Open Login Items Settings") {
                                    PrivacyPermissionCoordinator.openSystemSettingsLoginItems()
                                }
                                .buttonStyle(.bordered)
                            }

                            if daemonManager.status == .enabled || daemonManager.status == .requiresApproval {
                                Button("Unregister", role: .destructive) {
                                    Task { await viewModel.unregisterDaemon() }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(6)
                }

                GroupBox("Privacy & Full Disk Access") {
                    HStack {
                        Image(systemName: viewModel.fullDiskAccess == .granted ? "checkmark.shield.fill" : "lock.shield")
                            .font(.title2)
                            .foregroundStyle(viewModel.fullDiskAccess == .granted ? .green : .orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.fullDiskAccess == .granted ? "Full Disk Access Granted" : "Full Disk Access Not Granted")
                                .font(.subheadline.weight(.semibold))
                            Text("Allows inspecting protected Safari, Mail, and container caches.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Open System Settings") {
                            PrivacyPermissionCoordinator.openSystemSettingsFullDiskAccess()
                        }
                        .buttonStyle(.bordered)

                        Button("Re-check") {
                            viewModel.refreshPermissionsAndDaemon()
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(6)
                }
            }
            .padding(24)
        }
        .navigationTitle("Maintenance")
    }
}
