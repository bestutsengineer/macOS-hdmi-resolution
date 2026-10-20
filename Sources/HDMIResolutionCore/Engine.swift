import Foundation

/// The two display rules.
///
///   Mirror rule: while an external display mirrors the laptop screen, the
///     mirrored desktop is switched to the configured target mode. The user's
///     own modes are restored when mirroring ends. Can be switched off globally
///     or per display.
///   Extend rule: when exactly one external display is extended, it is placed
///     above the laptop screen, horizontally centred. Can be switched off
///     globally or per display.
///
/// `pass()` is run once per display configuration change and never on a timer.
/// Every action is tied to a transition or to a state file the action itself
/// removes, so a pass that follows the engine's own change does nothing.
public final class Engine {
    /// The layout as the rules see it: a mirrored layout the mirror rule does
    /// not apply to is `mirrorManual`.
    public enum State: String {
        case unknown
        case panelOff = "panel-off"
        case noDisplay = "no-display"
        case extend
        case mirror
        case mirrorManual = "mirror-manual"
    }

    /// More display changes than this within `changeWindow` seconds means
    /// something is undoing them; the engine then holds off instead of
    /// flashing the screens in a loop.
    public static let changeLimit = 10
    public static let changeWindow: TimeInterval = 30

    public private(set) var config = Config()
    public private(set) var facts = LayoutFacts.unknown
    public private(set) var state: State?

    private let paths: Paths
    private let backend: DisplayBackend
    private let log: (String) -> Void
    private let clock: () -> Date
    private var lastExtendSignature: String?
    private var lastAppliedPositions: String?
    private var lastSizes: String?
    /// The display that was the main one, the one with the menu bar, the
    /// last time the layout was the user's to arrange.
    private var mainKey: String?
    private var recentChanges: [Date] = []

    public init(
        paths: Paths, backend: DisplayBackend,
        clock: @escaping () -> Date = Date.init, log: @escaping (String) -> Void
    ) {
        self.paths = paths
        self.backend = backend
        self.clock = clock
        self.log = log
    }

    /// Reads the config and forgets what was seen before, as a restart of the
    /// Linux service does. The next pass therefore counts as extend mode or
    /// mirror mode starting.
    public func start() {
        try? FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
        let loaded = Config.load(from: paths.configFile)
        config = loaded.config
        for line in loaded.rejectedLines {
            log("WARNING: ignoring line \(line) of \(paths.configFile.path)")
        }
        state = nil
        lastExtendSignature = nil
        lastAppliedPositions = nil
        lastSizes = nil
        log("Started: session=macos mirror_rule=\(config.enabled ? 1 : 0) "
            + "target=\(config.targetWidth)x\(config.targetHeight) "
            + "extend_rule=\(config.extendTopCenter ? 1 : 0) "
            + "displays_off=\(config.autoOffDisplays.count) "
            + "extend_displays_off=\(config.extendOffDisplays.count) watch=quartz")
    }

    /// Looks at the display configuration once and lets both rules act on it.
    public func pass() {
        refreshSnapshot()
        var now = State(rawValue: facts.layout.rawValue) ?? .unknown
        // Mirroring with the rule switched off: the layout is the user's.
        if now == .mirror && !mirrorRuleWanted() { now = .mirrorManual }
        log("Display configuration changed; layout=\(now.rawValue)")
        if now != state {
            let displays = facts.externals.map(\.summary).joined(separator: "; ")
            log("Layout changed: \(state?.rawValue ?? "initial") -> \(now.rawValue)"
                + (displays.isEmpty ? "" : " [\(displays)]"))
        }
        switch now {
        case .unknown:
            if now != state { log("ERROR: could not determine display layout from macOS") }
        case .panelOff:
            // The laptop screen is off or absent; leave everything as it is.
            break
        case .mirror:
            if state != .mirror {
                savePendingMode()
                saveDisplayPendings()
                applyMirrorMode()
            }
        case .mirrorManual:
            // macOS chose these modes, not the user, and pulling a display out
            // of the shared size would break the mirror: track and restore nothing.
            break
        case .noDisplay, .extend:
            restoreOrTrack()
        }
        let placed = placeExtendedDisplay()
        // Which display is main is noted only while there is a choice: with
        // the laptop screen alone it is main of necessity. The positions in
        // the snapshot are out of date once placed; the next pass notes it.
        if !placed && facts.layout == .extend {
            let all = (facts.panel.map { [$0] } ?? []) + facts.externals
            if let main = all.first(where: { $0.pos == .zero }) { mainKey = main.key }
        }
        state = now
    }

    // MARK: - Snapshot

    private func refreshSnapshot() {
        facts = LayoutFacts(backend.snapshot())
    }

    private func apply(_ changes: [DisplayChange]) -> Bool {
        let now = clock()
        recentChanges.removeAll { now.timeIntervalSince($0) > Engine.changeWindow }
        guard recentChanges.count < Engine.changeLimit else {
            log("ERROR: \(recentChanges.count) display changes within \(Int(Engine.changeWindow)) s; "
                + "holding off so the screens are not changed in a loop")
            return false
        }
        recentChanges.append(now)
        return backend.apply(changes)
    }

    private func describe(_ changes: [DisplayChange]) -> String {
        changes.map(\.description).joined(separator: " ")
    }

    // MARK: - Mirror rule

    /// True when the mirror rule should act: the master switch is on and at
    /// least one mirroring display has not been switched off.
    private func mirrorRuleWanted() -> Bool {
        config.enabled && facts.mirroring.contains { !config.isAutoOff($0.key) }
    }

    private func readLine(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return String(decoding: data, as: UTF8.self).components(separatedBy: "\n").first
    }

    private func write(_ spec: ModeSpec, to file: URL) {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((spec.text + "\n").utf8).write(to: file, options: .atomic)
    }

    /// Notes `spec` as the mode the user runs a display at.
    private func track(_ spec: ModeSpec?, in file: URL) {
        guard let spec, readLine(file) != spec.text else { return }
        write(spec, to: file)
    }

    /// On entering mirror mode, note what the laptop screen has to go back to.
    /// The service often notices mirror mode after macOS has already changed
    /// the screen, so the tracked mode is trusted over the current one.
    private func savePendingMode() {
        let spec: ModeSpec?
        if let line = readLine(paths.baselineFile) {
            spec = ModeSpec(line)
        } else {
            spec = facts.panel?.currentMode?.spec
        }
        guard let spec else { return }
        write(spec, to: paths.pendingFile)
    }

    /// The same for each mirroring display: the mode it was last seen with in
    /// extend mode, else the one it has now.
    private func saveDisplayPendings() {
        for display in facts.mirroring {
            let key = display.key
            guard let pending = paths.displayFile(key: key, .pending),
                  let baseline = paths.displayFile(key: key, .baseline) else { continue }
            let spec: ModeSpec?
            if let line = readLine(baseline) {
                spec = ModeSpec(line)
            } else if readLine(pending) != nil {
                continue
            } else {
                spec = display.currentMode?.spec
            }
            guard let spec else { continue }
            write(spec, to: pending)
        }
    }

    /// A macOS mirror set shows one desktop, in the mode of the display the
    /// others mirror ("Optimise for" in System Settings). The target is
    /// therefore given to that display. A MacBook screen is 16:10 and offers
    /// no 16:9 mode of its own, so when it leads the set and lacks the target,
    /// the set is turned round to follow a display that has it.
    private func applyMirrorMode() {
        guard let panel = facts.panel else { return }
        let width = config.targetWidth, height = config.targetHeight
        let members = [panel] + facts.mirroring
        let source = members.first { member in
            members.contains { $0.replicationSource == member.id }
        } ?? panel
        log("Mirror set follows \(source.name): " + members.map { member in
            "\(member.name) at \(member.currentMode.map { "\($0.spec.label) x\($0.scale)" } ?? "an unknown mode")"
        }.joined(separator: ", "))

        // What to try, in order: the display the set already follows, then
        // the laptop screen, then the others. Only a display that offers the
        // target as a mode of its own can lead; while mirrored, the laptop
        // screen also lists the size of the set, but cannot be switched to it.
        var seen = Set<UInt32>()
        var attempts: [(driver: Output, mode: DisplayMode)] = []
        for driver in ([source] + members) where seen.insert(driver.id).inserted {
            guard driver.offers(width: width, height: height),
                  let best = driver.mode(width: width, height: height) else { continue }
            attempts.append((driver, best))
            // Should macOS refuse a mirror-only mode, the display's own is next.
            if best.mirrorOnly, let own = driver.mode(width: width, height: height, ownOnly: true) {
                attempts.append((driver, own))
            }
        }
        if attempts.isEmpty {
            log("ERROR: no display in the mirror set has a \(width)x\(height) mode "
                + "(\(members.map(\.name).joined(separator: ", "))); mirroring stays at the size macOS chose")
            return
        }
        // One try each, and never again until mirror mode is next entered.
        for (driver, mode) in attempts {
            var changes: [DisplayChange] = []
            if driver.id != source.id {
                changes.append(.mirror(source: driver.ref, members: members.filter { $0.id != driver.id }.map(\.ref)))
            }
            if mode.id != driver.currentModeId {
                changes.append(.mode(driver.ref, modeId: mode.id))
            }
            if changes.isEmpty {
                log("Mirroring is already at \(width)x\(height)")
                return
            }
            if apply(changes) {
                log("Applied mirrored mode \(width)x\(height) on \(driver.name) (\(describe(changes)))")
                refreshSnapshot()
                return
            }
            log("ERROR: macOS refused the mirrored mode (\(describe(changes)))")
        }
    }

    /// Outside mirror mode: put back every mode that is still owed, in one
    /// reconfiguration, or, when nothing is owed, track the modes in use.
    private func restoreOrTrack() {
        guard let panel = facts.panel else { return }
        let files = FileManager.default
        var changes: [DisplayChange] = []
        var settled: [URL] = []
        if let line = readLine(paths.pendingFile) {
            if let spec = ModeSpec(line) {
                if let mode = panel.mode(for: spec) {
                    settled.append(paths.pendingFile)
                    if mode.id != panel.currentModeId { changes.append(.mode(panel.ref, modeId: mode.id)) }
                } else {
                    log("ERROR: saved user mode \(spec.label) is unavailable")
                }
            } else {
                log("ERROR: discarding unreadable pending user mode")
                try? files.removeItem(at: paths.pendingFile)
            }
        }
        for display in facts.externals {
            guard let pending = paths.displayFile(key: display.key, .pending),
                  let line = readLine(pending) else { continue }
            guard let spec = ModeSpec(line), let mode = display.mode(for: spec) else {
                log("ERROR: saved mode of \(display.name) is unavailable; forgetting it")
                try? files.removeItem(at: pending)
                continue
            }
            settled.append(pending)
            if mode.id != display.currentModeId { changes.append(.mode(display.ref, modeId: mode.id)) }
        }
        if !changes.isEmpty {
            if apply(changes) {
                log("Restored user modes (\(describe(changes)))")
                settled.forEach { try? files.removeItem(at: $0) }
                refreshSnapshot()
            } else {
                log("ERROR: macOS refused restoring user modes (\(describe(changes)))")
            }
            return
        }
        if !settled.isEmpty {
            log("User modes are already back in place")
            settled.forEach { try? files.removeItem(at: $0) }
        }
        // A restore that could not be done is still owed: track nothing.
        guard !files.fileExists(atPath: paths.pendingFile.path) else { return }
        track(panel.currentMode?.spec, in: paths.baselineFile)
        for display in facts.externals {
            guard let baseline = paths.displayFile(key: display.key, .baseline) else { continue }
            track(display.currentMode?.spec, in: baseline)
        }
    }

    // MARK: - Extend rule

    /// Where the display and the laptop screen go: the display on top, the
    /// screen directly below, the narrower of the two centred against the wider.
    ///
    /// macOS anchors its coordinates at the main display, the one at 0,0 with
    /// the menu bar, and moving a display to 0,0 makes it the main display.
    /// So the main display stays exactly where it is and the other is placed
    /// relative to it. `main` names the display that was main before, when
    /// that is known: leaving a mirror set the app turned round can leave the
    /// other display main, and the user's main display is put back.
    public static func placement(display: Output, panel: Output, main: String? = nil) -> (display: Point, panel: Point) {
        let width = max(display.logical.w, panel.logical.w)
        let displayAt = Point(x: (width - display.logical.w) / 2, y: 0)
        let panelAt = Point(x: (width - panel.logical.w) / 2, y: display.logical.h)
        let displayIsMain = main.map { $0 == display.key && $0 != panel.key }
            ?? (display.pos == .zero && panel.pos != .zero)
        let (anchor, anchorAt) = displayIsMain ? (display, displayAt) : (panel, panelAt)
        let anchorTarget = main != nil || anchor.pos == .zero ? Point.zero : anchor.pos
        let dx = anchorTarget.x - anchorAt.x, dy = anchorTarget.y - anchorAt.y
        return (Point(x: displayAt.x + dx, y: displayAt.y + dy), Point(x: panelAt.x + dx, y: panelAt.y + dy))
    }

    /// The placement is applied when a single extended display appears
    /// (plug-in, leaving mirror mode, start). Afterwards it is only refreshed
    /// while the layout is still the one this engine made, so a layout the
    /// user drags by hand is left alone until extend mode is next entered.
    ///
    /// When a display changes size, macOS moves it to fit, and its position
    /// no longer matches the one applied. That is not the user dragging it:
    /// if the layout was this engine's just before, it still is, and the
    /// display is centred again for its new size.
    /// Returns whether the displays were moved.
    @discardableResult
    private func placeExtendedDisplay() -> Bool {
        guard config.extendTopCenter, facts.layout == .extend, facts.externals.count == 1,
              let display = facts.externals.first, !display.isVirtual, !config.isExtendOff(display.key),
              let panel = facts.panel else {
            lastExtendSignature = nil
            lastAppliedPositions = nil
            lastSizes = nil
            return false
        }
        // Only a main display that is one of these two counts.
        let main = [display.key, panel.key].contains(mainKey ?? "") ? mainKey : nil
        let target = Engine.placement(display: display, panel: panel, main: main)
        let signature = "\(display.name) \(display.key)"
        let entered = signature != lastExtendSignature
        let sizes = "\(display.logical.w)x\(display.logical.h) \(panel.logical.w)x\(panel.logical.h)"
        let resized = !entered && sizes != lastSizes
        let current = "\(display.pos) \(panel.pos)"
        let ours = entered || (resized ? lastAppliedPositions != nil : current == lastAppliedPositions)
        lastExtendSignature = signature
        lastSizes = sizes
        guard ours else {
            lastAppliedPositions = nil
            return false
        }
        let wanted = "\(target.display) \(target.panel)"
        if current == wanted {
            if entered { log("\(display.name) is already above \(panel.name) and centred") }
            lastAppliedPositions = wanted
            return false
        }
        if apply([.position(display.ref, target.display), .position(panel.ref, target.panel)]) {
            log("Placed \(display.name) above \(panel.name), centred"
                + (resized ? " for its new size" : "")
                + " (\(display.name) at \(target.display), \(panel.name) at \(target.panel))")
            lastAppliedPositions = wanted
            return true
        }
        log("ERROR: macOS refused placing \(display.name) above \(panel.name)")
        lastAppliedPositions = nil
        return false
    }
}
