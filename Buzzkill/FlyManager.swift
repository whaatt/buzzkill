//
//  FlyManager.swift
//  Buzzkill
//
//  Manager class for the fly population.
//

import AppKit
import AudioToolbox
import Combine
import Foundation

// MARK: - Fly Manager

@MainActor
class FlyManager: ObservableObject {
  // Constants.
  private let scareRadius: CGFloat = 64.0  // 1X fly size (64 pixels).

  // Exposed data for rendering.
  @Published var flies: [Fly] = []

  // Reference to the swatter manager so we can process suspicion and cone strikes.
  private weak var swatterManager: SwatterManager?

  // Timer data.
  private var spawnTimer: AsyncRepeatingTimer?
  private var updateTimer: AsyncRepeatingTimer?
  private var lastUpdateTime: TimeInterval = 0

  // Settings-backed spawn controls.
  private var spawnMode: AppSettings.SpawnMode = .auto
  private var initialFlyCount: Int = 0
  private var intervalSeconds: Double = 5.0
  private var maxFlyCount: Int = 30

  // Event observers.
  private var cancellables = Set<AnyCancellable>()

  init() {
    // Set up event observers.
    Events.killAllFlies
      .sink { [weak self] playSoundEffects in
        self?.killAllFlies(playSoundEffects: playSoundEffects)
      }
      .store(in: &cancellables)
    Events.showRoast
      .sink { [weak self] (text) in
        self?.setRoast(text: text)
      }
      .store(in: &cancellables)

    // Default to auto spawn with defaults; can be overridden via settings.
    applySpawnSettings(
      mode: AppSettings.shared.spawn.mode,
      initialCount: AppSettings.shared.spawn.initialCount,
      maxCount: AppSettings.shared.spawn.maxCount,
      interval: AppSettings.shared.spawn.intervalSeconds
    )
    startUpdating()
  }

  deinit {
    spawnTimer?.invalidate()
    updateTimer?.invalidate()
  }

  private func startUpdating() {
    lastUpdateTime = CACurrentMediaTime()
    let timer = AsyncRepeatingTimer(interval: .milliseconds(16)) { [weak self] in
      await self?.update()
    }
    updateTimer = timer
    timer.start()
  }

  private func getRenderBounds() -> CGRect? {
    guard
      let window = NSApp.windows.first(where: {
        $0.identifier == BuzzkillApp.Constants.overlayWindowIdentifier
      })
    else {
      return nil
    }
    guard let screen = window.screen else {
      return nil
    }
    return CGRect(
      x: 0,
      y: 0,
      width: screen.frame.width,
      height: screen.frame.height
    )
  }

  private func update() {
    guard let renderBounds = getRenderBounds() else {
      return
    }

    let currentTime = CACurrentMediaTime()
    let deltaTime = currentTime - lastUpdateTime
    lastUpdateTime = currentTime

    // Determine the active threat cone for suspicion processing.
    let activeCone = swatterManager?.activeThreatCone
    let swatReleaseTime = swatterManager?.swatReleaseTime
    let recentSwatFactor = Double(swatterManager?.recentSwatCount ?? 0)

    // Create a copy of the flies array to pass to each fly.
    let otherFlies = flies

    for fly in flies {
      // Find all other flies, excluding the current one.
      let fliesToConsider = otherFlies.filter { $0.id != fly.id }
      fly.update(
        deltaTime: deltaTime,
        renderBounds: renderBounds,
        otherFlies: fliesToConsider
      )

      // Suspicion processing.
      fly.processConeThreat(
        cone: activeCone,
        swatReleaseTime: swatReleaseTime,
        recentSwatFactor: recentSwatFactor,
        deltaTime: deltaTime
      )
    }

    // Remove flies once they're dead and goop has dissipated.
    cleanupDeadFlies()
  }

  // MARK: - Spawn Helpers

  private func resetSpawnTimer() {
    spawnTimer?.invalidate()
    guard spawnMode == .auto else {
      return
    }
    let timer = AsyncRepeatingTimer(
      interval: .milliseconds(
        Int(intervalSeconds * 1000)
      )
    ) { [weak self] in
      await self?.handleSpawnTimer()
    }
    spawnTimer = timer
    timer.start()
  }

  private func handleSpawnTimer() {
    if flies.count < maxFlyCount {
      spawnFly()
    }
  }

  private func spawnFly() {
    guard let renderBounds = getRenderBounds() else {
      return
    }

    // Determine a random edge to spawn from.
    let edge = ["left", "right", "top", "bottom"].randomElement()!
    var x: CGFloat = 0.0
    var y: CGFloat = 0.0
    let margin: CGFloat = 100.0

    switch edge {
    case "left":
      x = -margin
      y = CGFloat.random(in: 0...renderBounds.height)
    case "right":
      x = renderBounds.width + margin
      y = CGFloat.random(in: 0...renderBounds.height)
    case "top":
      x = CGFloat.random(in: 0...renderBounds.width)
      y = renderBounds.height + margin
    default:  // Bottom.
      x = CGFloat.random(in: 0...renderBounds.width)
      y = -margin
    }

    let newFly = Fly(position: CGPoint(x: x, y: y))
    flies.append(newFly)
  }

  @discardableResult
  func ensureInitialPopulation(count: Int) -> Int {
    let desiredCount = count
    let aliveCount = flies.reduce(0) { partial, fly in
      partial + (fly.isAlive ? 1 : 0)
    }
    let toSpawn = max(0, desiredCount - aliveCount)
    if toSpawn > 0 {
      for _ in 0..<toSpawn {
        spawnFly()
      }
    }
    return toSpawn
  }

  func spawnInitial(count: Int) {
    flies.removeAll()
    for _ in 0..<count {
      spawnFly()
    }
  }

  func killAllFlies(playSoundEffects: Bool = true) {
    // Don't kill flies until we remove existing goop.
    // Don't remove existing goop unless there are flies to kill.
    if flies.contains(where: { $0.isAlive }) {
      flies.removeAll { fly in
        !fly.isAlive
      }
    }
    if playSoundEffects {
      // System poof sound.
      AudioServicesPlaySystemSound(0xF)
    }
    // Kill flies to create new goop.
    for fly in flies where fly.isAlive {
      fly.swat(isBatchKill: true)
    }
  }

  private func cleanupDeadFlies() {
    flies.removeAll { fly in
      !fly.isAlive && fly.goopParticles.isEmpty
    }
    // Notify time trial if cleared.
    if flies.filter({ $0.isAlive }).isEmpty {
      Events.allFliesCleared.send(())
    }
  }

  // MARK: - Cone-Based Swatting

  /// Strike any flies that fall within the provided cone.
  func swatFlies(in cone: SwatCone) {
    for fly in flies where fly.isAlive {
      let corners = fly.getCorners()
      // A fly is swatted if any of its corners are inside the cone.
      let anyCornerInCone = corners.contains { corner in
        cone.contains(point: corner)
      }
      if anyCornerInCone {
        fly.swat(angle: atan2(cone.direction.dy, cone.direction.dx))
      }
    }
  }

  /// Allows the overlay view to inject the swatter manager after
  /// `@StateObject` initialization.
  func setSwatterManager(_ manager: SwatterManager) {
    swatterManager = manager
  }

  /// Scare flies from the given position.
  func scareFlies(from position: CGPoint) {
    for fly in flies where fly.isAlive {
      let distance = sqrt(
        pow(fly.position.x - position.x, 2) + pow(fly.position.y - position.y, 2)
      )
      if distance < scareRadius {
        fly.scare()
      }
    }
  }

  // MARK: - Settings Integration

  func applySpawnSettings(
    mode: AppSettings.SpawnMode,
    initialCount: Int,
    maxCount: Int,
    interval: Double
  ) {
    let gotModeChange = spawnMode != mode
    spawnMode = mode

    let gotInitialCountChange = initialFlyCount != initialCount
    initialFlyCount = initialCount
    maxFlyCount = maxCount
    intervalSeconds = interval

    // On mode change, reset timer and re-seed initial population (if mode changed to Auto-Spawn or
    // if the initial count changed while in Auto-Spawn mode).
    resetSpawnTimer()
    if mode == .auto && (gotModeChange || gotInitialCountChange) {
      ensureInitialPopulation(count: initialCount)
    }
  }

  // MARK: - Roasts

  func setRoast(text: String?) {
    // Clear any existing roasts.
    flies.forEach { $0.roastText = nil }

    // Add non-empty roasts to a random (and alive) fly.
    if let textTrimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
      !textTrimmed.isEmpty
    {
      ensureInitialPopulation(count: 1)
      let flyToRoast = flies.filter { $0.isAlive }.randomElement()
      flyToRoast?.roastText = textTrimmed
    }
  }
}
