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
/// The chart is called with `i` = stitch index along the scarf's length,
/// `j` = stitch index across the scarf's width, and `n` = stitches across.
struct Colourway {
    let id: String
    let name: String
    let blurb: String
    let yarns: [Yarn]
    /// Yarn index used for the fringe, or nil to continue each column's colour.
    let fringe: Int?
    let chart: (_ i: Int, _ j: Int, _ n: Int) -> Int

    func yarn(_ i: Int, _ j: Int, _ n: Int) -> Yarn {
        yarns[pmod(chart(i, j, n), yarns.count)]
    }

    /// The dark colour that shows in the gaps between stitches.
    var gap: Yarn { yarns[0].shade(0.42) }
}

enum Colourways {
    static let pumpkinSpice = Colourway(
        id: "pumpkin-spice", name: "Pumpkin Spice",
        blurb: "pumpkin, cream and cinnamon stripes",
        yarns: [Yarn(0xD9742B), Yarn(0xF2E4C9), Yarn(0x8A4528)], fringe: 0
    ) { i, _, _ in
        let seq = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 2, 1, 1]
        return seq[pmod(i, seq.count)]
    }

    static let maplePlaid = Colourway(
        id: "maple-plaid", name: "Maple Plaid",
        blurb: "red and charcoal tartan with a mustard thread",
        yarns: [Yarn(0xB3392C), Yarn(0x2A1D19), Yarn(0xE0A93E), Yarn(0x7A2219)], fringe: 0
    ) { i, j, n in
        let a = pmod(i, 14)
        let dj = abs(Double(j) - Double(n - 1) / 2)
        let darkRow = a < 4
        let darkCol = dj < 1.0
        if a == 8 { return 2 }
        if darkRow && darkCol { return 1 }
        if darkRow || darkCol { return pmod(i + j, 2) == 0 ? 1 : 3 }
        return 0
    }

    static let harvestFairIsle = Colourway(
        id: "harvest-fair-isle", name: "Harvest Fair Isle",
        blurb: "rust with cream diamonds and a mustard border",
        yarns: [Yarn(0xB4532A), Yarn(0xF0DFBF), Yarn(0xD99A2B), Yarn(0x5B2F1F)], fringe: 0
    ) { i, j, n in
        if j <= 0 || j >= n - 1 { return 3 }
        if j == 1 || j == n - 2 { return pmod(i, 2) == 0 ? 2 : 0 }
        let m = pmod(i, 12)
        let dj = abs(Double(j) - Double(n - 1) / 2)
        if m == 6 && dj < 1 { return 2 }
        if Double(abs(m - 6)) + dj <= 2.6 { return 1 }
        if m == 0 && dj < 1 { return 1 }
        return 0
    }

    static let forestZigzag = Colourway(
        id: "forest-zigzag", name: "Forest Zigzag",
        blurb: "pine green with a cream zigzag and moss edges",
        yarns: [Yarn(0x2E5234), Yarn(0xEADCBD), Yarn(0x7D8B3E)], fringe: 0
    ) { i, j, n in
        if j <= 0 || j >= n - 1 { return 2 }
        let span = max(1, n - 3)
        let m = pmod(i, 2 * span)
        let z = m <= span ? m : 2 * span - m
        return j == z + 1 ? 1 : 0
    }

    static let cranberryFleck = Colourway(
        id: "cranberry-fleck", name: "Cranberry Fleck",
        blurb: "cranberry with cream flecks and rosy stripes",
        yarns: [Yarn(0x8C2234), Yarn(0xF1E3CB), Yarn(0xC0505A)], fringe: 0
    ) { i, j, _ in
        let m = pmod(i, 24)
        if m == 0 || m == 1 { return 1 }
        if m == 3 || m == 22 { return 2 }
        if knitHash(i, j, 3) % 11 == 0 { return 1 }
        return 0
    }

    static let appleCiderCheck = Colourway(
        id: "apple-cider-check", name: "Apple Cider Check",
        blurb: "mustard and toffee checks",
        yarns: [Yarn(0xC88A2C), Yarn(0x6B3E22)], fringe: 1
    ) { i, j, _ in
        pmod(fdiv(i, 2) + fdiv(j, 2), 2)
    }

    static let oatmealHeather = Colourway(
        id: "oatmeal-heather", name: "Oatmeal Heather",
        blurb: "soft oat with walnut and cream flecks",
        yarns: [Yarn(0xD9C7A5), Yarn(0x8E6B49), Yarn(0xF2E8D5)], fringe: 0
    ) { i, j, _ in
        let h = knitHash(i, j, 11)
        if h % 19 == 0 { return 1 }
        if h % 13 == 0 { return 2 }
        return 0
    }

    static let all: [Colourway] = [
        pumpkinSpice, maplePlaid, harvestFairIsle, forestZigzag,
        cranberryFleck, appleCiderCheck, oatmealHeather,
    ]

    static let byAppID = "by-app"

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
