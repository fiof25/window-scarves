import Foundation

/// User preferences, saved in UserDefaults.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard
    var onChange: [() -> Void] = []

    private func changed() { onChange.forEach { $0() } }

    var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled"); changed() }
    }

    /// A colourway id, or `Colourways.byAppID` for a different scarf per app.
    var colourway: String {
        get { d.string(forKey: "colourway") ?? Colourways.byAppID }
        set { d.set(newValue, forKey: "colourway"); changed() }
    }

    var knot: KnotSide {
        get { KnotSide(rawValue: d.string(forKey: "knot") ?? "") ?? .right }
        set { d.set(newValue.rawValue, forKey: "knot"); changed() }
    }

    var thickness: Thickness {
        get { Thickness(rawValue: d.string(forKey: "thickness") ?? "") ?? .cosy }
        set { d.set(newValue.rawValue, forKey: "thickness"); changed() }
    }

    var frontOnly: Bool {
        get { d.bool(forKey: "frontOnly") }
        set { d.set(newValue, forKey: "frontOnly"); changed() }
    }

    /// Whether the system-wide on/off keyboard shortcut is active.
    var shortcutEnabled: Bool {
        get { d.object(forKey: "shortcutEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "shortcutEnabled") }
    }

    /// Cover the red, yellow and green window buttons with sewing buttons.
    var sewnButtons: Bool {
        get { d.object(forKey: "sewnButtons") as? Bool ?? true }
        set { d.set(newValue, forKey: "sewnButtons"); changed() }
    }

    /// Apps whose windows go without a scarf.
    var skippedApps: Set<String> {
        get { Set(d.stringArray(forKey: "skippedApps") ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "skippedApps"); changed() }
    }

    /// Which scarf each app has been given, in "a different scarf for each app" mode.
    private var assignments: [String: String] {
        get { d.dictionary(forKey: "assignments") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "assignments") }
    }

    /// Hand every app a fresh scarf.
    func shuffleAssignments() {
        assignments = [:]
        changed()
    }

    /// Whether the app has already asked for Accessibility access once.
    var askedForAccessibility: Bool {
        get { d.bool(forKey: "askedForAccessibility") }
        set { d.set(newValue, forKey: "askedForAccessibility") }
    }

    func colourway(forApp app: String) -> Colourway {
        if colourway != Colourways.byAppID, let chosen = Colourways.byID(colourway) { return chosen }
        var map = assignments
        if let id = map[app], let c = Colourways.byID(id) { return c }
        // A new app gets one of the scarves that the fewest other apps are wearing,
        // so the windows on screen end up with a good mix.
        var counts: [String: Int] = [:]
        for id in map.values { counts[id, default: 0] += 1 }
        let fewest = Colourways.all.map { counts[$0.id] ?? 0 }.min() ?? 0
        let candidates = Colourways.all.filter { (counts[$0.id] ?? 0) == fewest }
        let pick = candidates.randomElement() ?? Colourways.all[0]
        map[app] = pick.id
        assignments = map
        return pick
    }
}
