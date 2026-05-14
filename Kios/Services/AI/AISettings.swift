// Kios/Services/AI/AISettings.swift
import Foundation

/// `@Observable` only tracks *stored* properties. Each setting is a stored
/// property so SwiftUI re-renders when it changes; `didSet` writes through to
/// UserDefaults for persistence. The initial values are loaded from UserDefaults
/// at construction so the first read after relaunch matches what the user saw
/// before backgrounding.
@Observable
final class AISettings {
    private enum Keys {
        static let featuresEnabled = "ai.featuresEnabled"
        static let preferredEngine = "ai.preferredEngine"
        static let allowCellularDownload = "ai.allowCellularDownload"
        static let didShowFirstEnableSheet = "ai.didShowFirstEnableSheet"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var featuresEnabled: Bool {
        didSet { defaults.set(featuresEnabled, forKey: Keys.featuresEnabled) }
    }

    var preferredEngine: AIEngine {
        didSet { defaults.set(preferredEngine.rawValue, forKey: Keys.preferredEngine) }
    }

    var allowCellularDownload: Bool {
        didSet { defaults.set(allowCellularDownload, forKey: Keys.allowCellularDownload) }
    }

    var didShowFirstEnableSheet: Bool {
        didSet { defaults.set(didShowFirstEnableSheet, forKey: Keys.didShowFirstEnableSheet) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.featuresEnabled = defaults.bool(forKey: Keys.featuresEnabled)
        self.allowCellularDownload = defaults.bool(forKey: Keys.allowCellularDownload)
        self.didShowFirstEnableSheet = defaults.bool(forKey: Keys.didShowFirstEnableSheet)
        if let raw = defaults.string(forKey: Keys.preferredEngine),
           let engine = AIEngine(rawValue: raw) {
            self.preferredEngine = engine
        } else {
            self.preferredEngine = .gemma4_e4b
        }
    }
}
