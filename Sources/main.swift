import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let tracker = Tracker()
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🧣"
        statusItem.button?.toolTip = "Window Scarves"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        settings.onChange.append { [weak self] in
            ScarfOverlay.artQueue.async { ScarfArt.clearCache() }
            self?.tracker.refresh()
        }
        tracker.start()

        updateHotKey()

        // Debugging aid: SCARVES_SNAPSHOT=<folder> saves a picture of each scarf a few seconds in.
        if let dir = ProcessInfo.processInfo.environment["SCARVES_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.tracker.saveSnapshots(to: dir)
            }
        }
    }

    /// ⌃⌥S anywhere turns the scarves on and off. (Window managers such as Rectangle and Magnet
    /// use Control-Option with many letters, D included; S is one they leave alone.)
    private func updateHotKey() {
        hotKey = nil
        guard settings.shortcutEnabled else { return }
        hotKey = HotKey(keyCode: kVK_ANSI_S, modifiers: controlKey | optionKey) { [weak self] in
            self?.settings.enabled.toggle()
        }
        if hotKey == nil {
            FileHandle.standardError.write(Data("Window Scarves: couldn't register ⌃⌥S (another app may own it)\n".utf8))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tracker.removeAll()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let onOff = item(settings.enabled ? "Scarves On" : "Scarves Off", #selector(toggleEnabled),
                         on: settings.enabled, key: settings.shortcutEnabled ? "s" : "")
        onOff.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(onOff)
        menu.addItem(.separator())

        let colours = NSMenu()
        let mixed = settings.colourway == Colourways.byAppID
        colours.addItem(item("Mixed — a different scarf for each app", #selector(pickColourway(_:)),
                             on: mixed, value: Colourways.byAppID))
        if mixed { colours.addItem(item("Shuffle", #selector(shuffle), on: false)) }
        colours.addItem(.separator())
        for cw in Colourways.all {
            let it = item(cw.name, #selector(pickColourway(_:)), on: settings.colourway == cw.id, value: cw.id)
            it.toolTip = cw.blurb
            colours.addItem(it)
        }
        menu.addItem(submenu("Scarf", colours))

        let knot = NSMenu()
        for side in KnotSide.allCases {
            knot.addItem(item(side.title, #selector(pickKnot(_:)), on: settings.knot == side, value: side.rawValue))
        }
        menu.addItem(submenu("Long End", knot))

        let thick = NSMenu()
        for t in Thickness.allCases {
            thick.addItem(item(t.title, #selector(pickThickness(_:)), on: settings.thickness == t, value: t.rawValue))
        }
        menu.addItem(submenu("Thickness", thick))

        let which = NSMenu()
        which.addItem(item("Every Window", #selector(pickScope(_:)), on: !settings.frontOnly, value: "all"))
        which.addItem(item("Front Window Only", #selector(pickScope(_:)), on: settings.frontOnly, value: "front"))
        menu.addItem(submenu("Windows", which))

        let apps = NSMenu()
        let skipped = settings.skippedApps
        for app in tracker.recentApps.union(skipped).sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            apps.addItem(item(app, #selector(toggleApp(_:)), on: !skipped.contains(app), value: app))
        }
        if apps.items.isEmpty { apps.addItem(NSMenuItem(title: "No windows yet", action: nil, keyEquivalent: "")) }
        menu.addItem(submenu("Apps", apps))

        menu.addItem(.separator())
        menu.addItem(item("Keyboard Shortcut ⌃⌥S", #selector(toggleShortcut), on: settings.shortcutEnabled))
        menu.addItem(item("Start at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            menu.addItem(NSMenuItem(title: "Window Scarves \(version)", action: nil, keyEquivalent: ""))
        }
        menu.addItem(item("Quit Window Scarves", #selector(quit), on: false, key: "q"))
    }

    private func item(_ title: String, _ action: Selector, on: Bool, value: String? = nil, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        it.state = on ? .on : .off
        it.representedObject = value
        return it
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = menu
        return it
    }

    @objc private func toggleEnabled() { settings.enabled.toggle() }

    @objc private func toggleShortcut() {
        settings.shortcutEnabled.toggle()
        updateHotKey()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Start at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nIt works best when Window Scarves is in your Applications folder."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
    @objc private func shuffle() { settings.shuffleAssignments() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func pickColourway(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? String { settings.colourway = v }
    }

    @objc private func pickKnot(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? String, let s = KnotSide(rawValue: v) { settings.knot = s }
    }

    @objc private func pickThickness(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? String, let t = Thickness(rawValue: v) { settings.thickness = t }
    }

    @objc private func pickScope(_ sender: NSMenuItem) {
        settings.frontOnly = (sender.representedObject as? String) == "front"
    }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? String else { return }
        var s = settings.skippedApps
        if s.contains(app) { s.remove(app) } else { s.insert(app) }
        settings.skippedApps = s
    }
}

// Command-line extras: render previews without touching any real windows.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
    let dir = args[i + 1]
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let ok = Catalogue.hero(to: dir + "/hero.png")
        && Catalogue.swatches(to: dir + "/colourways.png")
        && Catalogue.closeUp(to: dir + "/close-up.png", colourway: Colourways.lilacCheck)
        && Catalogue.closeUp(to: dir + "/close-up-rib.png", colourway: Colourways.creamCable)
        && Catalogue.closeUp(to: dir + "/close-up-knit.png", colourway: Colourways.rosehip)
        && Catalogue.closeUp(to: dir + "/close-up-tucked.png", colourway: Colourways.cocoaCheck,
                             fit: ScarfFit(tuck: 0.9 * 43, shortEnd: false))
    print(ok ? "Rendered previews into \(dir)" : "Rendering failed")
    exit(ok ? 0 : 1)
}

// `--render-icon <file.png>` draws the app icon.
if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
    exit(Catalogue.icon(to: args[i + 1]) ? 0 : 1)
}

// `--self-test` checks the scarf-making code without touching any real windows.
if args.contains("--self-test") {
    exit(SelfTest.run() ? 0 : 1)
}

// Only one copy should run at a time, or every window would wear two scarves.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
