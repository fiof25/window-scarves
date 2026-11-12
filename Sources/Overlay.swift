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
    var inward: Bool
    var breeze: Bool
}

/// One scarf, worn by one window. It sits directly above its window in the stacking order,
/// so windows in front of it still cover it.
final class ScarfOverlay {
    let targetID: CGWindowID
    let window: OverlayWindow
    private let root = CALayer()
    private var layers: [CALayer] = []
    private var placements: [Placement] = []
    private var style: ScarfStyle?
    private var builtSize: CGSize = .zero
    private var tailLength: CGFloat = 0
    private var extents: CGRect = .zero
    private var lastBuild: CFTimeInterval = 0
    private var pendingRebuild: DispatchWorkItem?
    private var targetFrame: CGRect = .zero
    private var colourway: Colourway = Colourways.pumpkinSpice
    var lastSeen = Date()
    private(set) var isShown = false
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
    }

    deinit { window.orderOut(nil) }

    /// Follow the target window. `frame` is in global CoreGraphics coordinates (top-left origin).
    /// `live` is true while the mouse is down, when re-knitting is throttled.
    func update(frame: CGRect, colourway cw: Colourway, style newStyle: ScarfStyle, live: Bool) {
        targetFrame = frame
        colourway = cw
        if newStyle != style || layers.isEmpty {
            rebuild(size: frame.size, style: newStyle)
        } else if frame.size != builtSize {
            if !live && CACurrentMediaTime() - lastBuild > 0.15 {
                rebuild(size: frame.size, style: newStyle)
            } else {
                relayout(size: frame.size)
                scheduleRebuild()
            }
        }
        applyFrame()
    }

    func show() {
        if ProcessInfo.processInfo.environment["SCARVES_DEBUG"] != nil {
            FileHandle.standardError.write(Data("order above \(targetID) (shown=\(isShown))\n".utf8))
        }
        window.order(.above, relativeTo: Int(targetID))
        isShown = true
    }

    func hide() {
        guard isShown else { return }
        window.orderOut(nil)
        isShown = false
    }

    private func scheduleRebuild() {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let style = self.style else { return }
            self.rebuild(size: self.targetFrame.size, style: style)
            self.applyFrame()
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func rebuild(size: CGSize, style newStyle: ScarfStyle) {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        style = newStyle
        builtSize = size
        lastBuild = CACurrentMediaTime()
        tailLength = ScarfLayout.tailLength(height: size.height, T: newStyle.T)
        placements = ScarfLayout.placements(size: size, T: newStyle.T, side: newStyle.side,
                                            tailLength: tailLength, inward: newStyle.inward)
        if !newStyle.breeze {
            for i in placements.indices { placements[i].sway = 0 }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layers.forEach { $0.removeFromSuperlayer() }
        layers = placements.map { p in
            let l = CALayer()
            l.contents = ScarfLayout.image(for: p, colourway: colourway, T: newStyle.T, scale: scale)
            l.contentsScale = scale
            l.contentsGravity = .resize
            l.minificationFilter = .trilinear
            root.addSublayer(l)
            return l
        }
        extents = ScarfLayout.extents(placements, window: size)
        positionLayers()
        let phase = Double(targetID % 17) * 0.37
        for (l, p) in zip(layers, placements) where p.sway > 0 {
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = p.angle - p.sway
            a.toValue = p.angle + p.sway
            a.duration = p.period / 2
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.timeOffset = phase.truncatingRemainder(dividingBy: p.period)
            l.add(a, forKey: "breeze")
        }
        CATransaction.commit()
    }

    /// Move the existing pieces for a new window size without re-knitting them (used mid-resize).
    private func relayout(size: CGSize) {
        guard let style else { return }
        var ps = ScarfLayout.placements(size: size, T: style.T, side: style.side, tailLength: tailLength,
                                        inward: style.inward)
        for i in ps.indices where i < placements.count { ps[i].sway = placements[i].sway }
        placements = ps
        extents = ScarfLayout.extents(placements, window: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        positionLayers()
        CATransaction.commit()
    }

    private func positionLayers() {
        let H = extents.height
        for (l, p) in zip(layers, placements) {
            l.bounds = CGRect(origin: .zero, size: p.size)
            l.anchorPoint = CGPoint(x: p.anchorUnit.x, y: 1 - p.anchorUnit.y)
            l.position = CGPoint(x: p.anchor.x - extents.minX, y: H - (p.anchor.y - extents.minY))
            l.transform = CATransform3DMakeRotation(p.angle, 0, 0, 1)
        }
    }

    private func applyFrame() {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cg = CGRect(x: targetFrame.minX + extents.minX, y: targetFrame.minY + extents.minY,
                        width: extents.width, height: extents.height)
        let ns = NSRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
        if window.frame != ns {
            window.setFrame(ns, display: false)
            if ProcessInfo.processInfo.environment["SCARVES_DEBUG"] != nil {
                FileHandle.standardError.write(Data(
                    "target=\(targetFrame) extents=\(extents) wanted=\(ns) got=\(window.frame)\n".utf8))
            }
        }
        root.frame = CGRect(origin: .zero, size: ns.size)
    }
}
