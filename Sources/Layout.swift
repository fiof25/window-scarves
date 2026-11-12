import CoreGraphics
import Foundation

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

/// How the scarf is adjusted to fit the space around a window.
struct ScarfFit: Equatable {
    /// How far the long end is tucked inside the window, in points. Normally zero; it grows
    /// when the window is against the edge of the screen with no room beside it.
    var tuck: CGFloat = 0
    /// Whether there's room for the short end on the other side. Without room it's left off,
    /// rather than tucked inside where it would cover the window's buttons.
    var shortEnd = true
    static let roomy = ScarfFit()
}

/// How a scarf is worn by a window of width `w`. Coordinates are window-local,
/// top-left origin, y down.
///
/// One strand, hugging the window like a scarf round a neck: a short end hangs down one side,
/// the scarf comes up over that top corner, runs along the top edge with a slight sag, wraps
/// over the other corner and hangs down that side as the long end. (`side` is the long end.)
struct ScarfGeometry {
    let w: CGFloat, T: CGFloat, side: KnotSide, tailLength: CGFloat, fit: ScarfFit

    let path: [CGPoint]
    let tube: Tube
    /// Disjoint image rects that together hold the whole scarf: the top run first,
    /// then one for each hanging end.
    let rects: [CGRect]

    var fringeLength: CGFloat { (T * 0.95).rounded() }

    /// Identifies this geometry in the image cache.
    var key: String { "\(w)|\(T)|\(side)|\(tailLength)|\(fit.tuck)|\(fit.shortEnd)" }

    init(w: CGFloat, T: CGFloat, side: KnotSide, tailLength L: CGFloat, fit: ScarfFit = .roomy) {
        self.w = w; self.T = T; self.side = side; self.tailLength = L; self.fit = fit
        // Built with the long end on the right, then mirrored if it's on the left.
        let mirror = side == .left
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: mirror ? w - x : x, y: y) }

        // The scarf's centreline sits just outside the window, overlapping its edge a little,
        // so it never reaches the window's own buttons.
        let R = 0.8 * T
        let xL = -0.3 * T
        let xR = max(xL + 2 * R + 1, w + 0.3 * T - fit.tuck)
        let yT = -0.3 * T
        let k = 0.5523 * R
        let short = 2.4 * T

        let shortEnd = cubic(P(xL - 0.12 * T, yT + R + short), P(xL + 0.1 * T, yT + R + 0.66 * short),
                             P(xL - 0.05 * T, yT + R + 0.33 * short), P(xL, yT + R), steps: 20)
        let nearCorner = cubic(P(xL, yT + R), P(xL, yT + R - k), P(xL + R - k, yT), P(xL + R, yT), steps: 18)
        let span = (xR - R) - (xL + R)
        let sag = min(0.35 * T, span * 0.035)
        let top = cubic(P(xL + R, yT), P(xL + R + span * 0.3, yT + sag * 1.33),
                        P(xR - R - span * 0.3, yT + sag * 1.33), P(xR - R, yT), steps: max(24, Int(w / 10)))
        let farCorner = cubic(P(xR - R, yT), P(xR - R + k, yT), P(xR, yT + R - k), P(xR, yT + R), steps: 18)
        let longEnd = cubic(P(xR, yT + R), P(xR + 0.12 * T, yT + R + 0.35 * L),
                            P(xR - 0.14 * T, yT + R + 0.7 * L), P(xR - 0.04 * T, yT + R + L), steps: 48)

        let start = fit.shortEnd ? shortEnd + nearCorner.dropFirst() : []
        path = start + (start.isEmpty ? top[...] : top.dropFirst()) + farCorner.dropFirst() + longEnd.dropFirst()
        tube = Tube(path)

        // Cut into three images: everything above `split`, and each hanging end below it.
        let side = T * 0.62 + 18                 // half the width, plus fuzz and shadow
        let below = T * 1.5 + 18                 // the longest fringe, plus shadow
        let box = boundingBox(path)
        // Without a short end, the scarf starts on the top edge and its fringe points sideways.
        let across = fit.shortEnd ? side : below
        let full = CGRect(x: floor(box.minX - across), y: floor(box.minY - side),
                          width: ceil(box.width + 2 * across), height: ceil(box.height + side + below))
        let split = (yT + max(R, sag + 0.6 * T + 20)).rounded()
        var out = [CGRect(x: full.minX, y: full.minY, width: full.width, height: split - full.minY)]
        let hanging = path.filter { $0.y >= split - 1 }
        for half in [hanging.filter { $0.x < w / 2 }, hanging.filter { $0.x >= w / 2 }] where !half.isEmpty {
            let b = boundingBox(half)
            out.append(CGRect(x: floor(b.minX - side), y: split, width: ceil(b.width + 2 * side),
                              height: ceil(b.maxY + below - split)))
        }
        rects = out
    }

    /// The scarf's width along its length: it ripples a little, like soft fabric.
    func width(at s: CGFloat) -> CGFloat {
        T * (1 + 0.045 * sin(2 * .pi * s / (3.1 * T)) + 0.025 * sin(2 * .pi * s / (1.7 * T) + 1))
    }
}

/// Where one scarf image sits relative to its window.
///
/// Coordinates are window-local, top-left origin, y down.
struct Placement {
    /// Which of the geometry's image rects this is.
    var index: Int
    var size: CGSize
    /// Where the image's top-left corner sits, relative to the window's top-left corner.
    var origin: CGPoint
    /// The geometry this piece was cut from.
    var w: CGFloat, T: CGFloat, side: KnotSide, tailLength: CGFloat, fit: ScarfFit
}

enum ScarfLayout {
    static func tailLength(height h: CGFloat, T: CGFloat) -> CGFloat {
        let raw = min(max(h * 0.5, 4 * T), 12 * T)
        return (raw / 4).rounded() * 4
    }

    /// How much room the scarf wants outside each edge of the window.
    static func roomWanted(T: CGFloat) -> CGFloat { 0.85 * T }

    /// Work out which side the long end hangs on and how the scarf fits, given the free space
    /// on screen to the left and right of the window.
    static func fit(preferred: KnotSide, roomLeft: CGFloat, roomRight: CGFloat, T: CGFloat) -> (KnotSide, ScarfFit) {
        let want = roomWanted(T: T)
        let room = { (s: KnotSide) in s == .right ? roomRight : roomLeft }
        let other: KnotSide = preferred == .right ? .left : .right
        // The long end goes where there's room. If neither side has any it has to tuck inside the
        // window, and then it always goes on the right, away from the window's buttons.
        let side: KnotSide
        if room(preferred) >= want { side = preferred }
        else if room(other) >= want { side = other }
        else { side = .right }
        let far: KnotSide = side == .right ? .left : .right
        var fit = ScarfFit()
        if room(side) < want {
            // Snapped to a few steps so the scarf isn't re-knitted for every point of movement.
            let step = 0.2 * T
            fit.tuck = min(0.9 * T, ((want - max(room(side), 0)) / step).rounded(.up) * step)
        }
        fit.shortEnd = room(far) >= want
        return (side, fit)
    }

    /// The scarf, cut into images that sit side by side without overlapping.
    static func placements(size: CGSize, T: CGFloat, side: KnotSide, tailLength: CGFloat,
                           fit: ScarfFit = .roomy) -> [Placement] {
        let g = ScarfGeometry(w: size.width, T: T, side: side, tailLength: tailLength, fit: fit)
        return g.rects.enumerated().map { i, r in
            Placement(index: i, size: r.size, origin: r.origin, w: size.width, T: T, side: side,
                      tailLength: tailLength, fit: fit)
        }
    }

    /// The smallest rect (window-local, top-left origin) holding the window and every piece.
    static func extents(_ ps: [Placement], window: CGSize) -> CGRect {
        var r = CGRect(origin: .zero, size: window)
        for p in ps { r = r.union(CGRect(origin: p.origin, size: p.size)) }
        return r.insetBy(dx: -2, dy: -2).integral
    }

    /// Knit every piece of one scarf, all at the same time.
    static func images(for ps: [Placement], colourway cw: Colourway, scale: CGFloat) -> [CGImage?] {
        guard let first = ps.first else { return [] }
        let g = ScarfGeometry(w: first.w, T: first.T, side: first.side, tailLength: first.tailLength, fit: first.fit)
        var images = [CGImage?](repeating: nil, count: ps.count)
        images.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: ps.count) { i in
                let index = ps[i].index
                guard index < g.rects.count else { return }
                out[i] = ScarfArt.piece(cw, g, rect: g.rects[index], key: "\(index)", scale: scale)
            }
        }
        return images
    }

    static func image(for p: Placement, colourway cw: Colourway, scale: CGFloat) -> CGImage? {
        let g = ScarfGeometry(w: p.w, T: p.T, side: p.side, tailLength: p.tailLength, fit: p.fit)
        guard p.index < g.rects.count else { return nil }
        return ScarfArt.piece(cw, g, rect: g.rects[p.index], key: "\(p.index)", scale: scale)
    }
}
