import ApplicationServices
import AppKit

/// Simple flat sewing buttons that sit over a window's red, yellow and green buttons.
/// They're only pictures: clicks pass straight through to the real buttons underneath.
enum SewnButtons {
    /// Close, minimise, zoom.
    static let colours: [Yarn] = [Yarn(0xF2605A), Yarn(0xF5BD45), Yarn(0x52BF6B)]

    private static var cache: [String: CGImage] = [:]

    static func padding(_ d: CGFloat) -> CGFloat { 2 }

    static func image(_ index: Int, diameter d: CGFloat, scale: CGFloat) -> CGImage? {
        let key = "\(index)|\(d)|\(scale)"
        if let c = cache[key] { return c }
        let pad = padding(d)
        let size = CGSize(width: d + 2 * pad, height: d + 2 * pad)
        let base = colours[index % colours.count]
        let img = Knit.image(size: size, scale: scale) { ctx in
            let R = d / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func disc(_ r: CGFloat, dx: CGFloat = 0, dy: CGFloat = 0) -> CGRect {
                CGRect(x: c.x + dx - r, y: c.y + dy - r, width: 2 * r, height: 2 * r)
            }
            // A plain flat button: a disc, a thin rim, and four little holes.
            ctx.setFillColor(base.cg)
            ctx.fillEllipse(in: disc(R))
            ctx.setStrokeColor(base.shade(0.82).cg)
            ctx.setLineWidth(max(0.6, R * 0.12))
            ctx.strokeEllipse(in: disc(R * 0.7))
            let h = R * 0.24, hr = max(0.7, R * 0.12)
            ctx.setFillColor(base.shade(0.58).cg)
            for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] as [(CGFloat, CGFloat)] {
                ctx.fillEllipse(in: disc(hr, dx: sx * h, dy: sy * h))
            }
        }
        cache[key] = img
        return img
    }
}

/// Finds where a window's real red, yellow and green buttons are, using Accessibility.
/// Button positions differ between apps and title-bar styles, so there's no reliable way to
/// guess them: without permission the buttons simply aren't drawn.
enum WindowControls {
    struct Controls: Equatable {
        /// Window-local centres of close, minimise and zoom.
        var centres: [CGPoint]
        var diameter: CGFloat
        var exact: Bool
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    static func askForPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static func frame(of e: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv, CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID()
        else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Look up the buttons of the window owned by `pid` whose frame matches `windowFrame`.
    /// Returns nil when we can't tell (no permission or no match); an empty list when the
    /// window has no such buttons.
    static func lookup(pid: pid_t, windowFrame: CGRect) -> Controls? {
        guard trusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for w in windows {
            guard let f = frame(of: w),
                  abs(f.minX - windowFrame.minX) < 2, abs(f.minY - windowFrame.minY) < 2,
                  abs(f.width - windowFrame.width) < 2, abs(f.height - windowFrame.height) < 2 else { continue }
            var centres: [CGPoint] = []
            var diameter: CGFloat = 0
            for attr in [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute] {
                var b: CFTypeRef?
                guard AXUIElementCopyAttributeValue(w, attr as CFString, &b) == .success, let b,
                      CFGetTypeID(b) == AXUIElementGetTypeID(),
                      let bf = frame(of: b as! AXUIElement), bf.width > 4 else { continue }
                centres.append(CGPoint(x: bf.midX - f.minX, y: bf.midY - f.minY))
                diameter = max(diameter, min(bf.width, bf.height))
            }
            return Controls(centres: centres, diameter: diameter, exact: true)
        }
        return nil
    }
}
