// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation
import Testing
@testable import OrilioExtensionEngine
@testable import OrilioExtensionKit
@testable import OrilioPrototype

/// Serves the real runner over a real XPC connection, in this process.
private final class InProcessRunner: NSObject, NSXPCListenerDelegate {
    let listener = NSXPCListener.anonymous()

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ExtensionRunnerProtocol.self)
        connection.exportedObject = ExtensionRunner(connection: connection)
        connection.remoteObjectInterface = NSXPCInterface(with: ExtensionHostProtocol.self)
        connection.resume()
        return true
    }
}

@MainActor
struct ExtensionXPCTests {
    /// The whole path: the host loads the package into the runner, calls `refresh`, the script's fetch
    /// comes back to the host's broker (which refuses a host the manifest doesn't name), and the result
    /// lands on the installed extension.
    @Test func aRefreshGoesThroughTheRunnerAndItsFetchThroughTheBroker() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "orilio-xpc-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appending(path: "package", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("""
        {"schema": 1, "id": "test.xpc", "name": "XPC", "version": "1.0.0", "author": "Tests", "license": "GPL-3.0-or-later",
         "minOrilio": "0.1.0", "provides": ["widget.island"], "refresh": {"everyMinutes": 60},
         "permissions": {"network": ["example.com"], "notifications": false, "storage": false}, "settings": []}
        """.utf8).write(to: package.appending(path: "orilio-extension.json"))
        try Data("""
        async function refresh() {
          let said;
          try { await orilio.fetch("https://not-declared.example.org/"); said = "fetched"; } catch (e) { said = String(e); }
          return { island: { sections: [{ type: "footnote", text: said }] } };
        }
        """.utf8).write(to: package.appending(path: "main.js"))

        let runner = InProcessRunner()
        let host = ExtensionHost(store: ExtensionStore(root: root.appending(path: "Installed")), startsRunner: true) {
            NSXPCConnection(listenerEndpoint: runner.listener.endpoint)
        }
        let manifest = try ExtensionPackage.read(package)
        try host.install(from: package, granted: manifest.permissions, local: true)

        var footnote: String?
        for _ in 0..<500 where footnote == nil {
            try await Task.sleep(for: .milliseconds(10))
            footnote = host.installed.first?.result?.island?.sections.compactMap { if case .footnote(let t) = $0 { t } else { nil } }.first
        }
        #expect(footnote?.contains("Blocked: not-declared.example.org") == true, "\(String(describing: footnote)) \(String(describing: host.installed.first?.diagnostics.lastError))")
        #expect(host.installed.first?.diagnostics.lastError == nil)
    }
}
