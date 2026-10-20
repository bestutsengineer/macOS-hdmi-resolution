import Foundation

/// Settings, in the same file format as the Linux original.
///
/// The file is read as data and never executed. Each line must be exactly one
/// known setting; anything else is ignored and reported by line number.
public struct Config: Equatable {
    /// Mirror rule master switch.
    public var enabled = true
    public var targetWidth = 1920
    public var targetHeight = 1080
    /// Extend rule.
    public var extendTopCenter = true
    /// Keep the menu bar item when no external display is connected.
    /// The one setting the Linux original does not have.
    public var alwaysShowMenuBar = false
    /// Displays with the mirror rule switched off, one "<key> <label>" per entry.
    public var autoOffDisplays: [String] = []
    /// Displays with the extend rule switched off, in the same form.
    public var extendOffDisplays: [String] = []

    public init() {}

    public struct Loaded: Equatable {
        public var config: Config
        /// 1-based numbers of the lines that were not a known setting.
        public var rejectedLines: [Int]
    }

    public static func parse(_ text: String) -> Loaded {
        var config = Config()
        var rejected: [Int] = []
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for (index, line) in lines.enumerated() {
            if config.take(line) { continue }
            if !line.isEmpty && !line.hasPrefix("#") { rejected.append(index + 1) }
        }
        return Loaded(config: config, rejectedLines: rejected)
    }

    /// A missing or unreadable file leaves every setting at its default.
    public static func load(from file: URL) -> Loaded {
        guard let data = try? Data(contentsOf: file) else {
            return Loaded(config: Config(), rejectedLines: [])
        }
        return parse(String(decoding: data, as: UTF8.self))
    }

    private mutating func take(_ line: String) -> Bool {
        guard let equals = line.firstIndex(of: "=") else { return false }
        let name = line[..<equals]
        let value = line[line.index(after: equals)...]
        switch name {
        case "enabled", "extend_top_center", "always_show_menu_bar":
            guard value == "0" || value == "1" else { return false }
            switch name {
            case "enabled": enabled = value == "1"
            case "extend_top_center": extendTopCenter = value == "1"
            default: alwaysShowMenuBar = value == "1"
            }
        case "target_width", "target_height":
            let digits = value.utf8
            guard (3...5).contains(digits.count), digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let number = Int(value) else { return false }
            if name == "target_width" { targetWidth = number } else { targetHeight = number }
        case "auto_off_display", "extend_off_display":
            guard DisplayKey.isValidEntry(value) else { return false }
            if name == "auto_off_display" {
                autoOffDisplays.append(String(value))
            } else {
                extendOffDisplays.append(String(value))
            }
        default:
            return false
        }
        return true
    }

    public func isAutoOff(_ key: String) -> Bool {
        autoOffDisplays.contains { DisplayKey.key(ofEntry: $0) == key }
    }

    public func isExtendOff(_ key: String) -> Bool {
        extendOffDisplays.contains { DisplayKey.key(ofEntry: $0) == key }
    }

    /// The file as the menu writes it: only known settings, one per line.
    public func serialized() -> String {
        var lines = [
            "# Managed by hdmi-resolution (menu bar).",
            "enabled=\(enabled ? 1 : 0)",
            "target_width=\(targetWidth)",
            "target_height=\(targetHeight)",
            "extend_top_center=\(extendTopCenter ? 1 : 0)",
            "always_show_menu_bar=\(alwaysShowMenuBar ? 1 : 0)",
        ]
        // One line per display excluded from the mirror rule: key, then label.
        lines += autoOffDisplays.map { "auto_off_display=\($0)" }
        // The same for the extend rule.
        lines += extendOffDisplays.map { "extend_off_display=\($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    public func save(to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written to a temporary file and renamed, so a reader never sees half a file.
        try Data(serialized().utf8).write(to: file, options: .atomic)
    }
}

/// Stable identity of a display, as stored in the config and in state file names.
///
///   edid:<md5>        hash of the display's EDID; follows the monitor to any port
///                     and is the same value the Linux original computes
///   uuid:<uuid>       the identifier macOS derives for a display with no readable EDID
///   connector:<name>  last resort, tied to the output name
public enum DisplayKey {
    private static func isLowerHex(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a)
            || (byte >= 0x61 && byte <= 0x7a) || byte == 0x5f || byte == 0x2d
    }

    static func isPrintableASCII(_ byte: UInt8) -> Bool { byte >= 0x20 && byte < 0x7f }

    public static func isValid<S: StringProtocol>(_ key: S) -> Bool {
        if key.hasPrefix("edid:") {
            let value = key.dropFirst(5).utf8
            return value.count == 32 && value.allSatisfy(isLowerHex)
        }
        if key.hasPrefix("uuid:") {
            let value = key.dropFirst(5).utf8
            return value.count == 36 && value.allSatisfy { isLowerHex($0) || $0 == 0x2d }
        }
        if key.hasPrefix("connector:") {
            let value = key.dropFirst(10).utf8
            return (1...40).contains(value.count) && value.allSatisfy(isNameByte)
        }
        return false
    }

    /// A config entry is a key, optionally followed by a space and a label of
    /// up to 100 printable ASCII characters.
    static func isValidEntry<S: StringProtocol>(_ entry: S) -> Bool {
        let parts = entry.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let key = parts.first, isValid(key) else { return false }
        guard parts.count == 2 else { return true }
        let label = parts[1].utf8
        return label.count <= 100 && label.allSatisfy(isPrintableASCII)
    }

    public static func key(ofEntry entry: String) -> String {
        String(entry.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// The label part of an entry; an entry without one is labelled by its key.
    public static func label(ofEntry entry: String) -> String {
        let parts = entry.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        return String(parts.count == 2 ? parts[1] : parts.first ?? "")
    }

    /// File name stem for a display's state files, or nil for a key that must
    /// not become part of a path.
    public static func fileStem(_ key: String) -> String? {
        guard let colon = key.firstIndex(of: ":") else { return nil }
        let kind = key[..<colon]
        let value = key[key.index(after: colon)...].utf8
        guard ["edid", "uuid", "connector"].contains(kind), !value.isEmpty,
              value.allSatisfy({ isNameByte($0) || $0 == 0x2e }) else { return nil }
        return "\(kind)-\(key[key.index(after: colon)...])"
    }

    /// Reduce text that came from a monitor to something safe to store and show.
    public static func sanitized(_ text: String, limit: Int) -> String {
        String(String(decoding: text.utf8.filter(isPrintableASCII), as: UTF8.self).prefix(limit))
    }
}
