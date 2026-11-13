//
//  CleanerModels.swift
//  SystemCleaner
//
//  Core domain models and formatters used across the application.
//

import Foundation
import AppKit

public enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case dashboard = "Dashboard"
    case junkCleaner = "Junk Cleaner"
    case largeFiles = "Large Files"
    case duplicates = "Duplicates"
    case uninstaller = "Uninstaller"
    case maintenance = "Maintenance"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.bottom.50percent"
        case .junkCleaner: return "sparkles"
        case .largeFiles: return "doc.badge.ellipsis"
        case .duplicates: return "doc.on.doc"
        case .uninstaller: return "trash.square"
        case .maintenance: return "wrench.and.screwdriver"
        }
    }
}

public enum JunkCategory: String, CaseIterable, Identifiable, Sendable {
    case userCaches = "User App Caches"
    case applicationLogs = "Logs & Crash Reports"
    case browserCaches = "Browser Caches"
    case developerJunk = "Xcode & Developer Caches"
    case oldDownloads = "Old Installers in Downloads"
    case userTrash = "Trash"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .userCaches: return "internaldrive"
        case .applicationLogs: return "doc.text.magnifyingglass"
        case .browserCaches: return "safari"
        case .developerJunk: return "hammer"
        case .oldDownloads: return "arrow.down.circle"
        case .userTrash: return "trash"
        }
    }

    public var subtitle: String {
        switch self {
        case .userCaches: return "App-generated temporary cache folders in ~/Library/Caches"
        case .applicationLogs: return "Diagnostic reports and logs in ~/Library/Logs"
        case .browserCaches: return "Cached web assets for Safari, Chrome, Firefox, and Arc"
        case .developerJunk: return "Xcode DerivedData, simulator caches, and SwiftPM caches"
        case .oldDownloads: return "Installer packages (.dmg, .pkg, .zip) older than 14 days"
        case .userTrash: return "Items currently waiting in ~/.Trash"
        }
    }

    public var defaultSelected: Bool {
        switch self {
        case .userCaches, .applicationLogs, .browserCaches, .developerJunk, .userTrash:
            return true
        case .oldDownloads:
            return false
        }
    }
}

public struct JunkItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let category: JunkCategory
    public let byteSize: UInt64
    public let modifiedDate: Date?
    public let isDirectory: Bool
    public var isSelected: Bool

    public init(
        id: UUID = UUID(),
        url: URL,
        name: String? = nil,
        category: JunkCategory,
        byteSize: UInt64,
        modifiedDate: Date? = nil,
        isDirectory: Bool,
        isSelected: Bool = true
    ) {
        self.id = id
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.category = category
        self.byteSize = byteSize
        self.modifiedDate = modifiedDate
        self.isDirectory = isDirectory
        self.isSelected = isSelected
    }
}

public struct LargeFileItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let byteSize: UInt64
    public let modifiedDate: Date?
    public var isSelected: Bool

    public init(
        id: UUID = UUID(),
        url: URL,
        byteSize: UInt64,
        modifiedDate: Date?,
        isSelected: Bool = false
    ) {
        self.id = id
        self.url = url
        self.name = url.lastPathComponent
        self.byteSize = byteSize
        self.modifiedDate = modifiedDate
        self.isSelected = isSelected
    }
}

public struct DuplicateFileItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let modifiedDate: Date
    public var isSelected: Bool

    public init(
        id: UUID = UUID(),
        url: URL,
        modifiedDate: Date,
        isSelected: Bool = false
    ) {
        self.id = id
        self.url = url
        self.name = url.lastPathComponent
        self.modifiedDate = modifiedDate
        self.isSelected = isSelected
    }
}

public struct DuplicateGroup: Identifiable, Sendable {
    public let id: UUID
    public let hash: String
    public let byteSize: UInt64
    public var files: [DuplicateFileItem]

    public init(id: UUID = UUID(), hash: String, byteSize: UInt64, files: [DuplicateFileItem]) {
        self.id = id
        self.hash = hash
        self.byteSize = byteSize
        self.files = files
    }

    public var reclaimableBytes: UInt64 {
        let selectedCount = files.filter(\.isSelected).count
        return byteSize * UInt64(selectedCount)
    }

    public var totalWastedBytes: UInt64 {
        guard files.count > 1 else { return 0 }
        return byteSize * UInt64(files.count - 1)
    }
}

public struct DuplicateScanProgress: Sendable {
    public enum Stage: String, Sendable {
        case enumerating = "Indexing files..."
        case partialHashing = "Comparing file signatures..."
        case fullHashing = "Verifying exact SHA-256 matches..."
        case finished = "Scan complete"
    }

    public let stage: Stage
    public let filesExamined: Int
    public let candidateGroups: Int
    public let currentPath: String
}

public struct RemnantItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let kind: String
    public let byteSize: UInt64
    public var isSelected: Bool

    public init(
        id: UUID = UUID(),
        url: URL,
        kind: String,
        byteSize: UInt64,
        isSelected: Bool = true
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.byteSize = byteSize
        self.isSelected = isSelected
    }
}

public struct InstalledAppItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let bundleIdentifier: String
    public let version: String
    public let bundleURL: URL
    public let bundleSize: UInt64
    public var remnants: [RemnantItem]
    public var hasScannedRemnants: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        bundleIdentifier: String,
        version: String,
        bundleURL: URL,
        bundleSize: UInt64,
        remnants: [RemnantItem] = [],
        hasScannedRemnants: Bool = false
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.bundleURL = bundleURL
        self.bundleSize = bundleSize
        self.remnants = remnants
        self.hasScannedRemnants = hasScannedRemnants
    }

    public var totalRemnantBytes: UInt64 {
        remnants.reduce(0) { $0 + $1.byteSize }
    }

    public var totalFootprintBytes: UInt64 {
        bundleSize + totalRemnantBytes
    }
}

public struct CleanFailure: Identifiable, Sendable {
    public let id = UUID()
    public let url: URL
    public let reason: String
}

public struct CleanResult: Sendable {
    public let removedCount: Int
    public let freedBytes: UInt64
    public let failures: [CleanFailure]

    public var summaryMessage: String {
        let sizeText = ByteFormatter.format(freedBytes)
        if failures.isEmpty {
            return "Moved \(removedCount) item(s) to Trash, freeing \(sizeText)."
        } else {
            return "Cleaned \(removedCount) item(s) (\(sizeText)). \(failures.count) item(s) could not be removed."
        }
    }
}

public enum ByteFormatter {
    public static func format(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    public static func formatMemory(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    public static func formatRate(_ bytesPerSecond: UInt64) -> String {
        let kb = Double(bytesPerSecond) / 1024.0
        if kb < 1024 {
            return String(format: "%.0f KB/s", kb)
        }
        let mb = kb / 1024.0
        if mb < 1024 {
            return String(format: "%.1f MB/s", mb)
        }
        let gb = mb / 1024.0
        return String(format: "%.2f GB/s", gb)
    }
}
