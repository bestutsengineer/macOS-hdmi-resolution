import XCTest
@testable import HDMIResolutionCore

/// The resolution menu lists what System Settings lists.
final class ResolutionTests: XCTestCase {
    private func titles(_ choices: [ResolutionChoice]) -> [String] { choices.map(\.title) }

    /// The list in System Settings for a real DELL U2713H, from a screenshot.
    func testExternalDisplayListsWhatSystemSettingsLists() {
        let dell = monitor(Modes.dell, mode: "28").output
        XCTAssertEqual(titles(dell.resolutions), [
            "2560 × 1440 (Default)", "2048 × 1152", "1920 × 1080", "1600 × 900", "1280 × 720 (HiDPI)",
        ])
        XCTAssertEqual(dell.resolutions.filter(\.isCurrent).map(\.title), ["2560 × 1440 (Default)"])
        XCTAssertEqual(dell.resolutions.first { $0.width == 1920 }?.modeId, "24", "60 Hz, as the display runs now")
        XCTAssertEqual(dell.resolutions.last?.modeId, "12", "the HiDPI 1280 × 720")
    }

    func testAllResolutionsHasEveryMode() {
        let all = monitor(Modes.dell, mode: "28").output.allResolutions
        XCTAssertEqual(all.count, 21, "one entry per size and scale")
        XCTAssertTrue(titles(all).contains("1344 × 756"), "odd sizes are here")
        XCTAssertTrue(titles(all).contains("1280 × 720") && titles(all).contains("1280 × 720 (HiDPI)"))
        XCTAssertEqual(all.first?.title, "2560 × 1440 (Default)")
        XCTAssertEqual(all.map(\.width), all.map(\.width).sorted(by: >), "largest first")
    }

    func testSizeInUseIsListedEvenWhenItIsNotACommonOne() {
        let dell = monitor(Modes.dell, mode: "19").output
        XCTAssertEqual(titles(dell.resolutions).count, 6)
        XCTAssertEqual(dell.resolutions.filter(\.isCurrent).map(\.title), ["1344 × 756"])
    }

    func testRefreshRateInUseIsKept() {
        let dell = monitor(Modes.dell, mode: "25").output
        XCTAssertEqual(dell.resolutions.first { $0.width == 1920 }?.modeId, "25", "the 50 Hz mode in use")
    }

    /// For the laptop screen macOS publishes the list itself.
    func testLaptopScreenListsTheSizesMacOSPublishes() {
        var screen = laptop(modes: Modes.macBookFlagged)
        screen.scaledPixelSizes = Modes.macBookScaledSizes
        let output = screen.output
        XCTAssertEqual(titles(output.resolutions), [
            "1680 × 1050", "1440 × 900 (Default)", "1280 × 800", "1024 × 640", "960 × 600",
        ])
        XCTAssertEqual(output.resolutions.filter(\.isCurrent).map(\.title), ["1680 × 1050"])
        XCTAssertEqual(titles(output.allResolutions).prefix(3), [
            "2560 × 1600 (low resolution)", "2048 × 1280 (low resolution)", "1920 × 1200 (low resolution)",
        ])
    }

    func testOtherDisplays() {
        // A 1080p display: from 960 wide upwards, common 16:9 sizes only.
        XCTAssertEqual(titles(monitor(Modes.fhd, mode: "1").output.resolutions), ["1920 × 1080", "1280 × 720"])
        // A 4K display: HiDPI where there is one.
        let uhd = Modes.uhd.map { mode -> DisplayMode in
            var mode = mode
            mode.isNative = mode.id == "1"
            mode.isDefault = mode.id == "2"
            return mode
        }
        XCTAssertEqual(titles(monitor(uhd, mode: "2").output.resolutions), [
            "3840 × 2160 (low resolution)", "2560 × 1440", "1920 × 1080 (Default)",
        ])
    }

    func testModesThatExistOnlyWhileMirroringAreNotOffered() {
        let output = monitor(Modes.qhdMirrored, mode: "28").output
        XCTAssertFalse(output.allResolutions.contains { $0.modeId == "35" || $0.modeId == "38" })
    }
}
