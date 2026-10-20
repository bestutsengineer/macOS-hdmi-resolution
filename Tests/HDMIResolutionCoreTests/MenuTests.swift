import XCTest
@testable import HDMIResolutionCore

/// The menu bar item draws a `MenuModel` and saves the config a choice leads
/// to. These tests make the choices the way the menu does: build the model
/// from the file on disk, choose, save, and build it again.
final class MenuTests: RuleTestCase {
    private func snapshot(_ outputs: MockOutput...) -> Snapshot { Snapshot(outputs: outputs.map(\.output)) }

    private func model(_ snapshot: Snapshot?) -> MenuModel {
        MenuModel(config: Config.load(from: paths.configFile).config, snapshot: snapshot)
    }

    /// The settings lines of the saved file, joined by ";".
    private var savedSettings: String {
        let text = (try? String(contentsOf: paths.configFile, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { "\($0);" }.joined()
    }

    func testEveryEntryAndEveryChoice() throws {
        config("# Managed by hdmi-resolution-tui.", "enabled=1", "target_width=1920", "target_height=1080")
        let screens = snapshot(laptop(), monitor(Modes.qhd, at: Point(x: -440, y: -1440), edid: Fixture.dell))
        var menu = model(screens)
        XCTAssertTrue(menu.hasExternalDisplay)
        XCTAssertTrue(menu.statusText.contains("DELL P2723DE [USB-C/DisplayPort] (display-2, extended): mirror rule on"))
        XCTAssertTrue(menu.statusText.contains("Mirror rule ON: while a display mirrors the laptop screen"))
        XCTAssertEqual(menu.mirrorRuleTitle, "Mirror Rule: ON")
        XCTAssertEqual(menu.extendRuleTitle, "Extend Rule (Above, Centred): ON")
        XCTAssertEqual(menu.mirrorPerDisplayTitle, "Per Display: 1 of 1 on")
        XCTAssertEqual(menu.targetTitle, "Mirrored Target: 1920x1080")
        XCTAssertEqual(MenuModel.restoreTitle, "Restore User Mode: Always On")
        XCTAssertEqual(menu.displays.map(\.title), ["DELL P2723DE [USB-C/DisplayPort] (display-2, extended)"])
        XCTAssertEqual(menu.displays.map(\.ruleOn), [true])

        try menu.settingRule(false, forDisplay: Fixture.dellKey).save(to: paths.configFile)
        menu = model(screens)
        XCTAssertEqual(menu.mirrorPerDisplayTitle, "Per Display: 0 of 1 on", "display switched off")

        try menu.settingTarget(width: 2560, height: 1440).save(to: paths.configFile)
        menu = model(screens)
        XCTAssertEqual(menu.targetTitle, "Mirrored Target: 2560x1440")

        try menu.settingExtendRule(false).save(to: paths.configFile)
        menu = model(screens)
        XCTAssertEqual(menu.extendRuleTitle, "Extend Rule (Above, Centred): OFF")

        try menu.settingMirrorRule(false).save(to: paths.configFile)
        menu = model(screens)
        XCTAssertEqual(menu.mirrorRuleTitle, "Mirror Rule: OFF")

        XCTAssertEqual(savedSettings,
                       "enabled=0;target_width=2560;target_height=1440;extend_top_center=0;always_show_menu_bar=0;"
                       + "auto_off_display=\(Fixture.dellKey) DELL P2723DE [USB-C/DisplayPort];")
        XCTAssertEqual(Listing.rows(screens, config: Config.load(from: paths.configFile).config).map(\.ruleOn), [false],
                       "the rules read the saved config")
    }

    func testExtendRulePerDisplay() throws {
        config("enabled=1")
        let screens = snapshot(laptop(), monitor(Modes.qhd, edid: Fixture.dell))
        var menu = model(screens)
        XCTAssertEqual(menu.extendRuleTitle, "Extend Rule (Above, Centred): ON")
        XCTAssertEqual(menu.extendPerDisplayTitle, "Per Display: 1 of 1 on")
        try menu.settingExtendRule(false, forDisplay: Fixture.dellKey).save(to: paths.configFile)
        menu = model(screens)
        XCTAssertEqual(menu.extendPerDisplayTitle, "Per Display: 0 of 1 on")
        XCTAssertEqual(menu.mirrorPerDisplayTitle, "Per Display: 1 of 1 on", "the mirror rule is separate")
        XCTAssertTrue(savedSettings.hasSuffix("extend_off_display=\(Fixture.dellKey) DELL P2723DE [USB-C/DisplayPort];"))
        XCTAssertTrue(menu.statusText.contains("(display-2, extended): mirror rule on, extend rule off"))
        XCTAssertEqual(Listing.rows(screens, config: Config.load(from: paths.configFile).config).map { String($0.line.suffix(6)) },
                       ["on\toff"])

        // Remembered while unplugged, with both rules.
        try menu.settingRule(false, forDisplay: Fixture.dellKey).save(to: paths.configFile)
        menu = model(snapshot(laptop(), monitor(Modes.fhd)))
        XCTAssertEqual(menu.displays.last?.title, "DELL P2723DE [USB-C/DisplayPort] (not connected)")
        XCTAssertEqual(menu.displays.last.map { [$0.ruleOn, $0.extendOn] }, [false, false])
        try menu.settingExtendRule(true, forDisplay: Fixture.dellKey).save(to: paths.configFile)
        XCTAssertFalse(savedSettings.contains("extend_off_display"))
        XCTAssertTrue(savedSettings.contains("auto_off_display=\(Fixture.dellKey)"))
    }

    func testVirtualDisplayDoesNotBringUpTheMenuBarItem() {
        var virtual = monitor(Modes.fhd)
        virtual.isVirtual = true
        virtual.systemName = "Example Virtual Display"
        XCTAssertFalse(model(snapshot(laptop(), virtual)).showsMenuBarItem)
        XCTAssertTrue(model(snapshot(laptop(), virtual, monitor(3, Modes.qhd))).showsMenuBarItem)
    }

    func testMenuBarItemStaysWhileTheAppHasADisplaySwitchedOff() {
        let alone = snapshot(laptop())
        XCTAssertFalse(model(alone).showsMenuBarItem)
        let menu = MenuModel(config: Config(), snapshot: alone, switchedOff: [OutputRef(id: 2, name: "display-2")])
        XCTAssertTrue(menu.showsMenuBarItem, "or the display could not be switched on again")
    }

    func testTargetsCover1K2KAnd4K() {
        let menu = model(snapshot(laptop(), monitor(Modes.qhd)))
        XCTAssertEqual(menu.targets.map { "\($0.width)x\($0.height)" }, ["1920x1080", "2560x1440", "3840x2160", "1280x720"])
        XCTAssertEqual(menu.targets.map(\.selected), [true, false, false, false])
        XCTAssertEqual(menu.targets.map(\.available), [true, true, false, true], "a 2K monitor cannot do 4K")
        XCTAssertEqual(menu.targets.map(menu.title(of:)), [
            "1920x1080  1080p / 1K (recommended)", "2560x1440  1440p / 2K",
            "3840x2160  2160p / 4K  — not offered by the connected displays", "1280x720  720p",
        ])
        // Nothing connected: nothing to compare the sizes with, so no remark.
        let alone = model(snapshot(laptop()))
        XCTAssertEqual(alone.targets.map(alone.title(of:)), alone.targets.map(\.title))
        XCTAssertEqual(model(snapshot(laptop(), monitor(Modes.uhd))).targets.map(\.available), [true, true, true, true])
        XCTAssertEqual(model(snapshot(laptop(), monitor(Modes.fhd))).targets.map(\.available), [true, false, false, true])
    }

    func testTargetFromTheConfigFileThatTheMenuDoesNotOffer() {
        config("target_width=1920", "target_height=1200")
        let menu = model(snapshot(laptop(), monitor(Modes.qhd)))
        XCTAssertEqual(menu.targets.count, 5)
        XCTAssertEqual(menu.targets.last?.title, "1920x1200  (from the config file)")
        XCTAssertEqual(menu.targets.map(\.selected), [false, false, false, false, true])
        XCTAssertEqual(menu.targets.last?.available, true, "the laptop screen offers it")
    }

    func testMenuBarItemIsOnlyThereWhileAnExternalDisplayIsConnected() {
        XCTAssertFalse(model(snapshot(laptop())).showsMenuBarItem)
        XCTAssertFalse(model(nil).showsMenuBarItem)
        XCTAssertTrue(model(snapshot(laptop(), monitor(Modes.fhd))).showsMenuBarItem, "extended")
        XCTAssertTrue(model(snapshot(laptop(), monitor(Modes.fhd, at: .zero, mirrors: 1))).showsMenuBarItem, "mirrored")
        XCTAssertTrue(model(snapshot(monitor(Modes.fhd, at: .zero))).showsMenuBarItem, "lid closed")
        var off = monitor(Modes.fhd)
        off.enabled = false
        XCTAssertTrue(model(snapshot(laptop(), off)).showsMenuBarItem, "connected but disabled")
        // A remembered display that is not plugged in does not bring the item back.
        config("auto_off_display=\(Fixture.dellKey) DELL P2723DE [USB-C/DisplayPort]")
        XCTAssertFalse(model(snapshot(laptop())).showsMenuBarItem)
    }

    func testAlwaysShowKeepsTheMenuBarItemWithoutAnExternalDisplay() throws {
        let alone = snapshot(laptop())
        let connected = snapshot(laptop(), monitor(Modes.qhd, edid: Fixture.dell))
        var menu = model(connected)
        XCTAssertFalse(menu.config.alwaysShowMenuBar, "off unless asked for")
        XCTAssertFalse(model(alone).showsMenuBarItem)

        try menu.settingAlwaysShow(true).save(to: paths.configFile)
        XCTAssertTrue(savedSettings.contains("always_show_menu_bar=1;"))
        menu = model(alone)
        XCTAssertTrue(menu.config.alwaysShowMenuBar)
        XCTAssertTrue(menu.showsMenuBarItem, "stays when the display is unplugged")
        XCTAssertFalse(menu.hasExternalDisplay)
        XCTAssertTrue(model(nil).showsMenuBarItem, "and when macOS gives no answer")
        XCTAssertTrue(model(connected).showsMenuBarItem)

        // With no display connected the rest of the menu still works.
        XCTAssertTrue(menu.statusText.hasSuffix("No external display connected."))
        try menu.settingTarget(width: 3840, height: 2160).save(to: paths.configFile)
        menu = model(alone)
        XCTAssertEqual(menu.targetTitle, "Mirrored Target: 3840x2160")
        XCTAssertTrue(menu.config.alwaysShowMenuBar, "another choice keeps it")

        try menu.settingAlwaysShow(false).save(to: paths.configFile)
        XCTAssertFalse(model(alone).showsMenuBarItem)
        XCTAssertTrue(model(connected).showsMenuBarItem)
    }

    func testAlwaysShowDoesNotTouchTheRules() throws {
        start(laptop(), monitor(Modes.qhd))
        let calls = backend.calls
        try model(backend.snapshot()).settingAlwaysShow(true).save(to: paths.configFile)
        engine.start()
        settle()
        XCTAssertEqual(backend.calls, calls)
        XCTAssertTrue(engine.config.alwaysShowMenuBar)
        XCTAssertTrue(engine.config.enabled && engine.config.extendTopCenter)
    }

    func testSwitchedOffDisplayIsRememberedWhileUnplugged() throws {
        config("enabled=1", "auto_off_display=\(Fixture.dellKey) DELL P2723DE [USB-C/DisplayPort]")
        let screens = snapshot(laptop(), monitor(Modes.fhd))
        var menu = model(screens)
        XCTAssertEqual(menu.displays.map(\.title), [
            "Unidentified display [USB-C/DisplayPort] (display-2, extended)",
            "DELL P2723DE [USB-C/DisplayPort] (not connected)",
        ])
        XCTAssertEqual(menu.displays.map(\.ruleOn), [true, false])
        XCTAssertEqual(menu.mirrorPerDisplayTitle, "Per Display: 1 of 2 on")
        XCTAssertTrue(menu.statusText.contains("DELL P2723DE [USB-C/DisplayPort] (not connected): mirror rule off"))

        // An unrelated choice keeps it.
        try menu.settingExtendRule(false).save(to: paths.configFile)
        XCTAssertTrue(savedSettings.hasSuffix("auto_off_display=\(Fixture.dellKey) DELL P2723DE [USB-C/DisplayPort];"))

        // Switched back on: gone from the file, and from the menu.
        menu = model(screens)
        try menu.settingRule(true, forDisplay: Fixture.dellKey).save(to: paths.configFile)
        XCTAssertFalse(savedSettings.contains("auto_off_display"))
        XCTAssertEqual(model(screens).displays.count, 1)
    }

    func testJunkInTheConfigIsIgnoredAndGoneAfterASave() throws {
        let marker = directory.appendingPathComponent("pwned").path
        config("enabled=0; touch \(marker)-5", "target_width=(", "$(touch \(marker)-6)", "extend_top_center=0")
        let screens = snapshot(laptop(), monitor(Modes.qhd))
        let menu = model(screens)
        XCTAssertEqual(menu.mirrorRuleTitle, "Mirror Rule: ON", "rejected line leaves the default")
        XCTAssertEqual(menu.extendRuleTitle, "Extend Rule (Above, Centred): OFF", "valid line is honoured")
        try menu.settingMirrorRule(true).save(to: paths.configFile)
        XCTAssertEqual(savedSettings,
                       "enabled=1;target_width=1920;target_height=1080;extend_top_center=0;always_show_menu_bar=0;")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("pwned") }
        XCTAssertEqual(leftovers, [])
    }

    func testDisplayWhoseNameLooksLikeACommandLineOption() throws {
        config("enabled=1")
        let screens = snapshot(laptop(), monitor(Modes.fhd, edid: Fixture.hostile))
        let menu = model(screens)
        XCTAssertEqual(menu.displays.map(\.title), ["--title PWN [USB-C/DisplayPort] (display-2, extended)"])
        try menu.settingRule(false, forDisplay: Fixture.hostileKey).save(to: paths.configFile)
        XCTAssertTrue(savedSettings.contains("auto_off_display=\(Fixture.hostileKey) --title PWN [USB-C/DisplayPort];"),
                      "saved as one plain line")
        XCTAssertEqual(Listing.rows(screens, config: Config.load(from: paths.configFile).config).map(\.ruleOn), [false])
    }

    /// Whatever macOS calls a display, the line saved for it must read back.
    func testLabelThatWouldNotReadBackIsTamedBeforeSaving() throws {
        var odd = monitor(Modes.fhd)
        odd.systemName = "Écran \u{1F5A5}\tde\nprojection " + String(repeating: "long ", count: 40)
        odd.transport = nil
        let screens = snapshot(laptop(), odd)
        try model(screens).settingRule(false, forDisplay: "connector:display-2").save(to: paths.configFile)
        let loaded = Config.load(from: paths.configFile)
        XCTAssertEqual(loaded.rejectedLines, [])
        XCTAssertTrue(loaded.config.isAutoOff("connector:display-2"))
        XCTAssertEqual(model(screens).displays.map(\.ruleOn), [false])
    }

    func testNoDisplayConnectedAndNoneRemembered() {
        let menu = model(snapshot(laptop()))
        XCTAssertTrue(menu.statusText.hasSuffix("No external display connected."))
        XCTAssertEqual(menu.displays.count, 0)
        XCTAssertEqual(menu.mirrorPerDisplayTitle, "Per Display: 0 of 0 on")
    }

    /// A choice in the menu is saved and the rules start afresh with it.
    func testChoiceTakesEffectAtOnce() throws {
        start(laptop(), monitor(Modes.qhd, edid: Fixture.dell))
        XCTAssertEqual(backend.pos(2), "-440,-1440")
        change(laptop(mirrors: 2), monitor(Modes.qhd, at: .zero, edid: Fixture.dell))
        XCTAssertEqual(backend.size(2), "1920x1080")
        XCTAssertEqual(engine.state, .mirror)

        try model(backend.snapshot()).settingRule(false, forDisplay: Fixture.dellKey).save(to: paths.configFile)
        engine.start()
        settle()
        XCTAssertEqual(engine.state, .mirrorManual)
        XCTAssertEqual(pending, userMode, "still to be restored when mirroring ends")

        change(laptop(), monitor(Modes.qhd, mode: "24", edid: Fixture.dell))
        XCTAssertEqual(backend.size(2), "2560x1440")
        XCTAssertEqual(pending, "none")
    }
}
