import Foundation

/// Everything the menu bar item shows, and the config each choice leads to.
///
/// This holds what the Linux original's terminal menu held, and more. The
/// menu bar item itself only draws it, so the behaviour can be tested without
/// a screen.
public struct MenuModel: Equatable {
    public struct Display: Equatable {
        public var key: String
        /// "<model> [<kind>]"; also the label stored in the config.
        public var label: String
        /// "<name>, <state>" for a connected display, else "not connected".
        public var state: String
        /// Whether the mirror rule applies to this display.
        public var ruleOn: Bool
        /// Whether the extend rule applies to this display.
        public var extendOn: Bool

        public var title: String { "\(label) (\(state))" }
    }

    public struct Target: Equatable {
        public var width: Int
        public var height: Int
        public var title: String
        public var selected: Bool
        /// Whether a connected display, or the laptop screen, offers this size.
        public var available: Bool
    }

    /// The sizes offered in the menu. Any other size in the config still works.
    public static let presets: [(width: Int, height: Int, name: String)] = [
        (1920, 1080, "1080p / 1K (recommended)"),
        (2560, 1440, "1440p / 2K"),
        (3840, 2160, "2160p / 4K"),
        (1280, 720, "720p"),
    ]

    public var config: Config
    /// Everything connected now, plus displays with a rule switched off
    /// earlier that are not connected right now.
    public var displays: [Display]
    public var targets: [Target]
    /// Whether a real display other than the laptop screen is connected.
    /// A virtual one, such as an AirPlay screen, does not count.
    public var hasExternalDisplay: Bool
    /// Whether the app has switched a display off. The menu must stay
    /// reachable then, so it can be switched back on.
    public var hasSwitchedOffDisplay: Bool

    public init(config: Config, snapshot: Snapshot?, switchedOff: [OutputRef] = []) {
        self.config = config
        let rows = Listing.rows(snapshot, config: config)
        hasExternalDisplay = rows.contains { $0.kind != "Virtual" }
        hasSwitchedOffDisplay = !switchedOff.isEmpty
        var displays = rows.map {
            Display(key: $0.key, label: "\($0.model) [\($0.kind)]", state: "\($0.name), \($0.state)",
                    ruleOn: $0.ruleOn, extendOn: $0.extendOn)
        }
        for entry in config.autoOffDisplays + config.extendOffDisplays {
            let key = DisplayKey.key(ofEntry: entry)
            guard !displays.contains(where: { $0.key == key }) else { continue }
            displays.append(Display(
                key: key, label: DisplayKey.label(ofEntry: entry), state: "not connected",
                ruleOn: !config.isAutoOff(key), extendOn: !config.isExtendOff(key)))
        }
        self.displays = displays

        let outputs = (snapshot?.outputs ?? []).filter { $0.connected }
        func offered(_ width: Int, _ height: Int) -> Bool {
            outputs.contains { $0.mode(width: width, height: height) != nil }
        }
        var targets = MenuModel.presets.map {
            Target(width: $0.width, height: $0.height, title: "\($0.width)x\($0.height)  \($0.name)",
                   selected: $0.width == config.targetWidth && $0.height == config.targetHeight,
                   available: offered($0.width, $0.height))
        }
        if !targets.contains(where: \.selected) {
            targets.append(Target(
                width: config.targetWidth, height: config.targetHeight,
                title: "\(config.targetWidth)x\(config.targetHeight)  (from the config file)",
                selected: true, available: offered(config.targetWidth, config.targetHeight)))
        }
        self.targets = targets
    }

    /// The menu bar item is there while an external display is connected,
    /// while one is switched off, or all the time if the user asked for that.
    public var showsMenuBarItem: Bool { hasExternalDisplay || hasSwitchedOffDisplay || config.alwaysShowMenuBar }

    public var ruleOnCount: Int { displays.filter(\.ruleOn).count }
    public var extendOnCount: Int { displays.filter(\.extendOn).count }

    /// A target as its menu entry reads. A size the connected displays cannot
    /// do is marked; with no display connected there is nothing to say.
    public func title(of target: Target) -> String {
        target.title + (hasExternalDisplay && !target.available ? "  — not offered by the connected displays" : "")
    }

    private func onOff(_ on: Bool) -> String { on ? "ON" : "OFF" }

    // The menu's entries. A rule's submenu says in its title whether the rule is on.
    public var mirrorRuleTitle: String { "Mirror Rule: \(onOff(config.enabled))" }
    public var extendRuleTitle: String { "Extend Rule (Above, Centred): \(onOff(config.extendTopCenter))" }
    public static let allDisplaysTitle = "On for All Displays"
    public var mirrorPerDisplayTitle: String { "Per Display: \(ruleOnCount) of \(displays.count) on" }
    public var extendPerDisplayTitle: String { "Per Display: \(extendOnCount) of \(displays.count) on" }
    public var targetTitle: String { "Mirrored Target: \(config.targetWidth)x\(config.targetHeight)" }
    public static let restoreTitle = "Restore User Mode: Always On"
    public static let alwaysShowTitle = "Always Show in Menu Bar"

    /// The overview the terminal menu showed above its entries.
    public var statusText: String {
        var text = """
            Mirror rule \(onOff(config.enabled)): while a display mirrors the laptop screen, the
            laptop screen uses \(config.targetWidth)x\(config.targetHeight). Your own resolution is saved first and
            restored when mirroring ends.
            Extend rule \(onOff(config.extendTopCenter)): a single extended display is placed above the
            laptop screen, centred.


            """
        if displays.isEmpty { return text + "No external display connected." }
        text += "Displays:"
        for display in displays {
            text += "\n  \(display.title): mirror rule \(display.ruleOn ? "on" : "off"), "
                + "extend rule \(display.extendOn ? "on" : "off")"
        }
        return text
    }

    // MARK: - Choices

    public func settingMirrorRule(_ on: Bool) -> Config {
        var config = saved()
        config.enabled = on
        return config
    }

    public func settingExtendRule(_ on: Bool) -> Config {
        var config = saved()
        config.extendTopCenter = on
        return config
    }

    public func settingAlwaysShow(_ on: Bool) -> Config {
        var config = saved()
        config.alwaysShowMenuBar = on
        return config
    }

    public func settingTarget(width: Int, height: Int) -> Config {
        var config = saved()
        config.targetWidth = width
        config.targetHeight = height
        return config
    }

    /// Switches the mirror rule on or off for one display.
    public func settingRule(_ on: Bool, forDisplay key: String) -> Config {
        var model = self
        for index in model.displays.indices where model.displays[index].key == key {
            model.displays[index].ruleOn = on
        }
        return model.saved()
    }

    /// Switches the extend rule on or off for one display.
    public func settingExtendRule(_ on: Bool, forDisplay key: String) -> Config {
        var model = self
        for index in model.displays.indices where model.displays[index].key == key {
            model.displays[index].extendOn = on
        }
        return model.saved()
    }

    /// The config as a save writes it: the lists of switched-off displays are
    /// rebuilt from what the menu shows, so labels stay current and anything
    /// the menu does not know is dropped.
    private func saved() -> Config {
        func entries(_ off: (Display) -> Bool) -> [String] {
            displays.filter { off($0) && DisplayKey.isValid($0.key) }.map {
                let label = DisplayKey.sanitized($0.label, limit: 100)
                return label.isEmpty ? $0.key : "\($0.key) \(label)"
            }
        }
        var config = config
        config.autoOffDisplays = entries { !$0.ruleOn }
        config.extendOffDisplays = entries { !$0.extendOn }
        return config
    }

    // MARK: - Explanations, shown as tool tips

    public static let mirrorRuleHelp = """
        Master switch for automatic resolution. When enabled, the mirrored desktop changes to the \
        target mode only while an external display is connected AND macOS is in mirror mode. This \
        applies to every connector: HDMI, USB-C/DisplayPort and docks. Extended layouts never have \
        their resolution changed.

        Individual displays can be excluded below.
        """

    public static let perDisplayHelp = """
        Ticked displays switch the mirrored desktop to the target mode while they mirror the laptop \
        screen; unticked displays leave it alone. A display is recognised by its EDID, so the \
        setting follows it to any port. New displays start ticked.
        """

    public static let targetHelp = """
        This is the mode used while mirroring. It does not affect extended mode.
        """

    public static let extendRuleHelp = """
        When enabled, a single external display in extend mode is placed above the laptop screen, \
        horizontally centred, each time extend mode starts (plugging in, leaving mirror mode, \
        logging in) and when either screen changes resolution. It works with any connector, \
        resolution, scale and rotation.

        You can still drag the screens elsewhere in System Settings; that layout is kept until \
        extend mode next starts. With two or more external displays nothing is moved.
        """

    public static let extendPerDisplayHelp = """
        Ticked displays are placed above the laptop screen when they are the one extended display; \
        unticked displays are left where macOS puts them. A display is recognised by its EDID, so \
        the setting follows it to any port. New displays start ticked.
        """

    public static let restoreHelp = """
        Always enabled: before entering mirror mode, the app records the mode currently selected \
        by the user. When mirror mode ends, it restores that exact mode. The app never hardcodes \
        the restore resolution.
        """

    public static let displayModeHelp = """
        How the laptop screen and the external displays are used together. Switching a screen off \
        is not something macOS offers itself, so it is undone after 15 seconds unless you keep it.
        """

    public static let resolutionHelp = """
        Each display's resolutions as System Settings lists them; "All Resolutions" has every mode \
        the display offers. In extend mode only: while mirroring, the Mirror Rule's target decides.
        """

    public static let alwaysShowHelp = """
        When off, this menu bar item is only there while an external display is connected. When \
        on, it stays, so the rules can be changed before a display is plugged in.
        """

    public static let noDisplayHelp = """
        No external display is connected, and none has been switched off before.
        """
}
