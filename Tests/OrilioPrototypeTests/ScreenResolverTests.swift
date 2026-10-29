// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import CoreGraphics
import Foundation
import Testing
@testable import OrilioPrototype

/// The DELL (2560 × 1440, 1x, main) with the MacBook's notched display (1470 × 956, 2x) below it,
/// as on the development Mac.
private let external = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410), safeAreaTop: 0,
                                  auxLeftWidth: nil, auxRightWidth: nil, isBuiltIn: false, scale: 1)
private let builtIn = ScreenInfo(id: 2, frame: CGRect(x: 508, y: -956, width: 1470, height: 956),
                                 visibleFrame: CGRect(x: 508, y: -956, width: 1470, height: 924), safeAreaTop: 32,
                                 auxLeftWidth: 646, auxRightWidth: 645, isBuiltIn: true, scale: 2)
private let side = ScreenInfo(id: 3, frame: CGRect(x: 2560, y: 200, width: 1920, height: 1080),
                              visibleFrame: CGRect(x: 2560, y: 200, width: 1920, height: 1055), safeAreaTop: 0,
                              auxLeftWidth: nil, auxRightWidth: nil, isBuiltIn: false, scale: 2)

private func settings(_ placement: DisplaySettings.Placement, lid: Bool = true) -> DisplaySettings {
    var settings = DisplaySettings()
    settings.placement = placement
    settings.externalWhenLidClosed = lid
    return settings
}

struct ScreenResolverTests {
    @Test func notchGetsTheNotchAndOthersThePill() {
        let notch = builtIn.geometry
        #expect(notch.hasNotch && notch.notchWidth == 179)
        #expect(notch.windowFrame(for: .collapsed) == CGRect(x: 1154, y: -32, width: 179, height: 32))
        let pill = external.geometry
        #expect(!pill.hasNotch)
        #expect(pill.windowFrame(for: .collapsed) == CGRect(x: 1170, y: 1410, width: 220, height: 30))
    }

    @Test func builtInOnly() {
        #expect(ScreenResolver.targets([external, builtIn], settings: settings(.builtIn), pointer: 1).map(\.id) == [2])
    }

    @Test func allDisplays() {
        #expect(ScreenResolver.targets([external, builtIn, side], settings: settings(.all), pointer: nil).map(\.id) == [1, 2, 3])
    }

    @Test func displayWithThePointer() {
        let screens = [external, builtIn, side]
        #expect(ScreenResolver.targets(screens, settings: settings(.pointer), pointer: 3).map(\.id) == [3])
        #expect(ScreenResolver.targets(screens, settings: settings(.pointer), pointer: nil).map(\.id) == [1]) // unknown: the main one
        #expect(ScreenResolver.display(at: CGPoint(x: 1000, y: -500), in: screens) == 2)
        #expect(ScreenResolver.display(at: CGPoint(x: 3000, y: 800), in: screens) == 3)
        #expect(ScreenResolver.display(at: CGPoint(x: 3000, y: 100), in: screens) == nil) // the gap under the side display
        #expect(ScreenResolver.display(at: CGPoint(x: 1280, y: 1440), in: screens) == 1) // pushed to the top edge
    }

    @Test func lidClosedMovesToTheMainExternalAsAPill() {
        let clamshell = [external] // the built-in display is gone from the list
        let target = ScreenResolver.targets(clamshell, settings: settings(.builtIn), pointer: nil)
        #expect(target.map(\.id) == [1])
        #expect(!target[0].geometry.hasNotch)
        #expect(ScreenResolver.targets(clamshell, settings: settings(.builtIn, lid: false), pointer: nil).isEmpty)
    }

    @Test func pinnedIslandSurvivesItsDisplayBeingUnplugged() {
        // Two islands (all displays); the pinned one was on the built-in display, which goes away.
        let moved = ScreenResolver.assign(["a": 1, "b": 2], open: ["b"], to: [1])
        #expect(moved == ["b": 1]) // the pinned one keeps going on the remaining display; "a" closes
        // Pointer mode: one island follows to the new display.
        #expect(ScreenResolver.assign(["a": 1], open: [], to: [3]) == ["a": 3])
        // Islands whose display stays keep it; new displays are left for new islands.
        #expect(ScreenResolver.assign(["a": 1], open: [], to: [1, 2]) == ["a": 1])
        #expect(ScreenResolver.assign(["a": 1, "b": 2], open: [], to: []) == [:])
    }

    @Test func theAppsIslandTakesOverWhenItsDisplayGoes() {
        // "All displays", the lid closes: the app's island ("p", built-in 1) takes the external one.
        #expect(ScreenResolver.assign(["p": 1, "x": 2], open: [], to: [2], keep: "p") == ["p": 2])
        // A closed island's display before an open one's.
        #expect(ScreenResolver.assign(["p": 1, "x": 2, "y": 3], open: ["y"], to: [2, 3], keep: "p") == ["p": 2, "y": 3])
        // Its own display stays: nothing changes.
        #expect(ScreenResolver.assign(["p": 1, "x": 2], open: [], to: [1, 2], keep: "p") == ["p": 1, "x": 2])
        // Nothing left at all: it closes too.
        #expect(ScreenResolver.assign(["p": 1], open: [], to: [], keep: "p") == [:])
    }

    @Test func overAFullscreenAppTheIslandShowsOnlyWhenItShould() {
        let shows = IslandWindowController.shows
        #expect(shows(nil, false, false, false)) // no fullscreen app: always
        #expect(shows(.show, false, false, false))
        #expect(!shows(.hide, true, false, false)) // "Hide": a reveal doesn't count
        #expect(shows(.hide, false, false, true)) // … a meeting starting now does
        #expect(shows(.hide, false, true, false)) // … and so does an open island (the shortcut)
        #expect(!shows(.reveal, false, false, false))
        #expect(shows(.reveal, true, false, false))
    }

    @Test func mixedScaleFactorsSnapToEachPixelGrid() {
        // A centre that falls between pixels: whole points on 1x, half points allowed on 2x.
        var oneX = external.geometry // 1x
        oneX.centerX = 1280.25
        #expect(oneX.windowFrame(for: .collapsed).minX == 1170)
        var twoX = builtIn.geometry // 2x
        twoX.centerX = 1243.75
        #expect(twoX.windowFrame(for: .collapsed).minX == 1154.5)
        #expect(side.geometry.windowFrame(for: .collapsed).midX == side.frame.midX)
    }

    @Test func oldNotchedDisplaySettingCarriesOver() {
        let defaults = UserDefaults(suiteName: "orilio.displays.\(UUID().uuidString)")!
        #expect(DisplaySettings(defaults).placement == .pointer)
        defaults.set(true, forKey: SettingsKeys.preferNotchedDisplay)
        #expect(DisplaySettings(defaults).placement == .builtIn)
        defaults.set("all", forKey: DisplaySettings.Keys.placement)
        #expect(DisplaySettings(defaults).placement == .all)
        #expect(DisplaySettings(defaults).fullscreen == .reveal)
    }
}

struct FullscreenDetectorTests {
    private let screens = [external, builtIn]

    @Test func aWindowCoveringTheWholeDisplayIsFullscreen() {
        // Window-server coordinates: the built-in display (below the main one) starts at y = 1440.
        let windows = [FullscreenDetector.WindowInfo(bounds: CGRect(x: 508, y: 1440, width: 1470, height: 956), layer: 0, ownerPID: 42)]
        #expect(FullscreenDetector.displays(windows: windows, screens: screens, me: 1) == [2])
    }

    @Test func zoomedWindowsOwnWindowsAndOverlaysAreNot() {
        let windows = [
            FullscreenDetector.WindowInfo(bounds: CGRect(x: 0, y: 30, width: 2560, height: 1410), layer: 0, ownerPID: 42), // below the menu bar
            FullscreenDetector.WindowInfo(bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440), layer: 0, ownerPID: 1),   // Orilio itself
            FullscreenDetector.WindowInfo(bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440), layer: 25, ownerPID: 42), // an overlay
        ]
        #expect(FullscreenDetector.displays(windows: windows, screens: screens, me: 1).isEmpty)
    }
}
