//
//  IntentsManager.swift
//  Buzzkill
//
//  `AppIntent`s and a thin facade over runtime managers for Shortcuts integration.
//

import Foundation

@MainActor
final class IntentsManager: ObservableObject {
  static let shared = IntentsManager()

  // TODO: Migrate `FlyManager` calls to events.
  private weak var flyManager: FlyManager?
  private weak var timeTrialManager: TimeTrialManager?

  // MARK: - Wiring

  func setup(flyManager: FlyManager, timeTrialManager: TimeTrialManager) {
    self.flyManager = flyManager
    self.timeTrialManager = timeTrialManager
  }

  // MARK: - Guards

  private var isTimeTrialActive: Bool {
    guard let manager = timeTrialManager else {
      return false
    }

    switch manager.state {
    case .idle: return false
    default: return true
    }
  }

  private var aliveFlyCount: Int {
    guard let manager = flyManager else {
      return 0
    }

    return manager.flies.reduce(0) { $0 + ($1.isAlive ? 1 : 0) }
  }

  // MARK: - Actions

  /// Spawns `spawnCount` flies up to the provided `maxCount`; does nothing during a time trial.
  func spawnFlies(spawnCount: Int, maxCount: Int) -> Int? {
    guard !isTimeTrialActive else {
      return nil
    }
    guard let manager = flyManager else {
      return nil
    }

    let desiredAlive = min(maxCount, aliveFlyCount + spawnCount)
    let spawnedCount = manager.ensureInitialPopulation(count: desiredAlive)
    return spawnedCount
  }

  /// Kills all flies with the option to play sound effects; does nothing during a time trial.
  func killAllFlies(playSoundEffects: Bool) -> Bool {
    guard !isTimeTrialActive else {
      return false
    }
    guard let manager = flyManager else {
      return false
    }

    manager.killAllFlies(playSoundEffects: playSoundEffects)
    return true
  }

  /// Switches spawn mode and updates spawn settings if provided; does nothing during a time trial.
  func setSpawnMode(
    mode: AppSettings.SpawnMode,
    initialCount: Int? = nil,
    maxCount: Int? = nil,
    intervalSeconds: Double? = nil
  ) -> Bool {
    guard !isTimeTrialActive else {
      return false
    }

    var spawnSettings = AppSettings.shared.spawn
    spawnSettings.mode = mode
    if let initialCount = initialCount,
      let maxCount = maxCount,
      let intervalSeconds = intervalSeconds
    {
      spawnSettings.initialCount = initialCount
      spawnSettings.maxCount = maxCount
      spawnSettings.intervalSeconds = intervalSeconds
    }
    AppSettings.shared.spawn = spawnSettings
    Events.applySpawnSettings.send(spawnSettings)
    return true
  }

  /// Starts a time trial with the provided initial count; no-op if a time trial is already active.
  func startTimeTrial(initialCount: Int) -> Bool {
    guard !isTimeTrialActive else {
      return false
    }

    var timeTrial = AppSettings.shared.timeTrial
    timeTrial.initialCount = initialCount
    AppSettings.shared.timeTrial = timeTrial
    Events.startTimeTrial.send(timeTrial.initialCount)
    return true
  }

  /// Stops the active time trial (if any).
  func stopTimeTrial() -> Bool {
    guard isTimeTrialActive else {
      return false
    }

    Events.stopTimeTrial.send(())
    return true
  }

  /// Shows a manual roast on a random fly; does nothing during a time trial.
  func showManualRoast(text: String) -> Bool {
    guard !isTimeTrialActive else {
      return false
    }

    Task { @MainActor in
      // Nominal sleep to allow SwiftUI views to mount and observe changes.
      try? await Task.sleep(nanoseconds: 10_000_000)
      Events.showRoast.send(text)
    }
    return true
  }
}

#if canImport(AppIntents)
  import AppIntents

  // MARK: - App Shortcuts

  @available(macOS 13.0, *)
  struct BuzzkillShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .pink }

    static var appShortcuts: [AppShortcut] {
      return [
        AppShortcut(
          intent: SpawnFliesIntent(),
          phrases: ["Spawn flies in ${applicationName}"],
          shortTitle: "Spawn Flies",
          systemImageName: "plus.circle"
        ),
        AppShortcut(
          intent: KillAllFliesIntent(),
          phrases: ["Kill all flies in ${applicationName}"],
          shortTitle: "Kill All Flies",
          systemImageName: "trash"
        ),
        AppShortcut(
          intent: SetSpawnModeIntent(),
          phrases: ["Set spawn mode in ${applicationName}"],
          shortTitle: "Set Spawn Mode",
          systemImageName: "gear"
        ),
        AppShortcut(
          intent: StartTimeTrialIntent(),
          phrases: ["Start time trial in ${applicationName}"],
          shortTitle: "Start Time Trial",
          systemImageName: "play.circle"
        ),
        AppShortcut(
          intent: StopTimeTrialIntent(),
          phrases: ["Stop time trial in ${applicationName}"],
          shortTitle: "Stop Time Trial",
          systemImageName: "stop.circle"
        ),
        AppShortcut(
          intent: ShowManualRoastIntent(),
          phrases: ["Show manual roast in ${applicationName}"],
          shortTitle: "Show Manual Roast",
          systemImageName: "flame"
        ),
      ]
    }
  }

  // MARK: - App Intents

  enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case message(_ message: String)

    var localizedStringResource: LocalizedStringResource {
      switch self {
      case let .message(message): return "\(message)"
      }
    }
  }

  @available(macOS 13.0, *)
  // Keep this in sync with `AppSettings` constants!
  struct SpawnFliesIntent: AppIntent {
    static var title: LocalizedStringResource = "Spawn Flies"
    static var description = IntentDescription(
      "Spawns a number of flies up to a maximum value. Respects a global cap of 40 and won't run during an active time trial."
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Spawn Count (1 to 40)", default: 1, inclusiveRange: (1, 40))
    var spawnCount: Int

    @Parameter(title: "Max Count (1 to 40)", default: 40, inclusiveRange: (1, 40))
    var maxCount: Int

    static var parameterSummary: some ParameterSummary {
      Switch(\.$spawnCount) {
        Case(1) {
          Summary("Spawn \(\.$spawnCount) fly up to a maximum of \(\.$maxCount)")
        }
        DefaultCase {
          Summary("Spawn \(\.$spawnCount) flies up to a maximum of \(\.$maxCount)")
        }
      }
    }

    func perform() async throws -> some ReturnsValue<Int?> {
      guard spawnCount <= maxCount else {
        throw IntentError.message("Spawn count must not exceed max count.")
      }
      let spawned = await MainActor.run {
        IntentsManager.shared.spawnFlies(spawnCount: spawnCount, maxCount: maxCount)
      }
      return .result(value: spawned)
    }
  }

  @available(macOS 13.0, *)
  struct KillAllFliesIntent: AppIntent {
    static var title: LocalizedStringResource = "Kill All Flies"
    static var description = IntentDescription(
      "Kills all active flies. Plays a sound effect if enabled and won't run during an active time trial."
    )
    static var openAppWhenRun: Bool = true

    @Parameter(
      title: "Play Sound Effects",
      default: false,
      displayName: Bool.IntentDisplayName(true: "on", false: "off")
    )
    var playSoundEffects: Bool

    static var parameterSummary: some ParameterSummary {
      Summary("Kill all flies with sound effects \(\.$playSoundEffects)")
    }

    func perform() async throws -> some ReturnsValue<Bool> {
      let didKill = await MainActor.run {
        IntentsManager.shared.killAllFlies(playSoundEffects: playSoundEffects)
      }
      return .result(value: didKill)
    }
  }

  @available(macOS 13.0, *)
  enum SpawnModeIntentOption: String, AppEnum {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Spawn Mode")

    case none = "None"
    case auto = "Auto-Spawn"

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
      .none: "None",
      .auto: "Auto-Spawn",
    ]
  }

  @available(macOS 13.0, *)
  // Keep this in sync with `AppSettings` constants!
  struct SetSpawnModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Spawn Mode"
    static var description = IntentDescription(
      "Switches spawn mode; if Auto-Spawn is selected, provides optional configuration to replace the current Auto-Spawn settings."
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Spawn Mode")
    var spawnMode: SpawnModeIntentOption

    @Parameter(title: "Auto-Spawn Initial Count (1 to 40)", default: 10, inclusiveRange: (1, 40))
    var initialCount: Int?

    @Parameter(title: "Auto-Spawn Max Count (1 to 40)", default: 30, inclusiveRange: (1, 40))
    var maxCount: Int?

    @Parameter(
      title: "Auto-Spawn Interval Seconds (1 to 300)",
      default: 5, inclusiveRange: (1, 300)
    )
    var intervalSeconds: Double?

    func perform() async throws -> some ReturnsValue<Bool> {
      let spawnModeMapped: AppSettings.SpawnMode = (spawnMode == .none) ? .none : .auto
      let didUpdate = await MainActor.run {
        IntentsManager.shared.setSpawnMode(
          mode: spawnModeMapped,
          initialCount: (spawnModeMapped == .auto) ? initialCount : nil,
          maxCount: (spawnModeMapped == .auto) ? maxCount : nil,
          intervalSeconds: (spawnModeMapped == .auto) ? intervalSeconds : nil
        )
      }
      return .result(value: didUpdate)
    }
  }

  @available(macOS 13.0, *)
  // Keep this in sync with `AppSettings` constants!
  struct StartTimeTrialIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Time Trial"
    static var description = IntentDescription(
      "Starts a time trial using the provided initial fly count."
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Initial Count (1 to 40)", default: 10, inclusiveRange: (1, 40))
    var initialCount: Int

    static var parameterSummary: some ParameterSummary {
      Summary("Start time trial with \(\.$initialCount) flies")
    }

    func perform() async throws -> some ReturnsValue<Int?> {
      let didStart = await MainActor.run {
        IntentsManager.shared.startTimeTrial(initialCount: initialCount)
      }
      return .result(value: didStart ? initialCount : nil)
    }
  }

  @available(macOS 13.0, *)
  struct StopTimeTrialIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Time Trial"
    static var description = IntentDescription("Stops an active time trial if one is running.")
    static var openAppWhenRun: Bool = true

    static var parameterSummary: some ParameterSummary {
      Summary("Stop time trial")
    }

    func perform() async throws -> some ReturnsValue<Bool> {
      let didStop = await MainActor.run {
        IntentsManager.shared.stopTimeTrial()
      }
      return .result(value: didStop)
    }
  }

  @available(macOS 13.0, *)
  struct ShowManualRoastIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Manual Roast"
    static var description = IntentDescription("Shows a manual roast on a random fly.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Roast Text")
    var text: String

    static var parameterSummary: some ParameterSummary {
      Summary("Show manual roast with text \(\.$text) or clear if empty")
    }

    func perform() async throws -> some ReturnsValue<Bool> {
      let didShow = await MainActor.run {
        IntentsManager.shared.showManualRoast(text: text)
      }
      return .result(value: didShow)
    }
  }
#endif
