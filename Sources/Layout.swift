import CoreGraphics

enum KnotSide: String, CaseIterable {
    case right, left
    var title: String { self == .right ? "On the Right" : "On the Left" }
}

enum Thickness: String, CaseIterable {
    case slim, cosy, chunky
    var points: CGFloat {
        switch self {
        case .slim: return 18
        case .cosy: return 24
        case .chunky: return 32
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

enum PieceRole { case band, tailBack, tailFront, knot }

/// Where one scarf piece sits relative to its window.
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
    /// Sway amplitude in radians for the autumn breeze (0 = still).
    var sway: CGFloat
    var period: Double
    var tailLength: CGFloat
}

enum ScarfLayout {
    static func tailLength(height h: CGFloat, T: CGFloat) -> CGFloat {
        let raw = min(max(h * 0.42, 3 * T), 11 * T)
        return (raw / 4).rounded() * 4
    }

    /// Which side the knot goes on, and whether the tails must tuck inside the window
    /// because there's no room beside it on the screen.
    static func fit(preferred: KnotSide, roomLeft: CGFloat, roomRight: CGFloat, T: CGFloat) -> (KnotSide, Bool) {
        let need = 1.1 * T
        let room = { (s: KnotSide) in s == .right ? roomRight : roomLeft }
        if room(preferred) >= need { return (preferred, false) }
        let other: KnotSide = preferred == .right ? .left : .right
        if room(other) >= need { return (other, false) }
        return (preferred, true)
    }

    /// Back-to-front list of pieces for a window of `size`.
    static func placements(size: CGSize, T: CGFloat, side: KnotSide, tailLength: CGFloat,
                           inward: Bool = false) -> [Placement] {
        let w = size.width
        let pad = Knit.pad
        let bandLength = w + 0.9 * T
        let backLength = (tailLength * 0.78 / 4).rounded() * 4
        let backSize = ScarfArt.tailSize(length: backLength, T: T)
        let frontSize = ScarfArt.tailSize(length: tailLength, T: T)

        var ps = [
            Placement(role: .band, size: ScarfArt.bandSize(length: bandLength, T: T),
                      anchorUnit: CGPoint(x: 0.5, y: 0.5), anchor: CGPoint(x: w / 2, y: -0.25 * T),
                      angle: 0, sway: 0, period: 0, tailLength: 0),
            Placement(role: .tailBack, size: backSize,
                      anchorUnit: CGPoint(x: 0.5, y: pad / backSize.height),
                      anchor: CGPoint(x: w + 0.15 * T, y: -0.25 * T),
                      angle: 0.17, sway: 0.035, period: 4.6, tailLength: backLength),
            Placement(role: .tailFront, size: frontSize,
                      anchorUnit: CGPoint(x: 0.5, y: pad / frontSize.height),
                      anchor: CGPoint(x: w - 0.08 * T, y: -0.2 * T),
                      angle: 0.05, sway: 0.028, period: 3.7, tailLength: tailLength),
            Placement(role: .knot, size: ScarfArt.knotSize(T: T),
                      anchorUnit: CGPoint(x: 0.5, y: 0.5), anchor: CGPoint(x: w - 0.05 * T, y: -0.3 * T),
                      angle: -0.12, sway: 0, period: 0, tailLength: 0),
        ]
        if inward {
            // No room beside the window: knot sits just inside the corner, tails hang along the edge.
            ps[1].anchor.x = w - 0.5 * T; ps[1].angle = 0.02
            ps[2].anchor.x = w - 0.85 * T; ps[2].angle = -0.03
            ps[3].anchor.x = w - 0.7 * T
        }
        if side == .left {
            for i in ps.indices {
                ps[i].anchor.x = w - ps[i].anchor.x
                ps[i].angle = -ps[i].angle
            }
        }
        return ps
    }

    /// The smallest rect (window-local, top-left origin) holding the window and every piece,
    /// including how far the tails can swing in the breeze.
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

    static func image(for p: Placement, colourway cw: Colourway, T: CGFloat, scale: CGFloat) -> CGImage? {
        switch p.role {
        case .band: return ScarfArt.band(cw, length: p.size.width - 2 * Knit.pad, T: T, scale: scale)
        case .tailBack: return ScarfArt.tail(cw, length: p.tailLength, T: T, seed: 7, scale: scale)
        case .tailFront: return ScarfArt.tail(cw, length: p.tailLength, T: T, seed: 0, scale: scale)
        case .knot: return ScarfArt.knot(cw, T: T, scale: scale)
        }
    }
}
