//
//  DaemonManager.swift
//  SystemCleaner
//
//  Registers and manages com.cleaner.helper using Apple's modern SMAppService.
//

import Foundation
import ServiceManagement
import os.log

public final class DaemonManager: ObservableObject {
    public static let shared = DaemonManager()
    
    private let logger = Logger(subsystem: "com.cleaner.app", category: "DaemonManager")
    private let service = SMAppService.daemon(plistName: "com.cleaner.helper.plist")
    
    @Published public private(set) var status: SMAppService.Status = .notRegistered

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
            logger.info("Privileged daemon successfully registered with launchd.")
        } catch {
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
            logger.error("Unregister failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
