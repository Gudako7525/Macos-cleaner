//
//  SecureListenerDelegate.swift
//  com.cleaner.helper
//
//  Authenticates incoming NSXPCConnection requests via SecCodeCopyGuestWithAttributes.
//

import Foundation
import Security
import os.log

public final class SecureListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let logger = Logger(subsystem: "com.cleaner.helper", category: "SecureListener")

    // Validate that the connecting client is SystemCleaner ("com.cleaner.app")
    private let expectedRequirement = "identifier \"com.cleaner.app\""

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard validateCodeSignature(for: connection) else {
            logger.fault("Denied connection: Peer failed code signature requirement verification.")
            return false
        }

        let daemonImpl = CleanerDaemonImplementation()
        connection.exportedInterface = NSXPCInterface(with: CleanerDaemonProtocol.self)
        connection.exportedObject = daemonImpl
        connection.remoteObjectInterface = NSXPCInterface(with: CleanerClientProgressProtocol.self)

        connection.invalidationHandler = {
            daemonImpl.clearProgressDelegate()
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
        let attributes: [CFString: Any] = [
            kSecGuestAttributePid: connection.processIdentifier
        ]
        let status = SecCodeCopyGuestWithAttributes(
            nil,
            attributes as CFDictionary,
            SecCSFlags(),
            &guestSecCode
        )
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
