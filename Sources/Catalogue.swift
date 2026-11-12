import AppKit
import CoreText
import ImageIO

/// Renders scarves onto mock windows as PNGs, for previews and the README.
enum Catalogue {
    struct MockWindow {
        var frame: CGRect
        var colourway: Colourway
        var side: KnotSide
    }

    /// Where a mock window's red, yellow and green buttons sit (centres, window-local).
    static func mockControls(_ r: CGRect) -> [CGPoint] {
        (0..<3).map { CGPoint(x: 20 + CGFloat($0) * 23, y: 19) }
    }

    static func drawMockWindow(_ ctx: CGContext, _ r: CGRect) {
        let path = CGPath(roundedRect: r, cornerWidth: 14, cornerHeight: 14, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30,
                      color: CGColor(srgbRed: 0.25, green: 0.15, blue: 0.05, alpha: 0.28))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.995, blue: 0.985, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(CGColor(srgbRed: 0.965, green: 0.955, blue: 0.94, alpha: 1))
        ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 38))
        ctx.setFillColor(CGColor(srgbRed: 0.88, green: 0.87, blue: 0.85, alpha: 1))
        ctx.fill(CGRect(x: r.minX, y: r.minY + 38, width: r.width, height: 1))
        let lights: [UInt32] = [0xFF5F57, 0xFEBC2E, 0x28C840]
        for (c, hex) in zip(mockControls(r), lights) {
            ctx.setFillColor(Yarn(hex).cg)
            ctx.fillEllipse(in: CGRect(x: r.minX + c.x - 7, y: r.minY + c.y - 7, width: 14, height: 14))
        }
        ctx.setFillColor(CGColor(srgbRed: 0.91, green: 0.9, blue: 0.885, alpha: 1))
        var y = r.minY + 70
        var k = 0
        while y < r.maxY - 30 {
            let w = (r.width - 64) * (k % 3 == 2 ? 0.55 : (k % 2 == 0 ? 0.9 : 0.75))
            ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX + 32, y: y, width: w, height: 10),
                               cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
            y += 26; k += 1
        }
        ctx.restoreGState()
    }

    static func drawPlaced(_ ctx: CGContext, _ img: CGImage, _ p: Placement, origin: CGPoint) {
        ctx.saveGState()
        let rect = CGRect(x: origin.x + p.origin.x, y: origin.y + p.origin.y,
                          width: p.size.width, height: p.size.height)
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: rect)
        ctx.restoreGState()
    }

    static func drawScarf(_ ctx: CGContext, on r: CGRect, colourway cw: Colourway, side: KnotSide,
                          T: CGFloat, scale: CGFloat, fit: ScarfFit = .roomy) {
        let T = (T * cw.weight).rounded()
        let tl = ScarfLayout.tailLength(height: r.height, T: T)
        for p in ScarfLayout.placements(size: r.size, T: T, side: side, tailLength: tl, fit: fit) {
            if let img = ScarfLayout.image(for: p, colourway: cw, scale: scale) {
                drawPlaced(ctx, img, p, origin: r.origin)
            }
        }
        // Sewn-on buttons over the window's own.
        let d: CGFloat = 15
        for (k, c) in mockControls(r).enumerated() {
            guard let img = SewnButtons.image(k, diameter: d, scale: scale) else { continue }
            let pad = SewnButtons.padding(d)
            let rect = CGRect(x: r.minX + c.x - d / 2 - pad, y: r.minY + c.y - d / 2 - pad,
                              width: d + 2 * pad, height: d + 2 * pad)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: rect)
            ctx.restoreGState()
        }
    }

    static func drawText(_ ctx: CGContext, _ s: String, at p: CGPoint, size: CGFloat, weight: NSFont.Weight,
                         colour: Yarn) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attr = NSAttributedString(string: s, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: colour.cg) ?? .black,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = p
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static func background(_ ctx: CGContext, _ size: CGSize) {
        let colors = [Yarn(0xFDF3E3).cg, Yarn(0xF6E2C6).cg] as CFArray
        if let g = CGGradient(colorsSpace: Knit.sRGB, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
    }

    static func write(_ img: CGImage, to path: String) -> Bool {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// A few overlapping windows, each wearing a scarf.
    static func hero(to path: String, scale: CGFloat = 2) -> Bool {
        let size = CGSize(width: 1500, height: 940)
        let T: CGFloat = 34
        let windows = [
            MockWindow(frame: CGRect(x: 110, y: 120, width: 640, height: 430), colourway: Colourways.lilacCheck, side: .right),
            MockWindow(frame: CGRect(x: 880, y: 100, width: 500, height: 360), colourway: Colourways.oatMilk, side: .left),
            MockWindow(frame: CGRect(x: 330, y: 470, width: 560, height: 370), colourway: Colourways.rosehip, side: .right),
            MockWindow(frame: CGRect(x: 960, y: 540, width: 420, height: 300), colourway: Colourways.cocoaCheck, side: .right),
        ]
        guard let img = Knit.image(size: size, scale: scale, { ctx in
            background(ctx, size)
            for w in windows {
                drawMockWindow(ctx, w.frame)
                drawScarf(ctx, on: w.frame, colourway: w.colourway, side: w.side, T: T, scale: scale)
            }
        }) else { return false }
        return write(img, to: path)
    }

    /// Every colourway on its own little window, with its name underneath.
    static func swatches(to path: String, scale: CGFloat = 2) -> Bool {
        let cols = 3
        let cell = CGSize(width: 390, height: 360)
        let all = Colourways.all
        let rows = (all.count + cols - 1) / cols
        let size = CGSize(width: CGFloat(cols) * cell.width + 40, height: CGFloat(rows) * cell.height + 40)
        guard let img = Knit.image(size: size, scale: scale, { ctx in
            background(ctx, size)
            for (k, cw) in all.enumerated() {
                let ox = 20 + CGFloat(k % cols) * cell.width
                let oy = 20 + CGFloat(k / cols) * cell.height
                let r = CGRect(x: ox + 50, y: oy + 60, width: 270, height: 200)
                drawMockWindow(ctx, r)
                drawScarf(ctx, on: r, colourway: cw, side: .right, T: 28, scale: scale)
                drawText(ctx, cw.name, at: CGPoint(x: ox + 50, y: oy + 306), size: 17, weight: .semibold,
                         colour: Yarn(0x4A2E1E))
                drawText(ctx, cw.blurb, at: CGPoint(x: ox + 50, y: oy + 328), size: 12.5, weight: .regular,
                         colour: Yarn(0x7A5A44))
            }
        }) else { return false }
        return write(img, to: path)
    }

    /// A close-up of the knit, to check stitch detail.
    static func closeUp(to path: String, colourway cw: Colourway, scale: CGFloat = 3,
                        fit: ScarfFit = .roomy) -> Bool {
        let size = CGSize(width: 640, height: 470)
        let r = CGRect(x: 120, y: 110, width: 380, height: 300)
        guard let img = Knit.image(size: size, scale: scale, { ctx in
            background(ctx, size)
            drawMockWindow(ctx, r)
            drawScarf(ctx, on: r, colourway: cw, side: .right, T: 38, scale: scale, fit: fit)
        }) else { return false }
        return write(img, to: path)
    }
}
