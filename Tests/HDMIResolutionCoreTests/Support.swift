import Foundation
import XCTest
@testable import HDMIResolutionCore

// Nothing here touches the real displays, config or state: the display system
// is replaced by `MockBackend` and every path points into a temporary directory.

/// One simulated display. Its logical size follows from its mode and rotation,
/// as it does on macOS.
struct MockOutput {
    var id: UInt32
    var isPanel = false
    var connected = true
    var enabled = true
    var pos = Point.zero
    /// 0, 90, 180 or 270.
    var rotation = 0
    var mirrors: UInt32 = 0
    var mode: String
    var modes: [DisplayMode]
    var edid: Data?
    var uuid: String?
    var transport: String? = "DisplayPort"
    var systemName: String?
    var isVirtual = false
    /// Modes that are listed but that macOS refuses to switch this display to.
    var unsettable: Set<String> = []
    var scaledPixelSizes: [Size] = []

    var name: String { "display-\(id)" }

    var output: Output {
        let current = modes.first { $0.id == mode }
        let size = Size(w: current?.width ?? 0, h: current?.height ?? 0)
        return Output(
            id: id, name: name, isPanel: isPanel, connected: connected, enabled: enabled, pos: pos,
            logical: rotation % 180 == 0 ? size : Size(w: size.h, h: size.w),
            replicationSource: mirrors, currentModeId: mode, modes: modes, edid: edid, uuid: uuid,
            transport: transport, systemName: systemName, isVirtual: isVirtual, scaledPixelSizes: scaledPixelSizes)
    }
}

/// Stand-in for the macOS display system.
///
/// It keeps a fake display state and applies mode, position, mirror and on/off
/// settings to it. A setting that names an unknown display or mode is refused,
/// and a refused call changes nothing. What it does beyond that follows what
/// macOS was seen doing on real hardware: see docs/DESIGN.md.
final class MockBackend: DisplayBackend {
    var outputs: [MockOutput] = []
    /// The display system gives no usable answer.
    var broken = false
    /// Every setting is refused.
    var failApply = false
    /// This macOS has no way to switch a display off.
    var cannotSwitchOff = false
    /// A display that is switched off is no longer listed, as macOS might do.
    var hidesSwitchedOff = false
    /// Displays switched off while `hidesSwitchedOff`, kept to be switched on again.
    private var unlisted: [MockOutput] = []
    /// One entry per `apply`, whether it succeeded or not.
    var calls: [String] = []
    /// Set by a successful `apply`: macOS would now announce a change.
    var changed = false

    func snapshot() -> Snapshot? {
        broken ? nil : Snapshot(outputs: outputs.map(\.output), canSwitchDisplaysOff: !cannotSwitchOff)
    }

    func apply(_ changes: [DisplayChange]) -> Bool {
        calls.append(changes.map(\.description).joined(separator: " "))
        guard !failApply else { return false }
        var next = outputs
        var stash = unlisted
        func index(_ ref: OutputRef) -> Int? { next.firstIndex { $0.id == ref.id } }
        for change in changes {
            switch change {
            case .mode(let ref, let modeId):
                guard let i = index(ref), next[i].modes.contains(where: { $0.id == modeId }),
                      !next[i].unsettable.contains(modeId) else { return false }
                let before = next[i].output.logical
                next[i].mode = modeId
                let after = next[i].output.logical
                // A display that changes size is moved to fit, as macOS does:
                // it keeps its lower left corner, so it is no longer centred.
                // The main display stays at 0,0; a mirror set is left alone.
                let mirrored = next[i].mirrors != 0 || next.contains { $0.mirrors == next[i].id }
                if before != after && next[i].pos != .zero && !mirrored {
                    next[i].pos.y += before.h - after.h
                }
            case .position(let ref, let point):
                guard let i = index(ref) else { return false }
                next[i].pos = point
            case .mirror(let source, let members):
                guard let s = index(source) else { return false }
                next[s].mirrors = 0
                for member in members {
                    guard let m = index(member) else { return false }
                    next[m].mirrors = source.id
                    next[m].pos = next[s].pos
                }
            case .unmirror(let ref):
                guard let i = index(ref) else { return false }
                next[i].mirrors = 0
                // macOS puts it back to the right of the others.
                let right = next.filter { $0.id != ref.id }.map { $0.pos.x + $0.output.logical.w }.max() ?? 0
                next[i].pos = Point(x: right, y: 0)
            case .enable(let ref, let on):
                guard !cannotSwitchOff else { return false }
                if let i = index(ref) {
                    next[i].enabled = on
                } else if on, let s = stash.firstIndex(where: { $0.id == ref.id }) {
                    var output = stash.remove(at: s)
                    output.enabled = true
                    next.append(output)
                } else {
                    return false
                }
            }
        }
        if hidesSwitchedOff {
            stash += next.filter { !$0.enabled }
            next.removeAll { !$0.enabled }
        }
        outputs = next
        unlisted = stash
        changed = true
        return true
    }

    func output(_ id: UInt32) -> MockOutput? { outputs.first { $0.id == id } }
    func pos(_ id: UInt32) -> String { output(id).map { "\($0.pos)" } ?? "gone" }
    func size(_ id: UInt32) -> String {
        guard let output = output(id), let mode = output.modes.first(where: { $0.id == output.mode }) else { return "gone" }
        return "\(mode.width)x\(mode.height)"
    }
    func scale(_ id: UInt32) -> Int { output(id).flatMap { o in o.modes.first { $0.id == o.mode } }?.scale ?? 0 }
}

enum Modes {
    static func mode(_ id: Int, _ width: Int, _ height: Int, _ refresh: Double = 60, scale: Int = 1,
                     mirrorOnly: Bool = false, isDefault: Bool = false, isNative: Bool = false) -> DisplayMode {
        DisplayMode(id: String(id), width: width, height: height, refresh: refresh, scale: scale, mirrorOnly: mirrorOnly,
                    isDefault: isDefault, isNative: isNative)
    }

    /// The mode list of a real 13-inch MacBook screen (2560x1600), as macOS
    /// reports it. It is 16:10 and has no 16:9 mode at all.
    static let macBook = [
        mode(0, 960, 600, scale: 2), mode(1, 1024, 640, scale: 2), mode(2, 1280, 800, scale: 2),
        mode(3, 1440, 900, scale: 2), mode(4, 1680, 1050, scale: 2),
        mode(5, 1920, 1200), mode(6, 2048, 1280), mode(7, 2560, 1600),
    ]
    /// The same screen after macOS renumbered its modes.
    static let macBookRenumbered = [mode(11, 1920, 1200), mode(12, 1680, 1050, scale: 2), mode(13, 1440, 900, scale: 2)]
    /// A built-in 16:9 screen (iMac), which does offer the usual targets.
    static let iMac = [
        mode(0, 2560, 1440, scale: 2), mode(1, 1920, 1080, scale: 2), mode(2, 1280, 720, scale: 2),
        mode(3, 5120, 2880),
    ]
    /// 1K: a 1920x1080 display or projector.
    static let fhd = [mode(1, 1920, 1080), mode(2, 1920, 1080, 50), mode(3, 1280, 720)]
    /// 2K: taken from a real 2560x1440 monitor.
    static let qhd = [
        mode(28, 2560, 1440), mode(24, 1920, 1080), mode(25, 1920, 1080, 50), mode(26, 1920, 1080, 24),
        mode(13, 1280, 720), mode(12, 1280, 720, scale: 2), mode(40, 1366, 768), mode(41, 2561, 1440),
    ]
    /// The same monitor while it is part of a mirror set with a Retina laptop
    /// screen: macOS adds HiDPI sizes that exist only then. Ids as on real hardware.
    static let qhdMirrored = qhd + [
        mode(35, 1920, 1080, scale: 2, mirrorOnly: true), mode(38, 2560, 1440, scale: 2, mirrorOnly: true),
    ]
    /// Every mode a real DELL U2713H (2560x1440) offers while extended, ids
    /// and flags as macOS reports them.
    static let dell: [DisplayMode] = [
        mode(0, 800, 600, 75), mode(1, 800, 600), mode(2, 800, 600, scale: 2), mode(3, 840, 525, scale: 2),
        mode(4, 960, 540, scale: 2), mode(5, 960, 540, 50, scale: 2), mode(6, 960, 540, 24, scale: 2),
        mode(7, 1024, 576, scale: 2), mode(8, 1024, 576), mode(9, 1024, 768, 75), mode(10, 1024, 768),
        mode(11, 1152, 864, 75), mode(12, 1280, 720, scale: 2, isNative: true), mode(13, 1280, 720),
        mode(14, 1280, 720, 50), mode(15, 1280, 800), mode(16, 1280, 960), mode(17, 1280, 1024, 75),
        mode(18, 1280, 1024), mode(19, 1344, 756), mode(20, 1344, 1008), mode(21, 1600, 900), mode(22, 1600, 1200),
        mode(23, 1680, 1050), mode(24, 1920, 1080), mode(25, 1920, 1080, 50), mode(26, 1920, 1080, 24),
        mode(27, 2048, 1152), mode(28, 2560, 1440, isDefault: true, isNative: true),
    ]
    /// The same 13-inch MacBook screen as `macBook`, with its flags, and the
    /// sizes macOS lists for it in System Settings ("scale-resolutions").
    static let macBookFlagged = [
        mode(0, 960, 600, scale: 2), mode(1, 1024, 640, scale: 2), mode(2, 1280, 800, scale: 2, isNative: true),
        mode(3, 1440, 900, scale: 2, isDefault: true), mode(4, 1680, 1050, scale: 2),
        mode(5, 1920, 1200), mode(6, 2048, 1280), mode(7, 2560, 1600, isNative: true),
    ]
    static let macBookScaledSizes = [
        Size(w: 3360, h: 2100), Size(w: 2880, h: 1800), Size(w: 2560, h: 1600), Size(w: 2048, h: 1280), Size(w: 1920, h: 1200),
    ]
    /// 4K: 3840x2160, usually run as "looks like 1920x1080".
    static let uhd = [
        mode(1, 3840, 2160), mode(7, 3840, 2160, 30), mode(2, 1920, 1080, scale: 2), mode(4, 1920, 1080),
        mode(3, 2560, 1440, scale: 2), mode(5, 2560, 1440), mode(6, 1280, 720, scale: 2),
    ]
}

enum Fixture {
    static func edid(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "edid", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }
    /// A real monitor EDID with the serial number blanked.
    static let dell = edid("dell-p2723de")
    static let dellKey = "edid:97262ce623252689c142e639905a299d"
    /// Synthetic: no monitor name descriptor.
    static let noName = edid("no-name-lg")
    /// Synthetic: a monitor name that looks like a command-line option.
    static let hostile = edid("hostile-name")
    static let hostileKey = "edid:cbe35d2b690ef862cd12e6e23c1e2061"
}

/// The laptop screen, id 1, at "looks like 1680x1050".
func laptop(at pos: Point = .zero, mode: String = "4", modes: [DisplayMode] = Modes.macBook,
           mirrors: UInt32 = 0, enabled: Bool = true) -> MockOutput {
    MockOutput(id: 1, isPanel: true, enabled: enabled, pos: pos, mirrors: mirrors, mode: mode, modes: modes, transport: nil)
}

/// An external display, to the right of the laptop screen unless told otherwise.
func monitor(_ id: UInt32, _ modes: [DisplayMode], mode: String? = nil, at pos: Point = Point(x: 1680, y: 0),
             mirrors: UInt32 = 0, edid: Data? = nil) -> MockOutput {
    MockOutput(id: id, pos: pos, mirrors: mirrors, mode: mode ?? modes[0].id, modes: modes, edid: edid)
}

/// The usual single external display, id 2.
func monitor(_ modes: [DisplayMode], mode: String? = nil, at pos: Point = Point(x: 1680, y: 0),
             mirrors: UInt32 = 0, edid: Data? = nil) -> MockOutput {
    monitor(2, modes, mode: mode, at: pos, mirrors: mirrors, edid: edid)
}

/// The mode the laptop screen starts in, as the state files hold it.
let userMode = "1680 1050 60 2"

/// A clean config, state and display system for one test.
class RuleTestCase: XCTestCase {
    var directory: URL!
    var paths: Paths!
    var backend: MockBackend!
    var engine: Engine!
    var log: [String] = []
    var now = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdmi-resolution-tests-\(UUID().uuidString)", isDirectory: true)
        paths = Paths(
            configFile: directory.appendingPathComponent("config/hdmi-resolution/config"),
            stateDir: directory.appendingPathComponent("state/hdmi-resolution", isDirectory: true))
        try! FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(
            at: paths.configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        backend = MockBackend()
        log = []
        engine = Engine(paths: paths, backend: backend, clock: { [unowned self] in self.now }) { [unowned self] in
            self.log.append($0)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func config(_ lines: String...) {
        try! Data((lines.joined(separator: "\n") + "\n").utf8).write(to: paths.configFile)
    }

    /// Start the engine on an initial display state.
    func start(_ outputs: MockOutput...) {
        backend.outputs = outputs
        engine.start()
        settle()
    }

    /// Change the display state as macOS would, and let the engine react.
    func change(_ outputs: MockOutput...) {
        backend.outputs = outputs
        now += 60
        settle()
    }

    /// The engine is woken once for the change and again for every change it
    /// makes itself, until it does nothing. A rule that kept re-applying would
    /// never get there.
    func settle(file: StaticString = #filePath, line: UInt = #line) {
        var passes = 0
        repeat {
            backend.changed = false
            engine.pass()
            passes += 1
        } while backend.changed && passes < 12
        XCTAssertLessThan(passes, 12, "the engine keeps changing the displays", file: file, line: line)
    }

    private func saved(_ file: URL?) -> String {
        guard let file, let data = try? Data(contentsOf: file) else { return "none" }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .newlines).replacingOccurrences(of: "\t", with: " ")
    }

    var pending: String { saved(paths.pendingFile) }
    var baseline: String { saved(paths.baselineFile) }
    func displayState(_ key: String, _ state: Paths.DisplayState) -> String { saved(paths.displayFile(key: key, state)) }

    func write(_ text: String, to file: URL) {
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data((text.replacingOccurrences(of: " ", with: "\t") + "\n").utf8).write(to: file)
    }

    func assertLog(_ pattern: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            log.contains { $0.range(of: pattern, options: .regularExpression) != nil },
            "no log line matching '\(pattern)' in:\n\(log.joined(separator: "\n"))", file: file, line: line)
    }

    func logCount(_ text: String) -> Int { log.filter { $0.contains(text) }.count }
}
