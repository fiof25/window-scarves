import CoreGraphics

enum KnotSide: String, CaseIterable {
    case right, left
    var title: String { self == .right ? "On the Right" : "On the Left" }
}

enum Thickness: String, CaseIterable {
    case slim, cosy, chunky
    var points: CGFloat {
        switch self {
        case .slim: return 24
        case .cosy: return 32
        case .chunky: return 40
        }
    }
    var title: String {
        switch self {
        case .slim: return "Slim"
        case .cosy: return "Cosy"
        case .chunky: return "Chunky"
        }
    }
}

/// How a scarf drapes over a window of width `w`. Coordinates are window-local,
/// top-left origin, y down.
///
/// One continuous strand: a loose end pokes out above the far top corner, the scarf sags
/// across the top of the window, goes up and over the near top corner, and hangs down that
/// side. (`side` is the side it hangs down.)
struct ScarfGeometry {
    let w: CGFloat, T: CGFloat, side: KnotSide, tailLength: CGFloat

    let path: [CGPoint]
    let tube: Tube
    /// Below this y only the hanging end exists, so the scarf can be cut into two images there.
    let split: CGFloat
    /// The lowest the scarf dips before it reaches the hanging end.
    private let dip: CGFloat

    var fringeLength: CGFloat { (T * 0.95).rounded() }
    /// Room around the centreline for half the width, fuzz, fringe and shadow.
    var margin: CGFloat { T * 0.62 + fringeLength + Knit.pad + 6 }

    init(w: CGFloat, T: CGFloat, side: KnotSide, tailLength L: CGFloat) {
        self.w = w; self.T = T; self.side = side; self.tailLength = L
        let mirror = side == .left
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: mirror ? w - x : x, y: y) }

        let steps = max(32, Int(w / 10))
        // The loose end, then the sag across the top.
        let start = P(-2.6 * T, -2.0 * T)
        let c2 = P(0.65 * w, 2.2 * T)
        let corner = P(w + 0.9 * T, -1.05 * T)
        let sweep = cubic(start, P(0.15 * w, 2.6 * T), c2, corner, steps: steps)
        // Up and over the corner...
        var dx = corner.x - c2.x, dy = corner.y - c2.y
        let d = max(1, hypot(dx, dy)); dx /= d; dy /= d
        let top = P(w + 2.1 * T, -0.1 * T)
        let over = cubic(corner, CGPoint(x: corner.x + dx * 0.9 * T, y: corner.y + dy * 0.9 * T),
                         P(w + 2.35 * T, -1.0 * T), top, steps: 24)
        // ...and hanging down the side, drifting back towards the window.
        let hang = cubic(top, P(w + 2.0 * T, 0.4 * L), P(w + 1.1 * T, 0.75 * L), P(w + 0.8 * T, L), steps: 48)

        path = sweep + over.dropFirst() + hang.dropFirst()
        tube = Tube(path)
        dip = (sweep + over).map(\.y).max() ?? 0
        split = (dip + T * 0.62 + 18).rounded()
    }

    /// The scarf's width along its length: it ripples a little, like soft fabric.
    func width(at s: CGFloat) -> CGFloat {
        T * (1 + 0.05 * sin(2 * .pi * s / (3.1 * T)) + 0.03 * sin(2 * .pi * s / (1.7 * T) + 1))
    }

    private var fullRect: CGRect { boundingBox(path).insetBy(dx: -margin, dy: -margin).integral }

    /// Everything above `split`: the loose end, the sag and the corner.
    var topRect: CGRect {
        let r = fullRect
        return CGRect(x: r.minX, y: r.minY, width: r.width, height: split - r.minY)
    }

    /// The hanging end below `split`.
    var hangRect: CGRect {
        let r = fullRect
        // Only the hanging end goes lower than the dip, so this picks out just that end.
        let below = path.filter { $0.y > dip + 1 }
        let b = boundingBox(below.isEmpty ? [CGPoint(x: r.maxX, y: split)] : below)
        return CGRect(x: floor(b.minX - margin), y: split,
                      width: ceil(b.width + 2 * margin), height: max(1, r.maxY - split))
    }
}

enum PieceRole { case top, hang }

/// Where one scarf image sits relative to its window.
///
/// Coordinates are window-local, top-left origin, y down.
/// `angle` is in radians; positive means the bottom of the piece swings to the right.
struct Placement {
    var role: PieceRole
    var size: CGSize
    /// The pivot inside the piece image, in unit coordinates (top-left origin).
    var anchorUnit: CGPoint
    /// Where that pivot sits, relative to the window's top-left corner.
    var anchor: CGPoint
    var angle: CGFloat
    /// Sway amplitude in radians (0 = still).
    var sway: CGFloat
    var period: Double
    /// The geometry this piece was cut from.
    var w: CGFloat, T: CGFloat, side: KnotSide, tailLength: CGFloat
}

enum ScarfLayout {
    static func tailLength(height h: CGFloat, T: CGFloat) -> CGFloat {
        let raw = min(max(h * 0.62, 4 * T), 15 * T)
        return (raw / 4).rounded() * 4
    }

    /// The scarf, cut into two images that sit side by side without overlapping.
    static func placements(size: CGSize, T: CGFloat, side: KnotSide, tailLength: CGFloat) -> [Placement] {
        let g = ScarfGeometry(w: size.width, T: T, side: side, tailLength: tailLength)
        return [(PieceRole.top, g.topRect), (.hang, g.hangRect)].map { role, r in
            Placement(role: role, size: r.size, anchorUnit: .zero, anchor: r.origin, angle: 0, sway: 0,
                      period: 0, w: size.width, T: T, side: side, tailLength: tailLength)
        }
    }

    /// The smallest rect (window-local, top-left origin) holding the window and every piece.
    static func extents(_ ps: [Placement], window: CGSize) -> CGRect {
        var r = CGRect(origin: .zero, size: window)
        for p in ps {
            let x0 = -p.anchorUnit.x * p.size.width, y0 = -p.anchorUnit.y * p.size.height
            let corners = [
                CGPoint(x: x0, y: y0), CGPoint(x: x0 + p.size.width, y: y0),
                CGPoint(x: x0, y: y0 + p.size.height), CGPoint(x: x0 + p.size.width, y: y0 + p.size.height),
            ]
            for a in [p.angle - p.sway, p.angle, p.angle + p.sway] {
                let c = cos(a), s = sin(a)
                for q in corners {
                    let pt = CGPoint(x: p.anchor.x + q.x * c + q.y * s, y: p.anchor.y - q.x * s + q.y * c)
                    r = r.union(CGRect(origin: pt, size: .zero))
                }
            }
        }
        return r.insetBy(dx: -2, dy: -2).integral
    }

    /// How much room the hanging end needs beside the window.
    static func roomNeeded(T: CGFloat) -> CGFloat { 3 * T }

    static func image(for p: Placement, colourway cw: Colourway, scale: CGFloat) -> CGImage? {
        let g = ScarfGeometry(w: p.w, T: p.T, side: p.side, tailLength: p.tailLength)
        return ScarfArt.piece(cw, g, rect: p.role == .top ? g.topRect : g.hangRect,
                              key: "\(p.role)", scale: scale)
    }
}
