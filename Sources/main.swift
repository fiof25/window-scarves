import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let tracker = Tracker()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🧣"
        statusItem.button?.toolTip = "Window Scarves"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        settings.onChange.append { [weak self] in
            ScarfArt.clearCache()
            self?.tracker.refresh()
        }
        tracker.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tracker.removeAll()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(item(settings.enabled ? "Scarves On" : "Scarves Off (paused)", #selector(toggleEnabled),
                          on: settings.enabled))
        menu.addItem(.separator())

        let colours = NSMenu()
        colours.addItem(item("By App — a different scarf for each app", #selector(pickColourway(_:)),
                             on: settings.colourway == Colourways.byAppID, value: Colourways.byAppID))
        colours.addItem(.separator())
        for cw in Colourways.all {
            let it = item(cw.name, #selector(pickColourway(_:)), on: settings.colourway == cw.id, value: cw.id)
            it.toolTip = cw.blurb
            colours.addItem(it)
        }
        menu.addItem(submenu("Colourway", colours))

        let knot = NSMenu()
        for side in KnotSide.allCases {
            knot.addItem(item(side.title, #selector(pickKnot(_:)), on: settings.knot == side, value: side.rawValue))
        }
        menu.addItem(submenu("Knot", knot))

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

        menu.addItem(item("Autumn Breeze", #selector(toggleBreeze), on: settings.breeze))
        menu.addItem(.separator())
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
    @objc private func toggleBreeze() { settings.breeze.toggle() }
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
        && Catalogue.closeUp(to: dir + "/close-up.png", colourway: Colourways.maplePlaid)
        && Catalogue.closeUp(to: dir + "/close-up-tucked.png", colourway: Colourways.oatmealHeather, inward: true)
    print(ok ? "Rendered previews into \(dir)" : "Rendering failed")
    exit(ok ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
