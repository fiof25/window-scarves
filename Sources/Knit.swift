import CoreGraphics
import Foundation

// MARK: - Curves

struct PathSample {
    var p: CGPoint
    /// Unit tangent: the direction the scarf travels.
    var t: CGVector
    /// Arc length from the start.
    var s: CGFloat
    /// Unit normal, 90° clockwise on screen from the tangent.
    var n: CGVector { CGVector(dx: -t.dy, dy: t.dx) }
}

func cubic(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint, steps: Int = 64) -> [CGPoint] {
    (0...steps).map { k in
        let u = CGFloat(k) / CGFloat(steps), v = 1 - u
        let a = v * v * v, b = 3 * v * v * u, c = 3 * v * u * u, d = u * u * u
        return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p3.x,
                       y: a * p0.y + b * c1.y + c * c2.y + d * p3.y)
    }
}

func boundingBox(_ pts: [CGPoint]) -> CGRect {
    guard let f = pts.first else { return .zero }
    var r = CGRect(origin: f, size: .zero)
    for p in pts { r = r.union(CGRect(origin: p, size: .zero)) }
    return r
}

/// A centreline resampled every 1pt, so stitches can be laid along it.
struct Tube {
    let samples: [PathSample]
    var length: CGFloat { samples.last?.s ?? 0 }

    init(_ pts: [CGPoint]) {
        var out: [PathSample] = []
        var acc: CGFloat = 0, next: CGFloat = 0
        for (a, b) in zip(pts, pts.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let len = hypot(dx, dy)
            if len < 1e-6 { continue }
            let t = CGVector(dx: dx / len, dy: dy / len)
            while next <= acc + len {
                let f = (next - acc) / len
                out.append(PathSample(p: CGPoint(x: a.x + dx * f, y: a.y + dy * f), t: t, s: next))
                next += 1
            }
            acc += len
        }
        if let last = pts.last, let lt = out.last?.t {
            out.append(PathSample(p: last, t: lt, s: acc))
        }
        // Smooth the tangents so stitches turn gracefully round bends.
        var smooth = out
        for i in out.indices {
            var dx: CGFloat = 0, dy: CGFloat = 0
            for k in max(0, i - 4)...min(out.count - 1, i + 4) { dx += out[k].t.dx; dy += out[k].t.dy }
            let l = hypot(dx, dy)
            if l > 0 { smooth[i].t = CGVector(dx: dx / l, dy: dy / l) }
        }
        samples = smooth
    }

    /// The point at arc length `s`, extended in a straight line past either end.
    func at(_ s: CGFloat) -> PathSample {
        guard var q = samples.first else { return PathSample(p: .zero, t: CGVector(dx: 0, dy: 1), s: 0) }
        if s <= 0 {
            q.p = CGPoint(x: q.p.x + q.t.dx * s, y: q.p.y + q.t.dy * s); q.s = s
            return q
        }
        if s >= length {
            q = samples[samples.count - 1]
            let d = s - length
            q.p = CGPoint(x: q.p.x + q.t.dx * d, y: q.p.y + q.t.dy * d); q.s = s
            return q
        }
        return samples[min(Int(s), samples.count - 1)]
    }

    /// The outline of the scarf, whose width may vary along its length.
    func outline(width: (CGFloat) -> CGFloat) -> (path: CGPath, edge: [CGPoint]) {
        var left: [CGPoint] = [], right: [CGPoint] = []
        var s: CGFloat = 0
        while true {
            let q = at(s), n = q.n, half = width(s) / 2
            left.append(CGPoint(x: q.p.x + n.dx * half, y: q.p.y + n.dy * half))
            right.append(CGPoint(x: q.p.x - n.dx * half, y: q.p.y - n.dy * half))
            if s >= length { break }
            s = min(length, s + 1.5)
        }
        let path = CGMutablePath()
        path.addLines(between: left + right.reversed())
        path.closeSubpath()
        return (path, left + right)
    }
}

// MARK: - Knitting

enum Knit {
    static let pad: CGFloat = 10
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

    /// Height of one row for a scarf `width` wide in the given texture.
    static func rowHeight(_ width: CGFloat, _ texture: Texture) -> CGFloat {
        width / CGFloat(texture.across) * texture.rowRatio
    }

    static func black(_ a: CGFloat) -> CGColor { CGColor(srgbRed: 0, green: 0, blue: 0, alpha: a) }

    /// One knit stitch: a soft V whose point faces along the context's +y axis.
    private static func vStitch(_ ctx: CGContext, sw: CGFloat, sh: CGFloat, yarn: Yarn, contrast: CGFloat) {
        let ew = 0.6 * sw, eh = 1.42 * sh
        let outer = CGRect(x: -ew / 2, y: -eh / 2, width: ew, height: eh)
        let inner = CGRect(x: -ew * 0.37, y: -eh * 0.46, width: ew * 0.74, height: eh * 0.84)
        let shine = CGRect(x: -ew * 0.18, y: -eh * 0.38, width: ew * 0.3, height: eh * 0.4)
        let dark = yarn.shade(1 - 0.14 * contrast).cg, mid = yarn.cg, light = yarn.lighten(0.13 * contrast).cg
        for side in [-1.0, 1.0] as [CGFloat] {
            ctx.saveGState()
            ctx.translateBy(x: side * 0.23 * sw, y: 0)
            ctx.rotate(by: side * 0.5)
            ctx.setFillColor(dark); ctx.fillEllipse(in: outer)
            ctx.setFillColor(mid); ctx.fillEllipse(in: inner)
            ctx.setFillColor(light); ctx.fillEllipse(in: shine)
            ctx.restoreGState()
        }
    }

    /// Make a whole scarf along `tube`. Only the part near `visible` is drawn, so the same
    /// scarf can be rendered into several images that line up exactly.
    static func scarf(
        _ ctx: CGContext, _ tube: Tube, width: (CGFloat) -> CGFloat, visible: CGRect, scale: CGFloat,
        colourway cw: Colourway, colour: (_ row: Int, _ j: Int) -> Yarn
    ) {
        let texture = cw.texture
        let n = texture.across
        let o = tube.outline(width: width)

        // A soft shadow, and the colour between stitches.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3 * scale), blur: 9 * scale, color: black(0.22))
        ctx.addPath(o.path)
        ctx.setFillColor(cw.gap.cg)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(o.path)
        ctx.clip()
        let base = width(0)
        let sh = rowHeight(base, texture)
        let near = visible.insetBy(dx: -base, dy: -base)
        let rows = Int(ceil(tube.length / sh))
        // Brushed fibres are collected and drawn over the stitches.
        var wisps: [(CGPoint, CGPoint, Yarn)] = []
        for r in -1...(rows + 1) {
            let s = (CGFloat(r) + 0.5) * sh
            let q = tube.at(s)
            guard near.contains(q.p) else { continue }
            let nv = q.n, W = width(s), sw = W / CGFloat(n)
            let angle = atan2(-q.t.dx, q.t.dy)
            for j in 0..<n {
                let u = (CGFloat(j) + 0.5) / CGFloat(n) * 2 - 1
                let a = u * W / 2
                // Flat, soft fabric: barely darker at the edges, with slanting ripples.
                let ripple = 0.05 * sin(2 * .pi * (s + 0.9 * a) / (2.3 * base))
                    + 0.028 * sin(2 * .pi * (s - 0.5 * a) / (0.9 * base) + 2)
                let light = 1.03 - 0.09 * u * u - 0.03 * u * nv.dy + ripple
                let grain = 1 - cw.heather / 2 + cw.heather * noise01(r, j, 17)
                let y = colour(r, j).shade(light * grain)
                let c = CGPoint(x: q.p.x + nv.dx * a, y: q.p.y + nv.dy * a)
                ctx.saveGState()
                ctx.translateBy(x: c.x, y: c.y)
                ctx.rotate(by: angle)
                switch texture {
                case .knit:
                    vStitch(ctx, sw: sw, sh: sh, yarn: y, contrast: 1)
                case .rib:
                    // Fat stitches, each column rounded so the grooves between them read as ribs.
                    vStitch(ctx, sw: sw * 0.96, sh: sh * 1.08, yarn: y, contrast: 1.5)
                case .mohair:
                    // A soft-edged dab of colour, so neighbouring colours melt together.
                    ctx.setFillColor(y.cg(alpha: 0.9))
                    ctx.fillEllipse(in: CGRect(x: -sw * 0.8, y: -sh * 1.1, width: sw * 1.6, height: sh * 2.2))
                    ctx.setFillColor(y.lighten(0.1).cg(alpha: 0.35))
                    ctx.fillEllipse(in: CGRect(x: -sw * 0.4, y: -sh * 0.5, width: sw * 0.5, height: sh * 0.7))
                }
                ctx.restoreGState()

                // Fibres lying on the surface: a few for knits, a thick brushed pile for mohair.
                let count = texture == .mohair ? 3 : (noise01(r, j, 23) < 0.7 ? 1 : 0)
                for k in 0..<count {
                    let along = atan2(q.t.dy, q.t.dx)
                    let dir = texture == .mohair
                        ? along + (noise01(r, j, 29 + k) - 0.5) * 1.9
                        : noise01(r, j, 29) * 2 * .pi
                    let len = sw * (texture == .mohair ? 1.4 + 2.6 * noise01(r, j, 31 + k) : 0.7 + 1.3 * noise01(r, j, 31))
                    let ox = (noise01(r, j, 41 + k) - 0.5) * sw, oy = (noise01(r, j, 47 + k) - 0.5) * sh
                    let from = CGPoint(x: c.x + ox, y: c.y + oy)
                    wisps.append((from, CGPoint(x: from.x + cos(dir) * len, y: from.y + sin(dir) * len), y))
                }
            }
        }
        ctx.setLineCap(.round)
        ctx.setLineWidth(0.5)
        if texture == .mohair {
            for (from, to, y) in wisps {
                ctx.move(to: from); ctx.addLine(to: to)
                ctx.setStrokeColor(y.lighten(0.3).cg(alpha: 0.5))
                ctx.strokePath()
            }
        } else {
            for (from, to, _) in wisps { ctx.move(to: from); ctx.addLine(to: to) }
            ctx.setStrokeColor(cw.fuzz.cg(alpha: 0.2))
            ctx.strokePath()
        }
        ctx.restoreGState()

        // A fuzzy halo round the edge; mohair gets a much bigger one.
        let hairs = texture == .mohair ? 4 : 2
        let reach: CGFloat = texture == .mohair ? 7 : 3.5
        let halo = CGMutablePath()
        for (k, p) in o.edge.enumerated() where near.contains(p) {
            for h in 0..<hairs {
                let a = noise01(k, h, 1) * 2 * .pi
                let l = 1.5 + reach * noise01(k, h, 2) * noise01(k, h, 3)
                halo.move(to: p)
                halo.addLine(to: CGPoint(x: p.x + cos(a) * l, y: p.y + sin(a) * l))
            }
        }
        ctx.saveGState()
        ctx.addPath(halo)
        ctx.setStrokeColor(cw.fuzz.cg(alpha: texture == .mohair ? 0.42 : 0.38))
        ctx.setLineWidth(0.5)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Fringe at one end of the scarf, flowing on in the direction the end points.
    /// `colour` gives each strand's yarn from its position across the scarf (0...1).
    static func fringe(_ ctx: CGContext, _ tube: Tube, atStart: Bool, width W: CGFloat, length F: CGFloat,
                       style: FringeStyle, colour: (CGFloat) -> Yarn, scale: CGFloat, seed: Int) {
        let q = tube.at(atStart ? 0 : tube.length), nv = q.n
        let f: CGFloat = atStart ? -1 : 1
        let t = CGVector(dx: q.t.dx * f, dy: q.t.dy * f)
        let strands: Int, ws: CGFloat, reach: CGFloat, wave: CGFloat
        switch style {
        case .wispy: strands = 9; ws = W * 0.085; reach = 1; wave = 1
        case .chunky: strands = 6; ws = W * 0.135; reach = 0.78; wave = 0.6
        case .long: strands = 17; ws = W * 0.042; reach = 1.45; wave = 1.5
        }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2 * scale), blur: 5 * scale, color: black(0.18))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setLineCap(.round)
        for k in 0..<strands {
            let frac = (CGFloat(k) + 0.5) / CGFloat(strands)
            let u = frac * 2 - 1
            let a = u * W * 0.45
            let yarn = colour(frac)
            let base = CGPoint(x: q.p.x + nv.dx * a - t.dx * W * 0.12, y: q.p.y + nv.dy * a - t.dy * W * 0.12)
            let wob = (noise01(k, seed, 3) - 0.5) * wave
            let len = F * reach * (0.75 + 0.4 * noise01(k, seed, 5))
            func pt(_ along: CGFloat, _ side: CGFloat) -> CGPoint {
                CGPoint(x: base.x + t.dx * along + nv.dx * side, y: base.y + t.dy * along + nv.dy * side)
            }
            let path = CGMutablePath()
            path.move(to: base)
            path.addCurve(to: pt(len, wob * W * 0.45 + u * W * 0.08), control1: pt(len * 0.35, wob * W * 0.3),
                          control2: pt(len * 0.7, -wob * W * 0.2))
            for (width, shade) in [(ws, yarn.shade(0.84)), (ws * 0.62, yarn), (ws * 0.2, yarn.lighten(0.2))] {
                ctx.addPath(path)
                ctx.setStrokeColor(shade.cg)
                ctx.setLineWidth(width)
                ctx.strokePath()
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

// MARK: - Scarf images

/// Renders (and caches) images of the scarf described by a `ScarfGeometry`.
enum ScarfArt {
    private static var cache: [String: CGImage] = [:]

    static func clearCache() { cache.removeAll() }

    /// The part of the scarf inside `rect` (window-local coordinates).
    static func piece(_ cw: Colourway, _ g: ScarfGeometry, rect: CGRect, key: String, scale: CGFloat) -> CGImage? {
        let cacheKey = "\(key)|\(cw.id)|\(g.key)|\(scale)"
        if let c = cache[cacheKey] { return c }
        if cache.count > 48 { cache.removeAll() }
        let img = Knit.image(size: rect.size, scale: scale) { ctx in
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
            let tube = g.tube
            let n = cw.texture.across
            let rows = Int(ceil(tube.length / Knit.rowHeight(g.width(at: 0), cw.texture)))
            // Rows are counted from the nearer end, so both ends get the same stripes.
            let colour = { (r: Int, j: Int) in cw.colour(r, j, n, min(r, rows - 1 - r)) }
            for atStart in [true, false] {
                let row = atStart ? 0 : rows - 1
                Knit.fringe(ctx, tube, atStart: atStart, width: g.width(at: atStart ? 0 : tube.length),
                            length: g.fringeLength, style: cw.fringe,
                            colour: { colour(row, min(n - 1, Int($0 * CGFloat(n)))) },
                            scale: scale, seed: atStart ? 1 : 2)
            }
            Knit.scarf(ctx, tube, width: g.width(at:), visible: rect, scale: scale, colourway: cw, colour: colour)
        }
        cache[cacheKey] = img
        return img
    }
}
