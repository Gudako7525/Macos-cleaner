//
//  AppRemnantScanner.swift
//  SystemCleaner
//
//  Discovers installed apps, locates scattered application remnants, and finds orphaned leftovers.
//

import Foundation

public struct AppRemnantScanner {
    public static func scanRemnants(bundleIdentifier: String, appName: String) -> [URL] {
        scanDetailedRemnants(bundleIdentifier: bundleIdentifier, appName: appName).map(\.url)
    }

    public static func scanDetailedRemnants(bundleIdentifier: String, appName: String) -> [RemnantItem] {
        guard !bundleIdentifier.isEmpty || !appName.isEmpty else { return [] }
        let fileManager = FileManager.default
        var matches: [RemnantItem] = []
        var seenPaths = Set<String>()

        guard let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return []
        }

        let cleanName = appName.replacingOccurrences(of: ".app", with: "")
        var searchMatrices: [(String, String, String)] = []

        if !cleanName.isEmpty {
            searchMatrices.append(contentsOf: [
                ("Application Support", cleanName, "Application Support"),
                ("Caches", cleanName, "Cache"),
                ("Logs", cleanName, "Logs"),
                ("Application Support/CrashReporter", cleanName, "Crash Reports")
            ])
        }

        if !bundleIdentifier.isEmpty {
            searchMatrices.append(contentsOf: [
                ("Application Support", bundleIdentifier, "Application Support"),
                ("Preferences", "\(bundleIdentifier).plist", "Preferences"),
                ("Containers", bundleIdentifier, "Sandbox Container"),
                ("Caches", bundleIdentifier, "Cache"),
                ("Saved Application State", "\(bundleIdentifier).savedState", "Saved State"),
                ("WebKit", bundleIdentifier, "WebKit Data"),
                ("HTTPStorages", bundleIdentifier, "HTTP Storage"),
                ("Logs", bundleIdentifier, "Logs"),
                ("Cookies", "\(bundleIdentifier).binarycookies", "Cookies")
            ])
        }

        for (subDirectory, pattern, kind) in searchMatrices {
            let targetDir = libraryURL.appendingPathComponent(subDirectory, isDirectory: true)
            let candidate = targetDir.appendingPathComponent(pattern)

            if fileManager.fileExists(atPath: candidate.path), seenPaths.insert(candidate.path).inserted {
                let size = AsyncDiskScanner.computeRecursiveSize(at: candidate)
                matches.append(RemnantItem(url: candidate, kind: kind, byteSize: size, isSelected: true))
            }
        }

        if !bundleIdentifier.isEmpty {
            // Scan Group Containers for shared group app remnants
            let groupContainersURL = libraryURL.appendingPathComponent("Group Containers", isDirectory: true)
            if let enumerator = fileManager.enumerator(
                at: groupContainersURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsSubdirectoryDescendants]
            ) {
                for case let folderURL as URL in enumerator {
                    if folderURL.lastPathComponent.contains(bundleIdentifier),
                       seenPaths.insert(folderURL.path).inserted {
                        let size = AsyncDiskScanner.computeRecursiveSize(at: folderURL)
                        matches.append(RemnantItem(url: folderURL, kind: "Group Container", byteSize: size, isSelected: true))
                    }
                }
            }

            // Scan ByHost preferences
            let byHostURL = libraryURL.appendingPathComponent("Preferences/ByHost", isDirectory: true)
            if let contents = try? fileManager.contentsOfDirectory(at: byHostURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for fileURL in contents where fileURL.lastPathComponent.hasPrefix(bundleIdentifier) {
                    if seenPaths.insert(fileURL.path).inserted {
                        let size = AsyncDiskScanner.computeRecursiveSize(at: fileURL)
                        matches.append(RemnantItem(url: fileURL, kind: "ByHost Preferences", byteSize: size, isSelected: true))
                    }
                }
            }

            // Scan user LaunchAgents
            let launchAgentsURL = libraryURL.appendingPathComponent("LaunchAgents", isDirectory: true)
            if let contents = try? fileManager.contentsOfDirectory(at: launchAgentsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for fileURL in contents where fileURL.lastPathComponent.contains(bundleIdentifier) {
                    if seenPaths.insert(fileURL.path).inserted {
                        let size = AsyncDiskScanner.computeRecursiveSize(at: fileURL)
                        matches.append(RemnantItem(url: fileURL, kind: "Launch Agent", byteSize: size, isSelected: true))
                    }
                }
            }
        }

        return matches.sorted { $0.byteSize > $1.byteSize }
    }

    /// Discovers third-party / user-installed applications in /Applications and ~/Applications
    public static func discoverInstalledApps() async -> [InstalledAppItem] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let homeApps = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            let searchRoots = [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                homeApps
            ]

            var apps: [InstalledAppItem] = []
            var seenBundlePaths = Set<String>()

            for root in searchRoots where fm.fileExists(atPath: root.path) {
                guard let contents = try? fm.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for entry in contents {
                    if entry.pathExtension.lowercased() == "app" {
                        if seenBundlePaths.insert(entry.path).inserted,
                           let appItem = buildInstalledAppItem(from: entry) {
                            apps.append(appItem)
                        }
                    } else {
                        // Check 1 level deeper (e.g. /Applications/Utilities)
                        let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        if isDir,
                           let subContents = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                            for subEntry in subContents where subEntry.pathExtension.lowercased() == "app" {
                                if seenBundlePaths.insert(subEntry.path).inserted,
                                   let appItem = buildInstalledAppItem(from: subEntry) {
                                    apps.append(appItem)
                                }
                            }
                        }
                    }
                }
            }

            return apps.sorted { $0.bundleSize > $1.bundleSize }
        }.value
    }

    private static func buildInstalledAppItem(from appURL: URL) -> InstalledAppItem? {
        guard let bundle = Bundle(url: appURL) else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let displayName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let bundleId = bundle.bundleIdentifier ?? ""
        let version = (info["CFBundleShortVersionString"] as? String) ?? "1.0"
        let bundleSize = AsyncDiskScanner.computeRecursiveSize(at: appURL)

        return InstalledAppItem(
            name: displayName,
            bundleIdentifier: bundleId,
            version: version,
            bundleURL: appURL,
            bundleSize: bundleSize
        )
    }

    /// Scans ~/Library/Application Support, Caches, Containers, and Saved Application State
    /// for leftover folders that don't match any currently installed app.
    public static func scanOrphanedRemnants(installedApps: [InstalledAppItem]) async -> [RemnantItem] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard let libraryURL = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else {
                return []
            }

            let installedBundleIDs = Set(installedApps.map { $0.bundleIdentifier.lowercased() }.filter { !$0.isEmpty })
            let installedNames = Set(installedApps.map { $0.name.lowercased() })

            // Also include /System/Applications bundle IDs so we never flag Apple built-in app data
            var systemPrefixes: Set<String> = [
                "com.apple.", "apple", "icloud", "cloudkit", "group.com.apple.",
                "syncservices", "crashreporter", "addressbook", "calendars", "callhistory",
                "dock", "finder", "mail", "messages", "mobilesync", "safari", "spotlight",
                "system", "google", "mozilla", "microsoft", "adobe", "jetbrains"
            ]
            if let sysApps = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/System/Applications"), includingPropertiesForKeys: nil) {
                for app in sysApps where app.pathExtension == "app" {
                    if let bid = Bundle(url: app)?.bundleIdentifier?.lowercased() {
                        systemPrefixes.insert(bid)
                    }
                }
            }

            let candidateDirs: [(subDir: String, kind: String)] = [
                ("Application Support", "Orphaned App Support"),
                ("Containers", "Orphaned Container"),
                ("Saved Application State", "Orphaned Saved State")
            ]

            var orphans: [RemnantItem] = []

            for (subDir, kind) in candidateDirs {
                let dirURL = libraryURL.appendingPathComponent(subDir, isDirectory: true)
                guard let entries = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                    continue
                }

                for entry in entries {
                    if Task.isCancelled { return orphans }
                    let rawName = entry.lastPathComponent
                    let normalized = rawName
                        .replacingOccurrences(of: ".savedState", with: "")
                        .lowercased()

                    // Skip Apple/system/runtime shared folders
                    if systemPrefixes.contains(where: { normalized.hasPrefix($0) || normalized == $0 }) {
                        continue
                    }

                    // Match against installed bundle IDs or names
                    let isInstalled = installedBundleIDs.contains(where: { bid in
                        normalized == bid || normalized.contains(bid) || bid.contains(normalized)
                    }) || installedNames.contains(where: { name in
                        !name.isEmpty && (normalized == name || normalized.contains(name))
                    })

                    guard !isInstalled else { continue }

                    let size = AsyncDiskScanner.computeRecursiveSize(at: entry)
                    if size > 1024 {
                        orphans.append(RemnantItem(url: entry, kind: kind, byteSize: size, isSelected: false))
                    }
                }
            }

            return orphans.sorted { $0.byteSize > $1.byteSize }
        }.value
    }
}
