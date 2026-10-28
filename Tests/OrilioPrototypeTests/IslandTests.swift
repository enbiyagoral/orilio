import CoreGraphics
import Testing
@testable import OrilioPrototype

@MainActor
struct IslandTests {
    @Test func clickPinsAndHoverExitKeepsItOpen() async throws {
        let model = IslandModel()
        model.isPointerBusy = { false } // independent of the real mouse during the run
        model.tap()
        #expect(model.state == .pinned)
        model.hover(false)
        try await Task.sleep(for: IslandModel.closeDelay * 2)
        #expect(model.state == .pinned)
        model.dismiss()
        #expect(model.state == .collapsed)
    }

    @Test func hoverOpensAfterDelayAndQuickExitCancels() async throws {
        let model = IslandModel()
        model.isPointerBusy = { false } // independent of the real mouse during the run
        model.hover(true)
        model.hover(false) // pointer just passed over
        try await Task.sleep(for: model.hoverDelay * 2)
        #expect(model.state == .collapsed)

        model.hover(true)
        try await Task.sleep(for: model.hoverDelay * 2)
        #expect(model.state == .expanded)
        model.hover(false)
        try await Task.sleep(for: IslandModel.closeDelay * 2)
        #expect(model.state == .collapsed)
    }

    @Test func hoverDisabledNeverOpens() async throws {
        let model = IslandModel()
        model.isPointerBusy = { false } // independent of the real mouse during the run
        model.hoverOpens = false
        model.hover(true)
        try await Task.sleep(for: model.hoverDelay * 2)
        #expect(model.state == .collapsed)
    }

    @Test func notchGeometryCentersOnNotch() {
        // 14" MacBook Pro in its default "looks like 1512×982" mode.
        let g = IslandGeometry.make(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                    auxLeftWidth: 662, auxRightWidth: 664, menuBarHeight: 32)
        #expect(g.hasNotch)
        #expect(g.notchWidth == 186)
        #expect(g.collapsed == CGSize(width: 186, height: 32))
        let frame = g.windowFrame(for: .collapsed)
        #expect(frame.minX == 662 && frame.maxY == 982)
        #expect(g.windowFrame(for: .pinned).midX == 755)
        #expect(g.windowFrame(for: .expanded).midX == 755)
        #expect(g.size(for: .expanded) == g.size(for: .pinned)) // hover opens the full panel (M3 hub design)
    }

    @Test func noNotchFallsBackToPillOnSecondaryScreen() {
        let g = IslandGeometry.make(screenFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), safeAreaTop: 0,
                                    auxLeftWidth: nil, auxRightWidth: nil, menuBarHeight: 25)
        #expect(!g.hasNotch)
        #expect(g.collapsed == CGSize(width: IslandGeometry.pillWidth, height: 25))
        #expect(g.windowFrame(for: .collapsed).midX == CGFloat(1512 + 1280))
    }
}
