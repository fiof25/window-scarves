import AppKit
import QuartzCore

/// A borderless, transparent, click-through window that never takes focus.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

struct ScarfStyle: Equatable {
    var colourway: String
    var T: CGFloat
    var side: KnotSide
    var fit: ScarfFit
}

/// One scarf, worn by one window. It sits directly above its window in the stacking order,
/// so windows in front of it still cover it.
///
/// The window itself stays on screen for as long as the scarf exists; showing and hiding only
/// fades its contents. That avoids macOS replaying its "new window" animation every time.
final class ScarfOverlay {
    let targetID: CGWindowID
    let window: OverlayWindow
    private let root = CALayer()
    /// Everything visible, so it can be faded as one.
    private let content = CALayer()
    private var layers: [CALayer] = []
    private var placements: [Placement] = []
    private(set) var style: ScarfStyle?
    private var builtSize: CGSize = .zero
    private var extents: CGRect = .zero
    private var targetFrame: CGRect = .zero
    private var colourway: Colourway = Colourways.rosehip
    private var rendering = false
    private var needsRender = false
    /// Whether the layers hold images that match the current style.
    private var hasContents = false
    private(set) var isShown = false
    var lastSeen = Date()
    /// Bookkeeping for keeping the scarf directly above its window (see `Tracker`).
    var lastOrder: CFTimeInterval = 0
    var orderMisses = 0
    let scale: CGFloat

    init(targetID: CGWindowID) {
        self.targetID = targetID
        scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        window = OverlayWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                               styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let view = NSView(frame: .zero)
        view.layer = root
        view.wantsLayer = true
        window.contentView = view
        content.opacity = 0
        root.addSublayer(content)
    }

    deinit { window.orderOut(nil) }

    /// Follow the target window. `frame` is in global CoreGraphics coordinates (top-left origin).
    func update(frame: CGRect, colourway cw: Colourway, style newStyle: ScarfStyle) {
        targetFrame = frame
        colourway = cw
        if newStyle != style {
            // A different scarf or a different drape: the old pictures don't fit the new shape,
            // so fade out and come back once the new ones are knitted.
            if style != nil { setOpacity(0) }
            hasContents = false
            layout(size: frame.size, style: newStyle)
            startRender()
        } else if frame.size != builtSize {
            // Same scarf, new size: the old pictures stretch slightly until fresh ones land.
            layout(size: frame.size, style: newStyle)
            startRender()
        }
        applyFrame()
    }

    /// Put the scarf's window directly above the window it belongs to.
    func placeAboveTarget() {
        window.order(.above, relativeTo: Int(targetID))
    }

    func show() {
        guard !isShown else { return }
        isShown = true
        if hasContents { fadeIn() }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        setOpacity(0)
    }

    private func setOpacity(_ value: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.removeAnimation(forKey: "fade")
        content.opacity = value
        CATransaction.commit()
    }

    private func fadeIn() {
        setOpacity(1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        content.add(fade, forKey: "fade")
    }

    /// Work out where each piece of the scarf goes for this window size, and move the layers there.
    private func layout(size: CGSize, style newStyle: ScarfStyle) {
        style = newStyle
        builtSize = size
        let tail = ScarfLayout.tailLength(height: size.height, T: newStyle.T)
        placements = ScarfLayout.placements(size: size, T: newStyle.T, side: newStyle.side,
                                            tailLength: tail, fit: newStyle.fit)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if layers.count != placements.count {
            layers.forEach { $0.removeFromSuperlayer() }
            layers = placements.map { _ in
                let l = CALayer()
                l.contentsScale = scale
                l.contentsGravity = .resize
                l.minificationFilter = .trilinear
                l.anchorPoint = CGPoint(x: 0, y: 1)
                content.addSublayer(l)
                return l
            }
        }
        extents = ScarfLayout.extents(placements, window: size)
        let H = extents.height
        for (l, p) in zip(layers, placements) {
            l.bounds = CGRect(origin: .zero, size: p.size)
            l.position = CGPoint(x: p.origin.x - extents.minX, y: H - (p.origin.y - extents.minY))
        }
        CATransaction.commit()
    }

    /// All knitting happens here, one piece at a time, off the main thread.
    static let artQueue = DispatchQueue(label: "window-scarves.knitting", qos: .userInitiated)

    /// Knit pictures for the current layout in the background. Only one job runs per scarf at a
    /// time: if the window changes again meanwhile, one more job runs afterwards for the latest
    /// size, so a long resize never builds up a queue.
    private func startRender() {
        guard !rendering else { needsRender = true; return }
        rendering = true
        let ps = placements, cw = colourway, scale = scale, knitted = style
        ScarfOverlay.artQueue.async { [weak self] in
            let images = ScarfLayout.images(for: ps, colourway: cw, scale: scale)
            DispatchQueue.main.async {
                guard let self else { return }
                self.rendering = false
                // Pictures for an older size are still worth showing (they stretch a touch);
                // pictures for a different scarf or drape are not.
                if knitted == self.style, images.count == self.layers.count {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    for (l, img) in zip(self.layers, images) { l.contents = img }
                    CATransaction.commit()
                    if !self.hasContents {
                        self.hasContents = true
                        if self.isShown { self.fadeIn() }
                    }
                }
                if self.needsRender {
                    self.needsRender = false
                    self.startRender()
                }
            }
        }
    }

    /// A picture of the scarf exactly as it's currently being drawn, with the window's outline
    /// for reference. Used by the `SCARVES_SNAPSHOT` debugging option.
    func snapshot() -> CGImage? {
        let size = root.bounds.size
        guard size.width > 1, size.height > 1,
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: Knit.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        // The window this scarf belongs to, in the layer's bottom-left coordinates.
        let win = CGRect(x: -extents.minX, y: size.height - (targetFrame.height - extents.minY),
                         width: targetFrame.width, height: targetFrame.height)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(win)
        ctx.setStrokeColor(CGColor(srgbRed: 0.6, green: 0.6, blue: 0.65, alpha: 1))
        ctx.stroke(win, width: 1)
        root.render(in: ctx)
        return ctx.makeImage()
    }

    private func applyFrame() {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cg = CGRect(x: targetFrame.minX + extents.minX, y: targetFrame.minY + extents.minY,
                        width: extents.width, height: extents.height)
        let ns = NSRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
        if window.frame != ns {
            window.setFrame(ns, display: false)
        }
        let bounds = CGRect(origin: .zero, size: ns.size)
        if content.frame != bounds {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.frame = bounds
            content.frame = bounds
            CATransaction.commit()
        }
    }
}
