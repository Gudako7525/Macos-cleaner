//
//  XPCConnectionManager.swift
//  SystemCleaner
//
//  Maintains resilient, bidirectional NSXPCConnection to the privileged daemon.
//

import Foundation
import ServiceManagement
import os.log

public final class XPCConnectionManager: NSObject, CleanerClientProgressProtocol {
    public static let shared = XPCConnectionManager()
    
    private let logger = Logger(subsystem: "com.cleaner.app", category: "XPCManager")
    private let serviceName = "com.cleaner.helper"
    private var connection: NSXPCConnection?
    private let lock = NSLock()
    
    public var onProgressUpdate: (@Sendable (UInt64, String) -> Void)?
    public var onErrorEncountered: (@Sendable (String, Int32, String) -> Void)?

    private override init() {
        super.init()
    }

    /// Obtains an active, authenticated remote proxy object
    public func getRemoteProxy() throws -> CleanerDaemonProtocol {
        lock.lock()
        defer { lock.unlock() }

        if let existingConnection = connection {
            guard let proxy = existingConnection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                self?.logger.error("XPC execution error: \(error.localizedDescription, privacy: .public)")
            }) as? CleanerDaemonProtocol else {
                throw NSError(domain: "com.cleaner.xpc", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to cast remote proxy"])
            }
            return proxy
        }

        let newConnection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        newConnection.remoteObjectInterface = NSXPCInterface(with: CleanerDaemonProtocol.self)
        
        let clientInterface = NSXPCInterface(with: CleanerClientProgressProtocol.self)
        newConnection.exportedInterface = clientInterface
        newConnection.exportedObject = self

        newConnection.interruptionHandler = { [weak self] in
            self?.logger.warning("NSXPCConnection was interrupted. Connection will reset.")
            self?.invalidateConnection()
        }

        newConnection.invalidationHandler = { [weak self] in
            self?.logger.error("NSXPCConnection was invalidated.")
            self?.invalidateConnection()
        }

        newConnection.resume()
        self.connection = newConnection

        guard let proxy = newConnection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.logger.error("Initial XPC proxy validation error: \(error.localizedDescription, privacy: .public)")
        }) as? CleanerDaemonProtocol else {
            throw NSError(domain: "com.cleaner.xpc", code: -2, userInfo: [NSLocalizedDescriptionKey: "Remote proxy setup failure"])
        }

        // Register the progress callback with the daemon
        proxy.registerProgressDelegate(self)
        return proxy
    }

    public func invalidateConnection() {
        lock.lock()
        defer { lock.unlock() }
        connection?.invalidate()
        connection = nil
    }

    // MARK: - CleanerClientProgressProtocol Implementation
    
    public func didUpdateProgress(bytesProcessed: UInt64, currentPath: String) {
        onProgressUpdate?(bytesProcessed, currentPath)
    }

    public func didEncounterError(path: String, errorCode: Int32, errorMessage: String) {
        onErrorEncountered?(path, errorCode, errorMessage)
    }
}
