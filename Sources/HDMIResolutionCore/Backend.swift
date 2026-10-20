import Foundation

/// One setting to change on a display. Several are applied together, so a
/// change is seen by macOS as one reconfiguration.
public enum DisplayChange: Equatable, CustomStringConvertible {
    case mode(OutputRef, modeId: String)
    case position(OutputRef, Point)
    /// Make `source` the display the mirror set follows: every member mirrors it.
    case mirror(source: OutputRef, members: [OutputRef])
    /// Take a display out of its mirror set, so it shows a desktop of its own.
    case unmirror(OutputRef)
    /// Switch a display on or off while it stays plugged in.
    case enable(OutputRef, Bool)

    public var description: String {
        switch self {
        case .mode(let output, let modeId):
            return "output.\(output.name).mode.\(modeId)"
        case .position(let output, let point):
            return "output.\(output.name).position.\(point)"
        case .mirror(let source, let members):
            return members.map { "output.\($0.name).mirror.\(source.name)" }.joined(separator: " ")
        case .unmirror(let output):
            return "output.\(output.name).mirror.none"
        case .enable(let output, let on):
            return "output.\(output.name).\(on ? "enable" : "disable")"
        }
    }
}

/// The display system the rules act on: Quartz in the app, a simulation in the tests.
public protocol DisplayBackend: AnyObject {
    /// The current display configuration, or nil when it cannot be determined.
    func snapshot() -> Snapshot?
    /// Applies every change, or none. False when macOS refused.
    func apply(_ changes: [DisplayChange]) -> Bool
}

/// Where settings and state live. The same locations as the Linux original.
public struct Paths: Equatable {
    public var configFile: URL
    public var stateDir: URL

    public init(configFile: URL, stateDir: URL) {
        self.configFile = configFile
        self.stateDir = stateDir
    }

    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Paths {
        func base(_ variable: String, _ fallback: String) -> URL {
            if let value = environment[variable], !value.isEmpty {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
            return home.appendingPathComponent(fallback, isDirectory: true)
        }
        return Paths(
            configFile: base("XDG_CONFIG_HOME", ".config").appendingPathComponent("hdmi-resolution/config"),
            stateDir: base("XDG_STATE_HOME", ".local/state").appendingPathComponent("hdmi-resolution", isDirectory: true))
    }

    /// The laptop screen mode the user last chose.
    public var baselineFile: URL { stateDir.appendingPathComponent("baseline-mode") }
    /// Exists only while a restore of the laptop screen is owed.
    public var pendingFile: URL { stateDir.appendingPathComponent("pending-mode") }

    public enum DisplayState: String {
        /// What the user runs an external display at.
        case baseline
        /// What to put an external display back to.
        case pending
    }

    public func displayFile(key: String, _ state: DisplayState) -> URL? {
        guard let stem = DisplayKey.fileStem(key) else { return nil }
        return stateDir.appendingPathComponent("displays/\(stem).\(state.rawValue)")
    }
}
