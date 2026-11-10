# SystemCleaner for macOS (Sonoma 14 & Sequoia 15)

High-performance, lightweight macOS system cleaner and optimization utility built natively for **Apple Silicon (ARM64)** using Swift, AppKit/SwiftUI, and low-level Darwin kernel interfaces.

---

## Project Structure

```
SystemCleaner-macOS/
├── README.md                           # Setup & Build Guide
├── Config/
│   ├── App.entitlements               # Hardened Runtime entitlements for UI App
│   ├── Helper.entitlements            # Root entitlements for Privileged Daemon
│   └── com.cleaner.helper.plist       # launchd daemon configuration (SMAppService)
├── Shared/
│   └── SharedInterfaces.swift         # NSXPCConnection protocol contracts
├── App/
│   ├── AppMain.swift                  # SwiftUI App lifecycle
│   ├── ContentView.swift              # Main Dashboard UI
│   ├── DaemonManager.swift            # SMAppService registration lifecycle
│   ├── XPCConnectionManager.swift     # Resilient IPC client connection manager
│   ├── AsyncDiskScanner.swift         # Multi-threaded fts(3) disk scanner
│   ├── AppRemnantScanner.swift        # Heuristic bundle uninstaller
│   ├── DuplicateDetectionEngine.swift # Multi-stage duplicate finder
│   ├── SystemTelemetryEngine.swift    # Low-overhead Mach kernel stats (CPU/RAM/Disk)
│   └── PrivacyPermissionCoordinator.swift # Full Disk Access (FDA) TCC handler
├── Helper/
│   ├── HelperMain.swift               # Daemon entrypoint (Mach-O executable)
│   ├── SecureListenerDelegate.swift   # Code signature & Team ID verification
│   ├── CleanerDaemonImplementation.swift # Privileged operation executor
│   └── DarwinMaintenanceBridge.swift  # Native Darwin APIs (DNS, RAM, Spotlight)
└── Scripts/
    ├── build_and_sign.sh              # Codesigning & Notarization pipeline
    └── verify_cleaner.sh              # Automated pre-flight diagnostics suite
```

---

## How to Import into Xcode on macOS

1. Transfer this `SystemCleaner-macOS` folder to your Mac (via AirDrop, Git, or flash drive).
2. Open **Xcode** > **File** > **New** > **Project...**
3. Create a **macOS > App**:
   - Product Name: `SystemCleaner`
   - Interface: **SwiftUI**
   - Language: **Swift**
4. Add the Helper Daemon Target:
   - Select the project root in the left navigator > click **`+`** under Targets.
   - Choose **macOS > Command Line Tool**.
   - Product Name: `com.cleaner.helper`.
5. Organize Target Memberships in Xcode:
   - `Shared/`: Check **both** `SystemCleaner` and `com.cleaner.helper`.
   - `App/`: Check `SystemCleaner` only.
   - `Helper/`: Check `com.cleaner.helper` only.
6. Configure the `SMAppService` Bundle Phase:
   - Select the `SystemCleaner` target > **Build Phases** > **`+`** > **New Copy Files Build Phase**.
   - Destination: **Wrapper**.
   - Subpath: `Contents/Library/LaunchDaemons`.
   - Add files:
     - `com.cleaner.helper` (the built executable from your helper target)
     - `Config/com.cleaner.helper.plist`
7. Press **`Cmd + R`** to run.
