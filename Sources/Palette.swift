import CoreGraphics

/// A single yarn colour.
struct Yarn {
    var r: CGFloat, g: CGFloat, b: CGFloat

    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }

    init(r: CGFloat, g: CGFloat, b: CGFloat) {
        self.r = r; self.g = g; self.b = b
    }

    func shade(_ f: CGFloat) -> Yarn {
        Yarn(r: min(1, r * f), g: min(1, g * f), b: min(1, b * f))
    }

    func mix(_ o: Yarn, _ t: CGFloat) -> Yarn {
        Yarn(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
    }

    func lighten(_ t: CGFloat) -> Yarn { mix(Yarn(0xFFFFFF), t) }

    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    func cg(alpha: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
}

@inline(__always) func pmod(_ a: Int, _ m: Int) -> Int {
    let r = a % m
    return r < 0 ? r + m : r
}

@inline(__always) func fdiv(_ a: Int, _ b: Int) -> Int {
    a >= 0 ? a / b : -((-a + b - 1) / b)
}

func knitHash(_ a: Int, _ b: Int, _ c: Int) -> UInt32 {
    var h = UInt32(truncatingIfNeeded: a &* 374_761_393 &+ b &* 668_265_263 &+ c &* 1_274_126_177)
    h = (h ^ (h >> 13)) &* 1_274_126_177
    return h ^ (h >> 16)
}

func noise01(_ a: Int, _ b: Int, _ c: Int) -> CGFloat {
    CGFloat(knitHash(a, b, c) & 0xFFFF) / 65535
}

/// A scarf colourway: a set of yarns plus a knitting chart.
///
/// The chart is called with `i` = row along the scarf, `j` = stitch across it, `n` = stitches
/// across, and `fromEnd` = rows from the nearer fringed end, so colourways can add stripes
/// near the ends like a real scarf.
struct Colourway {
    let id: String
    let name: String
    let blurb: String
    let yarns: [Yarn]
    /// Yarn index used for the fringe.
    let fringe: Int
    let chart: (_ i: Int, _ j: Int, _ n: Int, _ fromEnd: Int) -> Int

    func yarn(_ i: Int, _ j: Int, _ n: Int, _ fromEnd: Int) -> Yarn {
        yarns[pmod(chart(i, j, n, fromEnd), yarns.count)]
    }

    /// The colour that shows in the little gaps between stitches.
    var gap: Yarn { yarns[0].shade(0.74) }
    /// Soft halo fibres around the edge.
    var fuzz: Yarn { yarns[0].lighten(0.42) }
    var fringeYarn: Yarn { yarns[fringe] }
}

/// Two stripes just above the fringe, like a classic scarf.
private func endStripes(_ fromEnd: Int) -> Bool {
    [3, 4, 7, 8].contains(fromEnd)
}

enum Colourways {
    static let cream = Yarn(0xF4EADA)

    static let rosehip = Colourway(
        id: "rosehip", name: "Rosehip",
        blurb: "a soft, warm red with cream stripes at the ends",
        yarns: [Yarn(0xC5483E), cream], fringe: 0
    ) { _, _, _, fromEnd in endStripes(fromEnd) ? 1 : 0 }

    static let candyStripe = Colourway(
        id: "candy-stripe", name: "Candy Stripe",
        blurb: "wide rosehip and cream stripes",
        yarns: [Yarn(0xC5483E), cream], fringe: 0
    ) { i, _, _, _ in pmod(i, 16) < 8 ? 0 : 1 }

    static let pumpkinPatch = Colourway(
        id: "pumpkin-patch", name: "Pumpkin Patch",
        blurb: "warm pumpkin with the odd cream stripe",
        yarns: [Yarn(0xDE7B3A), cream], fringe: 0
    ) { i, _, _, fromEnd in
        if endStripes(fromEnd) { return 1 }
        return fromEnd > 12 && pmod(i, 34) < 2 ? 1 : 0
    }

    static let marigold = Colourway(
        id: "marigold", name: "Marigold",
        blurb: "honey yellow with burnt-orange tips",
        yarns: [Yarn(0xE6AE42), Yarn(0xCB6E30)], fringe: 0
    ) { _, _, _, fromEnd in endStripes(fromEnd) ? 1 : 0 }

    static let buffaloCheck = Colourway(
        id: "buffalo-check", name: "Buffalo Check",
        blurb: "soft red and charcoal lumberjack checks",
        yarns: [Yarn(0xBF4038), Yarn(0x30272A), Yarn(0x7C302C)], fringe: 0
    ) { i, j, n, _ in
        let darkRow = pmod(fdiv(i, 5), 2) == 1
        let darkCol = (j * 2) / max(1, n) == 1
        if darkRow && darkCol { return 1 }
        if darkRow || darkCol { return 2 }
        return 0
    }

    static let evergreen = Colourway(
        id: "evergreen", name: "Evergreen",
        blurb: "mossy pine green with cream stripes",
        yarns: [Yarn(0x4A8C62), cream], fringe: 0
    ) { i, _, _, fromEnd in
        if endStripes(fromEnd) { return 1 }
        return fromEnd > 12 && pmod(i, 40) < 2 ? 1 : 0
    }

    static let raspberry = Colourway(
        id: "raspberry", name: "Raspberry",
        blurb: "dusty berry pink with thin blush stripes",
        yarns: [Yarn(0xC25578), Yarn(0xF3D9E1)], fringe: 0
    ) { i, _, _, fromEnd in
        if endStripes(fromEnd) { return 1 }
        return pmod(i, 10) == 0 ? 1 : 0
    }

    static let all: [Colourway] = [
        rosehip, candyStripe, pumpkinPatch, marigold, buffaloCheck, evergreen, raspberry,
    ]

    static let byAppID = "by-app"
    static let defaultID = rosehip.id

    static func byID(_ id: String) -> Colourway? { all.first { $0.id == id } }

    /// A stable colourway for an app, so each app always wears the same scarf.
    static func forApp(_ name: String) -> Colourway {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in name.lowercased().utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return all[Int(h % UInt64(all.count))]
    }
}
