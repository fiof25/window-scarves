import AppKit

/// Watches the on-screen windows and keeps one scarf on each.
///
/// Uses only public APIs: CGWindowListCopyWindowInfo for window positions and stacking order,
/// and the mouse button state to know when something might be moving. Neither needs
/// Accessibility or Screen Recording permission.
///
/// It checks slowly when nothing is happening and very quickly while windows are changing,
/// so scarves keep up with drags and resizes without wasting power the rest of the time.
final class Tracker {
    private var overlays: [CGWindowID: ScarfOverlay] = [:]
    private var timer: Timer?
    private var monitor: Any?
    private var mouseDown = false
    private let settings = Settings.shared
    private let myPID = getpid()

    /// Checking at full speed until this time.
    private var fastUntil: CFTimeInterval = 0
    private var isFast = false
    private var idleTicks = 0
    /// What the windows looked like at the last check, to notice when anything changes.
    private var lastSeen: [CGWindowID: CGRect] = [:]
    private var lastOrder: [CGWindowID] = []
    private var trusted = (value: false, checked: CFTimeInterval(0))

    private static let fastInterval = 1.0 / 120
    private static let idleInterval = 1.0 / 30
    /// While idle, look at the windows on every Nth tick (10 times a second).
    private static let idleStride = 3

    /// Things that draw normal-level windows but aren't really app windows.
    private let ignoredOwners: Set<String> = [
        "Window Server", "Dock", "Control Center", "Notification Center", "SystemUIServer",
        "Spotlight", "WindowManager", "screencaptureui", "Screenshot", "loginwindow",
        "Wallpaper", "TextInputMenuAgent", "Window Scarves",
        "universalAccessAuthWarn", "SecurityAgent", "CoreServicesUIAgent", "UserNotificationCenter",
    ]

    /// Apps seen with windows recently, for the "Apps" menu.
    private(set) var recentApps: Set<String> = []

    func start() {
        setTimer(fast: false)

        // A click often raises, closes or starts dragging a window: look closely straight away.
        // (If this monitor never fires, the timer's own check of the mouse button covers it.)
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] _ in
            self?.wake()
        }

        let nc = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
        ] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.wake(0.8) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.wake() }

        refresh()
    }

    /// Something just happened that may move windows: check now and keep checking quickly for a bit.
    func wake(_ duration: Double = 0.4) {
        stayFast(duration)
        refresh()
    }

    private func stayFast(_ duration: Double) {
        fastUntil = max(fastUntil, CACurrentMediaTime() + duration)
        if !isFast { setTimer(fast: true) }
    }

    private func setTimer(fast: Bool) {
        isFast = fast
        timer?.invalidate()
        let t = Timer(timeInterval: fast ? Tracker.fastInterval : Tracker.idleInterval, repeats: true) {
            [weak self] _ in self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        if down != mouseDown {
            mouseDown = down
            stayFast(0.4)
        }
        if isFast {
            refresh()
            if CACurrentMediaTime() > fastUntil { setTimer(fast: false) }
        } else {
            idleTicks += 1
            // With the button held, a drag could start at any moment, so look on every tick.
            if mouseDown || idleTicks % Tracker.idleStride == 0 { refresh() }
        }
    }

    /// Save a picture of every scarf as it's currently drawn (a debugging aid).
    func saveSnapshots(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (id, overlay) in overlays where overlay.isShown {
            guard let img = overlay.snapshot() else { continue }
            _ = Catalogue.write(img, to: "\(dir)/scarf-\(id).png")
        }
    }

    func removeAll() {
        overlays.removeAll()
        controlsCache.removeAll()
        lastSeen.removeAll()
        lastOrder.removeAll()
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

    /// Whether we have Accessibility permission. Asked at most once a second.
    private var isTrusted: Bool {
        let now = CACurrentMediaTime()
        if now - trusted.checked > 1 { trusted = (WindowControls.trusted, now) }
        return trusted.value
    }

    /// Where this window's real buttons are, or nil if we can't tell exactly. Buttons are only
    /// drawn when they can sit precisely on the real ones, which needs Accessibility permission.
    private func controls(for t: Target) -> WindowControls.Controls? {
        guard settings.sewnButtons, isTrusted else { return nil }
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
        guard settings.enabled else {
            if !overlays.isEmpty { removeAll() }
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

        // If any window moved, resized, appeared, vanished or changed order, keep watching closely.
        let seen = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.frame) })
        let order = targets.map(\.id)
        if seen != lastSeen || order != lastOrder {
            lastSeen = seen
            lastOrder = order
            stayFast(0.5)
        }

        let now = Date()
        for (id, overlay) in overlays where seen[id] == nil {
            overlay.hide()
            // Forget windows that have been gone a while (closed, or on another Space for ages).
            if now.timeIntervalSince(overlay.lastSeen) > 60 {
                overlays[id] = nil
                controlsCache[id] = nil
            }
        }

        let thickness = settings.thickness.points
        let visible = visibleRectsCG()
        let clock = CACurrentMediaTime()
        for t in targets {
            let overlay = overlays[t.id] ?? {
                let o = ScarfOverlay(targetID: t.id)
                overlays[t.id] = o
                return o
            }()
            overlay.lastSeen = now
            let cw = settings.colourway(forApp: t.owner)
            let T = (thickness * cw.weight).rounded()

            var style: ScarfStyle
            if mouseDown, let current = overlay.style, current.colourway == cw.id, current.T == T {
                // Mid-drag: keep the scarf's drape as it is. Re-fitting it every time the window
                // crosses a screen edge would make it flicker; it settles when the button is released.
                style = current
            } else {
                // Fit the scarf to the free space on screen either side of the window.
                let screen = visible.first {
                    $0.insetBy(dx: -1, dy: -40).contains(CGPoint(x: t.frame.midX, y: t.frame.minY))
                } ?? visible.first { $0.intersects(t.frame) } ?? t.frame.insetBy(dx: -200, dy: -200)
                let (side, fit) = ScarfLayout.fit(preferred: settings.knot, roomLeft: t.frame.minX - screen.minX,
                                                  roomRight: screen.maxX - t.frame.maxX, T: T)
                style = ScarfStyle(colourway: cw.id, T: T, side: side, fit: fit)
            }
            overlay.update(frame: t.frame, colourway: cw, style: style, controls: controls(for: t))

            // Keep the scarf directly above its own window.
            if index[CGWindowID(overlay.window.windowNumber)] == t.index - 1 {
                overlay.orderMisses = 0
            } else {
                // If it won't stay put (another window insists on sitting between them), stop
                // re-stacking it on every check, which would flicker, and just retry now and then.
                let wait = overlay.orderMisses < 3 ? 0 : 1.0
                if clock - overlay.lastOrder >= wait {
                    overlay.placeAboveTarget()
                    overlay.lastOrder = clock
                    if overlay.orderMisses < 3 { stayFast(0.2) }
                    overlay.orderMisses += 1
                }
            }
            overlay.show()
        }
    }
}
