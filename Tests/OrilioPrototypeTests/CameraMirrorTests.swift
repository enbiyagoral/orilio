// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation
import Testing
@testable import OrilioPrototype

private let faceTime = MirrorCamera(id: "builtin", name: "FaceTime HD Camera", kind: .builtIn)
private let iPhone = MirrorCamera(id: "iphone", name: "iPhone Camera", kind: .continuity)
private let usb = MirrorCamera(id: "usb", name: "USB Camera", kind: .external)

private func snapshot(_ cameras: [MirrorCamera] = [faceTime], preferred: String? = nil) -> MirrorSnapshot {
    var s = MirrorSnapshot()
    s.cameras = cameras
    s.preferredID = preferred
    return s
}

struct MirrorReducerTests {
    @Test func everyAuthorizationStatus() {
        var s = snapshot()
        #expect(MirrorReducer.reduce(&s, .shown(.notDetermined)).isEmpty)
        #expect(s.state == .needsConsent) // the in-island card, before any system prompt
        s = snapshot()
        _ = MirrorReducer.reduce(&s, .shown(.denied))
        #expect(s.state == .denied)
        s = snapshot()
        _ = MirrorReducer.reduce(&s, .shown(.restricted))
        #expect(s.state == .denied)
        s = snapshot()
        #expect(MirrorReducer.reduce(&s, .shown(.authorized)) == [.start(deviceID: "builtin", mirrored: true)])
        #expect(s.state == .live(deviceID: "builtin", mirrored: true))
    }

    @Test func consentThenTheSystemPrompt() {
        var s = snapshot()
        _ = MirrorReducer.reduce(&s, .shown(.notDetermined))
        #expect(MirrorReducer.reduce(&s, .consented) == [.requestAccess])
        #expect(s.state == .requesting)
        #expect(MirrorReducer.reduce(&s, .accessAnswered(granted: true)) == [.start(deviceID: "builtin", mirrored: true)])
        var refused = snapshot()
        _ = MirrorReducer.reduce(&refused, .shown(.notDetermined))
        _ = MirrorReducer.reduce(&refused, .consented)
        #expect(MirrorReducer.reduce(&refused, .accessAnswered(granted: false)).isEmpty)
        #expect(refused.state == .denied)
    }

    @Test func noCameraAtAll() {
        var s = snapshot([])
        #expect(MirrorReducer.reduce(&s, .shown(.authorized)).isEmpty)
        #expect(s.state == .noCamera)
        // Plugging one in while the card is up starts the mirror.
        #expect(MirrorReducer.reduce(&s, .cameraAdded(usb)) == [.start(deviceID: "usb", mirrored: true)])
    }

    @Test func rememberedCameraOrBuiltIn() {
        var s = snapshot([faceTime, usb], preferred: "usb")
        _ = MirrorReducer.reduce(&s, .shown(.authorized))
        #expect(s.activeCamera == usb)
        var missing = snapshot([faceTime], preferred: "usb") // the remembered one isn't connected
        _ = MirrorReducer.reduce(&missing, .shown(.authorized))
        #expect(missing.activeCamera == faceTime)
    }

    @Test func aNewCameraIsOfferedNeverSwitchedTo() {
        var s = snapshot()
        _ = MirrorReducer.reduce(&s, .shown(.authorized))
        #expect(MirrorReducer.reduce(&s, .cameraAdded(iPhone)).isEmpty)
        #expect(s.activeCamera == faceTime)
        #expect(s.notice == .available(iPhone))
        #expect(MirrorReducer.reduce(&s, .acceptOffer) == [.start(deviceID: "iphone", mirrored: true), .remember(deviceID: "iphone")])
        #expect(s.activeCamera == iPhone)
        #expect(s.notice == nil)
    }

    @Test func activeCameraRemovedFallsBackToBuiltIn() {
        var s = snapshot([faceTime, usb], preferred: "usb")
        _ = MirrorReducer.reduce(&s, .shown(.authorized))
        #expect(MirrorReducer.reduce(&s, .cameraRemoved(id: "usb")) == [.start(deviceID: "builtin", mirrored: true)])
        #expect(s.activeCamera == faceTime)
        #expect(s.notice == .switched(from: "USB Camera", to: "FaceTime HD"))
        // The last one gone: no camera, and the session stops.
        #expect(MirrorReducer.reduce(&s, .cameraRemoved(id: "builtin")) == [.stop])
        #expect(s.state == .noCamera)
    }

    @Test func inUseByAnotherApp() {
        var s = snapshot()
        _ = MirrorReducer.reduce(&s, .shown(.authorized))
        #expect(MirrorReducer.reduce(&s, .inUseElsewhere) == [.stop])
        #expect(s.state == .inUseElsewhere)
    }

    @Test func hidingStopsTheCamera() {
        var s = snapshot()
        _ = MirrorReducer.reduce(&s, .shown(.authorized))
        #expect(MirrorReducer.reduce(&s, .hidden) == [.stop]) // collapse, module switch, Esc, Turn off, sleep, lock
        #expect(s.state == .off)
        #expect(MirrorReducer.reduce(&s, .hidden).isEmpty) // nothing left running
        var card = snapshot()
        _ = MirrorReducer.reduce(&card, .shown(.notDetermined))
        #expect(MirrorReducer.reduce(&card, .hidden).isEmpty) // the camera never ran
    }

    @Test func mirroringAndPicking() {
        var s = snapshot([faceTime, iPhone])
        _ = MirrorReducer.reduce(&s, .shown(.authorized))
        #expect(MirrorReducer.reduce(&s, .toggleMirrored) == [.setMirrored(false)])
        #expect(s.state == .live(deviceID: "builtin", mirrored: false))
        #expect(MirrorReducer.reduce(&s, .pick(id: "iphone")) == [.start(deviceID: "iphone", mirrored: false), .remember(deviceID: "iphone")])
        #expect(MirrorReducer.reduce(&s, .pick(id: "nonexistent")).isEmpty)
    }
}

@MainActor
struct MirrorModuleTests {
    private func island() -> (IslandModel, ModuleSettings) {
        let defaults = UserDefaults(suiteName: "orilio.mirror.\(UUID().uuidString)")!
        let modules = ModuleSettings(defaults: defaults)
        let mirror = CameraMirrorModel(defaults: defaults, observeSystem: false)
        return (IslandModel(modules: modules, mirror: mirror), modules)
    }

    @Test func offByDefaultWithNoEntryPoints() {
        let (model, modules) = island()
        #expect(!modules.isVisible(.mirror))
        #expect(!modules.visible.contains(.mirror))
        model.openMirror() // the menu's "Mirror" does nothing while the module is hidden
        #expect(model.state == .collapsed)
        #expect(model.tab != .mirror)
    }

    @Test func turnedOnItOpensAndClosingGoesBack() {
        let (model, modules) = island()
        modules.setVisible(.mirror, true)
        #expect(modules.visible.last == .mirror)
        model.tab = .notes
        model.openMirror()
        #expect(model.tab == .mirror && model.state == .pinned)
        #expect(model.customPanel(for: .pinned) != nil)
        model.dismiss() // collapse: the camera stops and the island returns to Notes
        #expect(model.mirror.state == .off)
        #expect(model.tab == .notes)
    }

    @Test func hidingTheModuleLeavesIt() {
        let (model, modules) = island()
        modules.setVisible(.mirror, true)
        model.openMirror()
        modules.setVisible(.mirror, false)
        #expect(model.mirror.state == .off)
        #expect(model.tab != .mirror)
    }

    @Test func neverAnActivityInTheNotch() {
        let (model, modules) = island()
        modules.setVisible(.mirror, true)
        model.openMirror()
        model.dismiss()
        #expect(model.earLayout.isIdle)
    }
}
