//
//  AppMain.swift
//  SystemCleaner
//
//  Main application entrypoint.
//

import SwiftUI

@main
struct SystemCleanerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
