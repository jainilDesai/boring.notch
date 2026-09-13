//
//  main.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

// Run as the agent's PreToolUse hook rather than as an XPC service.
//
// The hook script at ~/.brow/gate.sh execs this binary with --gate-decide,
// which reads a payload on stdin and prints a decision. Handled before the
// listener is created, because that call never returns.
//
// Reusing this binary rather than shipping a second one keeps the gate's
// decision in exactly one place, and gives the hook a stable absolute path
// inside the app bundle.
if CommandLine.arguments.contains(AgentGate.hookFlag) {
    AgentGate.runAsHook()
}

// Write the hook without waiting for an agent run to do it.
//
// install() records the absolute path of the binary that calls it, so the hook
// must be written BY the helper it should point at. Running this from the
// installed bundle is therefore the only correct way to repair or inspect the
// gate by hand, and it is what the test suite uses.
if CommandLine.arguments.contains(AgentGate.installFlag) {
    AgentGate.install()
    print(AgentGate.scriptURL.path)
    exit(0)
}

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    
    /// This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        
        // Configure the connection.
        // First, set the interface that the exported object implements.
        newConnection.exportedInterface = NSXPCInterface(with: (any BoringNotchXPCHelperProtocol).self)

        // Configure the interface for callbacks from the helper to the app.
        let listenerInterface = NSXPCInterface(with: (any BoringNotchXPCHelperLunarListener).self)
        listenerInterface.setClasses(
            NSSet(array: [BNLunarBrightnessEvent.self]) as! Set<AnyHashable>,
            for: #selector(BoringNotchXPCHelperLunarListener.lunarEventDidUpdate(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        newConnection.remoteObjectInterface = listenerInterface
        
        // Next, set the object that the connection exports. All messages sent on the connection to this service will be sent to the exported object to handle. The connection retains the exported object.
        let exportedObject = BoringNotchXPCHelper(connection: newConnection)
        newConnection.exportedObject = exportedObject
        
        // Resuming the connection allows the system to deliver more incoming messages.
        newConnection.resume()
        
        // Returning true from this method tells the system that you have accepted this connection. If you want to reject the connection for some reason, call invalidate() on the connection and return false.
        return true
    }
}

// Create the delegate for the service.
let delegate = ServiceDelegate()

// Set up the one NSXPCListener for this service. It will handle all incoming connections.
let listener = NSXPCListener.service()
listener.delegate = delegate

// Resuming the serviceListener starts this service. This method does not return.
listener.resume()
