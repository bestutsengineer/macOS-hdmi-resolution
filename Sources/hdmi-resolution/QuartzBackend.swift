import AppKit
import CoreGraphics
import Foundation
import HDMIResolutionCore
import IOKit

/// The real displays, through Quartz Display Services.
///
/// Reading uses public API throughout, with one exception noted below. Every
/// change goes through a single display configuration transaction, so macOS
/// applies a set of changes together or not at all.
final class QuartzBackend: DisplayBackend {
    /// Told why macOS refused a change, for the log.
    var diagnostics: ((String) -> Void)?

    /// EDID blocks found earlier in this run, by the numbers Quartz reports
    /// for the display. A monitor's EDID does not change, and remembering it
    /// keeps the display's key steady whatever the registry holds at the moment.
    private var known: [String: RegistryEDID] = [:]
    /// Displays that had no EDID in the registry even after waiting for one.
    private var withoutEDID: Set<String> = []

    /// How often, half a second apart, the registry is read again for a newly
    /// connected display before it is taken to have no EDID there.
    private static let registryRetries = 10

    func snapshot() -> Snapshot? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        ids = Array(ids.prefix(Int(count)))
        let blobs = edids(for: ids)
        let names = systemNames()
        return Snapshot(
            outputs: ids.map { output($0, blob: blobs[$0], names: names) },
            canSwitchDisplaysOff: DisplaySwitch.isAvailable)
    }

    private func identity(_ id: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    /// The EDID of every display that has one.
    ///
    /// Right after a display is plugged in, Quartz already lists it while the
    /// registry does not yet hold its EDID. A display's key depends on the
    /// EDID, so the rules must not run on a half-identified display: the first
    /// time a real external display shows up without one, wait for it.
    private func edids(for ids: [CGDirectDisplayID]) -> [CGDirectDisplayID: RegistryEDID] {
        var found: [CGDirectDisplayID: RegistryEDID] = [:]
        for attempt in 0...QuartzBackend.registryRetries {
            let blobs = RegistryEDID.all()
            var waitingFor: [String] = []
            for id in ids where found[id] == nil {
                let key = identity(id)
                if let blob = RegistryEDID.match(
                    blobs, vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id),
                    serial: CGDisplaySerialNumber(id)) {
                    found[id] = blob
                    known[key] = blob
                } else if let blob = known[key] {
                    found[id] = blob
                } else if CGDisplayIsBuiltin(id) == 0, !WindowServerInfo.isVirtual(WindowServerInfo.describe(id)),
                          !withoutEDID.contains(key) {
                    waitingFor.append(key)
                }
            }
            if waitingFor.isEmpty { break }
            if attempt == QuartzBackend.registryRetries {
                withoutEDID.formUnion(waitingFor)
                break
            }
            usleep(500_000)
        }
        return found
    }

    private func output(_ id: CGDirectDisplayID, blob: RegistryEDID?, names: [CGDirectDisplayID: String]) -> Output {
        let source = CGDisplayMirrorsDisplay(id)
        // A display that mirrors another one occupies that display's place.
        let bounds = CGDisplayBounds(source == kCGNullDirectDisplay ? id : source)
        let current = CGDisplayCopyDisplayMode(id)
        var modes = allModes(id)
            .filter { $0.isUsableForDesktopGUI() || $0.ioDisplayModeID == current?.ioDisplayModeID }
            .map(displayMode)
        if let current, !modes.contains(where: { $0.id == String(current.ioDisplayModeID) }) {
            modes.append(displayMode(current))
        }
        var uuid: String?
        if let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            uuid = CFUUIDCreateString(nil, value) as String?
        }
        let info = WindowServerInfo.describe(id)
        return Output(
            id: id,
            name: "display-\(id)",
            isPanel: CGDisplayIsBuiltin(id) != 0,
            connected: true,
            // In a mirror set only one member counts as active for drawing.
            enabled: CGDisplayIsActive(id) != 0 || CGDisplayIsInMirrorSet(id) != 0,
            pos: Point(x: Int(bounds.origin.x), y: Int(bounds.origin.y)),
            logical: Size(w: Int(bounds.width), h: Int(bounds.height)),
            replicationSource: source,
            currentModeId: current.map { String($0.ioDisplayModeID) },
            modes: modes,
            edid: blob?.data,
            uuid: uuid,
            transport: blob?.transport,
            systemName: names[id],
            isVirtual: WindowServerInfo.isVirtual(info),
            scaledPixelSizes: WindowServerInfo.scaledPixelSizes(info))
    }

    /// Every mode, including the HiDPI ones the short list leaves out.
    private func allModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    }

    /// IOKit's kDisplayModeValidForMirroringFlag: set on the modes macOS adds
    /// to a display's list while it is part of a mirror set.
    private static let validForMirroring: UInt32 = 0x0020_0000
    /// kDisplayModeDefaultFlag: the mode System Settings calls "Default".
    private static let defaultMode: UInt32 = 0x0000_0004
    /// kDisplayModeNativeFlag: the mode that uses the panel's own pixels.
    private static let nativeMode: UInt32 = 0x0200_0000

    private func displayMode(_ mode: CGDisplayMode) -> DisplayMode {
        let scale = mode.width > 0 ? Int((Double(mode.pixelWidth) / Double(mode.width)).rounded()) : 1
        return DisplayMode(
            id: String(mode.ioDisplayModeID), width: mode.width, height: mode.height,
            refresh: mode.refreshRate, scale: max(1, scale),
            mirrorOnly: mode.ioFlags & QuartzBackend.validForMirroring != 0,
            isDefault: mode.ioFlags & QuartzBackend.defaultMode != 0,
            isNative: mode.ioFlags & QuartzBackend.nativeMode != 0)
    }

    private func systemNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            names[number.uint32Value] = screen.localizedName
        }
        return names
    }

    func apply(_ changes: [DisplayChange]) -> Bool {
        var token: CGDisplayConfigRef?
        let began = CGBeginDisplayConfiguration(&token)
        guard began == .success, let token else {
            diagnostics?("CGBeginDisplayConfiguration failed with error \(began.rawValue)")
            return false
        }
        for change in changes {
            if let failure = configure(token, change) {
                CGCancelDisplayConfiguration(token)
                diagnostics?("\(failure) for \(change); nothing was changed")
                return false
            }
        }
        // Permanent, as a change made in System Settings is: macOS remembers
        // it for this set of displays.
        let completed = CGCompleteDisplayConfiguration(token, .permanently)
        if completed != .success {
            diagnostics?("CGCompleteDisplayConfiguration failed with error \(completed.rawValue)")
        }
        return completed == .success
    }

    /// Adds one change to the transaction. Returns what went wrong, if anything.
    private func configure(_ token: CGDisplayConfigRef, _ change: DisplayChange) -> String? {
        func check(_ call: String, _ result: CGError) -> String? {
            result == .success ? nil : "\(call) failed with error \(result.rawValue)"
        }
        switch change {
        case .mode(let output, let modeId):
            // The id is resolved against the modes on offer right now.
            guard let mode = allModes(output.id).first(where: { String($0.ioDisplayModeID) == modeId }) else {
                return "the mode is no longer on offer"
            }
            return check("CGConfigureDisplayWithDisplayMode", CGConfigureDisplayWithDisplayMode(token, output.id, mode, nil))
        case .position(let output, let point):
            return check("CGConfigureDisplayOrigin", CGConfigureDisplayOrigin(token, output.id, Int32(point.x), Int32(point.y)))
        case .mirror(let source, let members):
            if let failure = check("CGConfigureDisplayMirrorOfDisplay",
                                   CGConfigureDisplayMirrorOfDisplay(token, source.id, kCGNullDirectDisplay)) {
                return failure
            }
            for member in members {
                if let failure = check("CGConfigureDisplayMirrorOfDisplay",
                                       CGConfigureDisplayMirrorOfDisplay(token, member.id, source.id)) {
                    return failure
                }
            }
            return nil
        case .unmirror(let output):
            return check("CGConfigureDisplayMirrorOfDisplay",
                         CGConfigureDisplayMirrorOfDisplay(token, output.id, kCGNullDirectDisplay))
        case .enable(let output, let on):
            guard let result = DisplaySwitch.configure(token, output.id, on: on) else {
                return "switching a display on or off is not available on this macOS"
            }
            return check(DisplaySwitch.name, result)
        }
    }
}

/// EDID blocks found in the I/O Registry.
///
/// Quartz hands out a display's vendor, product and serial number but not the
/// EDID itself. The registry has it, on the node of the port the display is
/// attached to, together with how it is attached.
struct RegistryEDID {
    var data: Data
    var transport: String?

    static func all() -> [RegistryEDID] {
        var iterator: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(
            root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [RegistryEDID] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            // "EDID" on Apple silicon, "IODisplayEDID" on Intel.
            for key in ["EDID", "IODisplayEDID"] {
                guard let data = property(entry, key) as? Data, EDID.isPlausible(data) else { continue }
                var transport = property(entry, "TransportTypeDescription") as? String
                if transport == nil {
                    var name = [CChar](repeating: 0, count: 128)
                    if IOObjectGetClass(entry, &name) == KERN_SUCCESS { transport = String(cString: name) }
                }
                found.append(RegistryEDID(data: data, transport: transport))
                break
            }
        }
        return found
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// The block belonging to a display, by the numbers Quartz reports for it.
    static func match(_ blobs: [RegistryEDID], vendor: UInt32, product: UInt32, serial: UInt32) -> RegistryEDID? {
        let sameModel = blobs.filter {
            guard let identity = EDID.identity($0.data) else { return false }
            return identity.vendor == vendor && identity.product == product
        }
        if let exact = sameModel.first(where: { EDID.identity($0.data)?.serial == serial }) { return exact }
        // Without a matching serial, only an unambiguous model is trusted.
        return Set(sameModel.map(\.data)).count == 1 ? sameModel.first : nil
    }
}

/// The window server's own description of a display.
///
/// Public API does not say whether a display is a software one (AirPlay,
/// Sidecar, a virtual screen), nor which sizes System Settings offers for it.
/// This description does. It comes from CoreDisplay, which is not public, and
/// is looked up at run time: if a future macOS drops it, every display counts
/// as a real one and its sizes are worked out from its modes instead.
enum WindowServerInfo {
    private typealias Describe = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    private static let function: Describe? = {
        guard let library = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
              let symbol = dlsym(library, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
        return unsafeBitCast(symbol, to: Describe.self)
    }()

    static func describe(_ id: CGDirectDisplayID) -> [String: Any]? {
        function?(id)?.takeRetainedValue() as? [String: Any]
    }

    static func isVirtual(_ info: [String: Any]?) -> Bool {
        ["kCGDisplayIsVirtualDevice", "kCGDisplayIsAirPlay"].contains { (info?[$0] as? NSNumber)?.boolValue == true }
    }

    /// "scale-resolutions": the backing pixel sizes of the HiDPI sizes System
    /// Settings offers, each entry starting with width and height as
    /// big-endian 32-bit numbers.
    static func scaledPixelSizes(_ info: [String: Any]?) -> [Size] {
        guard let entries = info?["scale-resolutions"] as? [Data] else { return [] }
        return entries.compactMap { entry in
            let bytes = [UInt8](entry)
            guard bytes.count >= 8 else { return nil }
            func number(_ offset: Int) -> Int { bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
            let size = Size(w: number(0), h: number(4))
            return size.w > 0 && size.h > 0 ? size : nil
        }
    }
}

/// Switching a display off and on again while it stays plugged in.
///
/// macOS has no public call for this; System Settings cannot do it either.
/// The window server's own configuration call is looked up at run time, the
/// one display tools such as displayplacer use. Without it, the arrangements
/// that need it are not offered.
enum DisplaySwitch {
    private typealias Configure = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError

    private static let found: (name: String, function: Configure)? = {
        let candidates = [
            ("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", "CGSConfigureDisplayEnabled"),
            ("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", "SLSConfigureDisplayEnabled"),
        ]
        for (path, name) in candidates {
            if let library = dlopen(path, RTLD_LAZY), let symbol = dlsym(library, name) {
                return (name, unsafeBitCast(symbol, to: Configure.self))
            }
        }
        return nil
    }()

    static var isAvailable: Bool { found != nil }
    static var name: String { found?.name ?? "CGSConfigureDisplayEnabled" }

    /// Adds the change to the transaction; nil when the call is not available.
    static func configure(_ token: CGDisplayConfigRef, _ id: CGDirectDisplayID, on: Bool) -> CGError? {
        found?.function(token, id, on)
    }
}
