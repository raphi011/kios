// Kios/Services/AI/AISettings.swift
import Foundation

@Observable
final class AISettings {
    private enum Keys {
        static let featuresEnabled = "ai.featuresEnabled"
        static let preferredEngine = "ai.preferredEngine"
        static let allowCellularDownload = "ai.allowCellularDownload"
        static let didShowFirstEnableSheet = "ai.didShowFirstEnableSheet"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var featuresEnabled: Bool {
        get { defaults.bool(forKey: Keys.featuresEnabled) }
        set { defaults.set(newValue, forKey: Keys.featuresEnabled) }
    }

    var preferredEngine: AIEngine {
        get {
            guard let raw = defaults.string(forKey: Keys.preferredEngine),
                  let engine = AIEngine(rawValue: raw) else {
                return .gemma3_4b
            }
            return engine
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.preferredEngine) }
    }

    var allowCellularDownload: Bool {
        get { defaults.bool(forKey: Keys.allowCellularDownload) }
        set { defaults.set(newValue, forKey: Keys.allowCellularDownload) }
    }

    var didShowFirstEnableSheet: Bool {
        get { defaults.bool(forKey: Keys.didShowFirstEnableSheet) }
        set { defaults.set(newValue, forKey: Keys.didShowFirstEnableSheet) }
    }
}
