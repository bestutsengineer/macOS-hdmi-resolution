import XCTest
@testable import HDMIResolutionCore

/// Every supported external display (1K, 2K and 4K, all 16:9) against every
/// target the menu offers, with the mirror set following either member, on a
/// laptop screen that has no 16:9 mode of its own.
final class ResolutionMatrixTests: RuleTestCase {
    private struct Case {
        var name: String
        var modes: [DisplayMode]
        /// The mode the user runs the display at.
        var mode: String
        var target: (Int, Int)
        /// The size the mirrored desktop ends up with, or nil when the display cannot do the target.
        var expected: String?
        /// Whether the mode chosen for the target is a HiDPI one.
        var hiDPI = false
    }

    private let cases = [
        Case(name: "1K", modes: Modes.fhd, mode: "1", target: (1920, 1080), expected: "1920x1080"),
        Case(name: "1K", modes: Modes.fhd, mode: "1", target: (2560, 1440), expected: nil),
        Case(name: "1K", modes: Modes.fhd, mode: "1", target: (3840, 2160), expected: nil),
        Case(name: "1K", modes: Modes.fhd, mode: "1", target: (1280, 720), expected: "1280x720"),
        Case(name: "2K", modes: Modes.qhd, mode: "28", target: (1920, 1080), expected: "1920x1080"),
        Case(name: "2K", modes: Modes.qhd, mode: "28", target: (2560, 1440), expected: "2560x1440"),
        Case(name: "2K", modes: Modes.qhd, mode: "28", target: (3840, 2160), expected: nil),
        // 1280x720 exists twice on this monitor; the HiDPI one uses every pixel of the panel.
        Case(name: "2K", modes: Modes.qhd, mode: "28", target: (1280, 720), expected: "1280x720", hiDPI: true),
        // A 4K display run as "looks like 1920x1080" keeps its sharp HiDPI rendering.
        Case(name: "4K", modes: Modes.uhd, mode: "2", target: (1920, 1080), expected: "1920x1080", hiDPI: true),
        Case(name: "4K", modes: Modes.uhd, mode: "2", target: (2560, 1440), expected: "2560x1440", hiDPI: true),
        Case(name: "4K", modes: Modes.uhd, mode: "2", target: (3840, 2160), expected: "3840x2160"),
        Case(name: "4K", modes: Modes.uhd, mode: "2", target: (1280, 720), expected: "1280x720", hiDPI: true),
        // The same display run at its native 3840x2160.
        Case(name: "4K native", modes: Modes.uhd, mode: "1", target: (1920, 1080), expected: "1920x1080", hiDPI: true),
        Case(name: "4K native", modes: Modes.uhd, mode: "1", target: (2560, 1440), expected: "2560x1440", hiDPI: true),
        Case(name: "4K native", modes: Modes.uhd, mode: "1", target: (3840, 2160), expected: "3840x2160"),
    ]

    func testEveryDisplayAgainstEveryTarget() {
        for item in cases {
            for displayLeads in [false, true] {
                tearDown()
                setUp()
                run(item, displayLeads: displayLeads)
            }
        }
    }

    private func run(_ item: Case, displayLeads: Bool) {
        let label = "\(item.name) display, target \(item.target.0)x\(item.target.1), "
            + (displayLeads ? "set follows the display" : "set follows the laptop screen")
        let original = backendSize(item.modes, item.mode)
        config("enabled=1", "target_width=\(item.target.0)", "target_height=\(item.target.1)")

        // Extended first, so the modes the user runs are known.
        start(laptop(), monitor(item.modes, mode: item.mode))
        let placedAt = backend.pos(2)
        let callsBefore = backend.calls.count

        // Mirroring starts.
        if displayLeads {
            change(laptop(mirrors: 2), monitor(item.modes, mode: item.mode, at: .zero))
        } else {
            change(laptop(), monitor(item.modes, mode: item.mode, at: .zero, mirrors: 1))
        }
        XCTAssertEqual(pending, userMode, label)
        if let expected = item.expected {
            XCTAssertEqual(backend.size(2), expected, label)
            XCTAssertEqual(backend.scale(2), item.hiDPI ? 2 : 1, label)
            XCTAssertEqual(backend.output(2)?.mirrors, 0, "\(label): the display leads the set")
            XCTAssertEqual(backend.output(1)?.mirrors, 2, "\(label): the laptop screen shows the display's desktop")
            XCTAssertLessThanOrEqual(backend.calls.count, callsBefore + 1, "\(label): one reconfiguration at most")
        } else {
            XCTAssertEqual(backend.calls.count, callsBefore, "\(label): nothing is changed")
            XCTAssertEqual(backend.size(2), original, label)
            assertLog("ERROR: no display in the mirror set has a \(item.target.0)x\(item.target.1) mode")
        }
        XCTAssertEqual(backend.size(1), "1680x1050", "\(label): the laptop screen's own mode is not touched")

        // Mirroring ends; macOS leaves the display in whatever mode it had while mirrored.
        change(laptop(), monitor(item.modes, mode: backend.output(2)!.mode))
        XCTAssertEqual(backend.size(2), original, "\(label): display back at the user's mode")
        XCTAssertEqual(backend.output(2)?.mode, item.mode, "\(label): the very mode, HiDPI or not")
        XCTAssertEqual(backend.size(1), "1680x1050", label)
        XCTAssertEqual(pending, "none", label)
        XCTAssertEqual(backend.pos(2), placedAt, "\(label): above and centred again")
        XCTAssertEqual(backend.pos(1), "0,0", label)
    }

    private func backendSize(_ modes: [DisplayMode], _ id: String) -> String {
        let mode = modes.first { $0.id == id }!
        return "\(mode.width)x\(mode.height)"
    }
}
