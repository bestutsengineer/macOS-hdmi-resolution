import AppKit
import HDMIResolutionCore

// macOS display rules for the laptop screen and external displays of any
// connector type, with a menu bar item to control them.
//
// Usage: hdmi-resolution [run|status|list-displays]
//
// The name is historical; the first version, for KDE Plasma, only handled HDMI.
// How it works and how to change it safely: docs/DESIGN.md in the repository.

let command = CommandLine.arguments.dropFirst().first ?? "run"

switch command {
case "run":
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    // No Dock icon and no main menu: the app lives in the menu bar.
    app.setActivationPolicy(.accessory)
    app.run()
case "status":
    let paths = Paths.standard()
    print(Listing.status(
        snapshot: QuartzBackend().snapshot(), config: Config.load(from: paths.configFile).config,
        paths: paths, service: serviceState()))
case "list-displays":
    let config = Config.load(from: Paths.standard().configFile).config
    for row in Listing.rows(QuartzBackend().snapshot(), config: config) {
        print(row.line)
    }
default:
    FileHandle.standardError.write(Data("Usage: hdmi-resolution [run|status|list-displays]\n".utf8))
    exit(2)
}
