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
        ctx.setFillColor(CGColor(srgbRed: 0.965, green: 0.952, blue: 0.93, alpha: 1))
        ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 38))
        ctx.setFillColor(CGColor(srgbRed: 0.88, green: 0.86, blue: 0.83, alpha: 1))
        ctx.fill(CGRect(x: r.minX, y: r.minY + 38, width: r.width, height: 1))
        let lights: [UInt32] = [0xFF5F57, 0xFEBC2E, 0x28C840]
        for (i, hex) in lights.enumerated() {
            ctx.setFillColor(Yarn(hex).cg)
            ctx.fillEllipse(in: CGRect(x: r.minX + 16 + CGFloat(i) * 20, y: r.minY + 13, width: 12, height: 12))
        }
        // A few lines of pretend content.
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.885, blue: 0.86, alpha: 1))
        var y = r.minY + 62
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

    static func drawScarf(_ ctx: CGContext, on r: CGRect, colourway cw: Colourway, side: KnotSide,
                          T: CGFloat, scale: CGFloat, inward: Bool = false) {
        let tl = ScarfLayout.tailLength(height: r.height, T: T)
        for p in ScarfLayout.placements(size: r.size, T: T, side: side, tailLength: tl, inward: inward) {
            guard let img = ScarfLayout.image(for: p, colourway: cw, T: T, scale: scale) else { continue }
            ctx.saveGState()
            ctx.translateBy(x: r.minX + p.anchor.x, y: r.minY + p.anchor.y)
            ctx.rotate(by: -p.angle)
            let rect = CGRect(x: -p.anchorUnit.x * p.size.width, y: -p.anchorUnit.y * p.size.height,
                              width: p.size.width, height: p.size.height)
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
        let colors = [Yarn(0xF6EBD6).cg, Yarn(0xEED9B8).cg] as CFArray
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

    /// A few overlapping windows, each wearing a different scarf.
    static func hero(to path: String, scale: CGFloat = 2) -> Bool {
        let size = CGSize(width: 1500, height: 920)
        let T: CGFloat = 30
        let windows = [
            MockWindow(frame: CGRect(x: 120, y: 110, width: 640, height: 430), colourway: Colourways.maplePlaid, side: .right),
            MockWindow(frame: CGRect(x: 860, y: 90, width: 520, height: 360), colourway: Colourways.forestZigzag, side: .left),
            MockWindow(frame: CGRect(x: 300, y: 420, width: 560, height: 380), colourway: Colourways.pumpkinSpice, side: .right),
            MockWindow(frame: CGRect(x: 940, y: 520, width: 450, height: 300), colourway: Colourways.harvestFairIsle, side: .right),
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
        let cols = 4
        let cell = CGSize(width: 380, height: 330)
        let all = Colourways.all
        let rows = (all.count + cols - 1) / cols
        let size = CGSize(width: CGFloat(cols) * cell.width + 40, height: CGFloat(rows) * cell.height + 40)
        guard let img = Knit.image(size: size, scale: scale, { ctx in
            background(ctx, size)
            for (k, cw) in all.enumerated() {
                let ox = 20 + CGFloat(k % cols) * cell.width
                let oy = 20 + CGFloat(k / cols) * cell.height
                let r = CGRect(x: ox + 50, y: oy + 50, width: 240, height: 190)
                drawMockWindow(ctx, r)
                drawScarf(ctx, on: r, colourway: cw, side: .right, T: 24, scale: scale)
                drawText(ctx, cw.name, at: CGPoint(x: ox + 50, y: oy + 282), size: 17, weight: .semibold,
                         colour: Yarn(0x4A2E1E))
                drawText(ctx, cw.blurb, at: CGPoint(x: ox + 50, y: oy + 304), size: 12.5, weight: .regular,
                         colour: Yarn(0x7A5A44))
            }
        }) else { return false }
        return write(img, to: path)
    }

    /// A close-up of the knit, to check stitch detail. `inward` shows the tucked-in fit used
    /// when a window fills the screen.
    static func closeUp(to path: String, colourway cw: Colourway, scale: CGFloat = 3, inward: Bool = false) -> Bool {
        let size = CGSize(width: 420, height: 380)
        let r = CGRect(x: 30, y: 70, width: inward ? 390 : 300, height: 400)
        guard let img = Knit.image(size: size, scale: scale, { ctx in
            background(ctx, size)
            drawMockWindow(ctx, r)
            drawScarf(ctx, on: r, colourway: cw, side: .right, T: 32, scale: scale, inward: inward)
        }) else { return false }
        return write(img, to: path)
    }
}
