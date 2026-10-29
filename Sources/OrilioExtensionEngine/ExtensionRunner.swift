// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation
import OrilioExtensionKit

/// What the runner process exports over XPC: the app's calls, each run on one serial queue against
/// the engine. Here rather than in the runner's `main.swift` so tests can serve it in process.
/// Unchecked-Sendable: XPC calls arrive on any thread, and each one hops onto `queue` before touching
/// the engine; `connection` is set once at init.
public final class ExtensionRunner: NSObject, ExtensionRunnerProtocol, @unchecked Sendable {
    /// Everything happens here, one call at a time (the engine is confined to it).
    /// Each work item drains its own autoreleased objects, so nothing keeps an unloaded context alive.
    private let queue = DispatchQueue(label: "com.enbiyagoral.orilio.ExtensionRunner.js", autoreleaseFrequency: .workItem)
    private weak var connection: NSXPCConnection?
    private lazy var engine = ExtensionEngine(queue: queue) { [weak self] id, url, method, body, completion in
        guard let host = self?.connection?.remoteObjectProxyWithErrorHandler({ error in
            completion(nil, 0, error.localizedDescription)
        }) as? ExtensionHostProtocol else { return completion(nil, 0, "Orilio isn't reachable") }
        host.fetch(extensionID: id, url: url, method: method, body: body, reply: completion)
    }

    public init(connection: NSXPCConnection) {
        self.connection = connection
    }

    public func load(extensionID: String, script: String, manifest: Data, reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            do {
                engine.unload(id: extensionID)
                try engine.load(id: extensionID, script: script, manifest: try ManifestValidator.validate(manifest))
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    public func call(extensionID: String, function: String, context: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        queue.async { [self] in
            guard let context = try? JSONDecoder().decode(CallContext.self, from: context) else { return reply(nil, "Bad call context") }
            engine.call(id: extensionID, function: function, context: context) { outcome in
                switch outcome {
                case .success(let callReply):
                    // Over budget, the app restarts this process once it has the answer.
                    reply(try? JSONEncoder().encode(callReply), nil)
                case .failure(let error):
                    reply(nil, error.localizedDescription)
                }
            }
        }
    }

    public func unload(extensionID: String) {
        queue.async { [self] in engine.unload(id: extensionID) }
    }
}
