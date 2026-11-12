import AppKit

/// Watches the on-screen windows and keeps one scarf on each.
///
/// Uses only public APIs: CGWindowListCopyWindowInfo for window positions and stacking order,
/// and the mouse button state to know when something might be moving. Neither needs any
/// permission.
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
    /// Newly seen windows, with the frame they had and when they first had it.
    private var settling: [CGWindowID: (frame: CGRect, since: CFTimeInterval)] = [:]

    private static let fastInterval = 1.0 / 120
    private static let idleInterval = 1.0 / 20
    /// While idle, look at the windows on every Nth tick (10 times a second).
    private static let idleStride = 2

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
        // While idle, let macOS line this timer up with other work to save power.
        t.tolerance = fast ? 0 : 0.012
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
        lastSeen.removeAll()
        lastOrder.removeAll()
        settling.removeAll()
    }

    struct Target {
        var id: CGWindowID
        var frame: CGRect
        var owner: String
        var pid: pid_t
        var index: Int
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

    /// Whether a window covers a whole screen: it spans the full width, reaches the bottom, and
    /// starts at the top (or just below the menu bar or camera notch).
    static func fillsScreen(_ r: CGRect, _ screens: [CGRect]) -> Bool {
        screens.contains {
            abs(r.minX - $0.minX) < 2 && abs(r.maxX - $0.maxX) < 2 && abs(r.maxY - $0.maxY) < 2
                && r.minY - $0.minY < 60
        }
    }

    /// Whether a window looks like a popover, hover card or small dialog rather than a window in
    /// its own right: it is small, and it sits directly on top of a much bigger window from the
    /// same app, mostly within it. `below` is the windows behind it, front to back.
    ///
    /// macOS doesn't say what kind of window something is without Accessibility permission, so
    /// this is a judgement from size and position. A genuinely small window resting on a bigger
    /// one from the same app is treated the same way until it's moved off.
    static func isPopover(_ w: Target, above below: ArraySlice<Target>) -> Bool {
        guard w.frame.width <= 560, w.frame.height <= 640 else { return false }
        let area = w.frame.width * w.frame.height
        for parent in below {
            // Only windows of the same app directly beneath count; another app's window in
            // between means this one stands on its own.
            guard parent.pid == w.pid else { return false }
            let overlap = w.frame.intersection(parent.frame)
            let covered = overlap.isNull ? 0 : overlap.width * overlap.height
            if area < 0.5 * parent.frame.width * parent.frame.height, covered >= 0.5 * area { return true }
        }
        return false
    }

    func refresh() {
        guard settings.enabled else {
            if !overlays.isEmpty { removeAll() }
            return
        }
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [NSDictionary] else { return }

        let screens = screenRectsCG()
        let skipped = settings.skippedApps
        var index: [CGWindowID: Int] = [:]
        var sizeable: [Target] = []     // every real-sized app window, front to back
        var targets: [Target] = []
        var apps: Set<String> = []

        for (i, w) in info.enumerated() {
            guard let num = w[kCGWindowNumber] as? Int, let id = CGWindowID(exactly: num) else { continue }
            index[id] = i
            guard (w[kCGWindowLayer] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID] as? Int32, pid != myPID else { continue }
            let owner = w[kCGWindowOwnerName] as? String ?? ""
            if ignoredOwners.contains(owner) { continue }
            if let alpha = w[kCGWindowAlpha] as? Double, alpha < 0.1 { continue }
            guard let bounds = w[kCGWindowBounds] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            if rect.width < 200 || rect.height < 140 { continue }
            sizeable.append(Target(id: id, frame: rect, owner: owner, pid: pid, index: i))
        }
        for (k, w) in sizeable.enumerated() {
            // A window that fills the screen (full screen, or maximised edge to edge) goes bare.
            if Tracker.fillsScreen(w.frame, screens) { continue }
            // So do popovers, hover cards and small dialogs sitting on top of their app's window.
            if Tracker.isPopover(w, above: sizeable[(k + 1)...]) { continue }
            apps.insert(w.owner)
            targets.append(w)
        }
        recentApps.formUnion(apps)

        // "Front window only" means the real front window; if its app is unticked, nothing wears one.
        if settings.frontOnly { targets = Array(targets.prefix(1)) }
        targets.removeAll { skipped.contains($0.owner) }

        // A window that has only just appeared may still be animating open, and macOS reports
        // it at the wrong size while it does. Wait until it has held still for a moment before
        // giving it a scarf, so the scarf is made once, for the right size.
        let clock = CACurrentMediaTime()
        targets = targets.filter { t in
            if overlays[t.id] != nil { return true }
            if let first = settling[t.id], first.frame == t.frame {
                if clock - first.since >= 0.18 {
                    settling[t.id] = nil
                    return true
                }
            } else {
                settling[t.id] = (t.frame, clock)
            }
            stayFast(0.3)
            return false
        }
        if settling.count > 64 { settling.removeAll() }

        // If any window moved, resized, appeared, vanished or changed order, keep watching closely.
        let seen = Dictionary(targets.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        let order = targets.map(\.id)
        if seen != lastSeen || order != lastOrder {
            // The windows were re-stacked (a click, say): let every scarf be put back at once,
            // even one that had been told to stop trying so often.
            if order != lastOrder { overlays.values.forEach { $0.orderMisses = 0 } }
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
            overlay.update(frame: t.frame, colourway: cw, style: style)

            // Keep the scarf directly above its own window: every one of its pieces should be
            // in the block of windows immediately in front of it.
            let numbers = overlay.windowNumbers
            let positions = numbers.compactMap { n in CGWindowID(exactly: n).flatMap { index[$0] } }
            let inPlace = !numbers.isEmpty && positions.count == numbers.count
                && positions.allSatisfy { $0 < t.index && $0 >= t.index - numbers.count }
            if inPlace {
                overlay.orderMisses = 0
            } else {
                // If it won't stay put (another window insists on sitting between them, or the
                // window is somewhere scarves can't go), stop re-stacking it on every check, which
                // would flicker, and retry less and less often.
                let wait = overlay.orderMisses < 3 ? 0 : (overlay.orderMisses < 12 ? 1.0 : 10.0)
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
