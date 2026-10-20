import XCTest
@testable import HDMIResolutionCore

final class IdentityTests: RuleTestCase {
    private func row(_ rows: [DisplayRow], _ name: String) -> String {
        rows.first { $0.name == name }?.line.replacingOccurrences(of: "\t", with: "|") ?? ""
    }

    func testListDisplaysIdentifiesAndLabelsEveryKindOfDisplay() {
        var hdmi = monitor(3, Modes.fhd, at: .zero, mirrors: 1, edid: Fixture.noName)
        hdmi.transport = "HDMI"
        var disabled = monitor(4, Modes.fhd, at: .zero)
        disabled.enabled = false
        disabled.transport = nil
        disabled.uuid = "0A1B2C3D-4E5F-4061-8728-394A5B6C7D8E"
        var vga = monitor(5, Modes.fhd, at: Point(x: 5000, y: 0))
        vga.transport = "VGA"
        var sidecar = monitor(8, Modes.fhd, at: Point(x: 9000, y: 0))
        sidecar.isVirtual = true
        sidecar.systemName = "Sidecar Display"
        let snapshot = Snapshot(outputs: [
            laptop(), monitor(Modes.qhd, edid: Fixture.dell),
            monitor(6, Modes.fhd, at: Point(x: 7000, y: 0), edid: Fixture.hostile), hdmi, disabled, vga, sidecar,
        ].map(\.output))
        var config = Config()
        config.autoOffDisplays = ["connector:display-5 Unidentified display [VGA]"]
        let rows = Listing.rows(snapshot, config: config)

        XCTAssertEqual(row(rows, "display-2"), "\(Fixture.dellKey)|display-2|USB-C/DisplayPort|DELL P2723DE|extended|on|on",
                       "named from its EDID")
        XCTAssertEqual(row(rows, "display-3"), "edid:c032f503ffb5651ff410cd80a7ce58a9|display-3|HDMI|GSM 5B08|mirrored|on|on",
                       "no name in the EDID: vendor code and product number")
        XCTAssertEqual(row(rows, "display-4"),
                       "uuid:0a1b2c3d-4e5f-4061-8728-394a5b6c7d8e|display-4|External|Unidentified display|disabled|on|on",
                       "no EDID: the identifier macOS gives the display")
        XCTAssertEqual(row(rows, "display-5"), "connector:display-5|display-5|VGA|Unidentified display|extended|off|on",
                       "switched off in the config")
        XCTAssertEqual(row(rows, "display-6"), "\(Fixture.hostileKey)|display-6|USB-C/DisplayPort|--title PWN|extended|on|on",
                       "a name that looks like an option is kept as plain text")
        XCTAssertEqual(row(rows, "display-8"), "connector:display-8|display-8|Virtual|Sidecar Display|extended|on|on",
                       "no EDID: named as macOS names it")
        XCTAssertEqual(row(rows, "display-1"), "", "the laptop screen is not listed")
        XCTAssertEqual(rows.count, 6)
    }

    func testTheKeyIsTheSameOneTheLinuxOriginalComputes() {
        // md5sum of the EDID, as stored by KWin and by the original's config.
        XCTAssertEqual(monitor(Modes.qhd, edid: Fixture.dell).output.key, "edid:97262ce623252689c142e639905a299d")
    }

    func testKindFollowsHowTheDisplayIsAttached() {
        func kind(_ transport: String?) -> String {
            var output = monitor(Modes.fhd)
            output.transport = transport
            return output.output.kind
        }
        XCTAssertEqual(kind("DisplayPort"), "USB-C/DisplayPort")
        XCTAssertEqual(kind("HDMI"), "HDMI")
        XCTAssertEqual(kind("IOPortTransportStateHDMI"), "HDMI")
        XCTAssertEqual(kind("Thunderbolt"), "USB-C/DisplayPort")
        XCTAssertEqual(kind("DVI"), "DVI")
        XCTAssertEqual(kind(nil), "External")
        XCTAssertEqual(kind("Weird\u{1b}[31m thing that goes on and on"), "Weird[31m thing that", "untrusted text is tamed")
        XCTAssertEqual(laptop().output.kind, "Built-in")
    }

    func testMonitorNameIsReducedToPrintableASCIIAndCapped() {
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes.replaceSubrange(0..<8, with: [0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0])
        // Two name descriptors, with control and non-ASCII bytes mixed in.
        bytes.replaceSubrange(54..<72, with: [0, 0, 0, 0xfc, 0] + Array("AB\u{07}C".utf8) + [0x80, 0xff] + Array("DEFGHI ".utf8))
        bytes.replaceSubrange(72..<90, with: [0, 0, 0, 0xfc, 0] + Array("JK  ".utf8) + [10] + Array("ignored!".utf8))
        XCTAssertEqual(EDID.model(bytes), "ABCDEFGHI JK")
        XCTAssertNil(EDID.model(Array(bytes.prefix(100))), "too short to be an EDID")
    }

    func testEDIDTooShortToHoldANameStillIdentifiesTheDisplay() {
        var output = monitor(Modes.fhd, edid: Data([1, 2, 3])).output
        XCTAssertEqual(output.key, "edid:5289df737df57326fcdd22597afb1fac")
        XCTAssertEqual(output.model, "Unidentified display")
        output.systemName = "LG \u{1F5A5} TV\n"
        XCTAssertEqual(output.model, "LG  TV")
    }

    func testEDIDNumbersMatchWhatMacOSReportsForADisplay() {
        // A 2560x1440 monitor as Quartz reports it: vendor 0x10ac, model 0xa091, serial 0x12345678.
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes.replaceSubrange(0..<16, with: [0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0x10, 0xac, 0x91, 0xa0, 0x78, 0x56, 0x34, 0x12])
        let identity = EDID.identity(Data(bytes))
        XCTAssertEqual(identity?.vendor, 0x10ac)
        XCTAssertEqual(identity?.product, 0xa091)
        XCTAssertEqual(identity?.serial, 0x1234_5678)
        XCTAssertTrue(EDID.isPlausible(Data(bytes)))
        XCTAssertFalse(EDID.isPlausible(Data(bytes.dropFirst())))
    }

    /// Output names are made up by the app, but a key still must not be able
    /// to reach outside the state directory or into the config.
    func testNameWithAPathInItCannotBecomeAFile() {
        var output = monitor(Modes.fhd).output
        output.name = "x/../display-9"
        XCTAssertEqual(output.key, "connector:x/../display-9")
        XCTAssertNil(paths.displayFile(key: output.key, .pending))
        XCTAssertFalse(DisplayKey.isValid(output.key))
        XCTAssertEqual(paths.displayFile(key: Fixture.dellKey, .pending)?.lastPathComponent,
                       "edid-97262ce623252689c142e639905a299d.pending")
        XCTAssertNil(paths.displayFile(key: "edid:", .pending))
        XCTAssertNil(paths.displayFile(key: "other:abc", .pending))
    }

    func testStatus() {
        config("enabled=1", "target_width=2560", "target_height=1440", "extend_top_center=0")
        start(laptop(), monitor(Modes.fhd, at: .zero, mirrors: 1, edid: Fixture.dell))
        let status = Listing.status(snapshot: backend.snapshot(), config: engine.config, paths: paths, service: "active")
        let lines = status.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Service:      active")
        XCTAssertEqual(lines[1], "Session:      macos")
        XCTAssertEqual(lines[2], "Layout:       mirror")
        XCTAssertEqual(lines[3], "Panel:        display-1 1680x1050 scale 2, occupies 1680x1050 at 0,0")
        XCTAssertEqual(lines[5], "  display-2: DELL P2723DE [USB-C/DisplayPort] 1920x1080 scale 1, occupies 1920x1080 at 0,0, "
                       + "mirrored, mirror rule on, extend rule on (\(Fixture.dellKey))")
        XCTAssertTrue(lines.contains("Mirror rule:  on, target 2560x1440"))
        XCTAssertTrue(lines.contains("Extend rule:  off (single display above the panel, centred)"))
        XCTAssertTrue(lines.contains("To restore:   \(userMode)"))

        let alone = Listing.status(snapshot: Snapshot(outputs: [laptop().output]), config: Config(), paths: paths, service: "inactive")
        XCTAssertTrue(alone.contains("Layout:       no-display"))
        XCTAssertTrue(alone.contains("  none connected"))
        XCTAssertTrue(Listing.status(snapshot: nil, config: Config(), paths: paths, service: "inactive").contains("Layout:       unknown"))
    }
}
