import Foundation

/// The launchd label of the login agent, and the app's bundle identifier.
let serviceLabel = "com.github.bestutsengineer.hdmi-resolution"

/// Timestamped lines on stderr and, for the running app, in a log file.
///
/// The file takes the place of the journal the Linux service logs to.
final class Logger {
    static let file: URL = {
        // Test hook: a second copy started by hand, with its own XDG
        // directories, can keep out of the real log.
        if let path = ProcessInfo.processInfo.environment["HDMI_RESOLUTION_LOG"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/hdmi-resolution.log")
    }()

    private var handle: FileHandle?
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        return formatter
    }()

    init(toFile: Bool) {
        guard toFile else { return }
        let files = FileManager.default
        let path = Logger.file.path
        // The log only grows by a few lines per display change; keep one old copy.
        if let size = (try? files.attributesOfItem(atPath: path))?[.size] as? NSNumber, size.intValue > 1_000_000 {
            let old = Logger.file.appendingPathExtension("1")
            try? files.removeItem(at: old)
            try? files.moveItem(at: Logger.file, to: old)
        }
        try? files.createDirectory(at: Logger.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !files.fileExists(atPath: path) { files.createFile(atPath: path, contents: nil) }
        handle = try? FileHandle(forWritingTo: Logger.file)
        _ = try? handle?.seekToEnd()
    }

    func log(_ message: String) {
        let line = Data("[\(formatter.string(from: Date()))] \(message)\n".utf8)
        FileHandle.standardError.write(line)
        try? handle?.write(contentsOf: line)
    }
}

/// Makes sure only one copy of the app drives the displays.
enum InstanceLock {
    private static var descriptor: Int32 = -1

    static func acquire(in directory: URL) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return true }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
}

/// Whether the login agent is running, for `hdmi-resolution status`.
func serviceState() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["print", "gui/\(getuid())/\(serviceLabel)"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "unknown" }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return "inactive" }
    return output.contains("state = running") ? "active" : "inactive"
}
