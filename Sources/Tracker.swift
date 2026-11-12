import AppKit

/// Watches the on-screen windows and keeps one scarf on each.
///
/// Uses only public APIs: CGWindowListCopyWindowInfo for window positions and stacking order,
/// and a global mouse monitor to follow drags smoothly. Neither needs Accessibility or
/// Screen Recording permission.
final class Tracker {
    private var overlays: [CGWindowID: ScarfOverlay] = [:]
    private var timer: Timer?
    private var monitor: Any?
    private var mouseDown = false
    private var lastRefresh: CFTimeInterval = 0
    private let settings = Settings.shared
    private let myPID = getpid()

    /// Things that draw normal-level windows but aren't really app windows.
    private let ignoredOwners: Set<String> = [
        "Window Server", "Dock", "Control Center", "Notification Center", "SystemUIServer",
        "Spotlight", "WindowManager", "screencaptureui", "Screenshot", "loginwindow",
        "Wallpaper", "TextInputMenuAgent", "Window Scarves",
        "universalAccessAuthWarn", "SecurityAgent", "CoreServicesUIAgent", "UserNotificationCenter",
    ]

    /// Apps seen with windows recently, for the "Skip an App" menu.
    private(set) var recentApps: Set<String> = []

    func start() {
        timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)

        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) {
            [weak self] e in
            guard let self else { return }
            switch e.type {
            case .leftMouseDown:
                self.mouseDown = true
                self.refreshSoon(0.03)
            case .leftMouseDragged:
                if CACurrentMediaTime() - self.lastRefresh > 1.0 / 90 { self.refresh() }
            case .leftMouseUp:
                self.mouseDown = false
                self.refresh()
                self.refreshSoon(0.15)
                self.refreshSoon(0.4)
            default: break
            }
        }

        let nc = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
        ] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
                self?.refreshSoon(0.25)
                self?.refreshSoon(0.6)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }

        refresh()
    }

    func refreshSoon(_ delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
    }

    func removeAll() {
        overlays.values.forEach { $0.hide() }
        overlays.removeAll()
    }

    private struct Target {
        var id: CGWindowID
        var frame: CGRect
        var owner: String
        var pid: pid_t
        var index: Int
    }

    /// Exact button positions found via Accessibility, per window, with the size they were found at.
    private var controlsCache: [CGWindowID: (size: CGSize, controls: WindowControls.Controls?, checked: Date)] = [:]

    /// Where this window's real buttons are, or nil if we can't tell exactly. Buttons are only
    /// drawn when they can sit precisely on the real ones, which needs Accessibility permission.
    private func controls(for t: Target) -> WindowControls.Controls? {
        guard settings.sewnButtons, WindowControls.trusted else { return nil }
        if let c = controlsCache[t.id] {
            // Reuse the answer until the window changes size; retry a failed lookup after a while.
            let fresh = c.controls != nil || Date().timeIntervalSince(c.checked) < 5
            if mouseDown || (c.size == t.frame.size && fresh) { return c.controls }
        }
        var found = WindowControls.lookup(pid: t.pid, windowFrame: t.frame)
        if found?.centres.isEmpty == true { found = nil }
        controlsCache[t.id] = (t.frame.size, found, Date())
        return found
    }

    /// Each screen's usable area (below the menu bar, beside the Dock) in CoreGraphics coordinates.
    private func visibleRectsCG() -> [CGRect] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map {
            let v = $0.visibleFrame
            return CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height)
        }
    }

    private func screenRectsCG() -> [CGRect] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map {
            CGRect(x: $0.frame.minX, y: primaryHeight - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
        }
    }

    func refresh() {
        lastRefresh = CACurrentMediaTime()
        guard settings.enabled else {
            overlays.values.forEach { $0.hide() }
            return
        }
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return }

        let screens = screenRectsCG()
        let skipped = settings.skippedApps
        var index: [CGWindowID: Int] = [:]
        var targets: [Target] = []
        var apps: Set<String> = []

        for (i, w) in info.enumerated() {
            guard let num = w[kCGWindowNumber as String] as? Int else { continue }
            let id = CGWindowID(num)
            index[id] = i
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != myPID else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            if ignoredOwners.contains(owner) { continue }
            if let alpha = w[kCGWindowAlpha as String] as? Double, alpha < 0.1 { continue }
            guard let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            if rect.width < 200 || rect.height < 140 { continue }
            // Full-screen windows have nowhere to hang a scarf.
            if screens.contains(where: { abs($0.width - rect.width) < 2 && abs($0.height - rect.height) < 2 }) { continue }
            apps.insert(owner)
            if skipped.contains(owner) { continue }
            targets.append(Target(id: id, frame: rect, owner: owner, pid: pid, index: i))
        }
        recentApps.formUnion(apps)

        if settings.frontOnly { targets = Array(targets.prefix(1)) }

        let now = Date()
        let live = Set(targets.map(\.id))
        for (id, overlay) in overlays where !live.contains(id) {
            overlay.hide()
            // Forget windows that have been gone a while (closed, or on another Space for ages).
            if now.timeIntervalSince(overlay.lastSeen) > 60 {
                overlays[id] = nil
                controlsCache[id] = nil
            }
        }

        let thickness = settings.thickness.points
        let visible = visibleRectsCG()
        for t in targets {
            let overlay = overlays[t.id] ?? {
                let o = ScarfOverlay(targetID: t.id)
                overlays[t.id] = o
                return o
            }()
            overlay.lastSeen = now
            let cw = settings.colourway(forApp: t.owner)
            let T = (thickness * cw.weight).rounded()
            // Fit the scarf to the free space on screen either side of the window.
            let screen = visible.first { $0.insetBy(dx: -1, dy: -40).contains(CGPoint(x: t.frame.midX, y: t.frame.minY)) }
                ?? visible.first { $0.intersects(t.frame) } ?? t.frame.insetBy(dx: -200, dy: -200)
            let (side, fit) = ScarfLayout.fit(preferred: settings.knot, roomLeft: t.frame.minX - screen.minX,
                                              roomRight: screen.maxX - t.frame.maxX, T: T)
            let style = ScarfStyle(colourway: cw.id, T: T, side: side, fit: fit)
            overlay.update(frame: t.frame, colourway: cw, style: style, controls: controls(for: t), live: mouseDown)

            // Keep the scarf directly above its own window.
            let overlayIndex = index[CGWindowID(overlay.window.windowNumber)]
            if !overlay.isShown || overlayIndex == nil || overlayIndex! != t.index - 1 {
                overlay.show()
            }
        }
    }
}
