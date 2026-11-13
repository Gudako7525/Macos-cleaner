//
//  ContentView.swift
//  SystemCleaner
//
//  Main NavigationSplitView shell connecting Dashboard, Junk Cleaner, Large Files,
//  Duplicates, App Uninstaller, and System Maintenance.
//

import SwiftUI

public struct ContentView: View {
    @ObservedObject var viewModel: CleanerViewModel

    public init(viewModel: CleanerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $viewModel.selectedSection) { section in
                HStack {
                    Label(section.rawValue, systemImage: section.icon)
                    Spacer()
                    if section == .junkCleaner, viewModel.totalJunkBytes > 0 {
                        Text(ByteFormatter.format(viewModel.totalJunkBytes))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 250)
        } detail: {
            Group {
                switch viewModel.selectedSection {
                case .dashboard:
                    DashboardView(
                        viewModel: viewModel,
                        telemetry: viewModel.telemetry,
                        daemonManager: viewModel.daemonManager
                    )
                case .junkCleaner:
                    JunkCleanerView(viewModel: viewModel)
                case .largeFiles:
                    LargeFilesView(viewModel: viewModel)
                case .duplicates:
                    DuplicatesView(viewModel: viewModel)
                case .uninstaller:
                    UninstallerView(viewModel: viewModel)
                case .maintenance:
                    MaintenanceView(
                        viewModel: viewModel,
                        daemonManager: viewModel.daemonManager
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 920, minHeight: 620)
        .onAppear {
            viewModel.telemetry.startPolling()
            viewModel.refreshPermissionsAndDaemon()
        }
        .onDisappear {
            viewModel.telemetry.stopPolling()
        }
    }
}
