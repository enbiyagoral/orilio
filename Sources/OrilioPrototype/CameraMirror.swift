@preconcurrency import AVFoundation
import AppKit
import Observation

/// One camera the mirror can show.
struct MirrorCamera: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable { case builtIn, continuity, external }

    let id: String // AVCaptureDevice.uniqueID
    let name: String
    let kind: Kind

    /// The short name on the camera button (the design's "FaceTime HD", "iPhone").
    var shortName: String {
        switch kind {
        case .builtIn: name.replacingOccurrences(of: " Camera", with: "")
        case .continuity: "iPhone"
        case .external: name
        }
    }

    var detail: String {
        switch kind {
        case .builtIn: "Built-in"
        case .continuity: "Continuity Camera"
        case .external: "External"
        }
    }
}

enum CameraMirrorState: Equatable, Sendable {
    /// Not on screen; the camera is off.
    case off
    /// Before any system prompt: the in-island card that asks first.
    case needsConsent
    /// The system prompt is up.
    case requesting
    case denied
    case noCamera
    case inUseElsewhere
    case live(deviceID: String, mirrored: Bool)
}

enum MirrorAuthorization: Equatable, Sendable {
    case notDetermined, authorized, denied, restricted
}

/// A one-line notice over the preview.
enum MirrorNotice: Equatable, Sendable {
    /// A camera appeared; offered, never switched to on its own.
    case available(MirrorCamera)
    /// The camera in use went away; the mirror moved to another one.
    case switched(from: String, to: String)
}

enum MirrorEvent: Equatable, Sendable {
    case shown(MirrorAuthorization)
    case hidden
    case consented
    case accessAnswered(granted: Bool)
    case camerasFound([MirrorCamera])
    case cameraAdded(MirrorCamera)
    case cameraRemoved(id: String)
    case inUseElsewhere
    case pick(id: String)
    case toggleMirrored
    case acceptOffer
    case dismissNotice
}

enum MirrorEffect: Equatable, Sendable {
    case requestAccess
    case start(deviceID: String, mirrored: Bool)
    case setMirrored(Bool)
    case stop
    case remember(deviceID: String)
}

struct MirrorSnapshot: Equatable, Sendable {
    var state = CameraMirrorState.off
    var cameras: [MirrorCamera] = []
    /// The last camera the user chose.
    var preferredID: String?
    var mirrored = true
    var notice: MirrorNotice?

    var activeCamera: MirrorCamera? {
        guard case .live(let id, _) = state else { return nil }
        return cameras.first { $0.id == id }
    }
}

/// Every state change of the mirror, without hardware. Pure.
enum MirrorReducer {
    static func reduce(_ s: inout MirrorSnapshot, _ event: MirrorEvent) -> [MirrorEffect] {
        switch event {
        case .shown(let authorization):
            switch authorization {
            case .notDetermined: s.state = .needsConsent; return []
            case .denied, .restricted: s.state = .denied; return []
            case .authorized: return goLive(&s)
            }

        case .hidden:
            let wasRunning = s.state.isRunning
            s.state = .off
            s.notice = nil
            return wasRunning ? [.stop] : []

        case .consented:
            guard s.state == .needsConsent else { return [] }
            s.state = .requesting
            return [.requestAccess]

        case .accessAnswered(let granted):
            guard s.state == .requesting else { return [] }
            if granted { return goLive(&s) }
            s.state = .denied
            return []

        case .camerasFound(let cameras):
            s.cameras = cameras
            return []

        case .cameraAdded(let camera):
            guard !s.cameras.contains(where: { $0.id == camera.id }) else { return [] }
            s.cameras.append(camera)
            switch s.state {
            case .live: s.notice = .available(camera); return [] // offer only
            case .noCamera: return goLive(&s)
            default: return []
            }

        case .cameraRemoved(let id):
            let removed = s.cameras.first { $0.id == id }
            s.cameras.removeAll { $0.id == id }
            if case .available(let offered) = s.notice, offered.id == id { s.notice = nil }
            guard case .live(let active, let mirrored) = s.state, active == id else { return [] }
            guard let fallback = fallback(in: s.cameras) else {
                s.state = .noCamera
                return [.stop]
            }
            s.state = .live(deviceID: fallback.id, mirrored: mirrored)
            s.notice = .switched(from: removed?.name ?? "Camera", to: fallback.shortName)
            return [.start(deviceID: fallback.id, mirrored: mirrored)]

        case .inUseElsewhere:
            guard s.state != .off else { return [] }
            let wasRunning = s.state.isRunning
            s.state = .inUseElsewhere
            return wasRunning ? [.stop] : []

        case .pick(let id):
            guard case .live(let active, let mirrored) = s.state, active != id, s.cameras.contains(where: { $0.id == id }) else { return [] }
            s.state = .live(deviceID: id, mirrored: mirrored)
            s.preferredID = id
            s.notice = nil
            return [.start(deviceID: id, mirrored: mirrored), .remember(deviceID: id)]

        case .toggleMirrored:
            s.mirrored.toggle()
            guard case .live(let id, _) = s.state else { return [] }
            s.state = .live(deviceID: id, mirrored: s.mirrored)
            return [.setMirrored(s.mirrored)]

        case .acceptOffer:
            guard case .available(let camera) = s.notice else { return [] }
            return reduce(&s, .pick(id: camera.id))

        case .dismissNotice:
            s.notice = nil
            return []
        }
    }

    /// The remembered camera if it is still there, else the built-in one, else any.
    private static func goLive(_ s: inout MirrorSnapshot) -> [MirrorEffect] {
        let camera = s.cameras.first { $0.id == s.preferredID } ?? fallback(in: s.cameras)
        guard let camera else {
            s.state = .noCamera
            return []
        }
        s.state = .live(deviceID: camera.id, mirrored: s.mirrored)
        return [.start(deviceID: camera.id, mirrored: s.mirrored)]
    }

    private static func fallback(in cameras: [MirrorCamera]) -> MirrorCamera? {
        cameras.first { $0.kind == .builtIn } ?? cameras.first
    }
}

private extension CameraMirrorState {
    var isRunning: Bool { if case .live = self { true } else { false } }
}

// MARK: - The capture session

/// The AVCaptureSession, touched only on its own serial queue (start and stop can block). It has a
/// preview layer and nothing else: no movie, photo or video-data output, so no frame leaves the
/// render server.
final class CameraSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.deaconcornsoft.orilio.camera")

    /// Switches to the camera and runs. Reports `false` when another app holds the camera.
    func start(deviceID: String, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [session] in
            guard let device = AVCaptureDevice(uniqueID: deviceID), !device.isInUseByAnotherApplication,
                  let input = try? AVCaptureDeviceInput(device: device) else {
                session.stopRunning()
                return completion(false)
            }
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            if session.canAddInput(input) { session.addInput(input) }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            completion(true)
        }
    }

    /// Stops at once: the green camera light goes out with it.
    func stop() {
        queue.async { [session] in
            session.stopRunning()
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.commitConfiguration()
        }
    }
}

enum CameraDevices {
    static func all() -> [MirrorCamera] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
                                         mediaType: .video, position: .unspecified).devices.map(camera)
    }

    static func camera(_ device: AVCaptureDevice) -> MirrorCamera {
        let kind: MirrorCamera.Kind = switch device.deviceType {
        case .builtInWideAngleCamera: .builtIn
        case .continuityCamera: .continuity
        default: .external
        }
        return MirrorCamera(id: device.uniqueID, name: device.localizedName, kind: kind)
    }

    static var authorization: MirrorAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }

    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
}

// MARK: - The mirror's state for the views

/// The Camera Mirror module. The camera runs only while the mirror is on screen in an island the
/// user opened; it stops the moment the island collapses or shows another module, on Esc or Turn
/// off, when the Mac sleeps or the screen locks, and when displays change.
@MainActor @Observable
final class CameraMirrorModel {
    private(set) var snapshot = MirrorSnapshot()
    @ObservationIgnored let camera = CameraSession()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Called when the mirror must go away now (sleep, lock, display change): the island closes.
    @ObservationIgnored private var mustClose: [() -> Void] = []
    @ObservationIgnored private var changed: [() -> Void] = []
    static let preferredKey = "mirror.camera"

    /// Every island registers: the one showing the mirror closes / resizes.
    func whenMustClose(_ handler: @escaping () -> Void) { mustClose.append(handler) }
    func whenChanged(_ handler: @escaping () -> Void) { changed.append(handler) }

    init(defaults: UserDefaults = .standard, observeSystem: Bool = true) {
        self.defaults = defaults
        snapshot.preferredID = defaults.string(forKey: Self.preferredKey)
        if observeSystem { observe() }
    }

    var state: CameraMirrorState { snapshot.state }

    /// Shown in an island the user opened (pinned) on the mirror tab, or not.
    func setVisible(_ visible: Bool) {
        if visible {
            guard snapshot.state == .off else { return }
            send(.camerasFound(CameraDevices.all()))
            send(.shown(CameraDevices.authorization))
        } else if snapshot.state != .off {
            send(.hidden)
        }
    }

    func send(_ event: MirrorEvent) {
        let before = snapshot.state
        for effect in MirrorReducer.reduce(&snapshot, event) { perform(effect) }
        if snapshot.state != before { changed.forEach { $0() } }
    }

    private func perform(_ effect: MirrorEffect) {
        switch effect {
        case .requestAccess:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in self?.send(.accessAnswered(granted: granted)) }
            }
        case .start(let id, _):
            camera.start(deviceID: id) { [weak self] started in
                guard !started else { return }
                Task { @MainActor in self?.send(.inUseElsewhere) }
            }
        case .setMirrored:
            break // the preview view reads `snapshot` and flips its connection
        case .stop:
            camera.stop()
        case .remember(let id):
            defaults.set(id, forKey: Self.preferredKey)
        }
    }

    private func observe() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        func add(_ c: NotificationCenter, _ name: Notification.Name, object: Any? = nil,
                 _ handler: @escaping @MainActor @Sendable (CameraMirrorModel) -> Void) {
            let token = c.addObserver(forName: name, object: object, queue: .main) { [weak self] note in
                let device = note.object as? AVCaptureDevice
                let camera = device.map(CameraDevices.camera)
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let camera, name == AVCaptureDevice.wasConnectedNotification {
                        self.send(.cameraAdded(camera))
                    } else if let camera, name == AVCaptureDevice.wasDisconnectedNotification {
                        self.send(.cameraRemoved(id: camera.id))
                    } else {
                        handler(self)
                    }
                }
            }
            observers.append((c, token))
        }
        add(center, AVCaptureDevice.wasConnectedNotification) { _ in }
        add(center, AVCaptureDevice.wasDisconnectedNotification) { _ in }
        // Another app took the camera (a call started), or the session failed.
        add(center, AVCaptureSession.runtimeErrorNotification, object: camera.session) { model in model.send(.inUseElsewhere) }
        add(center, AVCaptureSession.wasInterruptedNotification, object: camera.session) { model in model.send(.inUseElsewhere) }
        // The mirror goes away with the Mac: sleep, screen sleep or lock, a session switch, display changes.
        let close: @MainActor @Sendable (CameraMirrorModel) -> Void = { model in
            guard model.snapshot.state != .off else { return }
            model.send(.hidden)
            model.mustClose.forEach { $0() }
        }
        add(workspace, NSWorkspace.willSleepNotification, close)
        add(workspace, NSWorkspace.screensDidSleepNotification, close)
        add(workspace, NSWorkspace.sessionDidResignActiveNotification, close)
        add(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), close)
        add(center, NSApplication.didChangeScreenParametersNotification, close)
    }
}
