// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

// The sandboxed XPC service extensions run in. It has no network, no files outside its container and
// no access to Orilio's data: it only answers the app's calls, and asks the app for fetches (which the
// app checks against the manifest). One process holds every enabled extension, each in its own
// JavaScript virtual machine; the app restarts it if it stops answering.
import Foundation
import OrilioExtensionEngine
import OrilioExtensionKit

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ExtensionRunnerProtocol.self)
        connection.exportedObject = ExtensionRunner(connection: connection)
        connection.remoteObjectInterface = NSXPCInterface(with: ExtensionHostProtocol.self)
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
