import AppKit
import ApplicationServices

/// Moving other apps' windows. macOS only allows this with Accessibility permission, so it's
/// used for one optional feature: dragging a window by its scarf.
enum WindowMover {
    static var allowed: Bool { AXIsProcessTrusted() }

    /// Show macOS's own prompt, which sends the user to System Settings to allow it.
    static func askForAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The window of app `pid` that has this frame right now (global, top-left origin).
    static func window(pid: pid_t, frame: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        // Never wait long on an app that's busy or hung.
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        var best: AXUIElement?
        var bestOff = CGFloat(8)
        for w in windows {
            guard let p = point(of: w), let s = size(of: w) else { continue }
            let off = abs(p.x - frame.minX) + abs(p.y - frame.minY)
                + abs(s.width - frame.width) + abs(s.height - frame.height)
            if off <= bestOff {
                best = w
                bestOff = off - 0.001      // on a tie, keep the first (frontmost) one
            }
        }
        return best
    }

    private static func value(of element: AXUIElement, _ attribute: String) -> AXValue? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    static func point(of window: AXUIElement) -> CGPoint? {
        var p = CGPoint.zero
        guard let v = value(of: window, kAXPositionAttribute), AXValueGetValue(v, .cgPoint, &p) else { return nil }
        return p
    }

    private static func size(of window: AXUIElement) -> CGSize? {
        var s = CGSize.zero
        guard let v = value(of: window, kAXSizeAttribute), AXValueGetValue(v, .cgSize, &s) else { return nil }
        return s
    }

    @discardableResult
    static func move(_ window: AXUIElement, to point: CGPoint) -> Bool {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v) == .success
    }

    /// What clicking a window's title bar does: bring it, and its app, to the front.
    static func bringForward(_ window: AXUIElement, pid: pid_t) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
}

/// An invisible window over part of a scarf that catches the mouse, so the scarf can be grabbed.
/// It never takes focus, and clicking it doesn't bring Window Scarves itself forward.
final class GripPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class GripView: NSView {
    var onDown: (() -> Void)?
    var onDrag: (() -> Void)?
    var onUp: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onDown?() }
    override func mouseDragged(with event: NSEvent) { onDrag?() }
    override func mouseUp(with event: NSEvent) { onUp?() }
}
