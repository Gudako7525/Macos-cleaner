# SystemCleaner for macOS (Sonoma 14 & Sequoia 15)

High-performance, lightweight macOS system cleaner and optimization utility built natively for **Apple Silicon (ARM64)** using Swift, AppKit/SwiftUI, and low-level Darwin kernel interfaces.

---

## Project Structure

```
Macos-cleaner/
├── SystemCleaner.xcodeproj             # Ready-to-build Xcode project (App, Helper, Tests)
├── README.md                           # Setup & Build Guide
├── Config/
│   ├── App-Info.plist                  # Bundle Info.plist for SystemCleaner.app
│   ├── App.entitlements                # Entitlements for UI App
│   ├── Helper.entitlements             # Entitlements for Privileged Daemon
│   └── com.cleaner.helper.plist        # launchd daemon configuration (SMAppService)
├── Shared/
│   └── SharedInterfaces.swift          # NSXPCConnection protocol contracts
├── App/
│   ├── AppMain.swift                   # SwiftUI App lifecycle
│   ├── ContentView.swift               # NavigationSplitView root UI
│   ├── DaemonManager.swift             # SMAppService registration lifecycle
│   ├── XPCConnectionManager.swift      # Resilient IPC client connection manager
│   ├── AsyncDiskScanner.swift          # Multi-threaded fts(3) disk, junk & large-file scanner
│   ├── AppRemnantScanner.swift         # Installed app discovery, remnant & orphan scanner
│   ├── DuplicateDetectionEngine.swift  # 3-stage duplicate finder (size -> partial -> SHA-256)
│   ├── SystemTelemetryEngine.swift     # Mach kernel stats (CPU/RAM/Disk + rolling history)
│   ├── PrivacyPermissionCoordinator.swift # Full Disk Access (FDA) TCC & Login Items helper
│   ├── Models/
│   │   └── CleanerModels.swift         # App models, categories, formatters
│   ├── Services/
│   │   ├── CleanActionService.swift    # Trash, permanent delete + XPC escalation, Finder reveal
│   │   ├── CleanerViewModel.swift      # Centralized @MainActor scan/clean state coordinator
│   │   └── MaintenanceService.swift    # DNS, Spotlight, LaunchServices & memory maintenance
│   └── Views/
│       ├── DashboardView.swift         # Live CPU/RAM/Disk telemetry, RAM cleanup, helper controls
│       ├── JunkCleanerView.swift       # Categorized junk scanner (Caches, Logs, Trash, Xcode)
│       ├── LargeFilesView.swift        # Configurable threshold large-file explorer
│       ├── DuplicatesView.swift        # Multi-stage duplicate finder with keep-newest/oldest
│       ├── UninstallerView.swift       # App uninstaller & orphaned leftover scanner
│       ├── MaintenanceView.swift       # System maintenance tasks & SMAppService management
│       └── MenuBarWidgetView.swift     # Top menu bar popover widget (CPU, RAM purge, Net, Disk)
├── Helper/
│   ├── HelperMain.swift                # Daemon entrypoint (@main Mach-O executable)
│   ├── SecureListenerDelegate.swift    # Code signature & Team ID verification
│   ├── CleanerDaemonImplementation.swift # Privileged operation executor
│   └── DarwinMaintenanceBridge.swift   # Native Darwin maintenance utilities
├── Tests/
│   └── SystemCleanerTests.swift        # Swift Testing unit tests
└── Scripts/
    ├── build_and_sign.sh               # Codesigning & Notarization pipeline
    └── verify_cleaner.sh               # Automated pre-flight diagnostics suite
```

---

## Building & Running in Xcode

1. Open [SystemCleaner.xcodeproj](SystemCleaner.xcodeproj) in Xcode.
2. Select the **SystemCleaner** scheme (`My Mac`).
3. Press **`Cmd + R`** to build and launch `SystemCleaner.app` (which automatically builds and embeds `com.cleaner.helper` and `com.cleaner.helper.plist` into `Contents/Library/LaunchDaemons/`).
4. Press **`Cmd + U`** to run `SystemCleanerTests`.

> **Signing Note**: The project is configured for local ad-hoc signing (`Sign to Run Locally`) so it builds and runs out of the box. For production distribution and `SMAppService` privileged helper installation, set your Apple Developer Team ID in Signing & Capabilities and update `TEAMID1234` in `Helper/SecureListenerDelegate.swift` and `Config/Helper.entitlements`.
