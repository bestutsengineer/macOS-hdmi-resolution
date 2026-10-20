import Foundation

/// The displays the app has switched off.
///
/// Remembered in the state directory, so that the menu still offers to switch
/// them on again after a restart of the app, even if macOS stops listing a
/// display that is off.
public enum SwitchedOffDisplays {
    private static func file(_ paths: Paths) -> URL { paths.stateDir.appendingPathComponent("switched-off") }

    /// One "<id> <name>" per line; anything else is ignored.
    public static func load(from paths: Paths) -> [OutputRef] {
        guard let data = try? Data(contentsOf: file(paths)) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t")
            guard fields.count == 2, let id = UInt32(fields[0]), fields[1] == "display-\(id)" else { return nil }
            return OutputRef(id: id, name: String(fields[1]))
        }
    }

    public static func save(_ displays: [OutputRef], to paths: Paths) {
        let target = file(paths)
        guard !displays.isEmpty else {
            try? FileManager.default.removeItem(at: target)
            return
        }
        try? FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
        let text = displays.map { "\($0.id)\t\($0.name)\n" }.joined()
        try? Data(text.utf8).write(to: target, options: .atomic)
    }

    /// The list after the app applied `changes`.
    public static func updated(_ displays: [OutputRef], after changes: [DisplayChange]) -> [OutputRef] {
        var result = displays
        for change in changes {
            guard case .enable(let display, let on) = change else { continue }
            result.removeAll { $0.id == display.id }
            if !on { result.append(display) }
        }
        return result
    }

    /// Forgets a display that is on again, whoever switched it on.
    public static func pruned(_ displays: [OutputRef], in snapshot: Snapshot?) -> [OutputRef] {
        guard let snapshot else { return displays }
        return displays.filter { ref in !snapshot.outputs.contains { $0.id == ref.id && $0.enabled } }
    }
}
