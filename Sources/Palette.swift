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

/// How the fabric is made.
enum Texture {
    /// Fine stockinette: columns of little V stitches.
    case knit
    /// Chunky rib: a few fat columns of big stitches with soft grooves between them.
    case rib
    /// Brushed mohair weave: no visible stitches, soft blended colour and lots of fuzz.
    case mohair

    /// Stitches (or woven cells) across the scarf's width.
    var across: Int {
        switch self {
        case .knit: return 7
        case .rib: return 5
        case .mohair: return 9
        }
    }

    /// Row height as a fraction of stitch width.
    var rowRatio: CGFloat {
        switch self {
        case .knit: return 0.8
        case .rib: return 0.62
        case .mohair: return 1.0
        }
    }
}

enum FringeStyle {
    /// Medium, slightly wavy strands.
    case wispy
    /// A few short, fat tassels.
    case chunky
    /// Lots of long, fine strands.
    case long
}

/// A scarf design: its texture, colours and pattern.
///
/// `colour` is called with `i` = row along the scarf, `j` = stitch across it, `n` = stitches
/// across, and `fromEnd` = rows from the nearer fringed end, so designs can add stripes near
/// the ends like a real scarf.
struct Colourway {
    let id: String
    let name: String
    let blurb: String
    let texture: Texture
    /// The main colour, used for the fuzz and the gaps between stitches.
    let base: Yarn
    /// Width relative to the chosen thickness (a blanket scarf is wider than a skinny one).
    let weight: CGFloat
    /// How much each stitch's colour varies, for a heathered look.
    let heather: CGFloat
    let fringe: FringeStyle
    let colour: (_ i: Int, _ j: Int, _ n: Int, _ fromEnd: Int) -> Yarn

    var gap: Yarn {
        switch texture {
        case .knit: return base.shade(0.74)
        case .rib: return base.shade(0.7)
        case .mohair: return base.shade(0.96)   // brushed fabric has no dark gaps
        }
    }
    var fuzz: Yarn { base.lighten(0.42) }
}

/// Two stripes just above the fringe, like a classic scarf.
private func endStripes(_ fromEnd: Int) -> Bool {
    [3, 4, 7, 8].contains(fromEnd)
}

/// A soft woven check: lengthwise and crosswise bands of colour that blend where they cross.
private func check(_ yarns: [Yarn], warp: [(CGFloat, Int)], weft: [(Int, Int)])
    -> (Int, Int, Int, Int) -> Yarn {
    let period = weft.reduce(0) { $0 + $1.0 }
    return { i, j, n, _ in
        let f = (CGFloat(j) + 0.5) / CGFloat(max(1, n))
        let a = warp.first { f < $0.0 }?.1 ?? warp.last?.1 ?? 0
        var m = pmod(i, period), b = 0
        for (len, idx) in weft {
            if m < len { b = idx; break }
            m -= len
        }
        return a == b ? yarns[a] : yarns[a].mix(yarns[b], 0.5)
    }
}

enum Colourways {
    static let cream = Yarn(0xF2E9DA)

    static let lilacCheck = Colourway(
        id: "lilac-check", name: "Lilac Check",
        blurb: "fuzzy mohair check in lilac, butter and pink",
        texture: .mohair, base: Yarn(0xB9A6DA), weight: 1.12, heather: 0.05, fringe: .long,
        colour: check([Yarn(0xB9A6DA), Yarn(0xF1E1A6), Yarn(0xE9A9C4)],
                      warp: [(0.36, 0), (0.7, 1), (0.84, 2), (1.01, 0)],
                      weft: [(9, 0), (8, 1), (3, 2), (8, 1)]))

    static let oatMilk = Colourway(
        id: "oat-milk", name: "Oat Milk",
        blurb: "chunky rib knit in heathered oatmeal",
        texture: .rib, base: Yarn(0xDCCFBA), weight: 1.04, heather: 0.07, fringe: .chunky
    ) { _, _, _, _ in Yarn(0xDCCFBA) }

    static let rosehip = Colourway(
        id: "rosehip", name: "Rosehip",
        blurb: "fine knit in soft red with cream stripes at the ends",
        texture: .knit, base: Yarn(0xC5483E), weight: 1, heather: 0.05, fringe: .wispy
    ) { _, _, _, fromEnd in endStripes(fromEnd) ? cream : Yarn(0xC5483E) }

    static let cocoaCheck = Colourway(
        id: "cocoa-check", name: "Cocoa Check",
        blurb: "fuzzy mohair check in cocoa, sky blue and cream",
        texture: .mohair, base: Yarn(0x7A5644), weight: 1.12, heather: 0.05, fringe: .long,
        colour: check([Yarn(0x7A5644), Yarn(0xA3BEDF), cream],
                      warp: [(0.3, 0), (0.62, 1), (0.76, 2), (1.01, 0)],
                      weft: [(10, 0), (7, 1), (3, 2), (7, 1)]))

    static let camel = Colourway(
        id: "camel", name: "Camel",
        blurb: "chunky rib knit in warm camel",
        texture: .rib, base: Yarn(0xC59C6C), weight: 1.04, heather: 0.06, fringe: .chunky
    ) { _, _, _, _ in Yarn(0xC59C6C) }

    static let heatherGrey = Colourway(
        id: "heather-grey", name: "Heather Grey",
        blurb: "fine knit in grey melange with charcoal stripes at the ends",
        texture: .knit, base: Yarn(0xABACB1), weight: 1, heather: 0.13, fringe: .wispy
    ) { _, _, _, fromEnd in endStripes(fromEnd) ? Yarn(0x5A5B62) : Yarn(0xABACB1) }

    static let mossCheck = Colourway(
        id: "moss-check", name: "Moss Check",
        blurb: "fuzzy mohair check in moss, butter and navy",
        texture: .mohair, base: Yarn(0x64855D), weight: 1.12, heather: 0.05, fringe: .long,
        colour: check([Yarn(0x64855D), Yarn(0xEBDCA6), Yarn(0x37456A)],
                      warp: [(0.34, 0), (0.66, 1), (0.8, 2), (1.01, 0)],
                      weft: [(9, 0), (8, 1), (3, 2), (8, 1)]))

    static let blush = Colourway(
        id: "blush", name: "Blush",
        blurb: "brushed mohair in powder pink",
        texture: .mohair, base: Yarn(0xE9C0C7), weight: 1.06, heather: 0.07, fringe: .long
    ) { i, _, _, _ in Yarn(0xE9C0C7).shade(pmod(i, 2) == 0 ? 1 : 0.975) }

    static let varsityStripe = Colourway(
        id: "varsity-stripe", name: "Varsity Stripe",
        blurb: "skinny fine knit in navy and cream with a rust thread",
        texture: .knit, base: Yarn(0x2F3B57), weight: 0.86, heather: 0.05, fringe: .wispy
    ) { i, _, _, _ in
        let m = pmod(i, 22)
        if m < 10 { return Yarn(0x2F3B57) }
        if m < 14 { return cream }
        if m < 16 { return Yarn(0xB95D3D) }
        return cream
    }

    /// Ordered so that the first few apps get a mix of textures.
    static let all: [Colourway] = [
        lilacCheck, oatMilk, rosehip, cocoaCheck, camel, heatherGrey, mossCheck, blush, varsityStripe,
    ]

    /// Setting value meaning "give each app its own scarf".
    static let byAppID = "by-app"

    static func byID(_ id: String) -> Colourway? { all.first { $0.id == id } }
}
