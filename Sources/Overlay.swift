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

/// One scarf, worn by one window.
///
/// The scarf is made of a few pieces (the run along the top, and each hanging end), and each
/// piece has its own small window sitting directly above the window it belongs to. Keeping the
/// windows that small means nothing invisible covers the app's own content, so screenshot and
/// screen-sharing window pickers, and anything else that asks "which window is under the
/// pointer?", still find the real window.
///
/// The windows stay on screen for as long as the scarf exists; showing and hiding only fades
/// their contents. That avoids macOS replaying its "new window" animation every time.
final class ScarfOverlay {
    let targetID: CGWindowID

    private final class Piece {
        let window: OverlayWindow
        let image = CALayer()

        init() {
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
            // Not a window anyone should land on with VoiceOver or other assistive tools.
            window.setAccessibilityElement(false)
            let root = CALayer()
            let view = NSView(frame: .zero)
            view.layer = root
            view.wantsLayer = true
            window.contentView = view
            image.contentsGravity = .resize
            image.minificationFilter = .trilinear
            image.opacity = 0
            image.frame = root.bounds
            root.addSublayer(image)
        }

        deinit { window.orderOut(nil) }
    }

    private var pieces: [Piece] = []
    private var placements: [Placement] = []
    private(set) var style: ScarfStyle?
    private var builtSize: CGSize = .zero
    private var targetFrame: CGRect = .zero
    private var colourway: Colourway = Colourways.rosehip
    private var rendering = false
    private var needsRender = false
    /// Whether the pieces hold images that match the current style.
    private var hasContents = false
    private(set) var isShown = false
    var lastSeen = Date()
    /// Bookkeeping for keeping the scarf directly above its window (see `Tracker`).
    var lastOrder: CFTimeInterval = 0
    var orderMisses = 0

    init(targetID: CGWindowID) {
        self.targetID = targetID
    }

    /// The window numbers of this scarf's pieces.
    var windowNumbers: [Int] { pieces.map { $0.window.windowNumber } }

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
        applyFrames()
    }

    /// Just above every ordinary window, and below anything that floats (palettes, picture in picture).
    private static let liftedLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
    private(set) var isLifted = false

    /// Hold the scarf above every ordinary window. When a window is pressed, macOS puts it in
    /// front of everything at its level, its own scarf included, and it stays there, casting its
    /// shadow over the scarf, until the scarf can be put back: a flash. A lifted scarf can't be
    /// covered that way. (Nothing is sent to macOS until the caller flushes.)
    func lift() {
        guard !isLifted else { return }
        isLifted = true
        for piece in pieces { piece.window.level = ScarfOverlay.liftedLevel }
    }

    /// Back to its usual place, directly above its own window.
    func settle() {
        guard isLifted else { return }
        isLifted = false
        for piece in pieces { piece.window.level = .normal }
        placeAboveTarget()
    }

    /// Everything the scarf and its window cover, in global coordinates (top-left origin).
    var extent: CGRect {
        var r = targetFrame
        for p in placements {
            r = r.union(CGRect(x: targetFrame.minX + p.origin.x, y: targetFrame.minY + p.origin.y,
                               width: p.size.width, height: p.size.height))
        }
        return r
    }

    /// Put the scarf's windows directly above the window it belongs to.
    func placeAboveTarget() {
        for piece in pieces { piece.window.order(.above, relativeTo: Int(targetID)) }
        // Sent straight away rather than with the next screen update, so a scarf that has
        // ended up beneath its window is back on top as soon as possible.
        CATransaction.flush()
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
        for piece in pieces {
            piece.image.removeAnimation(forKey: "fade")
            piece.image.opacity = value
        }
        CATransaction.commit()
    }

    private func fadeIn() {
        setOpacity(1)
        for piece in pieces {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            piece.image.add(fade, forKey: "fade")
        }
    }

    /// Work out where each piece of the scarf goes for this window size.
    private func layout(size: CGSize, style newStyle: ScarfStyle) {
        style = newStyle
        builtSize = size
        let tail = ScarfLayout.tailLength(height: size.height, T: newStyle.T)
        placements = ScarfLayout.placements(size: size, T: newStyle.T, side: newStyle.side,
                                            tailLength: tail, fit: newStyle.fit)
        if pieces.count != placements.count {
            // A different number of pieces (the short end comes or goes): start them afresh,
            // invisible until their pictures are ready.
            hasContents = false
            pieces = placements.map { _ in Piece() }
            if isLifted { for piece in pieces { piece.window.level = ScarfOverlay.liftedLevel } }
        }
    }

    /// All knitting happens here, one scarf at a time, off the main thread.
    static let artQueue = DispatchQueue(label: "window-scarves.knitting", qos: .userInitiated)

    /// Knit pictures for the current layout in the background. Only one job runs per scarf at a
    /// time: if the window changes again meanwhile, one more job runs afterwards for the latest
    /// size, so a long resize never builds up a queue.
    private func startRender() {
        guard !rendering else { needsRender = true; return }
        rendering = true
        let ps = placements, cw = colourway, knitted = style
        // Sharp enough for the sharpest display attached right now.
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        ScarfOverlay.artQueue.async { [weak self] in
            // The window may have closed while this job waited its turn.
            guard self != nil else { return }
            let images = ScarfLayout.images(for: ps, colourway: cw, scale: scale)
            DispatchQueue.main.async {
                guard let self else { return }
                self.rendering = false
                // Pictures for an older size are still worth showing (they stretch a touch);
                // pictures for a different scarf or drape are not.
                if knitted == self.style, images.count == self.pieces.count {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    for (piece, img) in zip(self.pieces, images) {
                        piece.image.contentsScale = scale
                        piece.image.contents = img
                    }
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

    /// Move each piece's window to where it belongs on the target window.
    private func applyFrames() {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for (piece, p) in zip(pieces, placements) {
            let cg = CGRect(x: targetFrame.minX + p.origin.x, y: targetFrame.minY + p.origin.y,
                            width: p.size.width, height: p.size.height)
            let ns = NSRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
            if piece.window.frame != ns {
                piece.window.setFrame(ns, display: false)
            }
            let bounds = CGRect(origin: .zero, size: ns.size)
            if piece.image.frame != bounds {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                piece.image.superlayer?.frame = bounds
                piece.image.frame = bounds
                CATransaction.commit()
            }
        }
    }

    /// A picture of the scarf exactly as it's currently being drawn, with the window's outline
    /// for reference. Used by the `SCARVES_SNAPSHOT` debugging option.
    func snapshot() -> CGImage? {
        let extents = ScarfLayout.extents(placements, window: targetFrame.size)
        let size = extents.size
        guard size.width > 1, size.height > 1,
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: Knit.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // This draws see-through pictures, so it takes its turn like all other such drawing.
        Knit.seeThrough.lock()
        defer { Knit.seeThrough.unlock() }
        // Work in window-local, top-left coordinates.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -extents.minX, y: -extents.minY)
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1))
        ctx.fill(extents)
        let win = CGRect(origin: .zero, size: targetFrame.size)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(win)
        ctx.setStrokeColor(CGColor(srgbRed: 0.6, green: 0.6, blue: 0.65, alpha: 1))
        ctx.stroke(win, width: 1)
        for (piece, p) in zip(pieces, placements) where piece.image.opacity > 0 {
            guard let contents = piece.image.contents else { continue }
            let img = contents as! CGImage
            let r = CGRect(origin: p.origin, size: p.size)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: r.minY + r.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: r)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}
