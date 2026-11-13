//
//  AppMain.swift
//  SystemCleaner
//
//  Main application entrypoint hosting the primary window and top menu bar widget.
//

import SwiftUI

@main
struct SystemCleanerApp: App {
    @StateObject private var viewModel = CleanerViewModel()

    var body: some Scene {
        WindowGroup("SystemCleaner", id: "main") {
            ContentView(viewModel: viewModel)
        }
        .defaultSize(width: 1020, height: 680)

        MenuBarExtra {
            MenuBarWidgetView(
                viewModel: viewModel,
                telemetry: viewModel.telemetry,
                daemonManager: viewModel.daemonManager
            )
        } label: {
            MenuBarStatusLabel(
                telemetry: viewModel.telemetry,
                showRAM: viewModel.showRAMInMenuBar
            )
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarStatusLabel: View {
    @ObservedObject var telemetry: SystemTelemetryEngine
    let showRAM: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "speedometer")
            if showRAM, telemetry.snapshot.memoryTotalBytes > 0 {
                Text(ByteFormatter.formatMemory(telemetry.snapshot.memoryUsedBytes))
                    .font(.caption.monospacedDigit())
            }
        }
        .onAppear {
            if showRAM {
                telemetry.startPolling()
            }
        }
    }
}
