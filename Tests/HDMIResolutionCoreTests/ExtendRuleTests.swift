import XCTest
@testable import HDMIResolutionCore

/// The laptop screen is the main display at 0,0 and occupies 1680x1050 unless
/// a test says otherwise, so "above, centred" for a display of width w and
/// height h is x = (1680 - w) / 2, y = -h.
final class ExtendRuleTests: RuleTestCase {
    private var positions: String { "\(backend.pos(2)) \(backend.pos(1))" }

    func test2KDisplayBesideTheLaptopScreenGoesAboveCentred() {
        start(laptop(), monitor(Modes.qhd, edid: Fixture.dell))
        XCTAssertEqual(backend.pos(2), "-440,-1440")
        XCTAssertEqual(backend.pos(1), "0,0")
        XCTAssertEqual(backend.calls, ["output.display-2.position.-440,-1440 output.display-1.position.0,0"])
        XCTAssertEqual(backend.size(1), "1680x1050", "laptop screen mode untouched")
        XCTAssertEqual(baseline, userMode, "user mode tracked")
        XCTAssertEqual(displayState(Fixture.dellKey, .baseline), "2560 1440 60 1")
        assertLog(#"Layout changed: initial -> extend \[display-2: DELL P2723DE, USB-C/DisplayPort\]"#)
        assertLog("Placed display-2 above display-1, centred")
    }

    func test1KDisplay() {
        start(laptop(), monitor(Modes.fhd))
        XCTAssertEqual(positions, "-120,-1080 0,0")
    }

    func test4KDisplayAtEveryCommonSize() {
        // "Looks like 1920x1080", the usual setting of a 4K display.
        start(laptop(), monitor(Modes.uhd, mode: "2"))
        XCTAssertEqual(positions, "-120,-1080 0,0")
        // "Looks like 2560x1440".
        change(laptop())
        change(laptop(), monitor(Modes.uhd, mode: "3"))
        XCTAssertEqual(positions, "-440,-1440 0,0")
        // Native 3840x2160.
        change(laptop())
        change(laptop(), monitor(Modes.uhd, mode: "1"))
        XCTAssertEqual(positions, "-1080,-2160 0,0")
    }

    func testDisplayNarrowerThanTheLaptopScreenIsTheCentredOne() {
        start(laptop(), monitor(Modes.qhd, mode: "13"))
        XCTAssertEqual(positions, "200,-720 0,0")
    }

    func testOddWidthDifferenceRoundsDown() {
        start(laptop(), monitor(Modes.qhd, mode: "40"))
        XCTAssertEqual(positions, "157,-768 0,0", "1366 wide: (1680 - 1366) / 2 = 157")
        change(laptop())
        change(laptop(), monitor(Modes.qhd, mode: "41"))
        XCTAssertEqual(positions, "-440,-1440 0,0", "2561 wide: the laptop screen sits 440 in from its left edge")
    }

    func testPortraitDisplay() {
        var portrait = monitor(Modes.qhd)
        portrait.rotation = 90
        start(laptop(), portrait)
        XCTAssertEqual(positions, "120,-2560 0,0", "occupies 1440x2560")
    }

    func testDisplayToTheLeftOfTheLaptopScreen() {
        start(laptop(), monitor(Modes.fhd, at: Point(x: -1920, y: 0)))
        XCTAssertEqual(positions, "-120,-1080 0,0")
    }

    /// Moving a display to 0,0 would make it the main display. Whichever of
    /// the two is main must stay exactly where it is.
    func testMainDisplayStaysMain() {
        start(laptop(at: Point(x: 2560, y: 390)), monitor(Modes.qhd, at: .zero))
        XCTAssertEqual(positions, "0,0 440,1440", "the display is main: the laptop screen moves below it")
        XCTAssertEqual(backend.calls.count, 1)
    }

    /// The display that was main while extended is main again when extend
    /// mode next starts, whatever macOS did in between.
    func testMainDisplayIsKeptAcrossMirroring() {
        start(laptop(), monitor(Modes.qhd))
        XCTAssertEqual(positions, "-440,-1440 0,0")
        change(laptop(mirrors: 2), monitor(Modes.qhd, at: .zero))
        // Out of mirror mode with the monitor left as the main display.
        change(laptop(at: Point(x: 2560, y: 0)), monitor(Modes.qhd, at: .zero))
        XCTAssertEqual(positions, "-440,-1440 0,0", "the laptop screen is main again")

        // Had the user made the monitor main, that is what is kept.
        change(laptop(at: Point(x: 440, y: 1440)), monitor(Modes.qhd, at: .zero))
        change(laptop())
        change(laptop(at: Point(x: 2560, y: 0)), monitor(Modes.qhd, at: .zero))
        XCTAssertEqual(positions, "0,0 440,1440", "the monitor stays main")
    }

    func testAlreadyAboveAndCentredAppliesNothing() {
        start(laptop(), monitor(Modes.qhd, at: Point(x: -440, y: -1440)))
        XCTAssertEqual(backend.calls, [])
        assertLog("display-2 is already above display-1 and centred")
    }

    func testExtendRuleSwitchedOffLeavesTheLayoutAlone() {
        config("enabled=1", "target_width=1920", "target_height=1080", "extend_top_center=0")
        start(laptop(), monitor(Modes.qhd))
        XCTAssertEqual(backend.calls, [])
        XCTAssertEqual(backend.pos(2), "1680,0")
    }

    func testTwoExternalDisplaysAreLeftAlone() {
        start(laptop(), monitor(Modes.qhd), monitor(3, Modes.fhd, at: Point(x: 4240, y: 0)))
        XCTAssertEqual(backend.calls, [])
    }

    func testVirtualDisplayOnlyIsLeftAlone() {
        var sidecar = monitor(Modes.fhd)
        sidecar.isVirtual = true
        start(laptop(), sidecar)
        XCTAssertEqual(backend.calls, [])
    }

    func testSecondDisplayConnectedButDisabledDoesNotCount() {
        var off = monitor(3, Modes.fhd, at: .zero)
        off.enabled = false
        start(laptop(), monitor(Modes.qhd), off)
        XCTAssertEqual(positions, "-440,-1440 0,0")
    }

    func testLidClosedDoesNothing() {
        start(monitor(Modes.qhd, at: .zero))
        XCTAssertEqual(backend.calls, [])
        assertLog("Layout changed: initial -> panel-off")
    }

    func testManualLayoutIsNotFoughtUntilExtendModeStartsAgain() {
        start(laptop(), monitor(Modes.qhd))
        XCTAssertEqual(positions, "-440,-1440 0,0", "placed on start")
        // The user drags the display to the right of the laptop screen.
        change(laptop(), monitor(Modes.qhd))
        XCTAssertEqual(positions, "1680,0 0,0", "manual layout kept")
        XCTAssertEqual(backend.calls.count, 1)
        change(laptop(), monitor(Modes.qhd, mode: "24"))
        XCTAssertEqual(positions, "1680,0 0,0", "manual layout kept after a resolution change")
        // Unplugged and plugged in again: extend mode starts afresh.
        change(laptop())
        change(laptop(), monitor(Modes.qhd))
        XCTAssertEqual(positions, "-440,-1440 0,0", "placed again after replug")
    }

    func testResolutionChangeWhileStillInPlaceIsRecentred() {
        start(laptop(), monitor(Modes.qhd))
        change(laptop(), monitor(Modes.qhd, mode: "24", at: Point(x: -440, y: -1440)))
        XCTAssertEqual(positions, "-120,-1080 0,0")
    }

    func testLaptopScreenResolutionChangeWhileStillInPlaceIsRecentred() {
        start(laptop(), monitor(Modes.qhd))
        // "Looks like 1440x900" on the laptop screen.
        change(laptop(mode: "3"), monitor(Modes.qhd, at: Point(x: -440, y: -1440)))
        XCTAssertEqual(positions, "-560,-1440 0,0")
    }

    /// What happened on real hardware: the resolution was changed in System
    /// Settings, macOS moved the display to fit, and it stayed off centre.
    func testResolutionChangedInSystemSettingsIsCentredAgain() {
        start(laptop(), monitor(Modes.qhd))
        XCTAssertEqual(positions, "-440,-1440 0,0")
        // 1920x1080: macOS keeps the lower left corner.
        change(laptop(), monitor(Modes.qhd, mode: "24", at: Point(x: -440, y: -1080)))
        XCTAssertEqual(positions, "-120,-1080 0,0")
        assertLog("Placed display-2 above display-1, centred for its new size")
        // 1280x720 HiDPI, where the real monitor ended up at -240,-720.
        change(laptop(), monitor(Modes.qhd, mode: "12", at: Point(x: -240, y: -720)))
        XCTAssertEqual(positions, "200,-720 0,0")
        XCTAssertEqual(baseline, userMode, "the laptop screen's mode is still the user's")
    }

    func testResolutionChosenInTheMenuIsCentredAndBecomesTheUsersOwn() {
        start(laptop(), monitor(Modes.qhd, edid: Fixture.dell))
        // What the menu does: set the mode, then the rules see the change.
        XCTAssertTrue(backend.apply([.mode(OutputRef(id: 2, name: "display-2"), modeId: "24")]))
        XCTAssertEqual(positions, "-440,-1080 0,0", "moved by macOS, not centred")
        settle()
        XCTAssertEqual(positions, "-120,-1080 0,0")
        XCTAssertEqual(displayState(Fixture.dellKey, .baseline), "1920 1080 60 1", "the new mode is the user's own")
        for _ in 0..<3 { engine.pass() }
        XCTAssertEqual(backend.calls.count, 3, "placed, resolution, placed again: nothing more")
    }

    func testResolutionChangeAfterTheUserMovedTheDisplayIsLeftAlone() {
        start(laptop(), monitor(Modes.qhd))
        change(laptop(), monitor(Modes.qhd, at: Point(x: 1680, y: 300)))
        change(laptop(), monitor(Modes.qhd, mode: "24", at: Point(x: 1680, y: 660)))
        XCTAssertEqual(positions, "1680,660 0,0")
        XCTAssertEqual(backend.calls.count, 1)
    }

    func testExtendRuleSwitchedOffForThisDisplayOnly() {
        config("extend_off_display=\(Fixture.dellKey) DELL P2723DE [USB-C/DisplayPort]")
        start(laptop(), monitor(Modes.qhd, edid: Fixture.dell))
        XCTAssertEqual(backend.calls, [])
        XCTAssertEqual(positions, "1680,0 0,0")
        // Another display is still placed.
        change(laptop())
        change(laptop(), monitor(3, Modes.fhd, edid: Fixture.noName))
        XCTAssertEqual("\(backend.pos(3)) \(backend.pos(1))", "-120,-1080 0,0")
        // And the switched-off one is recognised on another port.
        change(laptop())
        change(laptop(), monitor(7, Modes.qhd, edid: Fixture.dell))
        XCTAssertEqual(backend.pos(7), "1680,0")
        XCTAssertEqual(backend.calls.count, 1)
    }

    func testRefusedPlacementIsNotRetried() {
        backend.failApply = true
        start(laptop(), monitor(Modes.qhd))
        change(laptop(), monitor(Modes.qhd))
        XCTAssertEqual(backend.calls.count, 1, "exactly one attempt")
        assertLog("ERROR: macOS refused placing display-2 above display-1")
    }

    func testRestartAppliesThePlacementAgain() {
        start(laptop(), monitor(Modes.qhd))
        change(laptop(), monitor(Modes.qhd))
        XCTAssertEqual(positions, "1680,0 0,0", "manual layout kept")
        // Saving a setting from the menu restarts the rules.
        engine.start()
        settle()
        XCTAssertEqual(positions, "-440,-1440 0,0")
    }

    func testNothingIsReappliedWhenNothingChanged() {
        start(laptop(), monitor(Modes.qhd))
        for _ in 0..<5 { engine.pass() }
        XCTAssertEqual(backend.calls.count, 1)
    }

    func testPlacementGeometry() {
        func place(_ display: (Int, Int), _ panel: (Int, Int)) -> String {
            let d = Output(id: 2, name: "d", isPanel: false, pos: Point(x: 5000, y: 5000),
                           logical: Size(w: display.0, h: display.1), currentModeId: nil, modes: [])
            let p = Output(id: 1, name: "p", isPanel: true, pos: .zero,
                           logical: Size(w: panel.0, h: panel.1), currentModeId: nil, modes: [])
            let target = Engine.placement(display: d, panel: p)
            return "\(target.display) \(target.panel)"
        }
        XCTAssertEqual(place((2560, 1440), (1680, 1050)), "-440,-1440 0,0")
        XCTAssertEqual(place((1920, 1080), (1680, 1050)), "-120,-1080 0,0")
        XCTAssertEqual(place((3840, 2160), (1680, 1050)), "-1080,-2160 0,0")
        XCTAssertEqual(place((1680, 1050), (1680, 1050)), "0,-1050 0,0")
        XCTAssertEqual(place((1280, 720), (1512, 982)), "116,-720 0,0")
        // The two must never end up at the same position: that would read as mirroring.
        XCTAssertNotEqual(place((1680, 1050), (1680, 1050)).split(separator: " ")[0], "0,0")
    }
}
