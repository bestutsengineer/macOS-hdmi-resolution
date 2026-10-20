import AppKit
import HDMIResolutionCore

/// The running app: the rule engine, woken by display configuration changes,
/// and a menu bar item that is only there while an external display is connected.
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let paths = Paths.standard()
    private let backend = QuartzBackend()
    private let logger = Logger(toFile: true)
    private lazy var engine = Engine(paths: paths, backend: backend) { [logger] in logger.log($0) }
    private var statusItem: NSStatusItem?
    private var itemShown = false
    private var passOwedAfterWake = false
    /// The alert asking whether to keep a screen switched off, and when it gives up.
    private var confirmation: (alert: NSAlert, deadline: Date)?

    /// How long a screen stays switched off without the user keeping it that way.
    private static let keepSeconds: TimeInterval = 15

    /// How long the display configuration has to stay quiet before it is
    /// looked at, so a change macOS makes in several steps is seen once.
    private static let quietPeriod: TimeInterval = 1

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard InstanceLock.acquire(in: paths.stateDir) else {
            logger.log("Another copy is already running; this one exits")
            exit(0)
        }
        backend.diagnostics = { [logger] in logger.log("macOS: \($0)") }
        // Listen before the first pass: a change that pass makes is announced
        // like any other, and the pass that follows it must not be missed.
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            // Called once before a change and once after it; only the latter counts.
            guard !flags.contains(.beginConfigurationFlag), let context else { return }
            let app = Unmanaged<App>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { app.displaysChanged() }
        }, Unmanaged.passUnretained(self).toOpaque())
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        engine.start()
        runPass()
    }

    /// macOS announces one change many times over, once per display and step.
    private func displaysChanged() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(runPass), object: nil)
        perform(#selector(runPass), with: nil, afterDelay: App.quietPeriod)
    }

    @objc private func screensDidWake() {
        guard passOwedAfterWake else { return }
        passOwedAfterWake = false
        displaysChanged()
    }

    @objc private func runPass() {
        // What macOS reports while the screens sleep is not a layout to act on.
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            passOwedAfterWake = true
            return
        }
        engine.pass()
        updateStatusItem()
    }

    /// Re-reads the config and starts the rules afresh, as restarting the
    /// Linux service does.
    private func restart() {
        engine.start()
        runPass()
    }

    // MARK: - Menu bar item

    /// The displays this app switched off, kept on disk for a restart.
    private var switchedOff: [OutputRef] {
        get { SwitchedOffDisplays.load(from: paths) }
        set { SwitchedOffDisplays.save(newValue, to: paths) }
    }

    private func model(_ snapshot: Snapshot?) -> MenuModel {
        MenuModel(config: Config.load(from: paths.configFile).config, snapshot: snapshot, switchedOff: switchedOff)
    }

    private func updateStatusItem() {
        let snapshot = backend.snapshot()
        // A display that is on again, however that came about, is not the app's to remember.
        let remembered = SwitchedOffDisplays.pruned(switchedOff, in: snapshot)
        if remembered != switchedOff { switchedOff = remembered }
        let wanted = model(snapshot).showsMenuBarItem
        if wanted && statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Display Rules")
            image?.isTemplate = true
            item.button?.image = image
            if image == nil { item.button?.title = "▣" }
            item.button?.toolTip = "Display Rules (hdmi-resolution)"
            // Lets macOS remember where in the menu bar the user put it.
            item.autosaveName = "hdmi-resolution"
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }
        statusItem?.isVisible = wanted
        if wanted != itemShown {
            itemShown = wanted
            logger.log(wanted ? "Menu bar item shown" : "Menu bar item hidden: no external display is connected")
        }
    }

    /// The whole menu is built afresh each time it opens, from what macOS
    /// reports at that moment.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let snapshot = backend.snapshot()
        let model = model(snapshot)
        menu.removeAllItems()

        let header = note("Display Rules (hdmi-resolution)")
        header.toolTip = model.statusText
        menu.addItem(header)
        menu.addItem(note("Layout: \(engine.state?.rawValue ?? "unknown")"))
        menu.addItem(.separator())

        menu.addItem(displayModeMenu(Arrangements(snapshot, switchedOff: switchedOff)))
        menu.addItem(resolutionMenu(snapshot))
        let settings = item("Display Settings…", #selector(openDisplaySettings))
        settings.toolTip = "Opens System Settings > Displays."
        menu.addItem(settings)
        menu.addItem(.separator())

        menu.addItem(mirrorRuleMenu(model))
        menu.addItem(extendRuleMenu(model))
        menu.addItem(.separator())

        menu.addItem(optionsMenu(model))
        menu.addItem(item("Quit Display Rules", #selector(quit)))
    }

    private func displayModeMenu(_ arrangements: Arrangements) -> NSMenuItem {
        let current = arrangements.current
        let parent = submenu("Display Mode" + (current.map { ": \($0.title)" } ?? ""))
        parent.toolTip = MenuModel.displayModeHelp
        for arrangement in DisplayArrangement.allCases {
            let entry = item(arrangement.title, #selector(chooseArrangement), on: arrangement == current)
            entry.representedObject = arrangement.rawValue
            if !arrangements.isAvailable(arrangement) {
                // An entry without an action is shown greyed out.
                entry.action = nil
            }
            parent.submenu?.addItem(entry)
        }
        if current == nil {
            parent.submenu?.addItem(.separator())
            parent.submenu?.addItem(note("Connect a display to choose"))
        }
        return parent
    }

    private func resolutionMenu(_ snapshot: Snapshot?) -> NSMenuItem {
        let layout = LayoutFacts(snapshot).layout
        guard layout != .mirror else {
            let parent = submenu("Resolution: Extend Mode Only")
            parent.toolTip = MenuModel.resolutionHelp
            parent.submenu?.addItem(note("While mirroring, the Mirror Rule's target decides"))
            return parent
        }
        let parent = submenu("Resolution")
        parent.toolTip = MenuModel.resolutionHelp
        // External displays first and the laptop screen last, as in System Settings.
        let displays = (snapshot?.outputs ?? [])
            .filter { $0.connected && $0.enabled && !$0.isVirtual }
            .sorted { !$0.isPanel && $1.isPanel }
        for display in displays {
            let sameName = displays.filter { $0.model == display.model }.count > 1
            let entry = submenu(display.model + (sameName ? " (\(display.name))" : ""))
            for choice in display.resolutions {
                entry.submenu?.addItem(resolutionItem(choice, of: display))
            }
            entry.submenu?.addItem(.separator())
            let all = submenu("All Resolutions")
            for choice in display.allResolutions {
                all.submenu?.addItem(resolutionItem(choice, of: display))
            }
            entry.submenu?.addItem(all)
            parent.submenu?.addItem(entry)
        }
        if displays.isEmpty { parent.submenu?.addItem(note("No display to change")) }
        return parent
    }

    private func resolutionItem(_ choice: ResolutionChoice, of display: Output) -> NSMenuItem {
        let entry = item(choice.title, #selector(chooseResolution), on: choice.isCurrent)
        entry.representedObject = ResolutionPick(display: display.ref, modeId: choice.modeId, title: choice.title)
        return entry
    }

    private func mirrorRuleMenu(_ model: MenuModel) -> NSMenuItem {
        let parent = submenu(model.mirrorRuleTitle)
        parent.toolTip = MenuModel.mirrorRuleHelp
        let menu = parent.submenu!
        let all = item(MenuModel.allDisplaysTitle, #selector(toggleMirrorRule), on: model.config.enabled)
        all.toolTip = MenuModel.mirrorRuleHelp
        menu.addItem(all)
        let target = submenu(model.targetTitle)
        target.toolTip = MenuModel.targetHelp
        for choice in model.targets {
            let entry = item(model.title(of: choice), #selector(chooseTarget), on: choice.selected)
            entry.representedObject = [choice.width, choice.height]
            target.submenu?.addItem(entry)
        }
        menu.addItem(target)
        menu.addItem(.separator())
        addPerDisplay(to: menu, model: model, title: model.mirrorPerDisplayTitle, help: MenuModel.perDisplayHelp,
                      isOn: \.ruleOn, action: #selector(toggleDisplay))
        menu.addItem(.separator())
        let restore = note(MenuModel.restoreTitle)
        restore.toolTip = MenuModel.restoreHelp
        menu.addItem(restore)
        return parent
    }

    private func extendRuleMenu(_ model: MenuModel) -> NSMenuItem {
        let parent = submenu(model.extendRuleTitle)
        parent.toolTip = MenuModel.extendRuleHelp
        let menu = parent.submenu!
        let all = item(MenuModel.allDisplaysTitle, #selector(toggleExtendRule), on: model.config.extendTopCenter)
        all.toolTip = MenuModel.extendRuleHelp
        menu.addItem(all)
        menu.addItem(.separator())
        addPerDisplay(to: menu, model: model, title: model.extendPerDisplayTitle, help: MenuModel.extendPerDisplayHelp,
                      isOn: \.extendOn, action: #selector(toggleExtendDisplay))
        return parent
    }

    private func addPerDisplay(to menu: NSMenu, model: MenuModel, title: String, help: String,
                               isOn: KeyPath<MenuModel.Display, Bool>, action: Selector) {
        let header = note(title)
        header.toolTip = help
        menu.addItem(header)
        for display in model.displays {
            let entry = item(display.title, action, on: display[keyPath: isOn])
            entry.representedObject = display.key
            entry.toolTip = help
            entry.indentationLevel = 1
            menu.addItem(entry)
        }
        if model.displays.isEmpty { menu.addItem(note(MenuModel.noDisplayHelp)) }
    }

    private func optionsMenu(_ model: MenuModel) -> NSMenuItem {
        let parent = submenu("Options")
        let always = item(MenuModel.alwaysShowTitle, #selector(toggleAlwaysShow), on: model.config.alwaysShowMenuBar)
        always.toolTip = MenuModel.alwaysShowHelp
        parent.submenu?.addItem(always)
        parent.submenu?.addItem(.separator())
        parent.submenu?.addItem(item("Open Log", #selector(openLog)))
        let reload = item("Reload Config File", #selector(reloadConfig))
        reload.toolTip = "Use after editing \(paths.configFile.path) by hand."
        parent.submenu?.addItem(reload)
        return parent
    }

    /// A line of information; it cannot be chosen.
    private func note(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: Selector, on: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    private func submenu(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: title)
        return item
    }

    // MARK: - Settings

    /// Every choice is written at once and the rules are started afresh with
    /// it, which is what "Save and restart service" did in the terminal menu.
    private func save(_ config: Config) {
        do {
            try config.save(to: paths.configFile)
        } catch {
            logger.log("ERROR: could not write \(paths.configFile.path): \(error.localizedDescription)")
            return
        }
        restart()
    }

    @objc private func toggleMirrorRule() {
        let model = model(backend.snapshot())
        save(model.settingMirrorRule(!model.config.enabled))
    }

    @objc private func toggleExtendRule() {
        let model = model(backend.snapshot())
        save(model.settingExtendRule(!model.config.extendTopCenter))
    }

    @objc private func toggleAlwaysShow() {
        let model = model(backend.snapshot())
        save(model.settingAlwaysShow(!model.config.alwaysShowMenuBar))
    }

    @objc private func chooseTarget(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? [Int], size.count == 2 else { return }
        save(model(backend.snapshot()).settingTarget(width: size[0], height: size[1]))
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let model = model(backend.snapshot())
        guard let display = model.displays.first(where: { $0.key == key }) else { return }
        save(model.settingRule(!display.ruleOn, forDisplay: key))
    }

    @objc private func toggleExtendDisplay(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let model = model(backend.snapshot())
        guard let display = model.displays.first(where: { $0.key == key }) else { return }
        save(model.settingExtendRule(!display.extendOn, forDisplay: key))
    }

    // MARK: - Display changes chosen in the menu

    /// Applied as chosen, outside the rules. The rules then see the result
    /// like any other change: a new resolution becomes the user's own mode,
    /// and the extend rule centres the display for its new size.
    private func applyChosen(_ changes: [DisplayChange], _ what: String) -> Bool {
        let described = changes.map(\.description).joined(separator: " ")
        guard backend.apply(changes) else {
            logger.log("ERROR: macOS refused \(what) (\(described))")
            NSSound.beep()
            return false
        }
        logger.log("\(what), chosen in the menu (\(described))")
        switchedOff = SwitchedOffDisplays.updated(switchedOff, after: changes)
        return true
    }

    @objc private func chooseResolution(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? ResolutionPick else { return }
        _ = applyChosen([.mode(pick.display, modeId: pick.modeId)], "\(pick.display.name) at \(pick.title)")
    }

    @objc private func chooseArrangement(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let wanted = DisplayArrangement(rawValue: raw) else { return }
        let arrangements = Arrangements(backend.snapshot(), switchedOff: switchedOff)
        let before = arrangements.current ?? .extend
        guard let changes = arrangements.changes(to: wanted), !changes.isEmpty,
              applyChosen(changes, "Display mode \(wanted.title)") else { return }
        if wanted.switchesAScreenOff { confirmKeeping(wanted, before: before) }
    }

    /// A screen that has been switched off may be the one the user was
    /// looking at, or may not come back as expected. So, as with a new
    /// resolution on other systems, the change is undone unless it is kept.
    private func confirmKeeping(_ arrangement: DisplayArrangement, before: DisplayArrangement) {
        let alert = NSAlert()
        alert.messageText = "Keep \(arrangement.title)?"
        alert.addButton(withTitle: "Keep")
        alert.addButton(withTitle: "Go Back to \(before.title)")
        confirmation = (alert, Date().addingTimeInterval(App.keepSeconds))
        updateCountdown()
        let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(updateCountdown), userInfo: nil, repeats: true)
        // Common modes include the one a modal alert runs in.
        RunLoop.main.add(timer, forMode: .common)
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        let answer = alert.runModal()
        timer.invalidate()
        confirmation = nil
        if answer == .alertFirstButtonReturn {
            logger.log("\(arrangement.title) kept")
            return
        }
        logger.log(answer == .abort ? "No answer in time; going back to \(before.title)" : "Going back to \(before.title)")
        let arrangements = Arrangements(backend.snapshot(), switchedOff: switchedOff)
        if let changes = arrangements.changes(to: before), !changes.isEmpty {
            _ = applyChosen(changes, "Display mode \(before.title)")
        }
    }

    @objc private func updateCountdown() {
        guard let confirmation else { return }
        let left = Int(confirmation.deadline.timeIntervalSinceNow.rounded(.up))
        guard left > 0 else {
            NSApp.abortModal()
            return
        }
        confirmation.alert.informativeText =
            "The displays go back to how they were in \(left) second\(left == 1 ? "" : "s") unless you keep this."
    }

    @objc private func openDisplaySettings() {
        let settings = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!
        if !NSWorkspace.shared.open(settings) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Displays.prefPane"))
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Logger.file)
    }

    @objc private func reloadConfig() {
        restart()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// What a resolution entry in the menu stands for.
private final class ResolutionPick: NSObject {
    let display: OutputRef
    let modeId: String
    let title: String

    init(display: OutputRef, modeId: String, title: String) {
        self.display = display
        self.modeId = modeId
        self.title = title
    }
}
