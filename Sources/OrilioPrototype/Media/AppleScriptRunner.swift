import AppKit

enum AutomationPermission: Sendable, Equatable {
    case granted, undetermined, denied
}

extension MediaError {
    /// Maps an Apple Event / AppleScript error number.
    init(scriptErrorNumber number: Int, message: String) {
        switch number {
        case -1743: self = .permissionDenied // errAEEventNotPermitted
        case -600, -609: self = .notRunning   // procNotFound, connectionInvalid
        case -1712: self = .failed("The app did not respond") // errAETimeout
        default: self = .failed("\(message) (\(number))")
        }
    }
}

/// Runs every AppleScript off the main actor, on one serial queue.
/// One queue for all players: NSAppleScript isn't documented as thread-safe, and the calls are rare.
final class AppleScriptRunner: @unchecked Sendable {
    static let shared = AppleScriptRunner()

    private let queue = DispatchQueue(label: "com.deaconcornsoft.orilio.applescript", qos: .userInitiated)
    private var compiled: [String: NSAppleScript] = [:] // only touched on `queue`

    func run<T: Sendable>(_ source: String,
                          parse: @escaping @Sendable (NSAppleEventDescriptor) -> T) async throws(MediaError) -> T {
        let result: Result<T, MediaError> = await withCheckedContinuation { continuation in
            queue.async {
                guard let script = self.script(for: source) else {
                    continuation.resume(returning: .failure(.failed("Script did not compile")))
                    return
                }
                var error: NSDictionary?
                let output = script.executeAndReturnError(&error)
                if let error {
                    let number = error[NSAppleScript.errorNumber] as? Int ?? 0
                    let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
                    continuation.resume(returning: .failure(MediaError(scriptErrorNumber: number, message: message)))
                } else {
                    continuation.resume(returning: .success(parse(output)))
                }
            }
        }
        return try result.get()
    }

    private func script(for source: String) -> NSAppleScript? {
        if let cached = compiled[source] { return cached }
        guard let script = NSAppleScript(source: source) else { return nil }
        // Capped: seek commands embed a position, so they are mostly unique.
        if compiled.count < 32 { compiled[source] = script }
        return script
    }
}
