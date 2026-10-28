import CoreGraphics
import Testing
@testable import OrilioPrototype

/// The M5 no-notch design: the same panel, floating 6 pt below the menu bar, its tab row inside.
struct FloatingLayoutTests {
    private let notched = IslandGeometry.make(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                              auxLeftWidth: 662, auxRightWidth: 664, menuBarHeight: 32)
    private let external = IslandGeometry.make(screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440), safeAreaTop: 0,
                                               auxLeftWidth: nil, auxRightWidth: nil, menuBarHeight: 25)

    @Test func eachDisplayGetsItsOwnMode() {
        #expect(notched.layout == .notch && notched.openTop == 0)
        #expect(external.layout == .floating && external.openTop == 25 + 6)
    }

    @Test func theFloatingPanelIsTheSamePanelBelowTheMenuBar() {
        for state in [IslandState.expanded, .pinned] {
            let floating = external.size(for: state)
            #expect(floating.width == notched.size(for: state).width) // same panel-size setting
            #expect(floating.height == 25 + 6 + IslandGeometry.headerHeight + IslandGeometry.contentHeight)
        }
        // A module's own panel (mirror, onboarding, Quick Look) moves down the same way.
        let panel = CGSize(width: 760, height: 480)
        #expect(external.size(for: .pinned, panel: panel).height == CGFloat(511))
        #expect(notched.size(for: .pinned, panel: panel).height == 480)
        #expect(external.size(for: .dropTarget).height == 31 + IslandGeometry.dropTargetHeight)
    }

    @Test func collapsedStaysInsideTheMenuBar() {
        #expect(external.size(for: .collapsed) == CGSize(width: IslandGeometry.pillWidth, height: 25))
        #expect(external.windowFrame(for: .collapsed).height == 25) // the capsule is inset 3 pt inside it
        #expect(notched.size(for: .collapsed).width == notched.notchWidth)
    }
}
