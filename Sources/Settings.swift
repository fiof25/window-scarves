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
        get { d.string(forKey: "colourway") ?? Colourways.defaultID }
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

    func colourway(forApp app: String) -> Colourway {
        if colourway == Colourways.byAppID { return Colourways.forApp(app) }
        return Colourways.byID(colourway) ?? Colourways.forApp(app)
    }
}
