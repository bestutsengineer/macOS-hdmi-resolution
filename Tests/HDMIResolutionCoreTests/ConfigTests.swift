import XCTest
@testable import HDMIResolutionCore

final class ConfigTests: RuleTestCase {
    func testMissingFileLeavesTheDefaults() {
        let loaded = Config.load(from: paths.configFile)
        XCTAssertEqual(loaded.config, Config())
        XCTAssertTrue(loaded.config.enabled && loaded.config.extendTopCenter)
        XCTAssertFalse(loaded.config.alwaysShowMenuBar, "the menu bar item comes and goes with the display")
        XCTAssertEqual("\(loaded.config.targetWidth)x\(loaded.config.targetHeight)", "1920x1080")
        XCTAssertEqual(loaded.rejectedLines, [])
    }

    func testEverySetting() {
        let loaded = Config.parse("""
            # hdmi-resolution settings

            enabled=0
            target_width=2560
            target_height=1440
            extend_top_center=0
            always_show_menu_bar=1
            auto_off_display=\(Fixture.dellKey) DELL P2723DE [USB-C/DisplayPort]
            auto_off_display=connector:display-5
            auto_off_display=uuid:0a1b2c3d-4e5f-4061-8728-394a5b6c7d8e Sidecar Display [Virtual]
            extend_off_display=\(Fixture.dellKey) DELL P2723DE [USB-C/DisplayPort]
            """)
        XCTAssertEqual(loaded.rejectedLines, [])
        XCTAssertFalse(loaded.config.enabled)
        XCTAssertFalse(loaded.config.extendTopCenter)
        XCTAssertTrue(loaded.config.alwaysShowMenuBar)
        XCTAssertEqual(loaded.config.targetWidth, 2560)
        XCTAssertEqual(loaded.config.targetHeight, 1440)
        XCTAssertEqual(loaded.config.autoOffDisplays.count, 3)
        XCTAssertTrue(loaded.config.isAutoOff(Fixture.dellKey))
        XCTAssertTrue(loaded.config.isAutoOff("connector:display-5"))
        XCTAssertTrue(loaded.config.isAutoOff("uuid:0a1b2c3d-4e5f-4061-8728-394a5b6c7d8e"))
        XCTAssertFalse(loaded.config.isAutoOff("connector:display-6"))
        XCTAssertTrue(loaded.config.isExtendOff(Fixture.dellKey))
        XCTAssertFalse(loaded.config.isExtendOff("connector:display-5"), "the two rules are separate")
    }

    func testConfigFromTheFirstVersionKeepsBothRulesOn() {
        config("# Managed by hdmi-resolution-tui.", "enabled=1", "target_width=1920", "target_height=1080")
        start(laptop(), monitor(Modes.qhd))
        XCTAssertEqual("\(backend.pos(2)) \(backend.pos(1))", "-440,-1440 0,0", "extend rule active")
        change(laptop(mirrors: 2), monitor(Modes.qhd, at: .zero))
        XCTAssertEqual(backend.size(2), "1920x1080", "mirror rule active")
    }

    /// The config is data: shell code in it is never executed, and a line that
    /// is not exactly one known setting is ignored.
    func testShellCodeAndJunkAreIgnored() {
        let marker = directory.appendingPathComponent("pwned").path
        config("enabled=0; touch \(marker)-1",
               "target_width=$(touch \(marker)-2)",
               "`touch \(marker)-3`",
               "extend_top_center = 0",
               "target_width=(",
               "target_height=1080",
               // A label is any text of up to 100 characters; it is only ever shown.
               "auto_off_display=\(Fixture.dellKey) $(touch pwned-4)")
        start(laptop(), monitor(Modes.qhd, edid: Fixture.dell))
        XCTAssertEqual("\(backend.pos(2)) \(backend.pos(1))", "-440,-1440 0,0", "rejected lines leave the defaults (extend rule on)")
        for line in 1...5 {
            assertLog("WARNING: ignoring line \(line) of .*/config$")
        }
        XCTAssertEqual(logCount("WARNING: ignoring line"), 5)
        XCTAssertTrue(engine.config.enabled)
        change(laptop(mirrors: 2), monitor(Modes.qhd, at: .zero, edid: Fixture.dell))
        XCTAssertEqual(backend.size(2), "2560x1440", "well-formed display line still honoured")
        let leftovers = try! FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("pwned") }
        XCTAssertEqual(leftovers, [], "nothing in the config was executed")
    }

    func testOnlyExactValuesAreAccepted() {
        func rejected(_ line: String) -> Bool { !Config.parse(line).rejectedLines.isEmpty }
        XCTAssertTrue(rejected("enabled=2"))
        XCTAssertTrue(rejected("enabled=true"))
        XCTAssertTrue(rejected("enabled=1 "))
        XCTAssertTrue(rejected(" enabled=1"))
        XCTAssertTrue(rejected("enabled=1\r"), "a file with Windows line endings")
        XCTAssertTrue(rejected("Enabled=1"))
        XCTAssertTrue(rejected("target_width=99"), "too few digits")
        XCTAssertTrue(rejected("target_width=123456"), "too many digits")
        XCTAssertTrue(rejected("target_width=-1920"))
        XCTAssertTrue(rejected("target_width=19２0"), "digits that are not ASCII")
        XCTAssertTrue(rejected("unknown=1"))
        XCTAssertTrue(rejected("always_show_menu_bar=yes"))
        XCTAssertFalse(rejected("always_show_menu_bar=1"))
        XCTAssertFalse(rejected("extend_off_display=connector:display-5"))
        XCTAssertTrue(rejected("extend_off_display=connector:x/../y"))
        XCTAssertTrue(rejected("no equals sign"))
        XCTAssertFalse(rejected("target_height=0800"))
        XCTAssertEqual(Config.parse("target_height=0800").config.targetHeight, 800)
        XCTAssertFalse(rejected("# a comment"))
        XCTAssertFalse(rejected(""))
        XCTAssertEqual(Config.parse("enabled=0").config.enabled, false, "last line without a newline")
        XCTAssertEqual(Config.parse("enabled=0\nenabled=1\n").config.enabled, true, "the last one wins")
        XCTAssertEqual(Config.parse("junk\n\nenabled=0\nmore junk\n").rejectedLines, [1, 4], "numbered as in the file")
    }

    func testDisplayLines() {
        func accepted(_ value: String) -> Bool { Config.parse("auto_off_display=\(value)").config.autoOffDisplays == [value] }
        XCTAssertTrue(accepted("edid:0123456789abcdef0123456789abcdef"))
        XCTAssertTrue(accepted("edid:0123456789abcdef0123456789abcdef Example Monitor [HDMI]"))
        XCTAssertTrue(accepted("edid:0123456789abcdef0123456789abcdef "), "an empty label")
        XCTAssertTrue(accepted("connector:HDMI-A-1 Unidentified display [HDMI]"), "a line written on Linux")
        XCTAssertTrue(accepted("edid:0123456789abcdef0123456789abcdef " + String(repeating: "x", count: 100)))
        XCTAssertFalse(accepted("edid:0123456789abcdef0123456789abcdef " + String(repeating: "x", count: 101)))
        XCTAssertFalse(accepted("edid:0123456789ABCDEF0123456789ABCDEF"), "upper-case hash")
        XCTAssertFalse(accepted("edid:0123456789abcdef"), "short hash")
        XCTAssertFalse(accepted("edid:0123456789abcdef0123456789abcdefX label"))
        XCTAssertFalse(accepted("connector:x/../card1-DP-3"))
        XCTAssertFalse(accepted("connector:" + String(repeating: "a", count: 41)))
        XCTAssertFalse(accepted("connector:"))
        XCTAssertFalse(accepted("uuid:not-a-uuid"))
        XCTAssertFalse(accepted("edid:0123456789abcdef0123456789abcdef tab\there"))
        XCTAssertFalse(accepted("edid:0123456789abcdef0123456789abcdef Bildschirm für alle"), "labels are plain ASCII")
        XCTAssertFalse(accepted("serial:1234 label"))
    }

    func testSavedFileHoldsOnlyKnownSettingsAndReadsBackTheSame() throws {
        var config = Config()
        config.enabled = false
        config.targetWidth = 3840
        config.targetHeight = 2160
        config.alwaysShowMenuBar = true
        config.autoOffDisplays = ["\(Fixture.dellKey) DELL P2723DE [USB-C/DisplayPort]", "connector:display-5"]
        config.extendOffDisplays = ["connector:display-5 Projector"]
        try config.save(to: paths.configFile)
        let text = try String(contentsOf: paths.configFile, encoding: .utf8)
        XCTAssertEqual(text, """
            # Managed by hdmi-resolution (menu bar).
            enabled=0
            target_width=3840
            target_height=2160
            extend_top_center=1
            always_show_menu_bar=1
            auto_off_display=\(Fixture.dellKey) DELL P2723DE [USB-C/DisplayPort]
            auto_off_display=connector:display-5
            extend_off_display=connector:display-5 Projector

            """)
        XCTAssertEqual(Config.load(from: paths.configFile), Config.Loaded(config: config, rejectedLines: []))
    }

    func testStandardPathsFollowTheLinuxOriginal() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let plain = Paths.standard(environment: [:], home: home)
        XCTAssertEqual(plain.configFile.path, "/Users/someone/.config/hdmi-resolution/config")
        XCTAssertEqual(plain.stateDir.path, "/Users/someone/.local/state/hdmi-resolution")
        XCTAssertEqual(plain.baselineFile.path, "/Users/someone/.local/state/hdmi-resolution/baseline-mode")
        XCTAssertEqual(plain.pendingFile.path, "/Users/someone/.local/state/hdmi-resolution/pending-mode")
        let xdg = Paths.standard(environment: ["XDG_CONFIG_HOME": "/x/config", "XDG_STATE_HOME": ""], home: home)
        XCTAssertEqual(xdg.configFile.path, "/x/config/hdmi-resolution/config")
        XCTAssertEqual(xdg.stateDir.path, "/Users/someone/.local/state/hdmi-resolution", "an empty variable counts as unset")
    }

    func testModeSpec() {
        XCTAssertEqual(ModeSpec("1680\t1050\t60\t2"), ModeSpec(width: 1680, height: 1050, refresh: 60, scale: 2))
        XCTAssertEqual(ModeSpec("2560 1600 59.99399948120117"), ModeSpec(width: 2560, height: 1600, refresh: 59.99399948120117, scale: nil))
        XCTAssertEqual(ModeSpec(width: 1680, height: 1050, refresh: 60, scale: 2).text, "1680\t1050\t60\t2")
        XCTAssertEqual(ModeSpec(width: 1920, height: 1080, refresh: 59.951, scale: nil).text, "1920\t1080\t59.951")
        XCTAssertEqual(ModeSpec(width: 1920, height: 1080, refresh: 59.951, scale: 1).label, "1920x1080@59.951")
        for bad in ["", "1680 1050", "1680 1050 60 2 9", "a 1050 60", "1680 -1050 60", "1680 1050 6e1", "1680 1050 60 x", "1680 1050 . 2"] {
            XCTAssertNil(ModeSpec(bad), bad)
        }
    }
}
