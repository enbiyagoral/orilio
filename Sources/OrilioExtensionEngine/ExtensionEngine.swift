// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation
@preconcurrency import JavaScriptCore
import OrilioExtensionKit

/// Runs extension scripts in JavaScriptCore, each in its own virtual machine (separate heaps; one
/// extension can't see another's objects). Lives in the runner process only, never in the app.
///
/// A script is plain JavaScript that defines `refresh(ctx)`, and optionally `onAction(id, ctx)` and
/// `onSettingsChanged(ctx)`. They return a result object (or a promise of one). The only bridged API is
/// `orilio`: `fetch(url, {method, body})` (if the manifest declares network; the app checks the host),
/// `storage.get/set` (if declared), `settings`, `log`. No timers, no file system, no eval of fetched code.
///
/// Not thread-safe: confined to the runner's one serial queue (`queue`); that confinement is why it,
/// and the JavaScript values it hands across a fetch, are marked unchecked-Sendable.
public final class ExtensionEngine: @unchecked Sendable {
    /// Fetches for a script; called on the engine's queue, completes on any queue (`resume` hops back).
    public typealias Fetcher = (_ extensionID: String, _ url: String, _ method: String, _ body: Data?,
                                _ completion: @escaping @Sendable (Data?, Int, String?) -> Void) -> Void

    private struct Loaded {
        let vm: JSVirtualMachine
        let context: JSContext
        let manifest: ExtensionManifest
        var storage: [String: JSONValue] = [:]
    }

    private var loaded: [String: Loaded] = [:]
    private let fetcher: Fetcher
    /// Where work coming back from a fetch is run (the runner's serial queue).
    private let queue: DispatchQueue

    public init(queue: DispatchQueue, fetcher: @escaping Fetcher) {
        self.queue = queue
        self.fetcher = fetcher
    }

    public func load(id: String, script: String, manifest: ExtensionManifest) throws {
        guard let vm = JSVirtualMachine(), let context = JSContext(virtualMachine: vm) else { throw EngineError.message("JavaScriptCore is unavailable") }
        var thrown: String?
        context.exceptionHandler = { _, exception in thrown = exception?.toString() }
        // Nothing from the outside world but what is installed below.
        // Nothing that compiles a string into code: `eval`, `Function`, and the async and generator
        // function constructors that every such function still reaches through `.constructor`.
        context.evaluateScript("""
        for (const f of [function () {}, async function () {}, function* () {}, async function* () {}]) {
          delete Object.getPrototypeOf(f).constructor;
        }
        delete globalThis.eval; delete globalThis.Function;
        """)
        installAPI(in: context, id: id, manifest: manifest)
        context.evaluateScript(script, withSourceURL: URL(string: "orilio-extension://\(id)/main.js"))
        if let thrown { throw EngineError.message("The script failed to load: \(thrown)") }
        loaded[id] = Loaded(vm: vm, context: context, manifest: manifest)
    }

    public func unload(id: String) { loaded[id] = nil }

    /// Calls `function` with `context` (and the action id for `onAction`). Completes once, on the engine's queue.
    public func call(id: String, function: String, context: CallContext, completion: @escaping (Result<CallReply, EngineError>) -> Void) {
        guard var entry = loaded[id] else { return completion(.failure(.message("The extension isn't loaded"))) }
        guard ["refresh", "onAction", "onSettingsChanged"].contains(function) else { return completion(.failure(.message("Unknown function \(function)"))) }
        let js = entry.context
        guard let fn = js.objectForKeyedSubscript(function), !fn.isUndefined, fn.isObject else {
            return completion(.failure(.message("The script doesn't define \(function)")))
        }
        entry.storage = entry.manifest.permissions.storage ? context.storage : [:]
        loaded[id] = entry

        var finished = false
        let finish: (Result<JSValue?, EngineError>) -> Void = { [weak self] outcome in
            guard !finished, let self else { return }
            finished = true
            switch outcome {
            case .failure(let error): completion(.failure(error))
            case .success(let value):
                let json = js.objectForKeyedSubscript("JSON").invokeMethod("stringify", withArguments: [value ?? JSValue(nullIn: js)!])
                guard let text = json?.toString(), text != "undefined", let data = text.data(using: .utf8) else {
                    return completion(.failure(.message("\(function) returned nothing")))
                }
                completion(.success(CallReply(result: data, storage: self.loaded[id]?.storage ?? [:], residentBytes: Self.residentBytes())))
            }
        }

        var thrown: String?
        js.exceptionHandler = { _, exception in thrown = exception?.toString() }
        js.setObject(Self.jsValue(context.settings, in: js), forKeyedSubscript: "__settings" as NSString)
        js.evaluateScript("orilio.settings = Object.freeze(globalThis.__settings); delete globalThis.__settings;")
        let ctx = Self.jsValue(["now": .string(context.now), "locale": .string(context.locale), "timeZone": .string(context.timeZone),
                                "settings": .object(context.settings)], in: js)
        let arguments: [Any] = function == "onAction" ? [context.action ?? "", ctx] : [ctx]
        let value = fn.call(withArguments: arguments)
        if let thrown { return finish(.failure(.message(thrown))) }
        guard let value, value.isObject, let then = value.objectForKeyedSubscript("then"), then.isObject, !then.isUndefined else {
            return finish(.success(value))
        }
        // A promise: settle when it does (fetches resolve it from the engine's queue).
        let fulfilled: @convention(block) (JSValue?) -> Void = { finish(.success($0)) }
        let rejected: @convention(block) (JSValue?) -> Void = { finish(.failure(.message($0?.toString() ?? "The promise was rejected"))) }
        value.invokeMethod("then", withArguments: [JSValue(object: fulfilled, in: js) as Any, JSValue(object: rejected, in: js) as Any])
        if let thrown { finish(.failure(.message(thrown))) }
    }

    // MARK: The `orilio` object

    private func installAPI(in js: JSContext, id: String, manifest: ExtensionManifest) {
        guard let orilio = JSValue(newObjectIn: js) else { return }
        let log: @convention(block) (JSValue?) -> Void = { message in NSLog("[extension %@] %@", id, message?.toString() ?? "") }
        orilio.setObject(log, forKeyedSubscript: "log" as NSString)
        orilio.setObject(JSValue(newObjectIn: js), forKeyedSubscript: "settings" as NSString)

        if manifest.permissions.storage {
            let storage = JSValue(newObjectIn: js)!
            let get: @convention(block) (String) -> Any? = { [weak self] key in
                guard let value = self?.loaded[id]?.storage[key] else { return nil }
                return Self.foundation(value)
            }
            let set: @convention(block) (String, JSValue?) -> Void = { [weak self] key, value in
                guard let self, var entry = self.loaded[id] else { return }
                entry.storage[key] = value.flatMap { Self.jsonValue($0.toObject()) } ?? .null
                if let data = try? JSONEncoder().encode(entry.storage), data.count > ExtensionLimits.storageBytes {
                    js.exception = JSValue(newErrorFromMessage: "Storage is full (\(ExtensionLimits.storageBytes / 1024) KB)", in: js)
                    return
                }
                self.loaded[id] = entry
            }
            storage.setObject(get, forKeyedSubscript: "get" as NSString)
            storage.setObject(set, forKeyedSubscript: "set" as NSString)
            orilio.setObject(storage, forKeyedSubscript: "storage" as NSString)
        }

        if !manifest.permissions.network.isEmpty {
            let fetch: @convention(block) (String, JSValue?) -> JSValue? = { [weak self] url, given in
                guard let self else { return nil }
                // Reading a key of `undefined` throws in JavaScript: no options is no options.
                let options = given?.isObject == true ? given : nil
                let method = options?.objectForKeyedSubscript("method")?.toString().flatMap { $0 == "undefined" ? nil : $0 } ?? "GET"
                let body = options?.objectForKeyedSubscript("body").flatMap { $0.isString ? $0.toString().data(using: .utf8) : nil }
                return JSValue(newPromiseIn: js) { resolve, reject in
                    let settle = Confined((js, resolve, reject))
                    self.fetcher(id, url, method, body) { data, status, error in
                        self.queue.async {
                            let (js, resolve, reject) = settle.value
                            if let error {
                                reject?.call(withArguments: [error])
                                return
                            }
                            let response = JSValue(newObjectIn: js)!
                            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                            response.setObject(status, forKeyedSubscript: "status" as NSString)
                            response.setObject((200..<300).contains(status), forKeyedSubscript: "ok" as NSString)
                            response.setObject(text, forKeyedSubscript: "text" as NSString)
                            resolve?.call(withArguments: [response])
                        }
                    }
                }
            }
            orilio.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
        }
        js.setObject(orilio, forKeyedSubscript: "orilio" as NSString)
    }

    // MARK: Values

    static func jsValue(_ object: [String: JSONValue], in js: JSContext) -> JSValue {
        JSValue(object: foundation(.object(object)), in: js)
    }

    static func foundation(_ value: JSONValue) -> Any {
        switch value {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n
        case .string(let s): s
        case .array(let a): a.map(foundation)
        case .object(let o): o.mapValues(foundation)
        }
    }

    static func jsonValue(_ any: Any?) -> JSONValue {
        switch any {
        case nil, is NSNull: return .null
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(jsonValue))
        case let o as [String: Any]: return .object(o.mapValues(jsonValue))
        default: return .null
        }
    }

    /// This process's resident memory, for the host's diagnostics and the memory budget.
    public static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }
}

/// A value used only on the engine's queue, carried through a closure that hops back to it.
private struct Confined<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

public enum EngineError: Error, Equatable, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
}
