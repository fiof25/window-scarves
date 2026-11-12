import AppKit

/// Checks that the scarf-making code behaves, without touching any real windows.
/// Run with `WindowScarves --self-test`.
enum SelfTest {
    static func run() -> Bool {
        var checks = 0
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
            checks += 1
            if !ok && failures.count < 20 { failures.append(what()) }
        }

        // 1. The scarf's shape, for every scarf, thickness, side, window size and fit.
        for cw in Colourways.all {
            for thickness in Thickness.allCases {
                let T = (thickness.points * cw.weight).rounded()
                let fits = [ScarfFit.roomy, ScarfFit(tuck: 0.9 * T, shortEnd: true),
                            ScarfFit(tuck: 0, shortEnd: false), ScarfFit(tuck: 0.9 * T, shortEnd: false)]
                for side in KnotSide.allCases {
                    for w in [200, 333, 700, 1500, 3200] as [CGFloat] {
                        for h in [140, 600, 1400] as [CGFloat] {
                            for fit in fits {
                                let g = ScarfGeometry(w: w, T: T, side: side,
                                                      tailLength: ScarfLayout.tailLength(height: h, T: T), fit: fit)
                                let label = "\(cw.id), thickness \(T), \(side), window \(Int(w))x\(Int(h)), \(fit)"
                                expect(g.tube.length > 0 && g.tube.length.isFinite, "no path: \(label)")
                                expect(g.rects.count == (fit.shortEnd ? 3 : 2), "\(g.rects.count) pieces: \(label)")
                                expect(g.rects.allSatisfy {
                                    $0.width >= 1 && $0.height >= 1 && $0.width < 8000 && $0.height < 4000 && $0 == $0.integral
                                }, "odd piece size: \(label)")
                                for a in g.rects.indices {
                                    for b in g.rects.indices where b > a {
                                        let overlap = g.rects[a].intersection(g.rects[b])
                                        expect(overlap.isNull || overlap.width * overlap.height == 0,
                                               "pieces overlap: \(label)")
                                    }
                                }
                                expect(g.path.allSatisfy { p in g.rects.contains { $0.contains(p) } },
                                       "scarf goes outside its pieces: \(label)")
                            }
                        }
                    }
                }
            }
        }

        // 2. Every scarf draws something, and knitting in parallel strips gives the same picture
        //    as knitting in one go.
        var mostOff = 0
        for round in 0..<4 {
        for cw in Colourways.all {
            let T = (Thickness.cozy.points * cw.weight).rounded()
            let g = ScarfGeometry(w: 900 + CGFloat(round) * 150, T: T, side: .right, tailLength: ScarfLayout.tailLength(height: 700, T: T))
            for (i, rect) in g.rects.enumerated() {
                ScarfArt.clearCache()
                let striped = ScarfArt.piece(cw, g, rect: rect, key: "test\(i)", scale: 2, parallel: true)
                let whole = ScarfArt.piece(cw, g, rect: rect, key: "test\(i)", scale: 2, parallel: false)
                guard let striped, let whole, let a = striped.dataProvider?.data as Data?,
                      let b = whole.dataProvider?.data as Data? else {
                    expect(false, "\(cw.id) piece \(i) didn't draw")
                    continue
                }
                expect(striped.width == Int(rect.width * 2) && striped.height == Int(rect.height * 2),
                       "\(cw.id) piece \(i) is the wrong size")
                expect(a.count == b.count, "\(cw.id) piece \(i): strips and whole differ in size")
                // Count the values that are visibly off. A handful of stray ones is normal (hairlines
                // land a fraction differently); a real mismatch shows up as thousands.
                var opaque = 0, off = 0
                if a.count == b.count {
                    a.withUnsafeBytes { pa in
                        b.withUnsafeBytes { pb in
                            for k in 0..<a.count {
                                if abs(Int(pa[k]) - Int(pb[k])) > 8 { off += 1 }
                                if k % 4 == 3 && pa[k] > 200 { opaque += 1 }
                            }
                        }
                    }
                }
                mostOff = max(mostOff, off)
                expect(opaque > 500, "\(cw.id) piece \(i) is nearly empty")
                expect(off <= 80, "\(cw.id) piece \(i): \(off) values differ between strips and whole")
            }
        }
        }
        ScarfArt.clearCache()

        // 3. Which windows get scarves.
        let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982)]
        expect(Tracker.fillsScreen(CGRect(x: 0, y: 0, width: 1512, height: 982), screens), "full screen not recognised")
        expect(Tracker.fillsScreen(CGRect(x: 0, y: 33, width: 1512, height: 949), screens),
               "full screen below the menu bar not recognised")
        expect(!Tracker.fillsScreen(CGRect(x: 0, y: 33, width: 1512, height: 879), screens),
               "a maximised window above the Dock was treated as full screen")
        expect(!Tracker.fillsScreen(CGRect(x: 100, y: 100, width: 800, height: 600), screens),
               "an ordinary window was treated as full screen")
        func window(_ pid: pid_t, _ r: CGRect) -> Tracker.Target {
            Tracker.Target(id: 1, frame: r, owner: "test", pid: pid, index: 0)
        }
        let main = window(1, CGRect(x: 200, y: 200, width: 900, height: 600))
        expect(Tracker.isPopover(window(1, CGRect(x: 400, y: 300, width: 300, height: 220)), above: [main][...]),
               "a popover wasn't recognised")
        expect(!Tracker.isPopover(window(1, CGRect(x: 1200, y: 300, width: 300, height: 220)), above: [main][...]),
               "a separate small window was treated as a popover")
        expect(!Tracker.isPopover(window(2, CGRect(x: 400, y: 300, width: 300, height: 220)), above: [main][...]),
               "another app's window was treated as a popover")
        expect(!Tracker.isPopover(main, above: [window(1, CGRect(x: 400, y: 300, width: 300, height: 220))][...]),
               "a main window was treated as a popover")
        let big = window(1, CGRect(x: 0, y: 40, width: 1500, height: 900))
        expect(!Tracker.isPopover(window(1, CGRect(x: 300, y: 200, width: 700, height: 420)), above: [big][...]),
               "an ordinary mid-sized window over a big one was treated as a popover")

        // 4. Fitting the scarf to the space beside a window.
        let T: CGFloat = 32
        var (side, fit) = ScarfLayout.fit(preferred: .right, roomLeft: 300, roomRight: 300, T: T)
        expect(side == .right && fit == .roomy, "plenty of room should mean a normal scarf")
        (side, fit) = ScarfLayout.fit(preferred: .right, roomLeft: 300, roomRight: 0, T: T)
        expect(side == .left && fit.tuck == 0 && !fit.shortEnd, "no room on the right should move the long end left")
        (side, fit) = ScarfLayout.fit(preferred: .right, roomLeft: 0, roomRight: 0, T: T)
        expect(side == .right && fit.tuck > 0 && !fit.shortEnd, "no room either side should tuck the long end in")
        (side, fit) = ScarfLayout.fit(preferred: .left, roomLeft: 0, roomRight: 0, T: T)
        expect(side == .right && fit.tuck > 0, "a tucked-in long end must go on the right, away from the window's buttons")
        (side, fit) = ScarfLayout.fit(preferred: .left, roomLeft: 300, roomRight: 300, T: T)
        expect(side == .left && fit == .roomy, "with room, the long end should go on the chosen side")

        // 5. The collection itself.
        expect(Set(Colourways.all.map(\.id)).count == Colourways.all.count, "two scarves share an id")
        expect(Colourways.all.allSatisfy { !$0.name.isEmpty && $0.weight > 0.5 && $0.weight < 1.5 }, "odd scarf settings")

        print("\(checks) checks, \(failures.count == 0 ? "all passed" : "\(failures.count)+ failed")")
        print("strip-knitted vs whole-knitted pictures: at most \(mostOff) values differ per piece (out of ~1,400,000)")
        failures.forEach { print("  FAILED: \($0)") }
        return failures.isEmpty
    }
}
