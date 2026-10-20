import Foundation

/// How the laptop screen and the external displays are used together: the
/// four choices of Plasma's display switcher.
public enum DisplayArrangement: String, CaseIterable {
    case extend
    case mirror
    case builtInOnly = "built-in-only"
    case externalOnly = "external-only"

    public var title: String {
        switch self {
        case .extend: return "Extend"
        case .mirror: return "Mirror"
        case .builtInOnly: return "Built-in Display Only"
        case .externalOnly: return "External Displays Only"
        }
    }

    /// Switching a screen off is not something macOS offers itself, so such a
    /// change is confirmed by the user, or undone after a few seconds.
    public var switchesAScreenOff: Bool { self == .builtInOnly || self == .externalOnly }
}

/// The current arrangement, and the changes that lead to another one.
///
/// Virtual displays (AirPlay, Sidecar, and screens other apps create) are
/// left out: they belong to whoever made them.
public struct Arrangements {
    private let panel: Output?
    /// Connected displays other than the laptop screen.
    private let externals: [Output]
    /// Displays the app switched off that macOS no longer lists.
    private let missing: [OutputRef]
    private let canSwitchOff: Bool

    /// - Parameter switchedOff: the displays the app switched off, as it remembers them.
    public init(_ snapshot: Snapshot?, switchedOff: [OutputRef] = []) {
        let outputs = (snapshot?.outputs ?? []).filter { $0.connected && !$0.isVirtual }
        panel = outputs.first { $0.isPanel }
        externals = outputs.filter { !$0.isPanel }
        missing = switchedOff.filter { ref in !outputs.contains { $0.id == ref.id } }
        canSwitchOff = snapshot?.canSwitchDisplaysOff ?? false
    }

    public var current: DisplayArrangement? {
        guard let panel else {
            // Lid closed: only the external displays are there.
            return externals.isEmpty ? nil : .externalOnly
        }
        if externals.isEmpty && missing.isEmpty { return nil }
        if !panel.enabled { return .externalOnly }
        let on = externals.filter(\.enabled)
        if on.isEmpty { return .builtInOnly }
        if on.contains(where: { $0.mirrors(panel) }) { return .mirror }
        return .extend
    }

    public func isAvailable(_ arrangement: DisplayArrangement) -> Bool {
        changes(to: arrangement) != nil
    }

    /// What to change, all in one reconfiguration. Empty when the displays
    /// are arranged that way already; nil when it cannot be done: with the lid
    /// closed, without an external display, or where switching a screen off
    /// or on again would take a call this macOS does not have.
    public func changes(to arrangement: DisplayArrangement) -> [DisplayChange]? {
        guard let panel, !(externals.isEmpty && missing.isEmpty) else { return nil }
        if current == arrangement { return [] }
        let all = [panel] + externals
        var enable: [DisplayChange] = []
        var unmirror: [DisplayChange] = []
        var mirror: [DisplayChange] = []
        var disable: [DisplayChange] = []

        func switchOn(_ outputs: [Output]) {
            enable += outputs.filter { !$0.enabled }.map { .enable($0.ref, true) }
        }
        func separate() {
            unmirror = all.filter { $0.replicationSource != 0 }.map { .unmirror($0.ref) }
        }
        switch arrangement {
        case .extend:
            switchOn(all)
            enable += missing.map { .enable($0, true) }
            separate()
        case .mirror:
            switchOn(all)
            enable += missing.map { .enable($0, true) }
            mirror = [.mirror(source: panel.ref, members: externals.map(\.ref) + missing)]
        case .builtInOnly:
            switchOn([panel])
            separate()
            disable = externals.filter(\.enabled).map { .enable($0.ref, false) }
        case .externalOnly:
            switchOn(externals)
            enable += missing.map { .enable($0, true) }
            separate()
            disable = [.enable(panel.ref, false)]
        }
        let changes = enable + unmirror + mirror + disable
        let needsSwitching = changes.contains { if case .enable = $0 { return true } else { return false } }
        return needsSwitching && !canSwitchOff ? nil : changes
    }
}
