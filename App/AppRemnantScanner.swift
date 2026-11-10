//
//  AppRemnantScanner.swift
//  SystemCleaner
//
//  Locates scattered application files and remnants across user domains.
//

import Foundation

public struct AppRemnantScanner {
    public static func scanRemnants(bundleIdentifier: String, appName: String) -> [URL] {
        let fileManager = FileManager.default
        var matches: [URL] = []
        
        guard let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return []
        }
        
        let searchMatrices: [(subDirectory: String, pattern: String)] = [
            ("Application Support", appName),
            ("Application Support", bundleIdentifier),
            ("Preferences", "\(bundleIdentifier).plist"),
            ("Containers", bundleIdentifier),
            ("Caches", bundleIdentifier),
            ("Saved Application State", "\(bundleIdentifier).savedState"),
            ("WebKit", bundleIdentifier),
            ("HTTPStorages", bundleIdentifier)
        ]
        
        for item in searchMatrices {
            let targetDir = libraryURL.appendingPathComponent(item.subDirectory, isDirectory: true)
            let candidate = targetDir.appendingPathComponent(item.pattern)
            
            if fileManager.fileExists(atPath: candidate.path) {
                matches.append(candidate)
            }
        }
        
        // Scan Group Containers for shared group app remnants
        let groupContainersURL = libraryURL.appendingPathComponent("Group Containers", isDirectory: true)
        if let enumerator = fileManager.enumerator(
            at: groupContainersURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ) {
            for case let folderURL as URL in enumerator {
                if folderURL.lastPathComponent.contains(bundleIdentifier) {
                    matches.append(folderURL)
                }
            }
        }
        
        return matches
    }
}
