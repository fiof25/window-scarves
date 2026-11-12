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

    /// Set the fill colour directly, without making a colour object. This runs for every
    /// stitch, on several threads at once, and colour objects are slow to create there.
    @inline(__always) private static func fill(_ ctx: CGContext, _ y: Yarn, alpha: CGFloat = 1) {
        ctx.setFillColor(red: y.r, green: y.g, blue: y.b, alpha: alpha)
    }

    /// Held while drawing anything see-through (shadows, fuzz, mohair's soft dabs).
    ///
    /// On macOS, drawing see-through shapes on several threads at once can corrupt pixels,
    /// even when every thread has its own canvas. Solid shapes are unaffected. So solid
    /// stitches are knitted in parallel, and see-through drawing takes turns behind this lock.
    static let seeThrough = NSLock()

    static func black(_ a: CGFloat) -> CGColor { CGColor(srgbRed: 0, green: 0, blue: 0, alpha: a) }

    /// The outline of one knit stitch (a soft V of two leaning loops), built once per scarf and
    /// reused for every stitch. Each of its three layers holds both loops, so a stitch takes
    /// three fills rather than six.
    private struct StitchShape {
        let rim: CGPath, body: CGPath, shine: CGPath

        init(sw: CGFloat, sh: CGFloat) {
            let ew = 0.6 * sw, eh = 1.42 * sh
            func pair(_ r: CGRect) -> CGPath {
                let p = CGMutablePath()
                for side in [-1.0, 1.0] as [CGFloat] {
                    p.addEllipse(in: r, transform: CGAffineTransform(translationX: side * 0.23 * sw, y: 0)
                        .rotated(by: side * 0.5))
                }
                return p
            }
            rim = pair(CGRect(x: -ew / 2, y: -eh / 2, width: ew, height: eh))
            body = pair(CGRect(x: -ew * 0.37, y: -eh * 0.46, width: ew * 0.74, height: eh * 0.84))
            shine = pair(CGRect(x: -ew * 0.18, y: -eh * 0.38, width: ew * 0.3, height: eh * 0.4))
        }
    }

    /// Draw one knit stitch, its point facing along the context's +y axis. `size` scales the
    /// shape for rows where the scarf is a little wider or narrower.
    private static func vStitch(_ ctx: CGContext, _ shape: StitchShape, size: CGFloat, yarn: Yarn,
                                contrast: CGFloat, shadow: Yarn? = nil, shine showShine: Bool = true) {
        // The rim of each stitch: normally a darker shade, or a blend towards a given shadow tone.
        let rim = shadow.map { yarn.mix($0, 0.5 * contrast) } ?? yarn.shade(1 - 0.14 * contrast)
        ctx.scaleBy(x: size, y: size)
        fill(ctx, rim); ctx.addPath(shape.rim); ctx.fillPath()
        fill(ctx, yarn); ctx.addPath(shape.body); ctx.fillPath()
        if showShine {
            fill(ctx, yarn.lighten(0.13 * contrast)); ctx.addPath(shape.shine); ctx.fillPath()
        }
    }

    /// One stitch in a row: which column's colour it takes, where it sits across the scarf
    /// (in stitch widths from the edge), how far it leans, and how brightly it's lit.
    private struct Slot {
        enum Kind { case plain, purl, over }
        var j: Int
        var x: CGFloat
        var lean: CGFloat = 0
        var shade: CGFloat = 1
        /// How far the stitch is tinted towards the scarf's warm shadow tone (0 = not at all).
        var tint: CGFloat = 0
        var kind: Kind = .plain
    }

    /// The stitches in one row of cable knit: three slim rope cables, each four stitches wide,
    /// with a narrow groove either side of each. In every cable the two strands keep crossing:
    /// one pair travels across over the top while the other travels back underneath. The middle
    /// cable twists the opposite way, and the crossings are staggered, like a hand-knit Aran.
    private static func cableRow(_ r: Int, sw: CGFloat, sh: CGFloat) -> [Slot] {
        let period = 8
        let groove: CGFloat = 0.6, stitch: CGFloat = 1.1          // widths, in average stitch widths
        let total = 4 * groove + 12 * stitch
        let unit = 16 / total                                      // so the row spans the full width
        var row: [Slot] = []
        var under: [Slot] = [], over: [Slot] = []
        var x: CGFloat = 0
        for cable in 0..<3 {
            row.append(Slot(j: cable * 5, x: (x + groove / 2) * unit, tint: 0.45, kind: .purl))
            x += groove
            let phase = CGFloat(pmod(r + cable * 3, period)) / CGFloat(period)
            let t = min(max((phase - 0.15) / 0.7, 0), 1)
            let crossed = t * t * (3 - 2 * t)                               // 0 → 1 through the crossing
            let slope = 2 * stitch * (6 * t * (1 - t) / 0.7) / CGFloat(period)   // sideways per row
            let lean = atan(slope * unit * sw / sh)
            let mirrored = cable == 1
            for k in 0..<2 {
                // One pair starts on the near side and crosses over the top; the other starts on
                // the far side and crosses back underneath, in shadow where it passes below.
                let near = (CGFloat(k) + 0.5) * stitch + 2 * stitch * crossed
                let far = (CGFloat(k) + 2.5) * stitch - 2 * stitch * crossed
                let top = mirrored ? 4 * stitch - near : near
                let bottom = mirrored ? 4 * stitch - far : far
                let j = cable * 5 + 1 + k
                over.append(Slot(j: j, x: (x + top) * unit, lean: mirrored ? lean : -lean, shade: 1.04, kind: .over))
                under.append(Slot(j: j + 2, x: (x + bottom) * unit, lean: mirrored ? -lean : lean,
                                  tint: 0.55 * sin(.pi * t)))
            }
            x += 4 * stitch
        }
        row.append(Slot(j: 15, x: (x + groove / 2) * unit, tint: 0.45, kind: .purl))
        return row + under + over
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
        seeThrough.lock()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3 * scale), blur: 9 * scale, color: black(0.22))
        ctx.addPath(o.path)
        ctx.setFillColor(cw.gap.cg)
        ctx.fillPath()
        ctx.restoreGState()
        seeThrough.unlock()

        ctx.saveGState()
        ctx.addPath(o.path)
        ctx.clip()
        let base = width(0)
        let sh = rowHeight(base, texture)
        let near = visible.insetBy(dx: -base, dy: -base)
        let rows = Int(ceil(tube.length / sh))
        // Brushed fibres are collected and drawn over the stitches.
        var wisps: [(from: CGPoint, to: CGPoint, yarn: Yarn, row: Int)] = []
        let plain = (0..<n).map { Slot(j: $0, x: CGFloat($0) + 0.5) }
        // The stitch outline for this fabric, at the scarf's nominal width.
        let unit = base / CGFloat(n)
        let stitchShape: StitchShape
        switch texture {
        case .cable: stitchShape = StitchShape(sw: unit * 1.12, sh: sh * 1.14)
        default: stitchShape = StitchShape(sw: unit, sh: sh)
        }
        // A cable is drawn in three passes: everything but the top strands, then a soft shadow
        // under where the top strands will go, then the top strands themselves.
        for pass in 0..<(texture == .cable ? 3 : 1) {
        // Mohair's dabs and the cable's shadows are see-through, so those passes take turns.
        let locked = texture == .mohair || (texture == .cable && pass == 1)
        if locked { seeThrough.lock() }
        for r in -1...(rows + 1) {
            let s = (CGFloat(r) + 0.5) * sh
            let q = tube.at(s)
            guard near.contains(q.p) else { continue }
            let nv = q.n, W = width(s), sw = W / CGFloat(n)
            let angle = atan2(-q.t.dx, q.t.dy)
            let slots = texture == .cable ? cableRow(r, sw: sw, sh: sh).filter { ($0.kind == .over) == (pass > 0) } : plain
            for slot in slots {
                let j = slot.j
                let u = slot.x / CGFloat(n) * 2 - 1
                let a = u * W / 2
                // Flat, soft fabric: barely darker at the edges, with slanting ripples.
                let ripple = 0.05 * sin(2 * .pi * (s + 0.9 * a) / (2.3 * base))
                    + 0.028 * sin(2 * .pi * (s - 0.5 * a) / (0.9 * base) + 2)
                let light = 1.03 - 0.09 * u * u - 0.03 * u * nv.dy + ripple
                let grain = 1 - cw.heather / 2 + cw.heather * noise01(r, j, 17)
                var y = colour(r, j).shade(light * grain * slot.shade)
                if slot.tint > 0 { y = y.mix(cw.warmShadow, slot.tint) }
                let c = CGPoint(x: q.p.x + nv.dx * a, y: q.p.y + nv.dy * a)
                ctx.saveGState()
                ctx.translateBy(x: c.x, y: c.y)
                ctx.rotate(by: angle + slot.lean)
                switch texture {
                case .knit:
                    vStitch(ctx, stitchShape, size: sw / unit, yarn: y, contrast: 1)
                case .mohair:
                    // A soft-edged dab of colour, so neighbouring colours melt together.
                    fill(ctx, y, alpha: 0.9)
                    ctx.fillEllipse(in: CGRect(x: -sw * 0.8, y: -sh * 1.1, width: sw * 1.6, height: sh * 2.2))
                    fill(ctx, y.lighten(0.1), alpha: 0.35)
                    ctx.fillEllipse(in: CGRect(x: -sw * 0.4, y: -sh * 0.5, width: sw * 0.5, height: sh * 0.7))
                case .cable:
                    if slot.kind == .purl {
                        // A small bump down in the groove beside the cable.
                        fill(ctx, y)
                        ctx.fillEllipse(in: CGRect(x: -sw * 0.34, y: -sh * 0.3, width: sw * 0.68, height: sh * 0.6))
                    } else if pass == 1 {
                        // A soft warm shadow under the strand that crosses on top.
                        fill(ctx, cw.warmShadow.shade(0.82), alpha: 0.28)
                        ctx.fillEllipse(in: CGRect(x: -sw * 0.75, y: -sh * 0.35, width: sw * 1.5, height: sh * 1.9))
                    } else {
                        // These stitches are too fine for a highlight to show, so it's skipped.
                        vStitch(ctx, stitchShape, size: sw / unit, yarn: y, contrast: 0.85,
                                shadow: cw.warmShadow, shine: false)
                    }
                }
                ctx.restoreGState()

                // Fibres lying on the surface: a few for knits, a thick brushed pile for mohair.
                if pass == 1 { continue }   // the cable's shadow pass adds no fibres of its own
                let count = texture == .mohair ? 3 : (noise01(r, j, 23) < 0.7 ? 1 : 0)
                for k in 0..<count {
                    let along = atan2(q.t.dy, q.t.dx)
                    let dir = texture == .mohair
                        ? along + (noise01(r, j, 29 + k) - 0.5) * 1.9
                        : noise01(r, j, 29) * 2 * .pi
                    let len = sw * (texture == .mohair ? 1.4 + 2.6 * noise01(r, j, 31 + k) : 0.7 + 1.3 * noise01(r, j, 31))
                    let ox = (noise01(r, j, 41 + k) - 0.5) * sw, oy = (noise01(r, j, 47 + k) - 0.5) * sh
                    let from = CGPoint(x: c.x + ox, y: c.y + oy)
                    wisps.append((from, CGPoint(x: from.x + cos(dir) * len, y: from.y + sin(dir) * len), y, r))
                }
            }
        }
        if locked { seeThrough.unlock() }
        }
        // Fibres are drawn in small batches, each a fixed stretch of the scarf. That keeps every
        // batch identical however the scarf is cut into pieces, so the pieces join exactly.
        seeThrough.lock()
        defer { seeThrough.unlock() }
        ctx.setLineCap(.round)
        ctx.setLineWidth(0.5)
        var batches: [Int: CGMutablePath] = [:]
        for w in wisps {
            // Mohair fibres take the (rounded) colour of the cell they lie on; knits use one colour.
            let colour = texture == .mohair
                ? Int(w.yarn.r * 24) << 16 | Int(w.yarn.g * 24) << 8 | Int(w.yarn.b * 24) : 0
            let key = (w.row + 8) / 16 << 24 | colour
            let path = batches[key] ?? CGMutablePath()
            path.move(to: w.from)
            path.addLine(to: w.to)
            batches[key] = path
        }
        for key in batches.keys.sorted() {
            guard let path = batches[key] else { continue }
            if texture == .mohair {
                let c = key & 0xFFFFFF
                let h = Yarn(r: (CGFloat(c >> 16) + 0.5) / 24, g: (CGFloat(c >> 8 & 0xFF) + 0.5) / 24,
                             b: (CGFloat(c & 0xFF) + 0.5) / 24).lighten(0.3)
                ctx.setStrokeColor(red: h.r, green: h.g, blue: h.b, alpha: 0.5)
            } else {
                ctx.setStrokeColor(red: cw.fuzz.r, green: cw.fuzz.g, blue: cw.fuzz.b, alpha: 0.2)
            }
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()

        // A fuzzy halo round the edge; mohair gets a much bigger one. Batched the same way.
        let hairs = texture == .mohair ? 4 : 2
        let reach: CGFloat = texture == .mohair ? 7 : 3.5
        ctx.saveGState()
        ctx.setStrokeColor(red: cw.fuzz.r, green: cw.fuzz.g, blue: cw.fuzz.b, alpha: texture == .mohair ? 0.42 : 0.38)
        ctx.setLineWidth(0.5)
        ctx.setLineCap(.round)
        var halo = CGMutablePath(), pending = false
        for (k, p) in o.edge.enumerated() {
            if k % 96 == 0, pending {
                ctx.addPath(halo); ctx.strokePath()
                halo = CGMutablePath(); pending = false
            }
            guard near.contains(p) else { continue }
            for h in 0..<hairs {
                let a = noise01(k, h, 1) * 2 * .pi
                let l = 1.5 + reach * noise01(k, h, 2) * noise01(k, h, 3)
                halo.move(to: p)
                halo.addLine(to: CGPoint(x: p.x + cos(a) * l, y: p.y + sin(a) * l))
            }
            pending = true
        }
        if pending { ctx.addPath(halo); ctx.strokePath() }
        ctx.restoreGState()
    }

    /// Fringe at one end of the scarf, flowing on in the direction the end points.
    /// `colour` gives each strand's yarn from its position across the scarf (0...1).
    static func fringe(_ ctx: CGContext, _ tube: Tube, atStart: Bool, width W: CGFloat, length F: CGFloat,
                       style: FringeStyle, colour: (CGFloat) -> Yarn, seed: Int) {
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
        ctx.setLineCap(.round)
        var paths: [(CGPath, Yarn)] = []
        let all = CGMutablePath()
        for k in 0..<strands {
            let frac = (CGFloat(k) + 0.5) / CGFloat(strands)
            let u = frac * 2 - 1
            let a = u * W * 0.45
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
            paths.append((path, colour(frac)))
            all.addPath(path)
        }
        // A soft shadow under the strands, built from a few wide, faint strokes set slightly lower.
        // (A real blurred shadow here comes out differently depending on the size of the canvas,
        // which would stop separately knitted pieces from matching.)
        seeThrough.lock()
        ctx.saveGState()
        ctx.translateBy(x: 0, y: 2)
        ctx.setStrokeColor(black(0.035))
        for extra in [7.0, 5.0, 3.0, 1.5] as [CGFloat] {
            ctx.addPath(all)
            ctx.setLineWidth(ws + extra)
            ctx.strokePath()
        }
        ctx.restoreGState()
        seeThrough.unlock()
        for (path, yarn) in paths {
            for (width, shade) in [(ws, yarn.shade(0.84)), (ws * 0.62, yarn), (ws * 0.2, yarn.lighten(0.2))] {
                ctx.addPath(path)
                ctx.setStrokeColor(red: shade.r, green: shade.g, blue: shade.b, alpha: 1)
                ctx.setLineWidth(width)
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }
}

// MARK: - Scarf images

/// Renders (and caches) images of the scarf described by a `ScarfGeometry`.
/// Safe to call from several threads at once.
enum ScarfArt {
    private static var cache: [String: CGImage] = [:]
    private static let lock = NSLock()

    static func clearCache() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    /// The part of the scarf inside `rect` (window-local coordinates).
    ///
    /// A large piece is knitted as several strips at the same time, one per processor core,
    /// and the strips are then joined. Each strip draws the same scarf and simply keeps the
    /// part that falls inside it, so the join is exact.
    static func piece(_ cw: Colourway, _ g: ScarfGeometry, rect: CGRect, key: String, scale: CGFloat,
                      parallel: Bool = true) -> CGImage? {
        let cacheKey = "\(key)|\(cw.id)|\(g.key)|\(scale)|\(parallel)"
        lock.lock()
        let hit = cache[cacheKey]
        lock.unlock()
        if let hit { return hit }

        let strips = parallel ? split(rect) : [rect]
        let img: CGImage?
        if strips.count == 1 {
            img = knit(cw, g, rect: rect, scale: scale)
        } else {
            var parts = [CGImage?](repeating: nil, count: strips.count)
            parts.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: strips.count) { i in
                    out[i] = knit(cw, g, rect: strips[i], scale: scale)
                }
            }
            Knit.seeThrough.lock()
            defer { Knit.seeThrough.unlock() }
            img = Knit.image(size: rect.size, scale: scale) { ctx in
                ctx.setBlendMode(.copy)
                ctx.interpolationQuality = .none
                for (part, strip) in zip(parts, strips) {
                    guard let part else { continue }
                    let r = strip.offsetBy(dx: -rect.minX, dy: -rect.minY)
                    ctx.saveGState()
                    ctx.translateBy(x: 0, y: r.minY + r.maxY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(part, in: r)
                    ctx.restoreGState()
                }
            }
        }

        lock.lock()
        if cache.count > 16 { cache.removeAll() }
        cache[cacheKey] = img
        lock.unlock()
        return img
    }

    /// Cut a rect into strips along its longer side, on whole-point boundaries.
    static func split(_ rect: CGRect) -> [CGRect] {
        let wide = rect.width >= rect.height
        let long = wide ? rect.width : rect.height
        let n = min(max(1, Int((long / 320).rounded(.up))), max(1, ProcessInfo.processInfo.activeProcessorCount))
        guard n > 1 else { return [rect] }
        return (0..<n).map { i in
            let a = (long * CGFloat(i) / CGFloat(n)).rounded(), b = (long * CGFloat(i + 1) / CGFloat(n)).rounded()
            return wide
                ? CGRect(x: rect.minX + a, y: rect.minY, width: b - a, height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY + a, width: rect.width, height: b - a)
        }
    }

    /// Draw the part of the scarf that falls inside `rect`.
    private static func knit(_ cw: Colourway, _ g: ScarfGeometry, rect: CGRect, scale: CGFloat) -> CGImage? {
        Knit.image(size: rect.size, scale: scale) { ctx in
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
            let tube = g.tube
            let n = cw.texture.across
            let rows = Int(ceil(tube.length / Knit.rowHeight(g.width(at: 0), cw.texture)))
            // Rows are counted from the nearer end, so both ends get the same stripes.
            let colour = { (r: Int, j: Int) in cw.colour(r, j, n, min(r, rows - 1 - r)) }
            for atStart in [true, false] {
                let row = atStart ? 0 : rows - 1
                // Skip a fringe that's nowhere near this piece; preparing it isn't free.
                let end = tube.at(atStart ? 0 : tube.length).p
                let reach = g.fringeLength * 1.6 + g.T + 24
                guard rect.intersects(CGRect(x: end.x - reach, y: end.y - reach, width: 2 * reach, height: 2 * reach))
                else { continue }
                Knit.fringe(ctx, tube, atStart: atStart, width: g.width(at: atStart ? 0 : tube.length),
                            length: g.fringeLength, style: cw.fringe,
                            colour: { colour(row, min(n - 1, Int($0 * CGFloat(n)))) }, seed: atStart ? 1 : 2)
            }
            Knit.scarf(ctx, tube, width: g.width(at:), visible: rect, scale: scale, colourway: cw, colour: colour)
        }
    }
}
