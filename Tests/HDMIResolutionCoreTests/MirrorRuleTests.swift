import XCTest
@testable import HDMIResolutionCore

/// A macOS mirror set shows one desktop, in the mode of the display the others
/// mirror. In these tests `mirrors: 1` on a display means the set follows the
/// laptop screen, and `laptop(mirrors: 2)` means it follows the display.
final class MirrorRuleTests: RuleTestCase {
    private func mirroredOnPanel(_ modes: [DisplayMode], mode: String? = nil, id: UInt32 = 2, edid: Data? = nil) -> MockOutput {
        monitor(id, modes, mode: mode, at: .zero, mirrors: 1, edid: edid)
    }

    // MARK: A 16:10 laptop screen, which has no 16:9 mode of its own

    func testProjectorMirroringTheLaptopScreenTakesOverTheMirrorSet() {
        start(laptop())
        XCTAssertEqual(baseline, userMode, "user mode tracked while alone")
        change(laptop(), mirroredOnPanel(Modes.fhd))
        // The laptop screen cannot show 1920x1080 itself; the projector can,
        // so the set is turned round to follow the projector.
        XCTAssertEqual(backend.calls, ["output.display-1.mirror.display-2"])
        XCTAssertEqual(backend.output(1)?.mirrors, 2)
        XCTAssertEqual(backend.output(2)?.mirrors, 0)
        XCTAssertEqual(backend.size(2), "1920x1080")
        XCTAssertEqual(pending, userMode, "user mode saved for restore")
        XCTAssertEqual(baseline, userMode, "mirrored mode not mistaken for the user mode")
        assertLog("Layout changed: no-display -> mirror ")
        assertLog("Applied mirrored mode 1920x1080 on display-2")
        // Unplugged, and macOS put the laptop screen back by itself.
        change(laptop())
        XCTAssertEqual(pending, "none", "pending restore cleared")
        XCTAssertEqual(backend.calls.count, 1, "no further call needed")
        assertLog("User modes are already back in place")
    }

    func testLaptopScreenLeftAtAnotherModeIsPutBack() {
        start(laptop())
        change(laptop(), mirroredOnPanel(Modes.fhd))
        // macOS left the laptop screen at 1920x1200 when mirroring ended.
        change(laptop(mode: "5"))
        XCTAssertEqual(backend.size(1), "1680x1050", "user mode restored")
        XCTAssertEqual(backend.scale(1), 2, "as the HiDPI mode it was")
        XCTAssertEqual(backend.calls.last, "output.display-1.mode.4")
        XCTAssertEqual(pending, "none")
        assertLog("Restored user modes")
    }

    func testMonitorLeadingTheSetIsSetToTheTargetAndRestored() {
        start(laptop(), monitor(Modes.qhd, at: Point(x: -440, y: -1440), edid: Fixture.dell))
        XCTAssertEqual(backend.calls, [])
        XCTAssertEqual(displayState(Fixture.dellKey, .baseline), "2560 1440 60 1", "display mode tracked in extend mode")
        // "Optimise for" the monitor: the laptop screen mirrors it.
        change(laptop(mirrors: 2), monitor(Modes.qhd, at: .zero, edid: Fixture.dell))
        XCTAssertEqual(backend.calls, ["output.display-2.mode.24"], "60 Hz chosen over 50 and 24")
        XCTAssertEqual(backend.size(2), "1920x1080")
        XCTAssertEqual(pending, userMode)
        XCTAssertEqual(displayState(Fixture.dellKey, .pending), "2560 1440 60 1", "display mode saved for restore")
        assertLog(#"Layout changed: extend -> mirror \[display-2: DELL P2723DE, USB-C/DisplayPort\]"#)
        // macOS keeps the monitor at the mirrored size when extending again.
        change(laptop(), monitor(Modes.qhd, mode: "24", edid: Fixture.dell))
        XCTAssertEqual(backend.size(2), "2560x1440", "display restored")
        XCTAssertEqual(backend.size(1), "1680x1050")
        XCTAssertEqual("\(pending) \(displayState(Fixture.dellKey, .pending))", "none none", "pending restores cleared")
        XCTAssertEqual("\(backend.pos(2)) \(backend.pos(1))", "-440,-1440 0,0", "placed using the restored sizes")
    }

    func testDisplayNeverSeenExtendedGoesBackToTheSizeMacOSMirroredAt() {
        start(laptop())
        change(laptop(mirrors: 2), monitor(Modes.qhd, at: .zero, edid: Fixture.dell))
        XCTAssertEqual(backend.size(2), "1920x1080")
        change(laptop(), monitor(Modes.qhd, mode: "24", edid: Fixture.dell))
        XCTAssertEqual(backend.size(2), "2560x1440")
    }

    func testMirrorSetAlreadyAtTheTargetNeedsNoChange() {
        start(laptop())
        change(laptop(mirrors: 2), monitor(Modes.fhd, at: .zero))
        XCTAssertEqual(backend.calls, [])
        XCTAssertEqual(pending, userMode, "the restore is owed all the same")
        assertLog("Mirroring is already at 1920x1080")
    }

    func testNoDisplayInTheSetHasTheTarget() {
        config("enabled=1", "target_width=3000", "target_height=2000")
        start(laptop(), mirroredOnPanel(Modes.qhd))
        XCTAssertEqual(backend.calls, [])
        XCTAssertEqual(backend.size(1), "1680x1050")
        XCTAssertEqual(backend.size(2), "2560x1440")
        assertLog("ERROR: no display in the mirror set has a 3000x2000 mode")
    }

    func testThreeDisplaysInOneSet() {
        config("enabled=1", "target_width=2560", "target_height=1440")
        start(laptop(), mirroredOnPanel(Modes.fhd), mirroredOnPanel(Modes.qhd, id: 3))
        XCTAssertEqual(backend.calls, ["output.display-1.mirror.display-3 output.display-2.mirror.display-3"])
        XCTAssertEqual(backend.size(3), "2560x1440")
    }

    // MARK: What a real MacBook reports while mirrored

    /// While mirrored, the laptop screen lists the size the set last ran at as
    /// a mode of its own. macOS refuses to switch the screen to it, so it must
    /// not make the screen look like a display that can lead the set.
    private func mirroredLaptop(showing width: Int, _ height: Int) -> MockOutput {
        var screen = laptop()
        screen.modes.append(Modes.mode(8, width, height, scale: 2, mirrorOnly: true))
        screen.unsettable = ["8"]
        return screen
    }

    func testSizeOfTheMirrorSetListedOnTheLaptopScreenIsNotAModeOfItsOwn() {
        start(laptop(), monitor(Modes.qhd, at: Point(x: -440, y: -1440)))
        // Mirroring is switched on a second time: the monitor mirrors the
        // screen again, and the screen still lists 1920x1080 from last time.
        change(mirroredLaptop(showing: 1920, 1080), monitor(Modes.qhdMirrored, at: .zero, mirrors: 1))
        XCTAssertEqual(backend.calls, ["output.display-1.mirror.display-2 output.display-2.mode.35"],
                       "the monitor is made to lead, in one step, with no attempt on the laptop screen")
        XCTAssertEqual(backend.size(2), "1920x1080")
        XCTAssertEqual(backend.scale(2), 2, "the HiDPI size macOS adds for mirroring")
        XCTAssertEqual(logCount("ERROR"), 0)
        assertLog("Mirror set follows display-1: display-1 at 1680x1050@60 x2, display-2 at 2560x1440@60 x1")
    }

    func testLaptopScreenListingTheTargetOnlyAsTheSetSizeCannotLead() {
        config("enabled=1", "target_width=3840", "target_height=2160")
        var screen = laptop()
        screen.modes.append(Modes.mode(8, 3840, 2160, mirrorOnly: true))
        screen.unsettable = ["8"]
        start(screen, monitor(Modes.qhdMirrored, at: .zero, mirrors: 1))
        XCTAssertEqual(backend.calls, [], "nothing is tried")
        assertLog("ERROR: no display in the mirror set has a 3840x2160 mode")
    }

    func testRefusedMirrorOnlyModeFallsBackToTheDisplaysOwn() {
        var display = monitor(Modes.qhdMirrored, at: .zero, mirrors: 1)
        display.unsettable = ["35"]
        start(laptop(), display)
        XCTAssertEqual(backend.calls, [
            "output.display-1.mirror.display-2 output.display-2.mode.35",
            "output.display-1.mirror.display-2 output.display-2.mode.24",
        ])
        XCTAssertEqual(backend.size(2), "1920x1080")
        XCTAssertEqual(backend.scale(2), 1)
        XCTAssertEqual(logCount("ERROR: macOS refused the mirrored mode"), 1)
        // And that is all: a later pass does not try again.
        change(laptop(mirrors: 2), backend.output(2)!)
        XCTAssertEqual(backend.calls.count, 2)
    }

    func testRefusedOnOneDisplayFallsBackToTheNext() {
        config("enabled=1", "target_width=2560", "target_height=1440")
        var first = monitor(Modes.qhd, mode: "24", at: .zero, mirrors: 1)
        first.unsettable = ["28"]
        start(laptop(), first, monitor(3, Modes.uhd, mode: "2", at: .zero, mirrors: 1))
        XCTAssertEqual(backend.calls.count, 2, "one try per display that offers the target")
        XCTAssertEqual(backend.size(3), "2560x1440")
        XCTAssertEqual(backend.output(1)?.mirrors, 3)
        XCTAssertEqual(backend.output(2)?.mirrors, 3)
    }

    func testOwnModeWinsOverAMirrorOnlyOneOfTheSameKind() {
        // Same size, same scale: the display's own mode is the safe choice.
        let modes = [Modes.mode(9, 1920, 1080, mirrorOnly: true), Modes.mode(1, 1920, 1080), Modes.mode(2, 2560, 1440)]
        let output = monitor(modes, mode: "2").output
        XCTAssertEqual(output.mode(width: 1920, height: 1080)?.id, "1")
        XCTAssertTrue(output.offers(width: 1920, height: 1080))
        XCTAssertFalse(monitor([modes[0], modes[2]], mode: "2").output.offers(width: 1920, height: 1080))
    }

    // MARK: A built-in 16:9 screen, which offers the target itself

    func testScreenThatOffersTheTargetIsSwitchedItself() {
        start(laptop(mode: "0", modes: Modes.iMac))
        XCTAssertEqual(baseline, "2560 1440 60 2")
        change(laptop(mode: "0", modes: Modes.iMac), mirroredOnPanel(Modes.fhd))
        XCTAssertEqual(backend.calls, ["output.display-1.mode.1"])
        XCTAssertEqual(backend.size(1), "1920x1080", "screen switched to the target")
        XCTAssertEqual(backend.scale(1), 2, "the HiDPI mode of that size, like the one in use")
        XCTAssertEqual(backend.output(2)?.mirrors, 1, "the mirror set is not turned round")
        change(laptop(mode: "1", modes: Modes.iMac))
        XCTAssertEqual(backend.size(1), "2560x1440", "user mode restored after unplug")
        XCTAssertEqual(pending, "none")
    }

    func testOtherTargetMode() {
        config("enabled=1", "target_width=1280", "target_height=720")
        start(laptop(mode: "0", modes: Modes.iMac), mirroredOnPanel(Modes.fhd))
        XCTAssertEqual(backend.size(1), "1280x720")
    }

    // MARK: How mirroring is recognised

    func testMirrorReportedByTheDisplayMirroringTheScreen() {
        start(laptop(), mirroredOnPanel(Modes.fhd))
        assertLog("Layout changed: initial -> mirror ")
    }

    func testMirrorReportedByTheScreenMirroringTheDisplay() {
        start(laptop(mirrors: 2), monitor(Modes.fhd, at: Point(x: 300, y: 0)))
        assertLog("Layout changed: initial -> mirror ")
    }

    func testMirrorReportedOnlyByIdenticalPositions() {
        start(laptop(), monitor(Modes.fhd, at: .zero))
        assertLog("Layout changed: initial -> mirror ")
        XCTAssertEqual(pending, userMode)
    }

    // MARK: Restoring

    func testRestartWhileMirroredDoesNotForgetTheUserMode() {
        write(userMode, to: paths.baselineFile)
        write(userMode, to: paths.pendingFile)
        start(laptop(mode: "5", mirrors: 2), monitor(Modes.fhd, at: .zero))
        XCTAssertEqual(backend.calls, [])
        XCTAssertEqual(pending, userMode, "pending restore kept")
        XCTAssertEqual(baseline, userMode, "baseline not overwritten by the mirrored mode")
        change(laptop(mode: "5"))
        XCTAssertEqual(backend.size(1), "1680x1050", "user mode restored after unplug")
    }

    func testStartInExtendModeWithARestoreStillOwed() {
        write(userMode, to: paths.pendingFile)
        start(laptop(mode: "5"), monitor(Modes.qhd, at: Point(x: 1920, y: 0)))
        XCTAssertEqual(backend.size(1), "1680x1050", "user mode restored")
        XCTAssertEqual("\(backend.pos(2)) \(backend.pos(1))", "-440,-1440 0,0", "placed using the restored size")
        XCTAssertEqual(backend.calls.count, 2)
    }

    func testModeIdsRenumberedBetweenMirroringAndRestoring() {
        start(laptop())
        change(laptop(), mirroredOnPanel(Modes.fhd))
        change(laptop(mode: "11", modes: Modes.macBookRenumbered))
        XCTAssertEqual(backend.size(1), "1680x1050", "restored by size, refresh rate and scale")
        XCTAssertEqual(backend.output(1)?.mode, "12")
    }

    func testStateFileFromTheLinuxOriginalIsUnderstood() {
        // Three fields, no backing scale.
        write("1920 1200 60", to: paths.pendingFile)
        start(laptop())
        XCTAssertEqual(backend.size(1), "1920x1200")
        XCTAssertEqual(pending, "none")
    }

    func testUnreadablePendingModeIsDiscarded() {
        write("$(touch pwned) 1050 60", to: paths.pendingFile)
        start(laptop())
        XCTAssertEqual(backend.calls, [])
        XCTAssertEqual(pending, "none")
        assertLog("ERROR: discarding unreadable pending user mode")
    }

    func testSavedModeThatNoLongerExistsStaysOwed() {
        write("3000 2000 60 2", to: paths.pendingFile)
        start(laptop())
        XCTAssertEqual(backend.calls, [])
        XCTAssertEqual(pending, "3000 2000 60 2")
        XCTAssertEqual(baseline, "none", "nothing is tracked while a restore is owed")
        assertLog("ERROR: saved user mode 3000x2000@60 is unavailable")
    }

    func testRefusedRestoreStaysOwedWithoutARetryLoop() {
        start(laptop())
        change(laptop(), mirroredOnPanel(Modes.fhd))
        backend.failApply = true
        let before = backend.calls.count
        change(laptop(mode: "5"))
        XCTAssertEqual(backend.calls.count, before + 1, "exactly one restore attempt")
        XCTAssertEqual(pending, userMode, "pending restore kept")
        XCTAssertEqual(baseline, userMode, "the mode macOS left behind is not recorded as the user mode")
        assertLog("ERROR: macOS refused restoring user modes")
        backend.failApply = false
        change(laptop(mode: "5"))
        XCTAssertEqual(backend.size(1), "1680x1050", "restored at the next display change")
        XCTAssertEqual(pending, "none")
    }

    func testLidClosedWhileMirroringTouchesNothing() {
        start(laptop(), mirroredOnPanel(Modes.fhd))
        let before = backend.calls.count
        // The laptop screen goes away altogether.
        change(monitor(Modes.fhd, at: .zero))
        XCTAssertEqual(backend.calls.count, before, "no further call")
        XCTAssertEqual(pending, userMode, "pending restore kept")
        // Or it is reported, but switched off.
        change(laptop(mode: "5", enabled: false), monitor(Modes.fhd, at: .zero))
        XCTAssertEqual(backend.calls.count, before)
        change(laptop(mode: "5"))
        XCTAssertEqual(backend.size(1), "1680x1050", "user mode restored once the screen is back alone")
    }

    // MARK: Switches

    func testMirrorRuleSwitchedOffForThisDisplayOnly() {
        config("enabled=1", "target_width=1920", "target_height=1080",
               "auto_off_display=\(Fixture.dellKey) DELL P2723DE [USB-C/DisplayPort]")
        start(laptop())
        change(laptop(mode: "5", mirrors: 2), monitor(Modes.qhd, at: .zero, edid: Fixture.dell))
        XCTAssertEqual(backend.calls, [])
        XCTAssertEqual(backend.size(2), "2560x1440")
        XCTAssertEqual(pending, "none", "nothing saved for restore")
        XCTAssertEqual(baseline, userMode, "mirrored mode not tracked as the user mode")
        assertLog(#"Layout changed: no-display -> mirror-manual \[display-2: DELL P2723DE, USB-C/DisplayPort\]"#)
        change(laptop(), mirroredOnPanel(Modes.fhd, id: 3, edid: Fixture.noName))
        XCTAssertEqual(backend.calls.count, 1, "another display still triggers the rule")
        XCTAssertEqual(backend.output(1)?.mirrors, 3)
    }

    func testSwitchedOffDisplayIsRecognisedOnADifferentPort() {
        config("enabled=1", "auto_off_display=\(Fixture.dellKey) DELL P2723DE [USB-C/DisplayPort]")
        start(laptop(), mirroredOnPanel(Modes.qhd, id: 7, edid: Fixture.dell))
        XCTAssertEqual(backend.calls, [])
        assertLog("Layout changed: initial -> mirror-manual")
    }

    func testOneSwitchedOnDisplayInTheSetIsEnough() {
        config("enabled=1", "auto_off_display=\(Fixture.dellKey) DELL")
        start(laptop(), mirroredOnPanel(Modes.qhd, edid: Fixture.dell), mirroredOnPanel(Modes.fhd, id: 3))
        assertLog("Layout changed: initial -> mirror ")
        XCTAssertEqual(backend.calls.count, 1)
    }

    /// A mirrored layout is one shared desktop, so with the rule off it is
    /// left exactly as macOS made it; an owed restore waits until mirroring ends.
    func testMasterSwitchOffAppliesNothingAndRestoresWhenMirroringEnds() {
        config("enabled=0", "target_width=1920", "target_height=1080")
        write(userMode, to: paths.pendingFile)
        start(laptop(mode: "5", mirrors: 2), monitor(Modes.qhd, at: .zero))
        XCTAssertEqual(backend.calls, [], "not pulled out of the mirrored size")
        XCTAssertEqual(pending, userMode, "restore still owed")
        change(laptop(mode: "5"), monitor(Modes.qhd))
        XCTAssertEqual(backend.size(1), "1680x1050", "user mode restored once mirroring ends")
        XCTAssertEqual(pending, "none")
        let before = backend.calls.count
        change(laptop(), mirroredOnPanel(Modes.qhd))
        XCTAssertEqual(backend.calls.count, before, "left alone afterwards")
        XCTAssertEqual(backend.size(2), "2560x1440")
    }

    func testSwitchingTheRuleOnWhileMirroredAppliesIt() {
        config("enabled=0")
        start(laptop(), monitor(Modes.qhd, at: Point(x: -440, y: -1440), edid: Fixture.dell))
        change(laptop(mirrors: 2), monitor(Modes.qhd, at: .zero, edid: Fixture.dell))
        XCTAssertEqual(backend.calls, [])
        // Chosen in the menu: the config is saved and the rules start afresh.
        config("enabled=1")
        engine.start()
        settle()
        XCTAssertEqual(backend.size(2), "1920x1080")
        XCTAssertEqual(pending, userMode)
        XCTAssertEqual(displayState(Fixture.dellKey, .pending), "2560 1440 60 1")
    }

    func testChangingTheTargetWhileMirroredKeepsTheUserModesToRestore() {
        start(laptop(), monitor(Modes.qhd, at: Point(x: -440, y: -1440), edid: Fixture.dell))
        change(laptop(mirrors: 2), monitor(Modes.qhd, at: .zero, edid: Fixture.dell))
        XCTAssertEqual(backend.size(2), "1920x1080")
        config("enabled=1", "target_width=1280", "target_height=720")
        engine.start()
        settle()
        XCTAssertEqual(backend.size(2), "1280x720")
        XCTAssertEqual(backend.scale(2), 2, "the HiDPI 1280x720 mode: sharper than the plain one")
        XCTAssertEqual(displayState(Fixture.dellKey, .pending), "2560 1440 60 1", "not the mirrored mode")
        change(laptop(), monitor(Modes.qhd, mode: "12", edid: Fixture.dell))
        XCTAssertEqual(backend.size(2), "2560x1440")
    }

    // MARK: Failure handling

    func testNoUsableAnswerFromTheDisplaySystem() {
        backend.broken = true
        start(laptop(), monitor(Modes.qhd))
        XCTAssertEqual(backend.calls, [])
        assertLog("ERROR: could not determine display layout")
        engine.pass()
        engine.pass()
        XCTAssertEqual(logCount("ERROR: could not determine display layout"), 1, "reported once, not on every pass")
        backend.broken = false
        change(laptop(), monitor(Modes.qhd))
        XCTAssertEqual("\(backend.pos(2)) \(backend.pos(1))", "-440,-1440 0,0", "recovers when macOS answers again")
    }

    func testRefusedMirrorModeIsNotRetried() {
        backend.failApply = true
        start(laptop(), mirroredOnPanel(Modes.fhd))
        change(laptop(), mirroredOnPanel(Modes.fhd))
        XCTAssertEqual(backend.calls.count, 1, "exactly one attempt")
        assertLog("ERROR: macOS refused the mirrored mode")
    }

    /// Something keeps undoing what the engine does. It must give up rather
    /// than flash the screens for ever.
    func testRunawayChangesAreStopped() {
        start(laptop())
        for _ in 0..<(Engine.changeLimit + 5) {
            backend.outputs = [laptop(), monitor(Modes.qhd)]
            settle()
            backend.outputs = [laptop()]
            settle()
        }
        XCTAssertEqual(backend.calls.count, Engine.changeLimit)
        assertLog("holding off so the screens are not changed in a loop")
        // Later, things work again.
        now += Engine.changeWindow + 1
        backend.outputs = [laptop(), monitor(Modes.qhd)]
        settle()
        XCTAssertEqual(backend.calls.count, Engine.changeLimit + 1)
        XCTAssertEqual(backend.pos(2), "-440,-1440")
    }
}
