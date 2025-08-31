//
//  Fly.swift
//  Buzzkill
//
//  Core fly class and related types.
//

import AppKit
import Foundation

// MARK: - Fly Class

class Fly: ObservableObject, Identifiable {
  // MARK: - Configuration

  private struct FlyConstants {
    // Animation.
    static let wingFlapRate = 10.0
    static let wingFrameCount = 4
    static let targetSize = CGSize(width: 24, height: 24)

    // Movement.
    static let baseSpeedRange = 18.0...32.0
    static let agitationDecayFactor = 0.995
    static let agitationScareIncrease = 0.1
    static let maxAgitation = 1.0
    static let randomAgitationMeanInterval = 15.0  // Mean time between agitation spikes.
    // `lambda = ln(2) / meanInterval` for 50% probability over the interval.
    static let randomAgitationRate = log(2.0) / randomAgitationMeanInterval

    // Behavior timing.
    static let microMovementInterval = 0.1
    static let behaviorChangeRandomness = 0.015
    static let erraticStutterChance = 0.2
    static let maxConsecutiveStutters = 2

    // Boundaries.
    static let softBoundaryMargin = 20.0
    static let escapeRedirectMargin = 200.0
    static let nudgeStrength = 2.0
    static let targetApproachDistance = 15.0
    static let flightOvershootLimit = 1.1

    // Clustering.
    static let clusterRadius = 100.0
    static let clusterTargetChance = 0.6
    static let maxTargetAttempts = 15

    // Speed multipliers.
    static let hoverSpeedMultiplier = 0.3
    static let flyingSpeedMultiplier = 0.4
    static let circularSpeedMultiplier = 0.6

    // Probabilities.
    static let flyOffScreenChance = 0.3
    static let intensityBoostChance = 0.025

    // Velocity limiting.
    static let maxFlightVelocity = 200.0  // Cap velocity during flight.
    static let panicDampeningFactor = 0.6  // Reduce chaos when panicking.

    // Scared behavior.
    static let scareEscapeMinDistancePercent = 0.1  // 10% of screen diagonal.
    static let scareEscapeMaxDistancePercent = 0.3  // 30% of screen diagonal.

    // Spawn probabilities by personality.
    static let spawnProbabilities: [Personality: Double] = [
      .lazy: 0.7,
      .nervous: 0.2,
      .erratic: 0.1,
    ]
  }

  private struct GoopSplatterConstants {
    static let particleCount = 15...30
    static let particleSizeRange = 15.0...35.0
    static let particleSpeedRange = 100.0...500.0
    static let fadeOutDuration = 8.0...12.0
    static let dampingFactor = 0.90
    static let dampingFrequency = 60.0
  }

  private struct PersonalityTraits: Hashable {
    let name: String
    let transitionTimeRange: ClosedRange<Double>
    let jitterIntensity: Double
    let stutterFrequency: Double
    let stutterIntensity: Double
    let arcHeightMultiplier: ClosedRange<Double>
    let durationRange: ClosedRange<Double>
    let circleRadiusRange: ClosedRange<Double>
    let angularSpeedRange: ClosedRange<Double>
    let settlingTimeRange: ClosedRange<Double>
    let wobbleIntensity: Double
    let wobbleFrequencyX: Double
    let wobbleFrequencyY: Double
    let directionChaosX: Double
    let directionChaosY: Double
    let agitationRange: ClosedRange<Double>

    static let lazy = PersonalityTraits(
      name: "Lazy",
      transitionTimeRange: 3.5...7.0,
      jitterIntensity: 5.0,
      stutterFrequency: 0.8,
      stutterIntensity: 12.0,
      arcHeightMultiplier: 0.1...0.35,
      durationRange: 1.4...2.2,
      circleRadiusRange: 30.0...45.0,
      angularSpeedRange: 1.0...2.0,
      settlingTimeRange: 0.6...1.2,
      wobbleIntensity: 8.0,
      wobbleFrequencyX: 8.0,
      wobbleFrequencyY: 6.0,
      directionChaosX: 0.0,
      directionChaosY: 0.0,
      agitationRange: 0.0...0.3
    )

    static let nervous = PersonalityTraits(
      name: "Nervous",
      transitionTimeRange: 1.0...2.8,
      jitterIntensity: 15.0,
      stutterFrequency: 3.5,
      stutterIntensity: 22.0,
      arcHeightMultiplier: 0.2...0.6,
      durationRange: 0.8...1.4,
      circleRadiusRange: 25.0...50.0,
      angularSpeedRange: 2.0...4.0,
      settlingTimeRange: 0.4...0.8,
      wobbleIntensity: 25.0,
      wobbleFrequencyX: 18.0,
      wobbleFrequencyY: 15.0,
      directionChaosX: 8.0,
      directionChaosY: 6.0,
      agitationRange: 0.3...0.75
    )

    static let erratic = PersonalityTraits(
      name: "Erratic",
      transitionTimeRange: 0.5...3.5,
      jitterIntensity: 15.0,
      stutterFrequency: 5.5,
      stutterIntensity: 25.0,
      arcHeightMultiplier: 0.3...0.8,
      durationRange: 0.6...1.8,
      circleRadiusRange: 20.0...60.0,
      angularSpeedRange: 1.5...6.0,
      settlingTimeRange: 0.3...1.0,
      wobbleIntensity: 18.0,
      wobbleFrequencyX: 20.0,
      wobbleFrequencyY: 25.0,
      directionChaosX: 8.0,
      directionChaosY: 7.0,
      agitationRange: 0.75...1.0
    )
  }

  private struct SuspicionConstants {
    /// The rate at which suspicion decays when there is no threat cone.
    static let passiveDecayRate: CGFloat = 0.1
    /// The rate at which suspicion decays when a fly is outside an active threat cone.
    static let activeDecayRate: CGFloat = 0.05
    /// The weight of the fly's proximity to the cone's origin in the suspicion calculation.
    static let proximityWeight: CGFloat = 2.0
    /// The weight of the cone's stretch in the suspicion calculation.
    static let stretchWeight: CGFloat = 0.5
    /// The maximum stretch value to consider for the stretch factor. A value of 2.0 means
    /// the suspicion contribution maxes out when the swat is stretched to twice its normal length.
    static let maxStretchForFactor: CGFloat = 2.0
    /// An overall multiplier for how quickly suspicion builds.
    static let buildMultiplier: CGFloat = 1.3
    /// The suspicion level at which a fly will be triggered to flee (inclusive).
    /// At the moment, we clamp suspicion to 1.0 and require full suspicion to flee.
    static let fleeThreshold: CGFloat = 1.0
    /// How much the "recent swats" factor affects suspicion build-up. A value of 0.5 means
    /// that for each recently swatted fly, the suspicion build rate increases by 50%.
    static let recentSwatImpactFactor: CGFloat = 0.6
    /// The base time it takes for a fly to notice a released swat.
    static let swatReleaseNoticeTime: TimeInterval = 0.15
    /// How much suspicion reduces the time to notice a released swat. A value of 1.0 means
    /// a fly with maximum suspicion will notice instantly.
    static let suspicionNoticeTimeReductionFactor: TimeInterval = 1.0
    /// The time it takes for a fly to be able to be scared by a cone again.
    static let coneScareCooldown: TimeInterval = 1.0
  }

  // MARK: - Properties

  let id = UUID()

  @Published var position: CGPoint
  @Published var isAlive: Bool = true
  @Published var wingFrame: Int = 0
  @Published var facingRight: Bool = true
  @Published var rotation: Double = 0.0  // In degrees.
  @Published var goopParticles: [GoopParticle] = []
  @Published var goopOpacity: Double = 0.0
  @Published var suspicionLevel: CGFloat = 0.0  // In [0, 1].
  @Published var roastText: String? = nil
  @Published var velocity: CGPoint = .zero  // Will be set by initial behavior.
  /// When true, `SoundManager` should not play a death/splat sound for this fly.
  var suppressDeathSound: Bool = false

  private var wingAnimationTimer: Double = 0.0
  private var goopCreationTime: Date?

  // Personality and agitation.
  private var personality: Personality = .lazy  // Ignored default (overridden on init).
  private var personalityTraits: PersonalityTraits = PersonalityTraits.lazy  // Ignored default.
  private var agitationLevel: Double = 0.0  // Ignored default.
  private var scaredAndNeedsToFly: Bool = false
  private var randomAgitationTimer: Double = 0.0
  private var timeInsideCone: TimeInterval = 0.0
  private var lastConeScareTime: Date?

  // Behavior system.
  @Published var behaviorState: Behavior = .hovering  // Ignored default.
  @Published var ranFirstUpdate: Bool = false
  private var behaviorTimer: Double = 0.0
  private var nextStateTransition: Double = 0.0
  private var baseSpeed: Double = Double.random(in: FlyConstants.baseSpeedRange)

  // Behavior-specific properties.
  private var targetPosition: CGPoint?
  private var flightData: FlightData?
  private var circlingData: CirclingData?
  private var microMovementTimer: Double = 0.0

  private static func getTraits(for personality: Personality) -> PersonalityTraits {
    switch personality {
    case .nervous: return PersonalityTraits.nervous
    case .lazy: return PersonalityTraits.lazy
    case .erratic: return PersonalityTraits.erratic
    }
  }

  init(position: CGPoint) {
    self.position = position
    self.personality = Self.weightedRandom(dict: FlyConstants.spawnProbabilities)
    self.personalityTraits = Self.getTraits(for: personality)
    self.agitationLevel = personalityTraits.agitationRange.upperBound
  }

  private static func weightedRandom<T>(dict: [T: Double]) -> T {
    let total = dict.values.reduce(0, +)
    let random = Double.random(in: 0...total)
    var cumulative = 0.0
    for (key, value) in dict {
      cumulative += value
      if random <= cumulative {
        return key
      }
    }
    return dict.first!.key
  }

  func update(deltaTime: TimeInterval, renderBounds: CGRect, otherFlies: [Fly]) {
    guard deltaTime > 0 else {
      return
    }
    guard isAlive else {
      updateGoop(deltaTime: deltaTime)
      return
    }
    guard ranFirstUpdate else {
      transitionToFlying(
        renderBounds: renderBounds,
        otherFlies: otherFlies,
        isScared: false
      )
      ranFirstUpdate = true
      return
    }

    updateAgitation(deltaTime: deltaTime)
    updatePersonality()
    updateMovement(deltaTime: deltaTime, renderBounds: renderBounds, otherFlies: otherFlies)
    updateAnimation(deltaTime: deltaTime)
    updateGoop(deltaTime: deltaTime)
  }

  func swat(angle: Double? = nil, isBatchKill: Bool = false) {
    guard isAlive else {
      return
    }
    isAlive = false

    createGoopSplatter(angle: angle, isBatchKill: isBatchKill)
    suppressDeathSound = isBatchKill

    // Set velocity last since the goop splatter may use its angle.
    velocity = .zero
  }

  func scare(fromSwatter: Bool = false) {
    agitationLevel = min(
      FlyConstants.maxAgitation,
      agitationLevel + FlyConstants.agitationScareIncrease
    )
    if fromSwatter {
      agitationLevel = FlyConstants.maxAgitation
    }
    scaredAndNeedsToFly = true
  }

  private func updateAgitation(deltaTime: TimeInterval) {
    // Check for random agitation using exponential distribution.
    // P(spike in `dt`) = `1 - e^(-lambda * dt)`.
    let spikeChance = 1.0 - exp(-FlyConstants.randomAgitationRate * deltaTime)
    if Double.random(in: 0...1) < spikeChance {
      agitationLevel = Double.random(in: 0.0...FlyConstants.maxAgitation)
    }
    agitationLevel *= FlyConstants.agitationDecayFactor
  }

  private func createGoopSplatter(angle: Double? = nil, isBatchKill: Bool = false) {
    // Use a single particle for batch kills.
    let count = isBatchKill ? 1 : Int.random(in: GoopSplatterConstants.particleCount)
    for _ in 0..<count {
      let angle =
        angle == nil
        ? atan2(velocity.y, velocity.x)
        : angle! + Double.random(in: (-.pi / 2.0)...(.pi / 2.0))
      let speed = Double.random(in: GoopSplatterConstants.particleSpeedRange)
      let velocity = CGPoint(x: cos(angle) * speed, y: sin(angle) * speed)
      // Use max size particle for batch kills.
      let size =
        isBatchKill
        ? GoopSplatterConstants.particleSizeRange.upperBound
        : Double.random(in: GoopSplatterConstants.particleSizeRange)
      let particle = GoopParticle(
        position: position,
        velocity: velocity,
        size: size
      )
      goopParticles.append(particle)
    }
    goopCreationTime = Date()
    goopOpacity = 1.0
  }

  private func updateGoop(deltaTime: TimeInterval) {
    guard let creationTime = goopCreationTime else {
      return
    }

    for i in 0..<goopParticles.count {
      goopParticles[i].position.x += goopParticles[i].velocity.x * deltaTime
      goopParticles[i].position.y += goopParticles[i].velocity.y * deltaTime
      let damping = pow(
        GoopSplatterConstants.dampingFactor,
        deltaTime * GoopSplatterConstants.dampingFrequency
      )
      goopParticles[i].velocity.x *= damping
      goopParticles[i].velocity.y *= damping
    }

    let timeSinceCreation = Date().timeIntervalSince(creationTime)
    let fadeOutDuration = GoopSplatterConstants.fadeOutDuration.upperBound
    if timeSinceCreation >= fadeOutDuration {
      goopOpacity = 0.0
      goopParticles.removeAll()
      goopCreationTime = nil
    } else {
      goopOpacity = 1.0 - (timeSinceCreation / fadeOutDuration)
    }
  }

  private func updatePersonality() {
    let newPersonality: Personality
    if agitationLevel >= PersonalityTraits.erratic.agitationRange.lowerBound {
      newPersonality = .erratic
    } else if agitationLevel >= PersonalityTraits.nervous.agitationRange.lowerBound {
      newPersonality = .nervous
    } else {
      newPersonality = .lazy
    }

    if newPersonality != personality {
      personality = newPersonality
      personalityTraits = Self.getTraits(for: personality)
    }
  }
}

// MARK: - Data Structures

extension Fly {
  enum Personality {
    case nervous
    case lazy
    case erratic
  }

  enum Behavior {
    case hovering
    case flying
    case circling
  }

  struct GoopParticle: Identifiable {
    let id = UUID()
    var position: CGPoint
    var velocity: CGPoint
    var size: Double
  }

  struct FlightData {
    let startPosition: CGPoint
    let duration: Double
    let arcHeight: Double
    var stutterTimer: Double = 0.0
    var intensityBoost: Double = 1.0
    var isReturningToScreen: Bool = false
    var isScared: Bool = false
  }

  struct CirclingData {
    let radius: Double
    let angularSpeed: Double
    let settlingTime: Double
  }
}

// MARK: - Animation Updates

extension Fly {
  private func updateAnimation(deltaTime: TimeInterval) {
    guard isAlive else {
      return
    }

    wingAnimationTimer += deltaTime
    if wingAnimationTimer >= 1.0 / FlyConstants.wingFlapRate {
      wingFrame = (wingFrame + 1) % FlyConstants.wingFrameCount
      wingAnimationTimer = 0
    }
  }
}

// MARK: - Movement System

extension Fly {
  private func updateMovement(deltaTime: TimeInterval, renderBounds: CGRect, otherFlies: [Fly]) {
    if !isAlive {
      updatePosition(deltaTime: deltaTime)
      return
    }

    // Handle behavior transitions.
    behaviorTimer += deltaTime
    if scaredAndNeedsToFly {
      transitionToFlying(
        renderBounds: renderBounds,
        otherFlies: otherFlies,
        isScared: true
      )
      scaredAndNeedsToFly = false
    } else if behaviorState != .flying, behaviorTimer > nextStateTransition {
      transitionToNextBehavior(renderBounds: renderBounds, otherFlies: otherFlies)
    }

    // Update movement based on current behavior.
    updateBehaviorMovement(deltaTime: deltaTime, renderBounds: renderBounds)

    // Apply movement (flying behavior handles position directly).
    if behaviorState != .flying {
      updatePosition(deltaTime: deltaTime)
    }

    // Handle screen boundary collisions.
    handleScreenBoundaries(renderBounds: renderBounds, otherFlies: otherFlies)

    // Update facing direction and rotation based on final velocity.
    updateFacingAndRotation()
  }

  private func updatePosition(deltaTime: TimeInterval) {
    position.x += velocity.x * deltaTime
    position.y += velocity.y * deltaTime
  }

  private func updateBehaviorMovement(deltaTime: TimeInterval, renderBounds: CGRect) {
    switch behaviorState {
    case .hovering:
      updateHoveringMovement(deltaTime: deltaTime)
    case .flying:
      updateFlyingMovement(deltaTime: deltaTime, renderBounds: renderBounds)
    case .circling:
      updateCirclingMovement(deltaTime: deltaTime)
    }
  }
}

// MARK: - Hovering Behavior

extension Fly {
  private func updateHoveringMovement(deltaTime: TimeInterval) {
    applyMicroMovements(deltaTime: deltaTime)
    applyRandomMovements()
  }

  private func applyMicroMovements(deltaTime: TimeInterval) {
    microMovementTimer += deltaTime

    if microMovementTimer > FlyConstants.microMovementInterval {
      microMovementTimer = 0

      let jitterX = Double.random(
        in: -personalityTraits.jitterIntensity...personalityTraits.jitterIntensity
      )
      let jitterY = Double.random(
        in: -personalityTraits.jitterIntensity...personalityTraits.jitterIntensity
      )

      velocity.x += jitterX
      velocity.y += jitterY

      let maxSpeed = baseSpeed * 0.5
      velocity = limitSpeed(velocity: velocity, maxSpeed: maxSpeed)
    }
  }

  private func applyRandomMovements() {
    if Double.random(in: 0...1) < FlyConstants.behaviorChangeRandomness {
      let randomForce = 10.0
      velocity.x += Double.random(in: -randomForce...randomForce)
      velocity.y += Double.random(in: -randomForce...randomForce)

      let maxHoverSpeed = baseSpeed * FlyConstants.hoverSpeedMultiplier
      velocity = limitSpeed(velocity: velocity, maxSpeed: maxHoverSpeed)
    }
  }
}

// MARK: - Flying Behavior

extension Fly {
  private func updateFlyingMovement(deltaTime: TimeInterval, renderBounds: CGRect) {
    guard let target = targetPosition, let flightData = flightData else {
      return
    }

    let progress = behaviorTimer / flightData.duration
    position = calculateFlightPosition(
      progress: progress,
      flightData: flightData,
      deltaTime: deltaTime
    )

    // Check if we're close enough to target to transition.
    let distanceToTarget = distance(from: position, to: target)
    if distanceToTarget < FlyConstants.targetApproachDistance
      || progress >= FlyConstants.flightOvershootLimit
    {
      velocity = CGPoint(
        x: velocity.x * FlyConstants.hoverSpeedMultiplier,
        y: velocity.y * FlyConstants.hoverSpeedMultiplier)
      transitionToCircling()
    }
  }

  private func calculateFlightPosition(
    progress: Double,
    flightData: FlightData,
    deltaTime: TimeInterval
  ) -> CGPoint {
    guard let target = targetPosition else {
      return position
    }

    let start = flightData.startPosition
    var currentFlightData = flightData
    currentFlightData.stutterTimer += deltaTime

    // Apply intensity boost randomly.
    if Double.random(in: 0...1) < FlyConstants.intensityBoostChance {
      currentFlightData.intensityBoost = Double.random(in: 0.4...2.0)
    }

    // Calculate base position with limited overshoot.
    let adjustedProgress = min(progress, FlyConstants.flightOvershootLimit)
    let basePosition = interpolatePosition(start: start, target: target, progress: adjustedProgress)

    // Apply chaotic effects that fade as we approach target.
    let fadeOutFactor = calculateFadeOutFactor(progress: progress)
    let chaoticEffects = calculateChaoticEffects(
      flightData: currentFlightData,
      fadeOutFactor: fadeOutFactor
    )
    let finalPosition = CGPoint(
      x: basePosition.x + chaoticEffects.x,
      y: basePosition.y + chaoticEffects.y
    )

    // Match velocity to hit the final position.
    updateVelocityFromMovement(newPosition: finalPosition, deltaTime: deltaTime)

    self.flightData = currentFlightData
    return finalPosition
  }

  private func interpolatePosition(start: CGPoint, target: CGPoint, progress: Double) -> CGPoint {
    return CGPoint(
      x: start.x + (target.x - start.x) * progress,
      y: start.y + (target.y - start.y) * progress
    )
  }

  private func calculateFadeOutFactor(progress: Double) -> Double {
    return max(0.0, 1.0 - (progress - 0.8) * 5.0)
  }

  private func calculateChaoticEffects(flightData: FlightData, fadeOutFactor: Double) -> CGPoint {
    let arcEffect = calculateArcEffect(flightData: flightData, fadeOutFactor: fadeOutFactor)
    let stutterEffect = calculateStutterEffect(flightData: flightData, fadeOutFactor: fadeOutFactor)
    let wobbleEffect = calculateWobbleEffect(flightData: flightData, fadeOutFactor: fadeOutFactor)
    let directionEffect = calculateDirectionEffect(
      flightData: flightData,
      fadeOutFactor: fadeOutFactor
    )

    // Apply panic dampening to reduce extreme chaos when scared.
    let panicFactor = flightData.isScared ? FlyConstants.panicDampeningFactor : 1.0

    return CGPoint(
      x: (wobbleEffect.x + directionEffect.x + stutterEffect.x) * panicFactor,
      y: (arcEffect + wobbleEffect.y + directionEffect.y + stutterEffect.y) * panicFactor
    )
  }

  private func calculateArcEffect(flightData: FlightData, fadeOutFactor: Double) -> Double {
    let arcFrequency = personalityTraits.stutterFrequency * 0.8
    let arcPhase = behaviorTimer * arcFrequency
    let arcIntensity = sin(arcPhase) * cos(arcPhase * 1.4) * flightData.intensityBoost
    let arcMultiplier = personalityTraits.arcHeightMultiplier.lowerBound * 2.0
    return flightData.arcHeight * arcIntensity * arcMultiplier * fadeOutFactor
  }

  private func calculateStutterEffect(flightData: FlightData, fadeOutFactor: Double) -> CGPoint {
    let stutterPhaseX = sin(behaviorTimer * personalityTraits.stutterFrequency * 2 * .pi)
    let stutterPhaseY = cos(behaviorTimer * personalityTraits.stutterFrequency * 1.7 * .pi)
    return CGPoint(
      x: stutterPhaseX * personalityTraits.stutterIntensity * flightData.intensityBoost
        * fadeOutFactor,
      y: stutterPhaseY * personalityTraits.stutterIntensity * flightData.intensityBoost
        * fadeOutFactor
    )
  }

  private func calculateWobbleEffect(flightData: FlightData, fadeOutFactor: Double) -> CGPoint {
    let wobbleX =
      sin(behaviorTimer * personalityTraits.wobbleFrequencyX) * personalityTraits.wobbleIntensity
    let wobbleY =
      cos(behaviorTimer * personalityTraits.wobbleFrequencyY) * personalityTraits.wobbleIntensity
    return CGPoint(
      x: wobbleX * flightData.intensityBoost * 0.6 * fadeOutFactor,
      y: wobbleY * flightData.intensityBoost * 0.6 * fadeOutFactor
    )
  }

  private func calculateDirectionEffect(flightData: FlightData, fadeOutFactor: Double) -> CGPoint {
    let directionX =
      personalityTraits.directionChaosX > 0
      ? (sin(behaviorTimer * 8.0) * personalityTraits.directionChaosX + sin(behaviorTimer * 3.2)
        * personalityTraits.directionChaosX * 0.6) * flightData.intensityBoost * fadeOutFactor
      : 0.0
    let directionY =
      personalityTraits.directionChaosY > 0
      ? (cos(behaviorTimer * 7.5) * personalityTraits.directionChaosY + cos(behaviorTimer * 2.8)
        * personalityTraits.directionChaosY * 0.6) * flightData.intensityBoost * fadeOutFactor
      : 0.0
    return CGPoint(x: directionX, y: directionY)
  }

  private func updateVelocityFromMovement(newPosition: CGPoint, deltaTime: TimeInterval) {
    let deltaX = newPosition.x - position.x
    let deltaY = newPosition.y - position.y
    let newVelocity = CGPoint(x: deltaX / deltaTime, y: deltaY / deltaTime)

    // Limit velocity to prevent extreme speeds.
    velocity = limitSpeed(velocity: newVelocity, maxSpeed: FlyConstants.maxFlightVelocity)
  }
}

// MARK: - Circling Behavior

extension Fly {
  private func updateCirclingMovement(deltaTime: TimeInterval) {
    guard let target = targetPosition, let circlingData = circlingData else {
      return
    }

    let angle = behaviorTimer * circlingData.angularSpeed
    let targetPosition = CGPoint(
      x: target.x + cos(angle) * circlingData.radius,
      y: target.y + sin(angle) * circlingData.radius
    )
    let circularVelocity = CGPoint(
      x: (targetPosition.x - position.x) * FlyConstants.circularSpeedMultiplier,
      y: (targetPosition.y - position.y) * FlyConstants.circularSpeedMultiplier
    )

    // Smooth settling into circular motion.
    if behaviorTimer < circlingData.settlingTime {
      let settlingProgress = behaviorTimer / circlingData.settlingTime
      let easedProgress = settlingProgress * settlingProgress
      velocity.x = velocity.x * (1 - easedProgress) + circularVelocity.x * easedProgress
      velocity.y = velocity.y * (1 - easedProgress) + circularVelocity.y * easedProgress
    } else {
      velocity = circularVelocity
    }
  }
}

// MARK: - Behavior Transitions

extension Fly {
  private func transitionToNextBehavior(renderBounds: CGRect, otherFlies: [Fly]) {
    switch behaviorState {
    case .hovering:
      transitionToFlying(renderBounds: renderBounds, otherFlies: otherFlies)
    case .flying:
      transitionToCircling()
    case .circling:
      transitionToHovering()
    }
  }

  private func transitionToFlying(
    renderBounds: CGRect,
    otherFlies: [Fly],
    isScared: Bool = false,
    isReturningToScreen: Bool = false
  ) {
    behaviorState = .flying
    behaviorTimer = 0

    let targetBounds = calculateTargetBounds(
      renderBounds: renderBounds,
      isReturningToScreen: isReturningToScreen
    )
    targetPosition = findTargetPosition(
      targetBounds: targetBounds,
      otherFlies: otherFlies,
      isScared: isScared
    )
    flightData = createFlightData(isScared: isScared, isReturningToScreen: isReturningToScreen)
  }

  private func calculateTargetBounds(renderBounds: CGRect, isReturningToScreen: Bool) -> CGRect {
    let padding = 50.0

    if isReturningToScreen {
      // When returning to screen, target well within the bounds.
      let safePaddingX = min(padding, renderBounds.width / 4)
      let safePaddingY = min(padding, renderBounds.height / 4)
      return renderBounds.insetBy(dx: safePaddingX, dy: safePaddingY)
    } else {
      // When not returning, allow targeting slightly outside the screen.
      return renderBounds.insetBy(dx: -padding, dy: -padding)
    }
  }

  private func findTargetPosition(
    targetBounds: CGRect,
    otherFlies: [Fly],
    isScared: Bool
  ) -> CGPoint {
    // If the fly has an active roast, target a box in the center of the screen.
    if roastText != nil {
      let boxSize = CGSize(width: targetBounds.width / 3.0, height: targetBounds.height / 3.0)
      let boxCenter = CGPoint(x: targetBounds.midX, y: targetBounds.midY)
      let randomX = Double.random(
        in: boxCenter.x - boxSize.width / 2.0...boxCenter.x + boxSize.width / 2.0
      )
      let randomY = Double.random(
        in: boxCenter.y - boxSize.height / 2.0...boxCenter.y + boxSize.height / 2.0
      )
      return CGPoint(x: randomX, y: randomY)
    }

    if isScared {
      // Calculate screen diagonal and escape distances.
      let screenDiagonal = sqrt(
        targetBounds.width * targetBounds.width + targetBounds.height * targetBounds.height
      )
      let minDistance = screenDiagonal * FlyConstants.scareEscapeMinDistancePercent
      let maxDistance = screenDiagonal * FlyConstants.scareEscapeMaxDistancePercent

      // Find a point within escape distance range.
      let angle = Double.random(in: 0...(2 * .pi))
      let distance = Double.random(in: minDistance...maxDistance)

      var escapePoint = CGPoint(
        x: position.x + cos(angle) * distance,
        y: position.y + sin(angle) * distance
      )

      // Ensure the point is within screen bounds.
      escapePoint.x = min(max(escapePoint.x, targetBounds.minX), targetBounds.maxX)
      escapePoint.y = min(max(escapePoint.y, targetBounds.minY), targetBounds.maxY)
      return escapePoint
    }

    // Try to find a cluster target when calm.
    if !otherFlies.isEmpty && Double.random(in: 0...1) < FlyConstants.clusterTargetChance {
      if let clusterTarget = findClusterTarget(targetBounds: targetBounds, otherFlies: otherFlies) {
        return clusterTarget
      }
    }

    // Fall back to random target.
    let minDistance = min(targetBounds.width, targetBounds.height) * 0.25
    return findRandomTarget(targetBounds: targetBounds, minDistance: minDistance)
  }

  private func findClusterTarget(targetBounds: CGRect, otherFlies: [Fly]) -> CGPoint? {
    let otherFly = otherFlies.randomElement()!
    let prospectiveX = Double.random(
      in: (otherFly.position.x - FlyConstants.clusterRadius)...(otherFly.position.x
        + FlyConstants.clusterRadius)
    )
    let prospectiveY = Double.random(
      in: (otherFly.position.y - FlyConstants.clusterRadius)...(otherFly.position.y
        + FlyConstants.clusterRadius)
    )
    let prospectiveTarget = CGPoint(x: prospectiveX, y: prospectiveY)
    return targetBounds.contains(prospectiveTarget) ? prospectiveTarget : nil
  }

  private func findRandomTarget(targetBounds: CGRect, minDistance: Double) -> CGPoint {
    var attempts = 0
    var target: CGPoint

    repeat {
      let targetX = Double.random(in: targetBounds.minX...targetBounds.maxX)
      let targetY = Double.random(in: targetBounds.minY...targetBounds.maxY)
      target = CGPoint(x: targetX, y: targetY)
      attempts += 1
    } while attempts < FlyConstants.maxTargetAttempts
      && distance(from: position, to: target) < minDistance

    return target
  }

  private func createFlightData(
    isScared: Bool = false,
    isReturningToScreen: Bool = false
  ) -> FlightData {
    guard let target = targetPosition else {
      return FlightData(
        startPosition: position,
        duration: 1.0,
        arcHeight: 0.0,
        isReturningToScreen: isReturningToScreen,
        isScared: isScared
      )
    }

    let flightDistance = distance(from: position, to: target)
    let arcHeight = max(
      0,
      Double.random(in: personalityTraits.arcHeightMultiplier) * flightDistance
    )

    // Use shorter duration when returning to screen or scared.
    let baseDuration =
      isReturningToScreen || isScared
      ? personalityTraits.durationRange.lowerBound * 0.7
      : Double.random(in: personalityTraits.durationRange)
    let duration = max(0.5, baseDuration)

    return FlightData(
      startPosition: position,
      duration: duration,
      arcHeight: arcHeight,
      intensityBoost: Double.random(in: 0.9...1.5),
      isReturningToScreen: isReturningToScreen,
      isScared: isScared
    )
  }

  private func transitionToCircling() {
    behaviorState = .circling
    behaviorTimer = 0
    circlingData = CirclingData(
      radius: Double.random(in: personalityTraits.circleRadiusRange),
      angularSpeed: Double.random(in: personalityTraits.angularSpeedRange),
      settlingTime: Double.random(in: personalityTraits.settlingTimeRange)
    )
    nextStateTransition = behaviorTimer + Double.random(in: personalityTraits.transitionTimeRange)
  }

  private func transitionToHovering() {
    behaviorState = .hovering
    behaviorTimer = 0
    targetPosition = nil
    flightData = nil
    circlingData = nil
    nextStateTransition = getNextTransitionTime()

    // Smoothly reduce speed for hovering.
    let hoverSpeed = baseSpeed * FlyConstants.hoverSpeedMultiplier
    velocity = limitSpeed(velocity: velocity, maxSpeed: hoverSpeed)
  }
}

// MARK: - Boundary Handling

extension Fly {
  private func handleScreenBoundaries(renderBounds: CGRect, otherFlies: [Fly]) {
    // Check if the fly has gone too far and needs to be redirected.
    if !renderBounds.insetBy(
      dx: -FlyConstants.escapeRedirectMargin, dy: -FlyConstants.escapeRedirectMargin
    ).contains(position) {
      if !(flightData?.isReturningToScreen ?? false) {
        transitionToFlying(
          renderBounds: renderBounds,
          otherFlies: otherFlies,
          isReturningToScreen: true
        )
      }
      return
    }

    // Apply gentle nudges to keep flies on screen.
    applyBoundaryNudges(renderBounds: renderBounds)
  }

  private func applyBoundaryNudges(renderBounds: CGRect) {
    var nudge = CGPoint.zero

    if position.x < renderBounds.minX - FlyConstants.softBoundaryMargin {
      nudge.x = FlyConstants.nudgeStrength
    } else if position.x > renderBounds.maxX + FlyConstants.softBoundaryMargin {
      nudge.x = -FlyConstants.nudgeStrength
    }

    if position.y < renderBounds.minY - FlyConstants.softBoundaryMargin {
      nudge.y = FlyConstants.nudgeStrength
    } else if position.y > renderBounds.maxY + FlyConstants.softBoundaryMargin {
      nudge.y = -FlyConstants.nudgeStrength
    }

    velocity.x += nudge.x
    velocity.y += nudge.y
  }
}

// MARK: - Utility Functions

extension Fly {
  private func updateFacingAndRotation() {
    facingRight = velocity.x >= 0

    // Only calculate rotation while flying.
    // This value is currently unused.
    if behaviorState == .flying {
      let velocityMagnitude = sqrt(velocity.x * velocity.x + velocity.y * velocity.y)

      // Only update rotation if there's significant movement.
      if velocityMagnitude > 1.0 {
        var angle = atan2(velocity.y, abs(velocity.x)) * 180.0 / .pi

        // When facing left, negate the angle to compensate for the negative x-scale.
        if !facingRight {
          angle = -angle
        }

        // Limit rotation to +90 to -90 degrees.
        angle = max(-90.0, min(90.0, angle))
        rotation = angle
      }
    } else {
      // Reset rotation when not flying.
      rotation = 0
    }
  }

  private func limitSpeed(velocity: CGPoint, maxSpeed: Double) -> CGPoint {
    let currentSpeed = sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
    if currentSpeed > maxSpeed {
      return CGPoint(
        x: (velocity.x / currentSpeed) * maxSpeed,
        y: (velocity.y / currentSpeed) * maxSpeed
      )
    }
    return velocity
  }

  private func getNextTransitionTime() -> Double {
    return Double.random(in: personalityTraits.transitionTimeRange)
  }

  func getCorners() -> [CGPoint] {
    let halfWidth = FlyConstants.targetSize.width / 2
    let halfHeight = FlyConstants.targetSize.height / 2
    return [
      CGPoint(x: position.x - halfWidth, y: position.y - halfHeight),  // Top-left.
      CGPoint(x: position.x + halfWidth, y: position.y - halfHeight),  // Top-right.
      CGPoint(x: position.x - halfWidth, y: position.y + halfHeight),  // Bottom-left.
      CGPoint(x: position.x + halfWidth, y: position.y + halfHeight),  // Bottom-right.
    ]
  }

  func isOnScreen(bounds: CGRect) -> Bool {
    return bounds.contains(position)
  }

  private func distance(from: CGPoint, to: CGPoint) -> Double {
    return sqrt(pow(to.x - from.x, 2) + pow(to.y - from.y, 2))
  }
}

// MARK: - Suspicion System

extension Fly {
  /// Call every frame so the fly can react to an active swat cone.
  func processConeThreat(
    cone: SwatCone?,
    swatReleaseTime: Date?,
    recentSwatFactor: Double,
    deltaTime: TimeInterval,
  ) {
    guard let cone = cone else {
      // Decay suspicion slowly when there's no active threat.
      suspicionLevel = max(
        0.0,
        suspicionLevel - SuspicionConstants.passiveDecayRate * CGFloat(deltaTime)
      )
      timeInsideCone = 0.0
      return
    }

    if !cone.contains(point: position) {
      // More active decay when the threat is visible.
      suspicionLevel = max(
        0.0,
        suspicionLevel - SuspicionConstants.activeDecayRate * CGFloat(deltaTime)
      )
      timeInsideCone = 0.0
      return
    }

    // If a swat was just released and this fly hasn't noticed it yet, check if it should.
    if let releaseTime = swatReleaseTime {
      let timeSinceRelease = Date().timeIntervalSince(releaseTime)
      let noticeTime =
        SuspicionConstants.swatReleaseNoticeTime
        - (SuspicionConstants.swatReleaseNoticeTime * TimeInterval(suspicionLevel)
          * SuspicionConstants.suspicionNoticeTimeReductionFactor)

      if timeSinceRelease >= noticeTime {
        // The fly has noticed the swat; scare it (at most once per cooldown).
        let canScare =
          lastConeScareTime.map {
            Date().timeIntervalSince($0) > SuspicionConstants.coneScareCooldown
          }
          ?? true
        if canScare {
          scare(fromSwatter: true)
          lastConeScareTime = Date()
          return
        }
      }
    }

    // Accumulate time spent inside the cone.
    timeInsideCone += deltaTime

    // Proximity Factor: Closer to the swat origin means more danger.
    let distToVertex = hypot(position.x - cone.origin.x, position.y - cone.origin.y)
    let proximityFactor = max(0.0, 1.0 - (distToVertex / cone.radius))

    // Stretch Factor: A more stretched cone is more threatening.
    let stretchContribution =
      (cone.stretch - 1.0) / (SuspicionConstants.maxStretchForFactor - 1.0)
    let stretchFactor = max(0.0, min(1.0, stretchContribution))

    // Combine factors.
    let threatFactors =
      (SuspicionConstants.proximityWeight * proximityFactor)
      + (SuspicionConstants.stretchWeight * stretchFactor)

    // Apply recent swat factor to make remaining flies more paranoid.
    let buildRateWithSwatFactor =
      threatFactors
      * (1.0 + CGFloat(recentSwatFactor) * SuspicionConstants.recentSwatImpactFactor)

    // Scale by an additional (constant) build multiplier before applying the time delta.
    let finalBuildRate = buildRateWithSwatFactor * SuspicionConstants.buildMultiplier
    suspicionLevel = min(1.0, suspicionLevel + (finalBuildRate * CGFloat(deltaTime)))

    // Trigger flee if suspicion passes the threshold.
    if suspicionLevel >= SuspicionConstants.fleeThreshold {
      let canScare =
        lastConeScareTime.map {
          Date().timeIntervalSince($0) > SuspicionConstants.coneScareCooldown
        }
        ?? true
      if canScare {
        scare(fromSwatter: true)
        lastConeScareTime = Date()
      }
    }
  }
}
