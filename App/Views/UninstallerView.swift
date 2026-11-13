//
//  UninstallerView.swift
//  SystemCleaner
//
//  Application uninstaller with remnant discovery and orphaned leftovers scanner.
//

import SwiftUI

struct UninstallerView: View {
    @ObservedObject var viewModel: CleanerViewModel
    @State private var mode: UninstallerMode = .installedApps
    @State private var searchText = ""
    @State private var showUninstallConfirmation = false
    @State private var showOrphanTrashConfirmation = false

    enum UninstallerMode: String, CaseIterable {
        case installedApps = "Installed Apps"
        case orphanedLeftovers = "Orphaned Remnants"
    }

    private var filteredApps: [InstalledAppItem] {
        viewModel.installedApps.filter {
            searchText.isEmpty ||
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var selectedApp: InstalledAppItem? {
        guard let id = viewModel.selectedAppID else { return nil }
        return viewModel.installedApps.first(where: { $0.id == id })
    }

    private var selectedOrphanBytes: UInt64 {
        viewModel.orphanedRemnants.filter(\.isSelected).reduce(0) { $0 + $1.byteSize }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            if mode == .installedApps {
                installedAppsView
            } else {
                orphansView
            }

            if let message = viewModel.uninstallerStatusMessage {
                Divider()
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text(message)
                        .font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .navigationTitle("Uninstaller")
        .task {
            if viewModel.installedApps.isEmpty {
                await viewModel.loadInstalledApps()
            }
        }
        .confirmationDialog("Uninstall \(selectedApp?.name ?? "App")?", isPresented: $showUninstallConfirmation, titleVisibility: .visible) {
            if let app = selectedApp {
                let selectedRemnantBytes = app.remnants.filter(\.isSelected).reduce(0) { $0 + $1.byteSize }
                Button("Move App & Remnants (\(ByteFormatter.format(app.bundleSize + selectedRemnantBytes))) to Trash", role: .destructive) {
                    Task { await viewModel.uninstallApp(id: app.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The application bundle and all checked Library support files will be moved to Trash.")
        }
        .confirmationDialog("Remove Selected Orphaned Remnants?", isPresented: $showOrphanTrashConfirmation, titleVisibility: .visible) {
            Button("Move \(ByteFormatter.format(selectedOrphanBytes)) to Trash", role: .destructive) {
                Task { await viewModel.trashSelectedOrphans() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: $mode) {
                ForEach(UninstallerMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            Spacer()

            if mode == .installedApps {
                TextField("Search apps...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)

                Button {
                    Task { await viewModel.loadInstalledApps() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isLoadingApps)
            } else {
                Button {
                    Task { await viewModel.scanOrphans() }
                } label: {
                    Label("Scan Leftovers", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isScanningOrphans)

                Button {
                    showOrphanTrashConfirmation = true
                } label: {
                    Label("Move to Trash (\(ByteFormatter.format(selectedOrphanBytes)))", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedOrphanBytes == 0)
            }
        }
        .padding(14)
    }

    private var installedAppsView: some View {
        Group {
            if viewModel.isLoadingApps && viewModel.installedApps.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView("Scanning installed applications...")
                    Spacer()
                }
            } else if viewModel.installedApps.isEmpty {
                ContentUnavailableView("No Applications Found", systemImage: "app.dashed")
            } else {
                HSplitView {
                    List(filteredApps, selection: $viewModel.selectedAppID) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path))
                                .resizable()
                                .frame(width: 28, height: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text("v\(app.version)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(ByteFormatter.format(app.bundleSize))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .tag(app.id)
                    }
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 340)
                    .onChange(of: viewModel.selectedAppID) { _, newID in
                        if let id = newID {
                            viewModel.scanRemnantsForApp(id: id)
                        }
                    }

                    appDetailPane
                        .frame(minWidth: 380)
                }
            }
        }
    }

    @ViewBuilder
    private var appDetailPane: some View {
        if let app = selectedApp {
            let selectedRemnantBytes = app.remnants.filter(\.isSelected).reduce(0) { $0 + $1.byteSize }
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path))
                        .resizable()
                        .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name)
                            .font(.title3.bold())
                        Text(app.bundleIdentifier.isEmpty ? app.bundleURL.path : app.bundleIdentifier)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Total Footprint: \(ByteFormatter.format(app.bundleSize + selectedRemnantBytes))")
                            .font(.caption.weight(.medium))
                    }

                    Spacer()

                    Button {
                        CleanActionService.revealInFinder(app.bundleURL)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .help("Reveal App in Finder")

                    Button(role: .destructive) {
                        showUninstallConfirmation = true
                    } label: {
                        Label("Uninstall", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding(16)

                Divider()

                List {
                    Section("Application Bundle") {
                        HStack {
                            Image(systemName: "checkmark.square.fill")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading) {
                                Text(app.bundleURL.lastPathComponent)
                                    .font(.subheadline.weight(.medium))
                                Text(app.bundleURL.path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ByteFormatter.format(app.bundleSize))
                                .font(.subheadline.monospacedDigit())
                        }
                    }

                    Section("Related Library Remnants (\(app.remnants.count))") {
                        if !app.hasScannedRemnants {
                            ProgressView("Locating app support files...")
                        } else if app.remnants.isEmpty {
                            Text("No Library remnants found for this app.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(app.remnants) { remnant in
                                HStack(spacing: 10) {
                                    Button {
                                        viewModel.toggleRemnant(appID: app.id, remnantID: remnant.id)
                                    } label: {
                                        Image(systemName: remnant.isSelected ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(remnant.isSelected ? Color.accentColor : Color.secondary)
                                    }
                                    .buttonStyle(.plain)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(remnant.url.lastPathComponent)
                                                .font(.subheadline)
                                                .lineLimit(1)
                                            Text(remnant.kind)
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(.quaternary, in: Capsule())
                                        }
                                        Text(remnant.url.path)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    Spacer()

                                    Text(ByteFormatter.format(remnant.byteSize))
                                        .font(.caption.monospacedDigit())

                                    Button {
                                        CleanActionService.revealInFinder(remnant.url)
                                    } label: {
                                        Image(systemName: "magnifyingglass.circle")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("Select an Application", systemImage: "cursorarrow.click")
        }
    }

    private var orphansView: some View {
        Group {
            if viewModel.isScanningOrphans {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView("Scanning ~/Library for orphaned remnants...")
                    Spacer()
                }
            } else if viewModel.orphanedRemnants.isEmpty {
                ContentUnavailableView {
                    Label("Orphaned Remnants Scanner", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Find leftover folders in Application Support, Containers, and Saved Application State left behind by uninstalled apps.")
                } actions: {
                    Button("Scan Leftovers") {
                        Task { await viewModel.scanOrphans() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List(viewModel.orphanedRemnants) { item in
                    HStack(spacing: 10) {
                        Button {
                            viewModel.toggleOrphan(item.id)
                        } label: {
                            Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.url.lastPathComponent)
                                    .font(.subheadline.weight(.medium))
                                Text(item.kind)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                            Text(item.url.path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Text(ByteFormatter.format(item.byteSize))
                            .font(.subheadline.monospacedDigit())

                        Button {
                            CleanActionService.revealInFinder(item.url)
                        } label: {
                            Image(systemName: "magnifyingglass.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}
