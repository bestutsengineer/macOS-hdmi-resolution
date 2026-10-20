import Foundation

/// One connected external display, as `list-displays` prints it and the menu shows it.
public struct DisplayRow: Equatable {
    public var key: String
    public var name: String
    public var kind: String
    public var model: String
    /// "disabled", "mirrored" or "extended".
    public var state: String
    /// Whether the mirror rule applies to this display.
    public var ruleOn: Bool
    /// Whether the extend rule applies to this display.
    public var extendOn: Bool

    /// Tab-separated and never empty: key, name, kind, model, state, mirror
    /// rule (on/off), extend rule (on/off). The first six are the original's.
    public var line: String {
        [key, name, kind, model, state, ruleOn ? "on" : "off", extendOn ? "on" : "off"].joined(separator: "\t")
    }
}

public enum Listing {
    public static func rows(_ snapshot: Snapshot?, config: Config) -> [DisplayRow] {
        guard let snapshot else { return [] }
        let panel = snapshot.outputs.first { $0.isPanel }
        return snapshot.outputs.filter { !$0.isPanel && $0.connected }.map { output in
            let state: String
            if !output.enabled {
                state = "disabled"
            } else if let panel, panel.enabled, output.mirrors(panel) {
                state = "mirrored"
            } else {
                state = "extended"
            }
            let key = output.key
            return DisplayRow(
                key: key, name: output.name, kind: output.kind, model: output.model,
                state: state, ruleOn: !config.isAutoOff(key), extendOn: !config.isExtendOff(key))
        }
    }

    private static func geometry(_ output: Output) -> String {
        let mode = output.currentMode.map { "\($0.width)x\($0.height) scale \($0.scale)" } ?? "unknown mode"
        return "\(mode), occupies \(output.logical.w)x\(output.logical.h) at \(output.pos)"
    }

    /// What the app sees right now, for `hdmi-resolution status`.
    public static func status(snapshot: Snapshot?, config: Config, paths: Paths, service: String) -> String {
        let facts = LayoutFacts(snapshot)
        var lines = [
            "Service:      \(service)",
            "Session:      macos",
            "Layout:       \(facts.layout.rawValue)",
        ]
        if let panel = facts.panel {
            lines.append("Panel:        \(panel.name) \(geometry(panel))\(panel.enabled ? "" : ", off")")
        } else {
            lines.append("Panel:        none")
        }
        lines.append("Displays:")
        let rows = rows(snapshot, config: config)
        for row in rows {
            let output = snapshot?.outputs.first { $0.name == row.name }
            lines.append("  \(row.name): \(row.model) [\(row.kind)] \(output.map(geometry) ?? ""), "
                + "\(row.state), mirror rule \(row.ruleOn ? "on" : "off"), "
                + "extend rule \(row.extendOn ? "on" : "off") (\(row.key))")
        }
        if rows.isEmpty { lines.append("  none connected") }
        lines.append("Mirror rule:  \(config.enabled ? "on" : "off"), target \(config.targetWidth)x\(config.targetHeight)")
        lines.append("Extend rule:  \(config.extendTopCenter ? "on" : "off") (single display above the panel, centred)")
        for (label, file) in [("User mode:   ", paths.baselineFile), ("To restore:  ", paths.pendingFile)] {
            guard let data = try? Data(contentsOf: file) else { continue }
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .newlines).replacingOccurrences(of: "\t", with: " ")
            lines.append("\(label) \(text)")
        }
        return lines.joined(separator: "\n")
    }
}
