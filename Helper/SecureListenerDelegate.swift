//
//  SecureListenerDelegate.swift
//  com.cleaner.helper
//
//  Authenticates incoming NSXPCConnection requests via SecCodeCopyGuestWithProcessIdentifier.
//

import Foundation
import Security
import os.log

public final class SecureListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let logger = Logger(subsystem: "com.cleaner.helper", category: "SecureListener")
    
    // In production, update TEAMID1234 to your Developer Account Team ID
    private let expectedRequirement = "anchor apple generic and identifier \"com.cleaner.app\" and certificate leaf[subject.OU] = \"TEAMID1234\""

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        #if !DEBUG
        guard validateCodeSignature(for: connection) else {
            logger.fault("Denied connection: Peer failed code signature requirement verification.")
            return false
        }
        #endif

        connection.exportedInterface = NSXPCInterface(with: CleanerDaemonProtocol.self)
        connection.exportedObject = CleanerDaemonImplementation()
        
        connection.remoteObjectInterface = NSXPCInterface(with: CleanerClientProgressProtocol.self)
        
        connection.invalidationHandler = {
            // Clean up resources on disconnect
        }
        connection.interruptionHandler = {
            // Transient interruption handler
        }
        
        connection.resume()
        logger.info("Accepted secure connection from PID \(connection.processIdentifier)")
        return true
    }

    private func validateCodeSignature(for connection: NSXPCConnection) -> Bool {
        var guestSecCode: SecCode?
        let status = SecCodeCopyGuestWithProcessIdentifier(nil, connection.processIdentifier, &guestSecCode)
        guard status == errSecSuccess, let code = guestSecCode else {
            return false
        }

        var requirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(expectedRequirement as CFString, SecCSFlags(), &requirement)
        guard reqStatus == errSecSuccess, let secReq = requirement else {
            return false
        }

        let validity = SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), secReq)
        return validity == errSecSuccess
    }
}
