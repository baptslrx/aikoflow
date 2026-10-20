import AppKit
import ServiceManagement

struct AppRef: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

@MainActor
final class FlowSettings: ObservableObject {
    /// Petites applis laissées flottantes par défaut.
    static let defaultFloating: [AppRef] = [
        AppRef(bundleID: "com.apple.calculator", name: "Calculette"),
        AppRef(bundleID: "com.apple.systempreferences", name: "Réglages Système"),
        AppRef(bundleID: "com.apple.SystemProfiler", name: "Informations système"),
        AppRef(bundleID: "com.apple.ScreenSharing", name: "Partage d'écran"),
        AppRef(bundleID: "com.apple.PhotoBooth", name: "Photo Booth"),
        AppRef(bundleID: "com.apple.archiveutility", name: "Utilitaire d'archive"),
    ]

    private let d = UserDefaults.standard

    @Published var modKey: ModKey { didSet { d.set(modKey.rawValue, forKey: "modKey") } }
    @Published var innerGap: Double { didSet { d.set(innerGap, forKey: "innerGap") } }
    @Published var outerGap: Double { didSet { d.set(outerGap, forKey: "outerGap") } }
    @Published var showBorder: Bool { didSet { d.set(showBorder, forKey: "showBorder") } }
    @Published var enableAtLaunch: Bool { didSet { d.set(enableAtLaunch, forKey: "enableAtLaunch") } }
    @Published var floating: [AppRef] { didSet { save(floating, "floating") } }
    @Published var ignored: [AppRef] { didSet { save(ignored, "ignored") } }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    init() {
        modKey = ModKey(rawValue: d.string(forKey: "modKey") ?? "") ?? .controlOption
        innerGap = d.object(forKey: "innerGap") as? Double ?? 8
        outerGap = d.object(forKey: "outerGap") as? Double ?? 10
        showBorder = d.object(forKey: "showBorder") as? Bool ?? true
        enableAtLaunch = d.object(forKey: "enableAtLaunch") as? Bool ?? true
        floating = Self.load("floating", d) ?? Self.defaultFloating
        ignored = Self.load("ignored", d) ?? []
    }

    private static func load(_ key: String, _ d: UserDefaults) -> [AppRef]? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([AppRef].self, from: data)
    }

    private func save(_ list: [AppRef], _ key: String) {
        if let data = try? JSONEncoder().encode(list) { d.set(data, forKey: key) }
    }

    var floatingBundleIDs: Set<String> { Set(floating.map(\.bundleID)) }
    var ignoredBundleIDs: Set<String> { Set(ignored.map(\.bundleID)) }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {}
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
