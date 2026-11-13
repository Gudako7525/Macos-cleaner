//
//  CleanerViewModel.swift
//  SystemCleaner
//
//  Centralized application state coordinating scans, selections, and cleaning actions.
//

import Foundation
import SwiftUI
import Darwin

@MainActor
public final class CleanerViewModel: ObservableObject {
    public let telemetry = SystemTelemetryEngine()
    public let daemonManager = DaemonManager.shared

    private let diskScanner = AsyncDiskScanner()
    private let duplicateEngine = DuplicateDetectionEngine()

    @Published public var selectedSection: SidebarSection = .dashboard
    @Published public var fullDiskAccess: TCCAccessStatus = .denied
    @Published public var totalSessionReclaimedBytes: UInt64 = 0

    // MARK: - Junk Cleaner State
    @Published public var junkItems: [JunkItem] = []
    @Published public var isScanningJunk = false
    @Published public var isCleaningJunk = false
    @Published public var junkScanProgressPath = ""
    @Published public var junkStatusMessage: String?
    private var junkScanTask: Task<Void, Never>?

    // MARK: - Large Files State
    @Published public var largeFiles: [LargeFileItem] = []
    @Published public var isScanningLargeFiles = false
    @Published public var largeFilesProgressText = ""
    @Published public var largeFilesThresholdMB: Int = 100
    @Published public var largeFilesScopeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    @Published public var largeFilesStatusMessage: String?
    private var largeFilesTask: Task<Void, Never>?

    // MARK: - Duplicates State
    @Published public var duplicateGroups: [DuplicateGroup] = []
    @Published public var isScanningDuplicates = false
    @Published public var duplicateProgress: DuplicateScanProgress?
    @Published public var duplicateRoots: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
    ]
    @Published public var duplicateMinSizeKB: Int = 100
    @Published public var duplicatesStatusMessage: String?
    private var duplicateScanTask: Task<Void, Never>?

    // MARK: - Uninstaller State
    @Published public var installedApps: [InstalledAppItem] = []
    @Published public var isLoadingApps = false
    @Published public var selectedAppID: UUID?
    @Published public var orphanedRemnants: [RemnantItem] = []
    @Published public var isScanningOrphans = false
    @Published public var uninstallerStatusMessage: String?

    // MARK: - Maintenance & RAM Cleanup State
    @Published public var runningMaintenanceID: String?
    @Published public var maintenanceStatusMessage: String?
    @Published public var maintenanceLastSuccess: Bool = true
    @Published public var isCleaningRAM = false
    @Published public var ramCleanupStatusMessage: String?
    @Published public var ramCleanupLastSuccess: Bool = true
    @Published public var lastFreedRAMBytes: UInt64 = 0
    @Published public var showRAMInMenuBar: Bool = UserDefaults.standard.bool(forKey: "showRAMInMenuBar") {
        didSet {
            UserDefaults.standard.set(showRAMInMenuBar, forKey: "showRAMInMenuBar")
        }
    }

    public init() {
        refreshPermissionsAndDaemon()
    }

    public func refreshPermissionsAndDaemon() {
        fullDiskAccess = PrivacyPermissionCoordinator.verifyFullDiskAccess()
        daemonManager.syncStatus()
    }

    // MARK: - Junk Cleaner Computed & Actions

    public var totalSelectedJunkBytes: UInt64 {
        junkItems.filter(\.isSelected).reduce(0) { $0 + $1.byteSize }
    }

    public var totalJunkBytes: UInt64 {
        junkItems.reduce(0) { $0 + $1.byteSize }
    }

    public func items(for category: JunkCategory) -> [JunkItem] {
        junkItems.filter { $0.category == category }
    }

    public func startJunkScan() {
        junkScanTask?.cancel()
        isScanningJunk = true
        junkItems = []
        junkStatusMessage = nil
        junkScanProgressPath = "Starting scan..."

        junkScanTask = Task { [weak self] in
            guard let self else { return }
            var collected: [JunkItem] = []
            for category in JunkCategory.allCases {
                if Task.isCancelled { break }
                do {
                    let found = try await self.diskScanner.scanJunkCategory(category) { [weak self] path in
                        Task { @MainActor [weak self] in
                            self?.junkScanProgressPath = path
                        }
                    }
                    collected.append(contentsOf: found)
                    self.junkItems = collected
                } catch is CancellationError {
                    break
                } catch {
                    continue
                }
            }
            self.isScanningJunk = false
            self.junkScanProgressPath = ""
            if collected.isEmpty {
                self.junkStatusMessage = "No reclaimable junk items found."
            } else {
                self.junkStatusMessage = "Found \(collected.count) items totaling \(ByteFormatter.format(self.totalJunkBytes))."
            }
        }
    }

    public func cancelJunkScan() {
        junkScanTask?.cancel()
        isScanningJunk = false
        junkScanProgressPath = ""
    }

    public func toggleJunkItem(_ id: UUID) {
        guard let idx = junkItems.firstIndex(where: { $0.id == id }) else { return }
        junkItems[idx].isSelected.toggle()
    }

    public func setCategorySelected(_ category: JunkCategory, selected: Bool) {
        for idx in junkItems.indices where junkItems[idx].category == category {
            junkItems[idx].isSelected = selected
        }
    }

    public func cleanSelectedJunk(permanentlyEmptyTrash: Bool = true) async {
        let selected = junkItems.filter(\.isSelected)
        guard !selected.isEmpty else { return }

        isCleaningJunk = true
        let trashItems = selected.filter { $0.category == .userTrash }.map { ($0.url, $0.byteSize) }
        let nonTrashItems = selected.filter { $0.category != .userTrash }.map { ($0.url, $0.byteSize) }

        var totalRemoved = 0
        var totalFreed: UInt64 = 0
        var allFailures: [CleanFailure] = []

        if !nonTrashItems.isEmpty {
            let res = await CleanActionService.moveToTrash(nonTrashItems)
            totalRemoved += res.removedCount
            totalFreed += res.freedBytes
            allFailures.append(contentsOf: res.failures)
        }

        if !trashItems.isEmpty {
            if permanentlyEmptyTrash {
                let res = await CleanActionService.permanentlyDelete(trashItems, allowPrivilegedHelper: true)
                totalRemoved += res.removedCount
                totalFreed += res.freedBytes
                allFailures.append(contentsOf: res.failures)
            }
        }

        let failedURLs = Set(allFailures.map(\.url))
        junkItems.removeAll { $0.isSelected && !failedURLs.contains($0.url) }
        totalSessionReclaimedBytes += totalFreed

        let combined = CleanResult(removedCount: totalRemoved, freedBytes: totalFreed, failures: allFailures)
        junkStatusMessage = combined.summaryMessage
        isCleaningJunk = false
        telemetry.refreshNow()
    }

    // MARK: - Large Files Actions

    public func startLargeFilesScan() {
        largeFilesTask?.cancel()
        isScanningLargeFiles = true
        largeFiles = []
        largeFilesStatusMessage = nil
        largeFilesProgressText = "Scanning \(largeFilesScopeURL.lastPathComponent)..."

        let scope = largeFilesScopeURL
        let minBytes = UInt64(largeFilesThresholdMB) * 1024 * 1024

        largeFilesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await self.diskScanner.scanLargeFiles(in: [scope], minimumBytes: minBytes) { [weak self] path, count in
                    Task { @MainActor [weak self] in
                        self?.largeFilesProgressText = "Scanned \(count) files — \(path)"
                    }
                }
                self.largeFiles = results
                self.largeFilesStatusMessage = results.isEmpty
                    ? "No files larger than \(self.largeFilesThresholdMB) MB found."
                    : "Found \(results.count) large file(s) totaling \(ByteFormatter.format(results.reduce(0) { $0 + $1.byteSize }))."
            } catch is CancellationError {
                self.largeFilesStatusMessage = "Scan cancelled."
            } catch {
                self.largeFilesStatusMessage = "Scan error: \(error.localizedDescription)"
            }
            self.isScanningLargeFiles = false
            self.largeFilesProgressText = ""
        }
    }

    public func cancelLargeFilesScan() {
        largeFilesTask?.cancel()
        isScanningLargeFiles = false
        largeFilesProgressText = ""
    }

    public func toggleLargeFile(_ id: UUID) {
        guard let idx = largeFiles.firstIndex(where: { $0.id == id }) else { return }
        largeFiles[idx].isSelected.toggle()
    }

    public func trashSelectedLargeFiles() async {
        let selected = largeFiles.filter(\.isSelected).map { ($0.url, $0.byteSize) }
        guard !selected.isEmpty else { return }

        let result = await CleanActionService.moveToTrash(selected)
        let failedURLs = Set(result.failures.map(\.url))
        largeFiles.removeAll { $0.isSelected && !failedURLs.contains($0.url) }
        totalSessionReclaimedBytes += result.freedBytes
        largeFilesStatusMessage = result.summaryMessage
        telemetry.refreshNow()
    }

    // MARK: - Duplicates Actions

    public var totalSelectedDuplicateBytes: UInt64 {
        duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    public func startDuplicateScan() {
        duplicateScanTask?.cancel()
        isScanningDuplicates = true
        duplicateGroups = []
        duplicatesStatusMessage = nil

        let roots = duplicateRoots
        let minBytes = UInt64(duplicateMinSizeKB) * 1024

        duplicateScanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let groups = try await self.duplicateEngine.findDuplicates(in: roots, minimumBytes: minBytes) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.duplicateProgress = progress
                    }
                }
                self.duplicateGroups = groups
                if groups.isEmpty {
                    self.duplicatesStatusMessage = "No duplicate files found."
                } else {
                    let wasted = groups.reduce(0) { $0 + $1.totalWastedBytes }
                    self.duplicatesStatusMessage = "Found \(groups.count) duplicate group(s) wasting \(ByteFormatter.format(wasted))."
                }
            } catch is CancellationError {
                self.duplicatesStatusMessage = "Duplicate scan cancelled."
            } catch {
                self.duplicatesStatusMessage = "Scan failed: \(error.localizedDescription)"
            }
            self.isScanningDuplicates = false
        }
    }

    public func cancelDuplicateScan() {
        duplicateScanTask?.cancel()
        isScanningDuplicates = false
    }

    public func toggleDuplicateFile(groupID: UUID, fileID: UUID) {
        guard let gIdx = duplicateGroups.firstIndex(where: { $0.id == groupID }),
              let fIdx = duplicateGroups[gIdx].files.firstIndex(where: { $0.id == fileID }) else { return }
        duplicateGroups[gIdx].files[fIdx].isSelected.toggle()
    }

    public func autoSelectDuplicates(keepNewest: Bool) {
        for gIdx in duplicateGroups.indices {
            let sorted = duplicateGroups[gIdx].files.sorted {
                keepNewest ? ($0.modifiedDate > $1.modifiedDate) : ($0.modifiedDate < $1.modifiedDate)
            }
            duplicateGroups[gIdx].files = sorted.enumerated().map { idx, file in
                var copy = file
                copy.isSelected = idx > 0
                return copy
            }
        }
    }

    public func trashSelectedDuplicates() async {
        var targets: [(url: URL, knownSize: UInt64)] = []
        for group in duplicateGroups {
            for file in group.files where file.isSelected {
                targets.append((file.url, group.byteSize))
            }
        }
        guard !targets.isEmpty else { return }

        let result = await CleanActionService.moveToTrash(targets)
        let failedURLs = Set(result.failures.map(\.url))

        for gIdx in duplicateGroups.indices {
            duplicateGroups[gIdx].files.removeAll { $0.isSelected && !failedURLs.contains($0.url) }
        }
        duplicateGroups.removeAll { $0.files.count < 2 }

        totalSessionReclaimedBytes += result.freedBytes
        duplicatesStatusMessage = result.summaryMessage
        telemetry.refreshNow()
    }

    // MARK: - Uninstaller Actions

    public func loadInstalledApps() async {
        guard !isLoadingApps else { return }
        isLoadingApps = true
        installedApps = await AppRemnantScanner.discoverInstalledApps()
        if selectedAppID == nil {
            selectedAppID = installedApps.first?.id
        }
        if let firstID = selectedAppID {
            scanRemnantsForApp(id: firstID)
        }
        isLoadingApps = false
    }

    public func scanRemnantsForApp(id: UUID) {
        guard let idx = installedApps.firstIndex(where: { $0.id == id }) else { return }
        if installedApps[idx].hasScannedRemnants { return }
        let app = installedApps[idx]
        Task {
            let remnants = await Task.detached(priority: .userInitiated) {
                AppRemnantScanner.scanDetailedRemnants(
                    bundleIdentifier: app.bundleIdentifier,
                    appName: app.name
                )
            }.value
            if let currentIdx = installedApps.firstIndex(where: { $0.id == id }) {
                installedApps[currentIdx].remnants = remnants
                installedApps[currentIdx].hasScannedRemnants = true
            }
        }
    }

    public func toggleRemnant(appID: UUID, remnantID: UUID) {
        guard let aIdx = installedApps.firstIndex(where: { $0.id == appID }),
              let rIdx = installedApps[aIdx].remnants.firstIndex(where: { $0.id == remnantID }) else { return }
        installedApps[aIdx].remnants[rIdx].isSelected.toggle()
    }

    public func uninstallApp(id: UUID) async {
        guard let idx = installedApps.firstIndex(where: { $0.id == id }) else { return }
        let app = installedApps[idx]
        var itemsToTrash: [(url: URL, knownSize: UInt64)] = [(app.bundleURL, app.bundleSize)]
        for rem in app.remnants where rem.isSelected {
            itemsToTrash.append((rem.url, rem.byteSize))
        }

        let result = await CleanActionService.moveToTrash(itemsToTrash)
        totalSessionReclaimedBytes += result.freedBytes

        if !FileManager.default.fileExists(atPath: app.bundleURL.path) {
            installedApps.removeAll { $0.id == id }
            selectedAppID = installedApps.first?.id
        }
        uninstallerStatusMessage = result.summaryMessage
        telemetry.refreshNow()
    }

    public func scanOrphans() async {
        isScanningOrphans = true
        if installedApps.isEmpty {
            installedApps = await AppRemnantScanner.discoverInstalledApps()
        }
        orphanedRemnants = await AppRemnantScanner.scanOrphanedRemnants(installedApps: installedApps)
        isScanningOrphans = false
    }

    public func toggleOrphan(_ id: UUID) {
        guard let idx = orphanedRemnants.firstIndex(where: { $0.id == id }) else { return }
        orphanedRemnants[idx].isSelected.toggle()
    }

    public func trashSelectedOrphans() async {
        let selected = orphanedRemnants.filter(\.isSelected).map { ($0.url, $0.byteSize) }
        guard !selected.isEmpty else { return }

        let result = await CleanActionService.moveToTrash(selected)
        let failedURLs = Set(result.failures.map(\.url))
        orphanedRemnants.removeAll { $0.isSelected && !failedURLs.contains($0.url) }
        totalSessionReclaimedBytes += result.freedBytes
        uninstallerStatusMessage = result.summaryMessage
    }

    // MARK: - RAM Cleanup & Maintenance Actions

    public func cleanRAM(allowAdminPrompt: Bool = false) async {
        guard !isCleaningRAM else { return }
        isCleaningRAM = true
        ramCleanupStatusMessage = "Optimizing RAM..."
        telemetry.refreshNow()
        let beforeMem = telemetry.snapshot.memory

        // Always perform fast, passwordless user-space VM pressure reclamation first
        await MaintenanceService.reclaimUserSpaceMemory()

        var outcome = MaintenanceService.Outcome(success: true, message: "Memory optimized.")
        daemonManager.syncStatus()
        if daemonManager.status == .enabled || allowAdminPrompt {
            if let purgeTask = MaintenanceTaskInfo.allTasks.first(where: { $0.id == MaintenanceRoutines.purgeRAM }) {
                outcome = await MaintenanceService.run(purgeTask, allowAdminPromptFallback: allowAdminPrompt)
            }
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        telemetry.refreshNow()
        let afterMem = telemetry.snapshot.memory

        let usedDrop = beforeMem.usedBytes > afterMem.usedBytes ? (beforeMem.usedBytes - afterMem.usedBytes) : 0
        let freeGain = afterMem.freeBytes > beforeMem.freeBytes ? (afterMem.freeBytes - beforeMem.freeBytes) : 0
        let cacheDrop = beforeMem.cachedFilesBytes > afterMem.cachedFilesBytes ? (beforeMem.cachedFilesBytes - afterMem.cachedFilesBytes) : 0
        let freed = max(usedDrop, max(freeGain, cacheDrop))

        lastFreedRAMBytes = freed
        ramCleanupLastSuccess = outcome.success
        if outcome.success {
            if freed > 1_048_576 {
                ramCleanupStatusMessage = "Freed \(ByteFormatter.formatMemory(freed)) of RAM"
            } else {
                ramCleanupStatusMessage = "RAM optimized (inactive cache cleared)"
            }
        } else {
            ramCleanupStatusMessage = outcome.message
        }

        isCleaningRAM = false
    }

    public func runMaintenance(_ task: MaintenanceTaskInfo) async {
        runningMaintenanceID = task.id
        maintenanceStatusMessage = nil
        let outcome = await MaintenanceService.run(task)
        maintenanceLastSuccess = outcome.success
        maintenanceStatusMessage = outcome.message
        runningMaintenanceID = nil
        telemetry.refreshNow()
    }

    public func registerDaemon() {
        do {
            try daemonManager.register()
            maintenanceLastSuccess = true
            if daemonManager.status == .requiresApproval {
                maintenanceStatusMessage = "Helper registered — approve SystemCleaner in System Settings → Login Items."
            } else {
                maintenanceStatusMessage = "Helper registered via SMAppService."
            }
        } catch {
            maintenanceLastSuccess = false
            maintenanceStatusMessage = "Helper registration requires a signed .app bundle: \(error.localizedDescription)"
        }
    }

    public func unregisterDaemon() async {
        do {
            try await daemonManager.unregister()
            maintenanceLastSuccess = true
            maintenanceStatusMessage = "Helper unregistered."
        } catch {
            maintenanceLastSuccess = false
            maintenanceStatusMessage = "Unregister failed: \(error.localizedDescription)"
        }
    }
}
