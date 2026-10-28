@preconcurrency import AVFoundation
import AppKit
import SwiftUI

// The M4.1 Camera Mirror design, value for value: a 520 × 260 card (radius 34) before the camera
// runs, a 560 × 392 mirror (radius 36) while it does.
private enum Design {
    static let mint = SettingsDesign.mint
    static let ink = SettingsDesign.hex(0x00140D)
    static let green = SettingsDesign.hex(0x34C759)
    static let card = CGSize(width: 520, height: 260)
    static let live = CGSize(width: 560, height: 392)
}

extension CameraMirrorModel {
    /// The island's open size for the mirror (scaled with Settings › Appearance › Panel size).
    func panelSize(scale: CGFloat, hoverCard: Bool = false) -> CGSize {
        let base = if case .live = state, !hoverCard { Design.live } else { Design.card }
        return CGSize(width: (base.width * scale).rounded(), height: (base.height * scale).rounded())
    }
}

/// The Camera Mirror module in the island.
struct MirrorView: View {
    let mirror: CameraMirrorModel
    /// The island was opened by hovering: the camera waits for a click.
    let hoverOnly: Bool
    let close: () -> Void

    var body: some View {
        let mint = Design.mint
        Group {
            if hoverOnly {
                StatusCard(tone: .ask(tile: mint.opacity(0.12), ink: mint), symbol: "camera", title: "Camera Mirror",
                           detail: "Click to turn on the camera. It stops the moment the island closes.", layout: .ask)
            } else {
                switch mirror.state {
                case .off, .needsConsent:
                    StatusCard(tone: .ask(tile: mint.opacity(0.12), ink: mint), symbol: "camera", title: "Use the camera as a mirror?",
                               detail: "Preview only. Nothing is recorded, saved or sent. macOS will ask you to confirm next.",
                               primary: .init("Continue") { mirror.send(.consented) }, secondary: .init("Not now", close), layout: .ask)
                case .requesting:
                    StatusCard(tone: .ask(tile: mint.opacity(0.12), ink: mint), symbol: "camera", title: "Use the camera as a mirror?",
                               detail: "Confirm in the macOS dialog to see yourself here.", secondary: .init("Not now", close), layout: .ask)
                case .denied:
                    StatusCard(tone: .warn, symbol: "video.slash", title: "Camera access is off",
                               detail: "Turn on Orilio in Privacy & Security › Camera to use the mirror.",
                               primary: .init("Open System Settings") { NSWorkspace.shared.open(CameraDevices.privacySettingsURL) },
                               secondary: .init("Close", close))
                case .noCamera:
                    StatusCard(tone: .empty, symbol: "camera", title: "No camera found",
                               detail: "Connect one, or use your iPhone with Continuity Camera.", secondary: .init("Close", close))
                case .inUseElsewhere:
                    StatusCard(tone: .warn, symbol: "video.slash", title: "Camera is in use",
                               detail: "Another app is using it. Close the call to see yourself here.",
                               primary: .init("Try again") { mirror.send(.hidden); mirror.setVisible(true) },
                               secondary: .init("Close", close))
                case .live:
                    LiveMirror(mirror: mirror, close: close)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The live mirror: a 38 pt header ("Mirror" and close), then the preview (radius 24) with its
/// label, the camera picker, the mirror toggle and Turn off.
private struct LiveMirror: View {
    let mirror: CameraMirrorModel
    let close: () -> Void
    @State private var pickerOpen = false

    var body: some View {
        let snapshot = mirror.snapshot
        let mirrored = snapshot.mirrored
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 7) {
                    Circle().fill(Design.green).frame(width: 7, height: 7).shadow(color: Design.green.opacity(0.8), radius: 4)
                    Text("Mirror").font(.system(size: 12.5, weight: .semibold))
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Turn off camera and close")
            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            ZStack(alignment: .topLeading) {
                CameraPreview(session: mirror.camera.session, mirrored: mirrored)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                Text("PREVIEW · NOT RECORDING")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.66)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.leading, 14)
                    .padding(.top, 12)

                if let notice = snapshot.notice {
                    NoticePill(notice: notice, mirror: mirror)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 14)
                        .padding(.top, 10)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Spacer()
                    if pickerOpen {
                        CameraPicker(snapshot: snapshot) { id in
                            mirror.send(.pick(id: id))
                            pickerOpen = false
                        }
                        .padding(.bottom, 10)
                    }
                    HStack {
                        Button { pickerOpen.toggle() } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "video").font(.system(size: 13, weight: .medium))
                                Text(snapshot.activeCamera?.shortName ?? "Camera").font(.system(size: 13, weight: .medium))
                                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                            }
                            .padding(.leading, 10)
                            .padding(.trailing, 12)
                            .frame(height: 40)
                            .background(.black.opacity(0.5), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Camera: \(snapshot.activeCamera?.name ?? "")")
                        Spacer()
                        Button { mirror.send(.toggleMirrored) } label: {
                            Image(systemName: "flip.horizontal")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(mirrored ? Design.mint : .white)
                                .frame(width: 40, height: 40)
                                .background(mirrored ? Design.mint.opacity(0.22) : .black.opacity(0.5), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Mirror image")
                        .accessibilityValue(mirrored ? "On" : "Off")
                        Button(action: close) {
                            HStack(spacing: 6) {
                                Image(systemName: "video.slash").font(.system(size: 12, weight: .semibold))
                                Text("Turn off").font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                            .background(.white.opacity(0.92), in: Capsule())
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(14)
            }
            .padding(EdgeInsets(top: 4, leading: 18, bottom: 18, trailing: 18))
        }
    }
}

/// The design's camera list: a dark rounded menu of 44 pt rows with a mint check.
private struct CameraPicker: View {
    let snapshot: MirrorSnapshot
    let pick: (String) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(snapshot.cameras) { camera in
                let active = snapshot.activeCamera?.id == camera.id
                Button { pick(camera.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: camera.kind == .continuity ? "iphone" : camera.kind == .external ? "video" : "camera")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(camera.name).font(.system(size: 13, weight: .medium))
                            Text(camera.detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer(minLength: 0)
                        if active {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Design.mint)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(active ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(6)
        .frame(width: 280)
        .background(Color(red: 22 / 255, green: 22 / 255, blue: 26 / 255, opacity: 0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 16)
    }
}

/// "iPhone Camera is available · Switch", or "USB Camera disconnected · switched to FaceTime HD".
private struct NoticePill: View {
    let notice: MirrorNotice
    let mirror: CameraMirrorModel

    var body: some View {
        HStack(spacing: 8) {
            switch notice {
            case .available(let camera):
                Text("\(camera.name) is available").foregroundStyle(.white.opacity(0.85))
                Button("Switch") { mirror.send(.acceptOffer) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Design.mint)
            case .switched(let from, let to):
                Text("\(from) disconnected · switched to \(to)").foregroundStyle(.white.opacity(0.85))
            }
            Button { mirror.send(.dismissNotice) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The live preview: `AVCaptureVideoPreviewLayer`, aspect fill, mirrored by its connection.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool

    func makeNSView(context: Context) -> PreviewView { PreviewView(session: session) }

    func updateNSView(_ view: PreviewView, context: Context) { view.setMirrored(mirrored) }
}

final class PreviewView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    private var mirrored = true
    private var started: NSObjectProtocol?

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.17, green: 0.14, blue: 0.13, alpha: 1).cgColor // #2B2422 until frames arrive
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
        setAccessibilityElement(true)
        setAccessibilityLabel("Camera preview")
        // The preview's connection exists only once the session runs: apply the choice then too.
        started = NotificationCenter.default.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: session,
                                                         queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyMirroring() }
        }
    }

    deinit {
        if let started { NotificationCenter.default.removeObserver(started) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        CATransaction.commit()
    }

    /// A mirror shows you as others don't: flipped unless the user turns it off. Automatic
    /// mirroring is off so the choice holds for every camera.
    func setMirrored(_ mirrored: Bool) {
        self.mirrored = mirrored
        applyMirroring()
    }

    private func applyMirroring() {
        guard let connection = preview.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }
}
