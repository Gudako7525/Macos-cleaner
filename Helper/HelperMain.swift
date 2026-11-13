//
//  HelperMain.swift
//  com.cleaner.helper
//
//  Privileged Helper Mach-O entrypoint registered by launchd.
//

import Foundation
import os.log

@main
struct HelperMain {
    static func main() {
        let logger = Logger(subsystem: "com.cleaner.helper", category: "Lifecycle")
        logger.info("Privileged helper daemon starting up under launchd...")

        let listenerDelegate = SecureListenerDelegate()
        let listener = NSXPCListener(machServiceName: "com.cleaner.helper")
        listener.delegate = listenerDelegate
        listener.resume()

        logger.info("Mach service com.cleaner.helper active and listening. Entering run loop.")
        RunLoop.main.run()
    }
}
