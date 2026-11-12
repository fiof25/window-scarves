import CoreGraphics
import Foundation

/// Low-level knit drawing. All drawing happens in a top-left-origin, y-down space.
enum Knit {
    static let pad: CGFloat = 8
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Make a transparent bitmap of `size` points and draw into it with a y-down coordinate space.
    static func image(size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
        let pw = max(1, Int(ceil(size.width * scale)))
        let ph = max(1, Int(ceil(size.height * scale)))
        guard let ctx = CGContext(
            data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        draw(ctx)
        return ctx.makeImage()
    }

    /// Fill `rect` with stockinette stitches: columns of little V's pointing down.
    static func stitches(
        _ ctx: CGContext, rect: CGRect, sw: CGFloat, sh: CGFloat, seed: Int,
        colour: (_ col: Int, _ row: Int) -> Yarn
    ) {
        let cols = Int(ceil(rect.width / sw))
        let rows = Int(ceil(rect.height / sh))
        let theta: CGFloat = 0.5
        let ew = 0.54 * sw, eh = 1.34 * sh
        let outer = CGRect(x: -ew / 2, y: -eh / 2, width: ew, height: eh)
        let inner = CGRect(x: -ew * 0.34, y: -eh * 0.45, width: ew * 0.68, height: eh * 0.8)
        let shine = CGRect(x: -ew * 0.17, y: -eh * 0.38, width: ew * 0.3, height: eh * 0.4)
        let sides: [CGFloat] = [-1, 1]
        for row in -1...rows {
            for col in 0..<cols {
                let base = colour(col, row)
                let y = base.shade(0.92 + 0.16 * noise01(col, row, seed))
                let dark = y.shade(0.66).cg, mid = y.cg, light = y.lighten(0.17).cg
                let cx = rect.minX + (CGFloat(col) + 0.5) * sw
                let cy = rect.minY + (CGFloat(row) + 0.5) * sh
                for side in sides {
                    ctx.saveGState()
                    ctx.translateBy(x: cx + side * 0.23 * sw, y: cy)
                    ctx.rotate(by: side * theta)
                    ctx.setFillColor(dark); ctx.fillEllipse(in: outer)
                    ctx.setFillColor(mid); ctx.fillEllipse(in: inner)
                    ctx.setFillColor(light); ctx.fillEllipse(in: shine)
                    ctx.restoreGState()
                }
            }
        }
    }

    private static func grey(_ white: CGFloat, _ alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: white, green: white, blue: white, alpha: alpha)
    }

    /// Soft tube shading across the scarf so it looks puffy rather than flat.
    static func shadeAcross(_ ctx: CGContext, rect: CGRect, horizontal: Bool) {
        let colors = [
            grey(0, 0.30), grey(0, 0.05), grey(1, 0.13), grey(1, 0), grey(0, 0.10), grey(0, 0.48),
        ] as CFArray
        let locs: [CGFloat] = [0, 0.16, 0.36, 0.56, 0.8, 1]
        guard let g = CGGradient(colorsSpace: sRGB, colors: colors, locations: locs) else { return }
        let start = horizontal ? CGPoint(x: rect.minX, y: rect.midY) : CGPoint(x: rect.midX, y: rect.minY)
        let end = horizontal ? CGPoint(x: rect.maxX, y: rect.midY) : CGPoint(x: rect.midX, y: rect.maxY)
        ctx.drawLinearGradient(g, start: start, end: end, options: [])
    }

    /// Draw a scarf piece: a soft drop shadow, the knit body clipped to `shape`, and a faint edge.
    static func piece(
        _ ctx: CGContext, shape: CGPath, gap: Yarn, scale: CGFloat, body: (CGContext) -> Void
    ) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2.5 * scale), blur: 5 * scale, color: grey(0, 0.36))
        ctx.addPath(shape)
        ctx.setFillColor(gap.cg)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        body(ctx)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.setStrokeColor(grey(0, 0.2))
        ctx.setLineWidth(0.8)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

/// Renders (and caches) the three kinds of scarf piece: the band, a tail and the knot.
enum ScarfArt {
    private static var cache: [String: CGImage] = [:]

    static func clearCache() { cache.removeAll() }

    private static func cached(_ key: String, _ make: () -> CGImage?) -> CGImage? {
        if let c = cache[key] { return c }
        if cache.count > 240 { cache.removeAll() }
        let img = make()
        cache[key] = img
        return img
    }

    static func fringeLength(_ T: CGFloat) -> CGFloat { (T * 1.05).rounded() }

    static func bandSize(length: CGFloat, T: CGFloat) -> CGSize {
        CGSize(width: length.rounded() + 2 * Knit.pad, height: T + 2 * Knit.pad)
    }

    static func tailSize(length: CGFloat, T: CGFloat) -> CGSize {
        CGSize(width: T + 2 * Knit.pad, height: length + fringeLength(T) + 2 * Knit.pad)
    }

    static func knotSize(T: CGFloat) -> CGSize {
        CGSize(width: (1.45 * T).rounded() + 2 * Knit.pad, height: (1.25 * T).rounded() + 2 * Knit.pad)
    }

    /// The long band that drapes across the top of the window.
    static func band(_ cw: Colourway, length: CGFloat, T: CGFloat, scale: CGFloat) -> CGImage? {
        let L = length.rounded()
        return cached("band|\(cw.id)|\(L)|\(T)|\(scale)") {
            Knit.image(size: bandSize(length: L, T: T), scale: scale) { ctx in
                let rect = CGRect(x: Knit.pad, y: Knit.pad, width: L, height: T)
                let shape = CGPath(roundedRect: rect, cornerWidth: T * 0.49, cornerHeight: T * 0.49, transform: nil)
                let n = 10
                let sh = T / CGFloat(n), sw = sh / 0.82
                Knit.piece(ctx, shape: shape, gap: cw.gap, scale: scale) { ctx in
                    Knit.stitches(ctx, rect: rect, sw: sw, sh: sh, seed: 1) { c, r in
                        cw.yarn(c, min(max(r, 0), n - 1), n)
                    }
                    Knit.shadeAcross(ctx, rect: rect, horizontal: false)
                }
            }
        }
    }

    /// A hanging tail with a fringe at the bottom.
    static func tail(_ cw: Colourway, length: CGFloat, T: CGFloat, seed: Int, scale: CGFloat) -> CGImage? {
        cached("tail|\(cw.id)|\(length)|\(T)|\(seed)|\(scale)") {
            Knit.image(size: tailSize(length: length, T: T), scale: scale) { ctx in
                let n = 8
                let sw = T / CGFloat(n), sh = sw * 0.82
                let rows = Int(ceil(length / sh))
                let rect = CGRect(x: Knit.pad, y: Knit.pad, width: T, height: length)
                let F = fringeLength(T)

                // Fringe first, so the knitted end sits on top of the knots.
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -2 * scale), blur: 4 * scale,
                              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3))
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.setLineCap(.round)
                for col in 0..<n {
                    let yarn = cw.fringe.map { cw.yarns[$0] } ?? cw.yarn(rows + seed, col, n)
                    for s in 0..<2 {
                        let x = rect.minX + (CGFloat(col) + 0.3 + 0.4 * CGFloat(s)) * sw
                        let k = noise01(col, s, seed + 5) - 0.5
                        let len = F * (0.86 + 0.28 * noise01(col, s, seed + 9) - 0.14)
                        let top = CGPoint(x: x, y: rect.maxY - sh)
                        let path = CGMutablePath()
                        path.move(to: top)
                        path.addCurve(
                            to: CGPoint(x: x + k * sw * 1.6, y: rect.maxY + len),
                            control1: CGPoint(x: x + k * sw * 0.8, y: rect.maxY + len * 0.35),
                            control2: CGPoint(x: x - k * sw * 0.6, y: rect.maxY + len * 0.7)
                        )
                        ctx.addPath(path); ctx.setStrokeColor(yarn.shade(0.6).cg)
                        ctx.setLineWidth(sw * 0.5); ctx.strokePath()
                        ctx.addPath(path); ctx.setStrokeColor(yarn.cg)
                        ctx.setLineWidth(sw * 0.3); ctx.strokePath()
                        ctx.addPath(path); ctx.setStrokeColor(yarn.lighten(0.2).cg)
                        ctx.setLineWidth(sw * 0.1); ctx.strokePath()
                    }
                }
                ctx.endTransparencyLayer()
                ctx.restoreGState()

                let shape = CGPath(roundedRect: rect, cornerWidth: T * 0.16, cornerHeight: T * 0.16, transform: nil)
                Knit.piece(ctx, shape: shape, gap: cw.gap, scale: scale) { ctx in
                    Knit.stitches(ctx, rect: rect, sw: sw, sh: sh, seed: seed + 2) { c, r in
                        cw.yarn(r + seed, min(max(c, 0), n - 1), n)
                    }
                    Knit.shadeAcross(ctx, rect: rect, horizontal: true)
                    // A little gathered rib where the fringe is tied on.
                    let rib = CGRect(x: rect.minX, y: rect.maxY - sh * 1.2, width: rect.width, height: sh * 1.2)
                    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.16))
                    ctx.fill(rib)
                }
            }
        }
    }

    /// The knot where the scarf is tied, at one top corner.
    static func knot(_ cw: Colourway, T: CGFloat, scale: CGFloat) -> CGImage? {
        cached("knot|\(cw.id)|\(T)|\(scale)") {
            let size = knotSize(T: T)
            return Knit.image(size: size, scale: scale) { ctx in
                let rect = CGRect(x: Knit.pad, y: Knit.pad,
                                  width: size.width - 2 * Knit.pad, height: size.height - 2 * Knit.pad)
                let shape = CGPath(ellipseIn: rect, transform: nil)
                let n = 10
                let sh = T / CGFloat(n), sw = sh / 0.82
                Knit.piece(ctx, shape: shape, gap: cw.gap, scale: scale) { ctx in
                    Knit.stitches(ctx, rect: rect, sw: sw, sh: sh, seed: 4) { c, r in
                        cw.yarn(c + 5, min(max(r, 0), n - 1), n)
                    }
                    let colors = [
                        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10),
                        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0),
                        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5),
                    ] as CFArray
                    if let g = CGGradient(colorsSpace: Knit.sRGB, colors: colors, locations: [0, 0.45, 1]) {
                        let c = CGPoint(x: rect.midX - rect.width * 0.08, y: rect.midY - rect.height * 0.14)
                        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c,
                                               endRadius: max(rect.width, rect.height) * 0.62,
                                               options: [.drawsAfterEndLocation])
                    }
                    // Folds where the scarf wraps through itself.
                    ctx.setLineCap(.round)
                    for (from, ctrl, to) in [
                        (CGPoint(x: 0.30, y: 0.12), CGPoint(x: 0.12, y: 0.5), CGPoint(x: 0.34, y: 0.9)),
                        (CGPoint(x: 0.70, y: 0.12), CGPoint(x: 0.88, y: 0.5), CGPoint(x: 0.66, y: 0.9)),
                    ] {
                        let p = CGMutablePath()
                        func pt(_ u: CGPoint) -> CGPoint {
                            CGPoint(x: rect.minX + u.x * rect.width, y: rect.minY + u.y * rect.height)
                        }
                        p.move(to: pt(from))
                        p.addQuadCurve(to: pt(to), control: pt(ctrl))
                        ctx.addPath(p)
                        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.32))
                        ctx.setLineWidth(max(1.2, T * 0.07))
                        ctx.strokePath()
                    }
                }
            }
        }
    }
}
