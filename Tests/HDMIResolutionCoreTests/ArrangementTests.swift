import XCTest
@testable import HDMIResolutionCore

/// Extend, Mirror, Built-in Display Only and External Displays Only, chosen
/// in the menu, and what the rules make of each.
final class ArrangementTests: RuleTestCase {
    private func arrangements(_ switchedOff: [OutputRef] = []) -> Arrangements {
        Arrangements(backend.snapshot(), switchedOff: switchedOff)
    }

    /// Chooses an arrangement the way the menu does, then lets the rules react.
    @discardableResult
    private func choose(_ arrangement: DisplayArrangement, switchedOff: [OutputRef] = [],
                        file: StaticString = #filePath, line: UInt = #line) -> [String] {
        guard let changes = arrangements(switchedOff).changes(to: arrangement) else {
            XCTFail("\(arrangement.title) is not available", file: file, line: line)
            return []
        }
        if !changes.isEmpty { XCTAssertTrue(backend.apply(changes), file: file, line: line) }
        settle(file: file, line: line)
        return changes.map(\.description)
    }

    private var panelRef: OutputRef { OutputRef(id: 1, name: "display-1") }
    private var displayRef: OutputRef { OutputRef(id: 2, name: "display-2") }

    func testCurrentArrangement() {
        backend.outputs = [laptop(), monitor(Modes.qhd)]
        XCTAssertEqual(arrangements().current, .extend)
        backend.outputs = [laptop(), monitor(Modes.qhd, at: .zero, mirrors: 1)]
        XCTAssertEqual(arrangements().current, .mirror)
        backend.outputs = [laptop(mirrors: 2), monitor(Modes.qhd, at: .zero)]
        XCTAssertEqual(arrangements().current, .mirror, "the set following the display")
        var off = monitor(Modes.qhd)
        off.enabled = false
        backend.outputs = [laptop(), off]
        XCTAssertEqual(arrangements().current, .builtInOnly)
        backend.outputs = [laptop(enabled: false), monitor(Modes.qhd, at: .zero)]
        XCTAssertEqual(arrangements().current, .externalOnly)
        backend.outputs = [laptop()]
        XCTAssertNil(arrangements().current, "nothing to arrange")
        XCTAssertFalse(DisplayArrangement.allCases.contains { arrangements().isAvailable($0) })
    }

    func testLidClosedOffersNothing() {
        backend.outputs = [monitor(Modes.qhd, at: .zero)]
        XCTAssertEqual(arrangements().current, .externalOnly)
        XCTAssertFalse(DisplayArrangement.allCases.contains { arrangements().isAvailable($0) })
    }

    func testExtendAndMirror() {
        start(laptop(), monitor(Modes.qhd, edid: Fixture.dell))
        XCTAssertEqual(choose(.mirror), ["output.display-2.mirror.display-1"])
        XCTAssertEqual(arrangements().current, .mirror)
        XCTAssertEqual(backend.size(2), "1920x1080", "the mirror rule then does its part")
        XCTAssertEqual(choose(.extend), ["output.display-1.mirror.none"], "the set followed the monitor")
        XCTAssertEqual(arrangements().current, .extend)
        XCTAssertEqual(backend.size(2), "2560x1440", "restored when mirroring ended")
        XCTAssertEqual("\(backend.pos(2)) \(backend.pos(1))", "-440,-1440 0,0",
                       "placed above, and the laptop screen is the main display again")
        XCTAssertEqual(choose(.extend), [], "already so")
    }

    func testBuiltInDisplayOnlyAndBack() {
        start(laptop(), monitor(Modes.qhd))
        XCTAssertEqual(choose(.builtInOnly), ["output.display-2.disable"])
        XCTAssertEqual(arrangements().current, .builtInOnly)
        XCTAssertEqual(engine.state, .noDisplay)
        XCTAssertEqual(choose(.extend), ["output.display-2.enable"])
        XCTAssertEqual(arrangements().current, .extend)
        XCTAssertEqual("\(backend.pos(2)) \(backend.pos(1))", "-440,-1440 0,0")
    }

    func testExternalDisplaysOnlyAndBack() {
        start(laptop(), monitor(Modes.qhd))
        XCTAssertEqual(choose(.externalOnly), ["output.display-1.disable"])
        XCTAssertEqual(arrangements().current, .externalOnly)
        XCTAssertEqual(engine.state, .panelOff, "the rules leave everything alone")
        XCTAssertEqual(choose(.mirror), ["output.display-1.enable", "output.display-2.mirror.display-1"])
        XCTAssertEqual(arrangements().current, .mirror)
    }

    func testFromMirrorStraightToOneScreen() {
        start(laptop(), monitor(Modes.fhd, at: .zero, mirrors: 1))
        XCTAssertEqual(arrangements().current, .mirror)
        XCTAssertEqual(choose(.builtInOnly), ["output.display-1.mirror.none", "output.display-2.disable"],
                       "out of the mirror set first, in the same step")
        XCTAssertEqual(arrangements().current, .builtInOnly)
        XCTAssertEqual(backend.size(1), "1680x1050", "the user's mode is back on the laptop screen")
    }

    func testWithoutAWayToSwitchScreensOffOnlyExtendAndMirrorAreOffered() {
        backend.cannotSwitchOff = true
        backend.outputs = [laptop(), monitor(Modes.qhd)]
        XCTAssertTrue(arrangements().isAvailable(.mirror))
        XCTAssertFalse(arrangements().isAvailable(.builtInOnly))
        XCTAssertFalse(arrangements().isAvailable(.externalOnly))
    }

    func testVirtualDisplaysAreLeftAlone() {
        var virtual = monitor(5, Modes.fhd, at: Point(x: 5000, y: 0))
        virtual.isVirtual = true
        start(laptop(), monitor(Modes.qhd), virtual)
        XCTAssertEqual(choose(.builtInOnly), ["output.display-2.disable"])
        XCTAssertEqual(backend.output(5)?.enabled, true)
        backend.outputs = [laptop(), virtual]
        XCTAssertNil(arrangements().current, "a virtual display alone is nothing to arrange")
    }

    /// Should macOS stop listing a display that is off, the app's own record
    /// of it is what switches it on again.
    func testDisplayThatDisappearsWhenOffCanBeSwitchedOnAgain() {
        backend.hidesSwitchedOff = true
        start(laptop(), monitor(Modes.qhd))
        let changes = arrangements().changes(to: .builtInOnly)!
        XCTAssertTrue(backend.apply(changes))
        let remembered = SwitchedOffDisplays.updated([], after: changes)
        XCTAssertEqual(remembered, [displayRef])
        settle()
        XCTAssertNil(backend.output(2), "no longer listed")
        XCTAssertNil(arrangements().current, "without the record nothing is known")
        XCTAssertEqual(arrangements(remembered).current, .builtInOnly)
        XCTAssertEqual(choose(.extend, switchedOff: remembered), ["output.display-2.enable"])
        XCTAssertEqual(arrangements().current, .extend)
        XCTAssertEqual(SwitchedOffDisplays.pruned(remembered, in: backend.snapshot()), [])
    }

    func testRecordOfSwitchedOffDisplays() {
        XCTAssertEqual(SwitchedOffDisplays.load(from: paths), [])
        SwitchedOffDisplays.save([displayRef, OutputRef(id: 9, name: "display-9")], to: paths)
        XCTAssertEqual(SwitchedOffDisplays.load(from: paths).map(\.id), [2, 9])
        let file = paths.stateDir.appendingPathComponent("switched-off")
        try! Data("2\tdisplay-2\njunk\n7\tdisplay-8\n$(x)\tdisplay-1\n".utf8).write(to: file)
        XCTAssertEqual(SwitchedOffDisplays.load(from: paths), [displayRef], "anything odd is ignored")
        SwitchedOffDisplays.save([], to: paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(SwitchedOffDisplays.updated([displayRef], after: [.enable(panelRef, false), .enable(displayRef, true)]),
                       [panelRef])
    }
}
