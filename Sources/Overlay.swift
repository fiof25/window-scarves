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
}

/// One scarf, worn by one window. It sits directly above its window in the stacking order,
/// so windows in front of it still cover it.
final class ScarfOverlay {
    let targetID: CGWindowID
    let window: OverlayWindow
    private let root = CALayer()
    /// Holds the sewn-on buttons, always above the scarf.
    private let buttonRoot = CALayer()
    private var buttonLayers: [CALayer] = []
    private var controls: WindowControls.Controls?
    private var layers: [CALayer] = []
    private var placements: [Placement] = []
    private var style: ScarfStyle?
    private var builtSize: CGSize = .zero
    private var tailLength: CGFloat = 0
    private var extents: CGRect = .zero
    private var lastBuild: CFTimeInterval = 0
    private var pendingRebuild: DispatchWorkItem?
    private var targetFrame: CGRect = .zero
    private var colourway: Colourway = Colourways.rosehip
    private var renderGeneration = 0
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
        root.addSublayer(buttonRoot)
    }

    deinit { window.orderOut(nil) }

    /// Follow the target window. `frame` is in global CoreGraphics coordinates (top-left origin).
    /// `live` is true while the mouse is down, when re-knitting is throttled.
    func update(frame: CGRect, colourway cw: Colourway, style newStyle: ScarfStyle,
                controls newControls: WindowControls.Controls?, live: Bool) {
        targetFrame = frame
        colourway = cw
        if newControls != controls {
            controls = newControls
            rebuildButtons()
        }
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

    private func rebuildButtons() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        buttonLayers.forEach { $0.removeFromSuperlayer() }
        buttonLayers = []
        if let controls {
            let d = (controls.diameter + 1).rounded()
            let pad = SewnButtons.padding(d)
            for k in controls.centres.indices {
                let l = CALayer()
                l.contents = SewnButtons.image(k, diameter: d, scale: scale)
                l.contentsScale = scale
                l.bounds = CGRect(x: 0, y: 0, width: d + 2 * pad, height: d + 2 * pad)
                buttonRoot.addSublayer(l)
                buttonLayers.append(l)
            }
        }
        positionButtons()
        CATransaction.commit()
    }

    private func positionButtons() {
        guard let controls else { return }
        for (l, c) in zip(buttonLayers, controls.centres) {
            l.position = CGPoint(x: c.x - extents.minX, y: extents.height - (c.y - extents.minY))
        }
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
                                            tailLength: tailLength)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if layers.count != placements.count {
            layers.forEach { $0.removeFromSuperlayer() }
            layers = placements.map { _ in
                let l = CALayer()
                l.contentsScale = scale
                l.contentsGravity = .resize
                l.minificationFilter = .trilinear
                root.insertSublayer(l, below: buttonRoot)
                return l
            }
        }
        extents = ScarfLayout.extents(placements, window: size)
        positionLayers()
        CATransaction.commit()

        // Knit the new pieces in the background; until they're ready the old ones stretch to fit.
        renderGeneration += 1
        let generation = renderGeneration, ps = placements, cw = colourway, scale = scale
        ScarfOverlay.artQueue.async { [weak self] in
            let images = ps.map { ScarfLayout.image(for: $0, colourway: cw, scale: scale) }
            DispatchQueue.main.async {
                guard let self, generation == self.renderGeneration else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for (l, img) in zip(self.layers, images) { l.contents = img }
                CATransaction.commit()
            }
        }
    }

    /// All knitting happens here, one piece at a time, off the main thread.
    static let artQueue = DispatchQueue(label: "window-scarves.knitting", qos: .userInitiated)

    /// Move the existing pieces for a new window size without re-knitting them (used mid-resize).
    private func relayout(size: CGSize) {
        guard let style else { return }
        placements = ScarfLayout.placements(size: size, T: style.T, side: style.side, tailLength: tailLength)
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
        positionButtons()
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: ns.size)
        buttonRoot.frame = root.bounds
        CATransaction.commit()
    }
}
