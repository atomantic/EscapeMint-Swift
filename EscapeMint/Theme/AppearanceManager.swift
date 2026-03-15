import SwiftUI

enum AppearanceMode: String, CaseIterable, Sendable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor @Observable
final class AppearanceManager: Sendable {
    static let shared = AppearanceManager()

    var mode: AppearanceMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "appearanceMode") }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: "appearanceMode") ?? "System"
        self.mode = AppearanceMode(rawValue: stored) ?? .system
    }
}
