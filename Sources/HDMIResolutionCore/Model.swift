import CryptoKit
import Foundation

public struct Point: Equatable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
    public static let zero = Point(x: 0, y: 0)
    public var description: String { "\(x),\(y)" }
}

public struct Size: Equatable {
    public var w: Int
    public var h: Int
    public init(w: Int, h: Int) {
        self.w = w
        self.h = h
    }
}

/// One mode a display offers. Width and height are the size macOS shows in
/// System Settings ("looks like"); `scale` is 2 for a HiDPI mode and 1 otherwise.
public struct DisplayMode: Equatable {
    /// Only meaningful within one snapshot: macOS renumbers modes when displays
    /// come and go, so an id is looked up fresh every time and never stored.
    public var id: String
    public var width: Int
    public var height: Int
    public var refresh: Double
    public var scale: Int
    /// A mode macOS lists only while the display is part of a mirror set.
    /// On an external display these are extra HiDPI sizes and can be chosen.
    /// On the laptop screen it is the size the set runs at, which the screen
    /// shows but cannot be switched to.
    public var mirrorOnly: Bool
    /// The mode macOS recommends for the display ("Default" in System Settings).
    public var isDefault: Bool
    /// The mode whose pixels are the panel's own pixels.
    public var isNative: Bool

    public init(id: String, width: Int, height: Int, refresh: Double, scale: Int, mirrorOnly: Bool = false,
                isDefault: Bool = false, isNative: Bool = false) {
        self.id = id
        self.width = width
        self.height = height
        self.refresh = refresh
        self.scale = scale
        self.mirrorOnly = mirrorOnly
        self.isDefault = isDefault
        self.isNative = isNative
    }

    public var spec: ModeSpec { ModeSpec(width: width, height: height, refresh: refresh, scale: scale) }
}

/// A mode as it is remembered in a state file: size, refresh rate and, on
/// macOS, the backing scale. A file written by the Linux original has no
/// scale and matches a mode of either kind.
public struct ModeSpec: Equatable {
    public var width: Int
    public var height: Int
    public var refresh: Double
    public var scale: Int?

    public init(width: Int, height: Int, refresh: Double, scale: Int?) {
        self.width = width
        self.height = height
        self.refresh = refresh
        self.scale = scale
    }

    /// Parses "<width> <height> <refresh> [<scale>]", separated by tabs or spaces.
    public init?(_ text: String) {
        let fields = text.split(whereSeparator: { $0 == "\t" || $0 == " " })
        guard fields.count == 3 || fields.count == 4 else { return nil }
        func isNumber(_ field: Substring, allowDot: Bool) -> Bool {
            !field.isEmpty && field.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || (allowDot && $0 == 0x2e) }
        }
        guard isNumber(fields[0], allowDot: false), isNumber(fields[1], allowDot: false),
              isNumber(fields[2], allowDot: true),
              let width = Int(fields[0]), let height = Int(fields[1]), let refresh = Double(fields[2])
        else { return nil }
        var scale: Int?
        if fields.count == 4 {
            guard isNumber(fields[3], allowDot: false), let value = Int(fields[3]) else { return nil }
            scale = value
        }
        self.init(width: width, height: height, refresh: refresh, scale: scale)
    }

    private var refreshText: String {
        refresh == refresh.rounded() ? String(Int(refresh)) : String(refresh)
    }

    /// The line stored in a state file.
    public var text: String {
        (["\(width)", "\(height)", refreshText] + (scale.map { ["\($0)"] } ?? [])).joined(separator: "\t")
    }

    public var label: String { "\(width)x\(height)@\(refreshText)" }
}

/// One display as the backend reports it.
public struct Output: Equatable {
    public var id: UInt32
    public var name: String
    /// The laptop's own screen.
    public var isPanel: Bool
    public var connected: Bool
    public var enabled: Bool
    public var pos: Point
    /// The size the display occupies in the desktop layout.
    public var logical: Size
    /// Id of the display this one mirrors, or 0.
    public var replicationSource: UInt32
    public var currentModeId: String?
    public var modes: [DisplayMode]
    public var edid: Data?
    public var uuid: String?
    /// How the display is attached, as the system describes it ("DisplayPort", "HDMI", ...).
    public var transport: String?
    /// The name macOS shows for the display; used when there is no EDID to read one from.
    public var systemName: String?
    /// AirPlay, Sidecar and other software displays.
    public var isVirtual: Bool
    /// The HiDPI sizes macOS itself offers for this display in System Settings,
    /// as backing pixel sizes. Known for the laptop screen, empty for most others.
    public var scaledPixelSizes: [Size]

    public init(
        id: UInt32, name: String, isPanel: Bool, connected: Bool = true, enabled: Bool = true,
        pos: Point, logical: Size, replicationSource: UInt32 = 0, currentModeId: String?,
        modes: [DisplayMode], edid: Data? = nil, uuid: String? = nil, transport: String? = nil,
        systemName: String? = nil, isVirtual: Bool = false, scaledPixelSizes: [Size] = []
    ) {
        self.id = id
        self.name = name
        self.isPanel = isPanel
        self.connected = connected
        self.enabled = enabled
        self.pos = pos
        self.logical = logical
        self.replicationSource = replicationSource
        self.currentModeId = currentModeId
        self.modes = modes
        self.edid = edid
        self.uuid = uuid
        self.transport = transport
        self.systemName = systemName
        self.isVirtual = isVirtual
        self.scaledPixelSizes = scaledPixelSizes
    }

    public var ref: OutputRef { OutputRef(id: id, name: name) }

    public var currentMode: DisplayMode? { modes.first { $0.id == currentModeId } }

    /// The mode of a given size to switch to. A size is often offered twice,
    /// plain and HiDPI; the HiDPI one is sharper and is what System Settings
    /// picks. Among those, a mode of the display's own wins over a
    /// mirror-only one, then the refresh rate closest to the current one.
    public func mode(width: Int, height: Int, ownOnly: Bool = false) -> DisplayMode? {
        let now = currentMode
        return modes
            .filter { $0.width == width && $0.height == height && !(ownOnly && $0.mirrorOnly) }
            .min { rank($0, now) < rank($1, now) }
    }

    private func rank(_ mode: DisplayMode, _ now: DisplayMode?) -> (Int, Int, Double, Int) {
        (-mode.scale, mode.mirrorOnly ? 1 : 0,
         abs(mode.refresh - (now?.refresh ?? mode.refresh)), mode.id == currentModeId ? 0 : 1)
    }

    /// Whether the display can lead a mirror set at this size: it has a mode
    /// of that size of its own, not merely the size of the set it is in.
    public func offers(width: Int, height: Int) -> Bool {
        mode(width: width, height: height, ownOnly: true) != nil
    }

    /// The mode a state file refers to, resolved against the modes on offer now.
    public func mode(for spec: ModeSpec) -> DisplayMode? {
        modes
            .filter {
                $0.width == spec.width && $0.height == spec.height
                    && abs($0.refresh - spec.refresh) < 0.2
                    && (spec.scale == nil || spec.scale == $0.scale)
            }
            .min {
                (abs($0.refresh - spec.refresh), $0.id == currentModeId ? 0 : 1)
                    < (abs($1.refresh - spec.refresh), $1.id == currentModeId ? 0 : 1)
            }
    }
}

public struct OutputRef: Equatable {
    public var id: UInt32
    public var name: String
    public init(id: UInt32, name: String) {
        self.id = id
        self.name = name
    }
}

// MARK: - Display identity

extension Output {
    /// Stable identity of the display. See `DisplayKey`.
    public var key: String {
        if let edid, !edid.isEmpty {
            let digest = Insecure.MD5.hash(data: edid)
            return "edid:" + digest.map { String(format: "%02x", $0) }.joined()
        }
        if let uuid {
            let key = "uuid:" + uuid.lowercased()
            if DisplayKey.isValid(key) { return key }
        }
        return "connector:\(name)"
    }

    /// Human-readable model: the EDID monitor name, else vendor and product
    /// code, else whatever macOS calls it.
    public var model: String {
        if let edid, let name = EDID.model(Array(edid)) { return name }
        if let systemName {
            let name = DisplayKey.sanitized(systemName, limit: 60).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return "Unidentified display"
    }

    public var kind: String {
        if isPanel { return "Built-in" }
        if isVirtual { return "Virtual" }
        guard let transport else { return "External" }
        let lowered = transport.lowercased()
        if lowered.contains("hdmi") { return "HDMI" }
        // USB-C displays use DisplayPort signalling, so the two cannot be told apart.
        if lowered.contains("displayport") || lowered == "dp" || lowered.contains("usb-c")
            || lowered.contains("thunderbolt") { return "USB-C/DisplayPort" }
        if lowered.contains("dvi") { return "DVI" }
        if lowered.contains("vga") { return "VGA" }
        let label = DisplayKey.sanitized(transport, limit: 20)
        return label.isEmpty ? "External" : label
    }

    public var summary: String { "\(name): \(model), \(kind)" }
}

public enum EDID {
    /// The standard eight-byte header every EDID block starts with.
    public static func isPlausible(_ data: Data) -> Bool {
        data.count >= 128 && Array(data.prefix(8)) == [0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00]
    }

    /// Vendor, product and serial number, as macOS reports them for a display.
    public static func identity(_ data: Data) -> (vendor: UInt32, product: UInt32, serial: UInt32)? {
        guard data.count >= 16 else { return nil }
        let b = Array(data.prefix(16)).map(UInt32.init)
        return (b[8] << 8 | b[9], b[11] << 8 | b[10], b[15] << 24 | b[14] << 16 | b[13] << 8 | b[12])
    }

    /// The monitor name descriptor, else the vendor code and product number.
    /// The name is supplied by the monitor and therefore untrusted: only
    /// printable ASCII is kept, and the length is capped.
    public static func model(_ b: [UInt8]) -> String? {
        guard b.count >= 128 else { return nil }
        var name = ""
        for offset in [54, 72, 90, 108] {
            // Display descriptor 0xFC carries the monitor name.
            guard b[offset] == 0, b[offset + 1] == 0, b[offset + 2] == 0, b[offset + 3] == 0xfc else { continue }
            for i in (offset + 5)..<(offset + 18) {
                if b[i] == 10 { break }
                guard b[i] >= 32 && b[i] < 127 else { continue }
                name.unicodeScalars.append(Unicode.Scalar(b[i]))
            }
        }
        while name.hasSuffix(" ") { name.removeLast() }
        if name.isEmpty {
            // Bytes 8-9 pack the three-letter PNP vendor ID, five bits per letter.
            let packed = Int(b[8]) << 8 | Int(b[9])
            var vendor = ""
            for shift in [10, 5, 0] {
                vendor.unicodeScalars.append(Unicode.Scalar(UInt8((packed >> shift & 31) + 64)))
            }
            if !vendor.utf8.allSatisfy({ $0 >= 0x41 && $0 <= 0x5a }) { vendor = "???" }
            name = vendor + " " + String(format: "%04X", Int(b[11]) << 8 | Int(b[10]))
        }
        return String(name.prefix(60))
    }
}

// MARK: - Layout

public enum Layout: String {
    /// The backend gave no usable answer.
    case unknown
    /// The laptop screen is off or absent (lid closed).
    case panelOff = "panel-off"
    case noDisplay = "no-display"
    case extend
    case mirror
}

public struct Snapshot: Equatable {
    public var outputs: [Output]
    /// Whether this macOS lets the app switch a display off and on again.
    public var canSwitchDisplaysOff: Bool

    public init(outputs: [Output], canSwitchDisplaysOff: Bool = true) {
        self.outputs = outputs
        self.canSwitchDisplaysOff = canSwitchDisplaysOff
    }
}

/// What every rule works from, derived once from one snapshot.
public struct LayoutFacts: Equatable {
    public var layout: Layout
    public var panel: Output?
    /// Every connected, enabled display other than the laptop screen.
    public var externals: [Output]
    /// The externals mirroring the laptop screen; empty unless the layout is `mirror`.
    public var mirroring: [Output]

    public static let unknown = LayoutFacts(layout: .unknown, panel: nil, externals: [], mirroring: [])

    public init(layout: Layout, panel: Output?, externals: [Output], mirroring: [Output]) {
        self.layout = layout
        self.panel = panel
        self.externals = externals
        self.mirroring = mirroring
    }

    public init(_ snapshot: Snapshot?) {
        guard let snapshot else {
            self = .unknown
            return
        }
        let panel = snapshot.outputs.first { $0.isPanel }
        let externals = snapshot.outputs.filter { !$0.isPanel && $0.connected && $0.enabled }
        guard let panel, panel.enabled else {
            self.init(layout: .panelOff, panel: panel, externals: externals, mirroring: [])
            return
        }
        let mirroring = externals.filter { $0.mirrors(panel) }
        if externals.isEmpty {
            self.init(layout: .noDisplay, panel: panel, externals: [], mirroring: [])
        } else if mirroring.isEmpty {
            self.init(layout: .extend, panel: panel, externals: externals, mirroring: [])
        } else {
            self.init(layout: .mirror, panel: panel, externals: externals, mirroring: mirroring)
        }
    }
}

extension Output {
    /// macOS reports mirroring through the mirror source. Displays of one
    /// mirror set also share a position, which catches a set with three members.
    public func mirrors(_ panel: Output) -> Bool {
        replicationSource == panel.id || panel.replicationSource == id || pos == panel.pos
    }
}
