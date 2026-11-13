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

    /// When macOS last had its "desktop revealed" cover up (see `isRevealCover`).
    private var revealSeen: CFTimeInterval = -10
    private var revealActive = false
    /// Windows being swept aside or brought back by macOS, and when each last moved.
    private var sweptAt: [CGWindowID: CFTimeInterval] = [:]
    /// Windows found to be attached to another window of their app (drop-downs, popovers,
    /// sheets), and windows found to stand on their own. See `startProbe`.
    private var attached: Set<CGWindowID> = []
    private var standalone: Set<CGWindowID> = []
    private var probeWindow: OverlayWindow?
    private var probing: (child: CGWindowID, parent: CGWindowID, since: CFTimeInterval)?

    /// How long a swept window must hold still before its scarf comes back.
    private static let sweepRest = 0.15

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
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            switch event.type {
            case .mouseMoved:
                self?.hovered(at: NSEvent.mouseLocation)
            case .leftMouseDown:
                self?.pressed(at: NSEvent.mouseLocation, commandHeld: event.modifierFlags.contains(.command))
                self?.wake()
            default:
                self?.wake()
            }
        }

        // Debugging aid (SCARVES_TEST_PRESS): another program can stand in for the mouse by
        // posting a notification: "hover:x,y", "press:x,y" or "wake".
        if ProcessInfo.processInfo.environment["SCARVES_TEST_PRESS"] != nil {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.fiof25.windowscarves.test-press"), object: nil, queue: .main
            ) { [weak self] note in
                let words = (note.object as? String ?? "").split(separator: ":")
                let xy = (words.last ?? "").split(separator: ",").compactMap { Double($0) }
                if words.first == "hover", xy.count == 2 {
                    self?.lastHover = 0
                    self?.hovered(at: NSPoint(x: xy[0], y: xy[1]))
                } else {
                    if words.first == "press", xy.count == 2 { self?.pressed(at: NSPoint(x: xy[0], y: xy[1]), commandHeld: false) }
                    self?.wake()
                }
            }
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

    // MARK: Lifting a scarf ahead of a press
    //
    // Pressing on a window (to drag it, resize it, or just click in it) makes macOS put that
    // window in front of everything at its level, including its own scarf, which sits directly
    // above it. The scarf is back on top a moment later, but for a frame or two the window covers
    // the part of the scarf that overlaps it and casts its shadow over the rest: a flash.
    //
    // Reacting to the press is too late. So the scarf of the window under the pointer is lifted
    // just above the ordinary window level while the pointer is moving over it, where a press
    // can't cover it, and settles back shortly after the pointer stops or leaves. That is only
    // done while nothing in front overlaps the scarf, so lifting changes nothing you can see.

    /// The scarf that's lifted, until when, and (after a press on a window behind others) how
    /// long to wait for that window to come forward.
    private var lifted: (id: CGWindowID, until: CFTimeInterval, grace: CFTimeInterval)?
    private var lastSizeable: [Target] = []
    private var lastHover: CFTimeInterval = 0
    /// How long a scarf stays lifted after the pointer last moved over its window.
    private static let liftHold = 2.5

    /// Whether any real-sized window in front overlaps this window's scarf. `windows` is front to back.
    private func isObstructed(_ t: Target, by windows: [Target]) -> Bool {
        // With room to spare, so a window being dragged towards it counts before it arrives.
        let reach = (overlays[t.id]?.extent ?? t.frame.insetBy(dx: -100, dy: -100)).insetBy(dx: -48, dy: -48)
        for w in windows {
            if w.id == t.id { return false }
            // Its own drop-downs and popovers sit beneath its scarf anyway.
            if w.pid == t.pid && attached.contains(w.id) { continue }
            if w.frame.intersects(reach) { return true }
        }
        return false
    }

    private func lift(_ id: CGWindowID, _ overlay: ScarfOverlay, grace: CFTimeInterval) {
        let clock = CACurrentMediaTime()
        if let old = lifted, old.id != id { overlays[old.id]?.settle() }
        overlay.lift()
        lifted = (id, clock + Tracker.liftHold, grace)
        // macOS would hold these changes back until the app next updates the screen, several
        // milliseconds away. Send them now.
        CATransaction.flush()
    }

    private func settleLifted() {
        guard let old = lifted else { return }
        overlays[old.id]?.settle()
        lifted = nil
    }

    /// The window a press at `point` (screen coordinates, bottom-left origin) would land on.
    /// Scarves are click-through, so they never count.
    private func window(at point: NSPoint) -> CGWindowID? {
        CGWindowID(exactly: NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0))
    }

    /// The pointer moved, with no button held.
    private func hovered(at point: NSPoint) {
        guard settings.enabled, !mouseDown else { return }
        let clock = CACurrentMediaTime()
        // The pointer reports many times a second; a few looks are plenty.
        guard clock - lastHover >= 0.04 else { return }
        lastHover = clock
        guard let id = window(at: point) else { return }
        if lifted?.id == id {
            lifted?.until = clock + Tracker.liftHold
            return
        }
        guard let overlay = overlays[id], overlay.isShown,
              let t = lastSizeable.first(where: { $0.id == id }), !isObstructed(t, by: lastSizeable) else { return }
        lift(id, overlay, grace: 0)
        log("pointer over \(t.owner): scarf lifted")
    }

    /// The mouse button went down.
    private func pressed(at point: NSPoint, commandHeld: Bool) {
        guard settings.enabled else { return }
        let clock = CACurrentMediaTime()
        let id = window(at: point)
        if let now = lifted {
            // On the window whose scarf is already lifted (or on its edge, to resize it):
            // nothing to do, which is the point.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let p = CGPoint(x: point.x, y: primaryHeight - point.y)
            if now.id == id || lastSeen[now.id]?.insetBy(dx: -8, dy: -8).contains(p) == true {
                lifted?.until = clock + Tracker.liftHold
                log("pressed: scarf already lifted")
                return
            }
        }
        // Command-clicking works a window without bringing it forward.
        guard let id, !commandHeld else { return }
        if let overlay = overlays[id], overlay.isShown {
            // A window behind others (or the pointer hadn't moved lately). It's about to come
            // forward: lift its scarf now and hope to beat it there.
            lift(id, overlay, grace: clock + 0.6)
            log("pressed a window: scarf lifted at the last moment (\(id))")
        } else if lastSizeable.contains(where: { $0.id == id }) {
            // A bare window is coming forward: nothing may stay lifted over it.
            settleLifted()
            CATransaction.flush()
        }
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
            // The same goes while the desktop is revealed: the windows can fly back any time.
            // And while a scarf is lifted, so it comes down promptly if something moves over it.
            if mouseDown || revealActive || lifted != nil || idleTicks % Tracker.idleStride == 0 { refresh() }
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
        sweptAt.removeAll()
        attached.removeAll()
        standalone.removeAll()
        lifted = nil
        lastSizeable.removeAll()
        endProbe()
    }

    // MARK: Attached windows

    /// Find out whether `child` is attached to `parent`, a window of the same app beneath it.
    ///
    /// macOS keeps an attached window (a drop-down, popover or sheet) glued directly above its
    /// parent, and won't let anything be slotted in between. So an invisible one-point window
    /// is ordered "directly above the parent": if it lands above the child as well, the child
    /// is attached; if it lands between the two, the child is a window in its own right. The
    /// answer is read from the window list on the next check. This works for windows of any
    /// size and needs no permission.
    private func startProbe(child: Target, parent: Target, at clock: CFTimeInterval, screens: [CGRect]) {
        let probe = probeWindow ?? {
            let w = OverlayWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.animationBehavior = .none
            w.level = .normal
            w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            w.setAccessibilityElement(false)
            probeWindow = w
            return w
        }()
        // It has to be on a screen to show up in the window list.
        let onScreen = screens.lazy.map { $0.intersection(parent.frame) }
            .first { !$0.isNull && $0.width >= 2 && $0.height >= 2 } ?? parent.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        probe.setFrame(NSRect(x: onScreen.midX.rounded(), y: primaryHeight - onScreen.midY.rounded(), width: 1, height: 1),
                       display: false)
        probe.order(.above, relativeTo: Int(parent.id))
        probing = (child.id, parent.id, clock)
    }

    private func endProbe() {
        probeWindow?.orderOut(nil)
        probing = nil
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

    /// Debugging aid: start the app with SCARVES_LOG set to print what happens during sweeps.
    private let logging = ProcessInfo.processInfo.environment["SCARVES_LOG"] != nil
    private let started = CACurrentMediaTime()
    private func log(_ message: @autoclosure () -> String) {
        guard logging else { return }
        FileHandle.standardError.write(Data(String(format: "%7.2f  %@\n", CACurrentMediaTime() - started, message()).utf8))
    }

    /// Whether a window is the invisible cover macOS puts over a whole screen while the desktop
    /// is revealed (clicking the wallpaper, or Show Desktop). It goes up just as the windows
    /// start sliding to the screen edges and comes down as they arrive back.
    static func isRevealCover(owner: String, layer: Int, frame: CGRect, screens: [CGRect]) -> Bool {
        owner == "WindowManager" && layer > 0 && screens.contains {
            abs(frame.minX - $0.minX) < 2 && abs(frame.minY - $0.minY) < 2
                && abs(frame.width - $0.width) < 2 && abs(frame.height - $0.height) < 2
        }
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
        var revealed = false
        var pidAt = [pid_t](repeating: -1, count: info.count)   // who owns each entry in the list

        for (i, w) in info.enumerated() {
            guard let num = w[kCGWindowNumber] as? Int, let id = CGWindowID(exactly: num) else { continue }
            index[id] = i
            guard let layer = w[kCGWindowLayer] as? Int, let pid = w[kCGWindowOwnerPID] as? Int32 else { continue }
            pidAt[i] = pid
            if pid == myPID { continue }
            let owner = w[kCGWindowOwnerName] as? String ?? ""
            if layer != 0 {
                if !revealed, owner == "WindowManager", let bounds = w[kCGWindowBounds] as? NSDictionary,
                   let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
                    revealed = Tracker.isRevealCover(owner: owner, layer: layer, frame: rect, screens: screens)
                }
                continue
            }
            if ignoredOwners.contains(owner) { continue }
            if let alpha = w[kCGWindowAlpha] as? Double, alpha < 0.1 { continue }
            guard let bounds = w[kCGWindowBounds] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            if rect.width < 200 || rect.height < 140 { continue }
            sizeable.append(Target(id: id, frame: rect, owner: owner, pid: pid, index: i))
        }
        lastSizeable = sizeable

        // Which windows are attached to another one? Forget the answers for windows that have
        // gone, read the answer to the question in progress, then ask the next one.
        let clock = CACurrentMediaTime()
        if !attached.isEmpty { attached = attached.filter { index[$0] != nil } }
        if !attached.isEmpty {
            // macOS keeps an attached window glued directly above a window of its own app. One
            // found anywhere else was misjudged (the windows moved while it was being asked
            // about): it's a window in its own right after all.
            for (k, w) in sizeable.enumerated() where attached.contains(w.id) {
                if k + 1 >= sizeable.count || sizeable[k + 1].pid != w.pid {
                    attached.remove(w.id)
                    log("window \(w.id) isn't attached after all: scarf back on")
                }
            }
        }
        if !standalone.isEmpty { standalone = standalone.filter { index[$0] != nil } }
        let probeIndex = probeWindow.flatMap { CGWindowID(exactly: $0.windowNumber) }.flatMap { index[$0] }
        if let p = probing {
            if let pi = probeIndex, let ci = index[p.child], let parentIndex = index[p.parent] {
                if ci > parentIndex {
                    // The windows were re-stacked before the answer came (a click brought the
                    // parent forward, say), so the probe now sits above both and proves nothing.
                    // Ask again later rather than mistake a window of its own for a drop-down.
                    log("window \(p.child) went behind \(p.parent) mid-question: asking again")
                } else if pi < ci {
                    attached.insert(p.child)
                    log("window \(p.child) is attached to \(p.parent): no scarf")
                } else {
                    standalone.insert(p.child)
                    log("window \(p.child) stands on its own")
                }
                endProbe()
            } else if index[p.child] == nil || index[p.parent] == nil || clock - p.since > 0.4 {
                // No answer (a window went away, or the probe never showed): judge it by size instead.
                if index[p.child] != nil { standalone.insert(p.child) }
                endProbe()
            }
        }
        // Any window resting directly on another of the same app needs an answer. Work from
        // the back, so that the windows beneath the one being asked about are already known.
        var undecided: Set<CGWindowID> = []
        var nextProbe: (child: Target, parent: Target)?
        for k in sizeable.indices.reversed() where k + 1 < sizeable.count {
            let w = sizeable[k]
            guard sizeable[k + 1].pid == w.pid, !attached.contains(w.id), !standalone.contains(w.id) else { continue }
            undecided.insert(w.id)
            if nextProbe == nil {
                // Ask about the window at the bottom of the stack it's resting on.
                var j = k + 1
                while attached.contains(sizeable[j].id), j + 1 < sizeable.count, sizeable[j + 1].pid == w.pid { j += 1 }
                nextProbe = (w, sizeable[j])
            }
        }
        if probing == nil, let next = nextProbe { startProbe(child: next.child, parent: next.parent, at: clock, screens: screens) }
        if !undecided.isEmpty { stayFast(0.3) }

        for (k, w) in sizeable.enumerated() {
            // A drop-down, popover or sheet belongs to the window it's attached to.
            if attached.contains(w.id) { continue }
            // A window that fills the screen (full screen, or maximised edge to edge) goes bare.
            if Tracker.fillsScreen(w.frame, screens) { continue }
            // So do popovers, hover cards and small dialogs sitting on top of their app's window.
            // But a window that has already worn a scarf is a window in its own right: it keeps
            // it when it's clicked in front of a bigger window of the same app.
            if overlays[w.id] == nil, Tracker.isPopover(w, above: sizeable[(k + 1)...]) { continue }
            apps.insert(w.owner)
            targets.append(w)
        }
        recentApps.formUnion(apps)

        // "Front window only" means the real front window; if its app is unticked, nothing wears one.
        if settings.frontOnly { targets = Array(targets.prefix(1)) }
        targets.removeAll { skipped.contains($0.owner) }

        // Switching tabs in a tabbed window (Finder, Terminal, and others) swaps in a different
        // window at exactly the same place and hides the old one. Rather than take the scarf off
        // and knit a new one for the new window, which made scarves vanish for a moment on every
        // tab switch, hand the scarf across.
        let now = Date()
        let current = Set(targets.map(\.id))
        for t in targets where overlays[t.id]?.isShown != true {
            guard let match = overlays.first(where: { id, o in
                id != t.id && !current.contains(id) && o.pid == t.pid
                    && now.timeIntervalSince(o.lastSeen) < 0.5
                    && abs(o.targetFrame.minX - t.frame.minX) < 2 && abs(o.targetFrame.minY - t.frame.minY) < 2
                    && abs(o.targetFrame.width - t.frame.width) < 2 && abs(o.targetFrame.height - t.frame.height) < 2
            }) else { continue }
            let (oldID, overlay) = match
            overlays[oldID] = nil
            overlay.moveTo(t.id)
            overlay.orderMisses = 0
            overlay.lastOrder = 0
            overlays[t.id] = overlay
            settling[t.id] = nil
            standalone.insert(t.id)
            if lifted?.id == oldID { lifted?.id = t.id }
            if let at = sweptAt.removeValue(forKey: oldID) { sweptAt[t.id] = at }
            log("tab switched in \(t.owner): scarf handed from \(oldID) to \(t.id)")
        }

        // A window that has only just appeared may still be animating open, and macOS reports
        // it at the wrong size while it does. Wait until it has held still for a moment before
        // giving it a scarf, so the scarf is made once, for the right size.
        targets = targets.filter { t in
            if overlays[t.id] != nil { return true }
            // Not yet known whether it's a window of its own or part of another: wait.
            if undecided.contains(t.id) { return false }
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

        // Revealing the desktop sweeps every window to the screen edges, and macOS sweeps each
        // piece of a scarf too, as if it were a window of its own, each towards a different edge.
        // Chasing the windows through that would be a tug of war. So while windows are in flight
        // their scarves step out of sight, and come back once the windows have landed (at the
        // edge, and again when they return).
        if revealed { revealSeen = clock }
        let wasActive = revealActive
        revealActive = clock - revealSeen < 0.5
        if revealActive != wasActive {
            // The sweep is starting, or the windows are nearly home: watch closely.
            stayFast(0.6)
            log("desktop \(revealActive ? "revealed" : "covered again")")
        }
        if revealActive {
            let moved = targets.filter { lastSeen[$0.id] != $0.frame }
            // With the button held, one window moving is the user dragging it; several at once
            // is still a sweep.
            if !moved.isEmpty, !mouseDown || moved.count >= 2 {
                for t in moved { sweptAt[t.id] = clock }
            }
        } else if !sweptAt.isEmpty {
            sweptAt.removeAll()
        }

        if seen != lastSeen || order != lastOrder {
            // The windows were re-stacked (a click, say): let every scarf be put back at once,
            // even one that had been told to stop trying so often.
            if order != lastOrder { overlays.values.forEach { $0.orderMisses = 0 } }
            lastSeen = seen
            lastOrder = order
            stayFast(0.5)
        }

        for (id, overlay) in overlays where seen[id] == nil {
            overlay.hide()
            if lifted?.id == id { settleLifted() }
            // Forget windows that have been gone a while (closed, or on another Space for ages).
            if now.timeIntervalSince(overlay.lastSeen) > 60 {
                overlays[id] = nil
            }
        }

        let thickness = settings.thickness.points
        let visible = visibleRectsCG()
        for t in targets {
            if let at = sweptAt[t.id] {
                if clock - at < Tracker.sweepRest {
                    // Still in flight: stay out of sight and leave the pieces wherever macOS
                    // takes them.
                    if let overlay = overlays[t.id] {
                        if overlay.isShown { log("in flight, scarf off: \(t.owner) \(t.frame.origin)") }
                        if lifted?.id == t.id { settleLifted() }
                        overlay.hide()
                        overlay.lastSeen = now
                    }
                    stayFast(0.3)
                    continue
                }
                // Landed. Put the scarf back on, re-stacking it straight away if need be.
                sweptAt[t.id] = nil
                overlays[t.id]?.orderMisses = 0
                log("landed, scarf back on: \(t.owner) \(t.frame.origin)")
            }
            let overlay = overlays[t.id] ?? {
                let o = ScarfOverlay(targetID: t.id)
                overlays[t.id] = o
                return o
            }()
            overlay.lastSeen = now
            overlay.pid = t.pid
            let cw = settings.colourway(forApp: t.owner)
            let T = (thickness * cw.weight).rounded()

            var style: ScarfStyle
            let current = overlay.style
            let sameKnot = overlay.fittedKnot == settings.knot
            if let current, current.colourway == cw.id, current.T == T, sameKnot,
               mouseDown || overlay.fittedSize == t.frame.size {
                // Mid-drag, or moved but not resized: keep the scarf exactly as it is. Its long end
                // stays on the same side and nothing is tucked or dropped when the window is let go.
                style = current
            } else {
                // Fit the scarf to the free space on screen either side of the window.
                let screen = visible.first {
                    $0.insetBy(dx: -1, dy: -40).contains(CGPoint(x: t.frame.midX, y: t.frame.minY))
                } ?? visible.first { $0.intersects(t.frame) } ?? t.frame.insetBy(dx: -200, dy: -200)
                let roomLeft = t.frame.minX - screen.minX, roomRight = screen.maxX - t.frame.maxX
                let side: KnotSide, fit: ScarfFit
                if let current, sameKnot {
                    // A scarf already on, its window resized: the long end stays on its side.
                    (side, fit) = ScarfLayout.refit(keeping: current.side, roomLeft: roomLeft,
                                                    roomRight: roomRight, T: T)
                } else {
                    (side, fit) = ScarfLayout.fit(preferred: settings.knot, roomLeft: roomLeft,
                                                  roomRight: roomRight, T: T)
                }
                style = ScarfStyle(colourway: cw.id, T: T, side: side, fit: fit)
                overlay.fittedKnot = settings.knot
                overlay.fittedSize = t.frame.size
            }
            overlay.update(frame: t.frame, colourway: cw, style: style)

            if let now = lifted, now.id == t.id {
                // Lifted above the ordinary windows (see `hovered`). It stays there while the
                // pointer has been on its window lately, or a button is held (a drag), and
                // nothing in front overlaps it; except that just after a press on a window
                // behind others, it waits for that window to come forward.
                let wanted = clock < now.until || mouseDown
                let clear = clock < now.grace || !isObstructed(t, by: sizeable)
                if !(wanted && clear) {
                    log("scarf settles: \(t.owner)\(clear ? "" : " (something moved in front)")")
                    settleLifted()
                    overlay.orderMisses = 0
                    overlay.lastOrder = clock
                }
                overlay.show()
                continue
            }

            // Keep the scarf directly above its own window: every one of its pieces should be
            // in the block of windows immediately in front of it.
            let numbers = overlay.windowNumbers
            let positions = numbers.compactMap { n in CGWindowID(exactly: n).flatMap { index[$0] } }
            var inPlace = !numbers.isEmpty && positions.count == numbers.count
                && positions.allSatisfy { $0 < t.index }
            if inPlace, let top = positions.min() {
                // Nothing may sit between the scarf and its window, except windows attached to
                // that window (macOS keeps those directly above it, beneath the scarf) and the probe.
                let own = Set(positions)
                for i in top..<t.index where !own.contains(i) && pidAt[i] != t.pid && i != probeIndex {
                    inPlace = false
                    break
                }
            }
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
