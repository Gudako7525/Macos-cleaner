//
//  DaemonManager.swift
//  SystemCleaner
//
//  Registers and manages com.cleaner.helper using Apple's modern SMAppService.
//

import Foundation
import ServiceManagement
import os.log

@MainActor
public final class DaemonManager: ObservableObject {
    public static let shared = DaemonManager()

    private let logger = Logger(subsystem: "com.cleaner.app", category: "DaemonManager")
    private let service = SMAppService.daemon(plistName: "com.cleaner.helper.plist")

    @Published public private(set) var status: SMAppService.Status = .notRegistered

    public var statusDescription: String {
        switch status {
        case .enabled:
            return "Active (Root Helper Running)"
        case .requiresApproval:
            return "Requires Approval in Login Items"
        case .notRegistered:
            return "Not Registered"
        case .notFound:
            return "Helper Not Embedded in Bundle"
        @unknown default:
            return "Unknown Status"
        }
    }

    public init() {
        syncStatus()
    }

    public func syncStatus() {
        status = service.status
    }

    public func register() throws {
        do {
            try service.register()
            syncStatus()
            logger.info("Privileged daemon registration invoked. Current status: \(String(describing: self.status), privacy: .public)")
        } catch {
            syncStatus()
            logger.error("Registration failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func unregister() async throws {
        do {
            try await service.unregister()
            syncStatus()
            logger.info("Privileged daemon successfully unregistered.")
        } catch {
            syncStatus()
            logger.error("Unregister failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
