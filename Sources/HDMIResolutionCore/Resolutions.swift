import Foundation

/// One entry of a display's resolution menu.
public struct ResolutionChoice: Equatable {
    /// The mode to switch to; valid only for the snapshot it came from.
    public var modeId: String
    public var width: Int
    public var height: Int
    public var scale: Int
    /// As System Settings writes it: "2560 × 1440 (Default)", "1280 × 720 (HiDPI)".
    public var title: String
    public var isCurrent: Bool
}

extension Output {
    /// The sizes System Settings lists for the display, largest first.
    ///
    /// Where macOS publishes that list, as it does for the laptop screen, it is
    /// used as it is. Elsewhere it is rebuilt the way System Settings shows it:
    /// the common sizes of the display's own shape, from half its width up to
    /// its full size, each in its HiDPI form where there is one. The size in
    /// use is always listed.
    public var resolutions: [ResolutionChoice] {
        let groups = modeGroups
        var picked: [DisplayMode]
        if !scaledPixelSizes.isEmpty {
            picked = scaledPixelSizes.compactMap { pixels in
                groups.first { $0.scale >= 2 && $0.width * $0.scale == pixels.w && $0.height * $0.scale == pixels.h }
            }
        } else if let native = nativeSize {
            let shape = Double(native.w) / Double(native.h)
            var bySize: [String: DisplayMode] = [:]
            var order: [String] = []
            for mode in groups {
                let ratio = Double(mode.width) / Double(mode.height)
                let isNativeSize = mode.width == native.w && mode.height == native.h
                guard abs(ratio - shape) / shape < 0.01, mode.width * 2 >= native.w, mode.width <= native.w,
                      isNativeSize || CommonSizes.contains(mode.width, mode.height) else { continue }
                let size = "\(mode.width)x\(mode.height)"
                if let held = bySize[size] {
                    if mode.scale > held.scale { bySize[size] = mode }
                } else {
                    bySize[size] = mode
                    order.append(size)
                }
            }
            picked = order.compactMap { bySize[$0] }
        } else {
            picked = groups
        }
        if let current = groups.first(where: { $0.id == currentModeId }),
           !picked.contains(where: { $0.width == current.width && $0.height == current.height && $0.scale == current.scale }) {
            picked.append(current)
        }
        return choices(picked)
    }

    /// Every size the display offers, as "Show all resolutions" lists them.
    public var allResolutions: [ResolutionChoice] {
        choices(modeGroups)
    }

    /// One mode per size and scale: the one in use, else the refresh rate
    /// closest to the one in use, else the higher one. Modes that exist only
    /// while mirroring are left out; they are not this display's to choose.
    private var modeGroups: [DisplayMode] {
        let now = currentMode
        var best: [String: DisplayMode] = [:]
        var order: [String] = []
        for mode in modes where !mode.mirrorOnly {
            let key = "\(mode.width)x\(mode.height)@\(mode.scale)"
            guard let held = best[key] else {
                best[key] = mode
                order.append(key)
                continue
            }
            if held.id == currentModeId { continue }
            let target = now?.refresh ?? 60
            let distance = abs(mode.refresh - target), heldDistance = abs(held.refresh - target)
            if mode.id == currentModeId || distance < heldDistance || (distance == heldDistance && mode.refresh > held.refresh) {
                best[key] = mode
            }
        }
        return order.compactMap { best[$0] }
    }

    /// The panel's own pixel size.
    private var nativeSize: Size? {
        let plain = modes.filter { $0.scale == 1 && !$0.mirrorOnly }
        let native = plain.filter(\.isNative).max { $0.width * $0.height < $1.width * $1.height }
            ?? plain.max { $0.width * $0.height < $1.width * $1.height }
        return native.map { Size(w: $0.width, h: $0.height) }
    }

    /// Whether HiDPI is this display's normal way of working, as on a Retina screen.
    private var isRetina: Bool {
        (modes.first(where: \.isDefault) ?? currentMode)?.scale ?? 1 >= 2
    }

    private func choices(_ picked: [DisplayMode]) -> [ResolutionChoice] {
        let defaults = Set(modes.filter(\.isDefault).map { "\($0.width)x\($0.height)@\($0.scale)" })
        let retina = isRetina
        return picked
            .sorted { ($0.width, $0.height, $0.scale) > ($1.width, $1.height, $1.scale) }
            .map { mode in
                var title = "\(mode.width) × \(mode.height)"
                if defaults.contains("\(mode.width)x\(mode.height)@\(mode.scale)") { title += " (Default)" }
                if mode.scale >= 2 && !retina { title += " (HiDPI)" }
                if mode.scale == 1 && retina { title += " (low resolution)" }
                return ResolutionChoice(
                    modeId: mode.id, width: mode.width, height: mode.height, scale: mode.scale,
                    title: title, isCurrent: mode.id == currentModeId)
            }
    }
}

/// The resolutions displays are commonly run at, by shape. A display's list
/// keeps to these, as System Settings does; odd sizes a monitor also accepts,
/// such as 1344 × 756, are under "All Resolutions".
enum CommonSizes {
    private static let sizes: Set<String> = [
        // 16:9
        "1280x720", "1600x900", "1920x1080", "2048x1152", "2304x1296", "2560x1440", "3008x1692", "3200x1800",
        "3360x1890", "3840x2160", "4096x2304", "5120x2880", "6016x3384",
        // 16:10
        "1280x800", "1440x900", "1680x1050", "1920x1200", "2048x1280", "2304x1440", "2560x1600", "2880x1800",
        "3008x1880", "3360x2100", "3840x2400",
        // Ultrawide
        "2560x1080", "3440x1440", "3840x1600", "5120x2160", "3840x1080", "5120x1440",
        // 4:3, 5:4, 3:2
        "1024x768", "1280x960", "1400x1050", "1600x1200", "2048x1536", "1280x1024", "1440x960", "2160x1440",
    ]

    static func contains(_ width: Int, _ height: Int) -> Bool { sizes.contains("\(width)x\(height)") }
}
