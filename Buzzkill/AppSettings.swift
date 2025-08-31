//
//  AppSettings.swift
//  Buzzkill
//
//  Centralized user settings with lightweight persistence.
//

import AppKit
import Foundation

// MARK: - Default Constants

extension AppSettings {
  enum Defaults {
    // General fly count bounds.
    // Keep these values in sync with `IntentsManager` literals!
    // Keep these values in sync with `StatusBarController` ranges!
    static let minFlyCount: Int = 1
    static let maxFlyCount: Int = 40

    // Auto-spawn interval bounds (seconds).
    // Keep these values in sync with `IntentsManager` literals!
    static let minIntervalSeconds: Double = 1.0
    static let maxIntervalSeconds: Double = 300.0

    // Audio defaults.
    static let audioMasterVolume: Float = 1.0
    static let audioFlyEnabled: Bool = true
    static let audioSwatterDragEnabled: Bool = true
    static let audioSplatEnabled: Bool = true
    static let audioDeathEnabled: Bool = true

    // Spawn defaults.
    // Keep these values in sync with `IntentsManager` literals!
    static let spawnInitialCount: Int = 10
    static let spawnMaxCount: Int = 30
    static let spawnIntervalSeconds: Double = 5.0

    // Time Trial defaults.
    // Keep these values in sync with `IntentsManager` literals!
    static let timeTrialInitialCount: Int = 10

    // Startup defaults.
    static let startupLaunchAtLogin: Bool = false

    // Roast Mode defaults.
    static let roastEnabled: Bool = false
    static let didRequestScreenCaptureAccess: Bool = false
    static let roastIntervalSeconds: Double = 15.0
    static let roastMinIntervalSeconds: Double = 5.0
    static let roastMaxIntervalSeconds: Double = 120.0
    static let roastIntervalStepSeconds: Double = 5.0

    // Disclosure group expansion state defaults.
    static let disclosureGroupAutoSpawnExpanded: Bool = false
    static let disclosureGroupTimeTrialExpanded: Bool = false
    static let disclosureGroupRoastModeExpanded: Bool = true
    static let disclosureGroupSoundsExpanded: Bool = false
    static let disclosureGroupSystemExpanded: Bool = false
  }
}

// MARK: - Base Settings Accessor

@MainActor
final class AppSettings: ObservableObject {
  static let shared = AppSettings()

  @Published var audio = AudioSettings.load() {
    didSet { AudioSettings.save(audio) }
  }

  @Published var spawn = SpawnSettings.load() {
    didSet { SpawnSettings.save(spawn) }
  }

  @Published var timeTrial = TimeTrialSettings.load() {
    didSet { TimeTrialSettings.save(timeTrial) }
  }

  @Published var startup = StartupSettings.load() {
    didSet { StartupSettings.save(startup) }
  }

  @Published var roast = RoastSettings.load() {
    didSet { RoastSettings.save(roast) }
  }

  @Published var disclosureGroup = DisclosureGroupSettings.load() {
    didSet { DisclosureGroupSettings.save(disclosureGroup) }
  }

  /// Restores all configurable settings to their defaults while preserving user data/records.
  func resetAllSettings() {
    let preservedRecords = timeTrial.recordsByInitialCount
    audio = .defaults
    spawn = .defaults
    timeTrial = AppSettings.TimeTrialSettings(
      initialCount: AppSettings.TimeTrialSettings.defaults.initialCount,
      recordsByInitialCount: preservedRecords
    )
    startup = .defaults
    roast = .defaults
    disclosureGroup = .defaults
  }

  /// Clears user data (time trial records) without changing any other settings.
  func resetAllData() {
    timeTrial = AppSettings.TimeTrialSettings(
      initialCount: timeTrial.initialCount,
      recordsByInitialCount: [:]
    )
  }
}

// MARK: - Audio Settings Management

extension AppSettings {
  struct AudioSettings: Codable, Equatable {
    var masterVolume: Float  // 0.0 to 1.0.
    var flyEnabled: Bool
    var swatterDragEnabled: Bool
    var splatEnabled: Bool
    var deathEnabled: Bool

    static let defaults = AudioSettings(
      masterVolume: AppSettings.Defaults.audioMasterVolume,
      flyEnabled: AppSettings.Defaults.audioFlyEnabled,
      swatterDragEnabled: AppSettings.Defaults.audioSwatterDragEnabled,
      splatEnabled: AppSettings.Defaults.audioSplatEnabled,
      deathEnabled: AppSettings.Defaults.audioDeathEnabled
    )

    private static let key = "bk.audio"

    static func load() -> AudioSettings {
      guard let data = UserDefaults.standard.data(forKey: key) else {
        return .defaults
      }
      return (try? JSONDecoder().decode(AudioSettings.self, from: data)) ?? .defaults
    }

    static func save(_ value: AudioSettings) {
      if let data = try? JSONEncoder().encode(value) {
        UserDefaults.standard.set(data, forKey: key)
      }
    }
  }
}

// MARK: - Spawn Settings Management

extension AppSettings {
  enum SpawnMode: String, Codable, CaseIterable, Hashable {
    case none
    case auto
  }

  struct SpawnSettings: Codable, Equatable {
    var mode: SpawnMode
    var initialCount: Int  // `minFlyCount` to `maxCount`.
    var maxCount: Int  // `minFlyCount` to `maxFlyCount`.
    var intervalSeconds: Double

    static let defaults = SpawnSettings(
      mode: .auto,
      initialCount: AppSettings.Defaults.spawnInitialCount,
      maxCount: AppSettings.Defaults.spawnMaxCount,
      intervalSeconds: AppSettings.Defaults.spawnIntervalSeconds
    )

    private static let key = "bk.spawn"

    static func load() -> SpawnSettings {
      guard let data = UserDefaults.standard.data(forKey: key) else {
        return .defaults
      }
      return (try? JSONDecoder().decode(SpawnSettings.self, from: data)) ?? .defaults
    }

    static func save(_ value: SpawnSettings) {
      if let data = try? JSONEncoder().encode(value) {
        UserDefaults.standard.set(data, forKey: key)
      }
    }
  }
}

// MARK: - Time Trial Settings Management

extension AppSettings {
  struct TimeTrialSettings: Codable, Equatable {
    var initialCount: Int
    var recordsByInitialCount: [Int: Record]

    struct Record: Codable, Equatable {
      var last: Double?
      var pr: Double?
    }

    static let defaults = TimeTrialSettings(
      initialCount: AppSettings.Defaults.timeTrialInitialCount,
      recordsByInitialCount: [:]
    )

    private static let key = "bk.timeTrial"

    static func load() -> TimeTrialSettings {
      guard let data = UserDefaults.standard.data(forKey: key) else {
        return .defaults
      }
      return (try? JSONDecoder().decode(TimeTrialSettings.self, from: data)) ?? .defaults
    }

    static func save(_ value: TimeTrialSettings) {
      if let data = try? JSONEncoder().encode(value) {
        UserDefaults.standard.set(data, forKey: key)
      }
    }
  }
}

// MARK: - Startup (Login Item) Settings Management

extension AppSettings {
  struct StartupSettings: Codable, Equatable {
    var launchAtLogin: Bool

    static let defaults = StartupSettings(launchAtLogin: AppSettings.Defaults.startupLaunchAtLogin)

    private static let key = "bk.startup"

    static func load() -> StartupSettings {
      guard let data = UserDefaults.standard.data(forKey: key) else {
        return .defaults
      }
      return (try? JSONDecoder().decode(StartupSettings.self, from: data)) ?? .defaults
    }

    static func save(_ value: StartupSettings) {
      if let data = try? JSONEncoder().encode(value) {
        UserDefaults.standard.set(data, forKey: key)
      }
    }
  }
}

// MARK: - Roast Mode Settings Management

extension AppSettings {
  struct RoastSettings: Codable, Equatable {
    var apiKey: String?  // When nil or empty, Roast Mode is not configured.
    var isEnabled: Bool
    var frequencySeconds: Double  // 5 to 120 (whole seconds only).
    var didRequestScreenCaptureAccess: Bool

    static let defaults = RoastSettings(
      apiKey: nil,
      isEnabled: AppSettings.Defaults.roastEnabled,
      frequencySeconds: AppSettings.Defaults.roastIntervalSeconds,
      didRequestScreenCaptureAccess: AppSettings.Defaults.didRequestScreenCaptureAccess
    )

    private static let key = "bk.roast"

    static func load() -> RoastSettings {
      guard let data = UserDefaults.standard.data(forKey: key) else {
        return .defaults
      }
      let decoded = (try? JSONDecoder().decode(RoastSettings.self, from: data)) ?? .defaults
      // Always start Roast Mode disabled on app launch, regardless of previous session state.
      var settings = decoded
      settings.isEnabled = false
      return settings
    }

    static func save(_ value: RoastSettings) {
      if let data = try? JSONEncoder().encode(value) {
        UserDefaults.standard.set(data, forKey: key)
      }
    }
  }
}

// MARK: - Disclosure Group State Management

extension AppSettings {
  struct DisclosureGroupSettings: Codable, Equatable {
    var autoSpawnExpanded: Bool
    var timeTrialExpanded: Bool
    var roastModeExpanded: Bool
    var soundsExpanded: Bool
    var systemExpanded: Bool

    static let defaults = DisclosureGroupSettings(
      autoSpawnExpanded: AppSettings.Defaults.disclosureGroupAutoSpawnExpanded,
      timeTrialExpanded: AppSettings.Defaults.disclosureGroupTimeTrialExpanded,
      roastModeExpanded: AppSettings.Defaults.disclosureGroupRoastModeExpanded,
      soundsExpanded: AppSettings.Defaults.disclosureGroupSoundsExpanded,
      systemExpanded: AppSettings.Defaults.disclosureGroupSystemExpanded
    )

    private static let key = "bk.disclosureGroup"

    static func load() -> DisclosureGroupSettings {
      guard let data = UserDefaults.standard.data(forKey: key) else {
        return .defaults
      }
      return (try? JSONDecoder().decode(DisclosureGroupSettings.self, from: data))
        ?? .defaults
    }

    static func save(_ value: DisclosureGroupSettings) {
      if let data = try? JSONEncoder().encode(value) {
        UserDefaults.standard.set(data, forKey: key)
      }
    }
  }
}
