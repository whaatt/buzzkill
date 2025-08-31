//
//  SoundManager.swift
//  Buzzkill
//
//  Manager class for all sound effects.
//

@preconcurrency import AVFAudio
import AVFoundation
import OSLog
import SwiftUI

@MainActor
final class SoundManager: ObservableObject {
  static let logger = Logger(
    subsystem: OSLog.subsystem,
    category: String(describing: SoundManager.self)
  )

  // MARK: - Constants

  /// Base frequency used for generation (and then pitch-shifted down).
  private static let baseSwatterFrequency: Float = 880.0  // A5.

  // MARK: - Audio Components

  private var engine = AVAudioEngine()
  private var environment = AVAudioEnvironmentNode()
  private var audioConfigObserver: NSObjectProtocol?

  // Track individual fly audio players for dynamic positioning.
  private var flyAudioPlayers: [UUID: AVAudioPlayerNode] = [:]

  // MARK: - Audio Buffers

  private var flyToneBuffers: [Float: AVAudioPCMBuffer] = [:]
  private var swatterPluckBuffer: AVAudioPCMBuffer?
  private var shimmerSplatBuffers: [Float: AVAudioPCMBuffer] = [:]

  // MARK: - Configuration

  private let maxPanWidth: Float = 0.5
  private var settings: AppSettings { AppSettings.shared }

  // MARK: - Managers and Timers

  private weak var flyManager: FlyManager?
  private weak var swatterManager: SwatterManager?
  private var updateTimer: AsyncRepeatingTimer?
  private var fadeTimers: [ObjectIdentifier: AsyncRepeatingTimer] = [:]

  // MARK: - State Tracking

  private var lastSwatReleaseTime: Date?
  private var activeFlyIDs = Set<UUID>()
  private var flyBehaviorStates: [UUID: Fly.Behavior] = [:]
  private var swatterPlayer: AVAudioPlayerNode?
  private var swatterPitchUnit: AVAudioUnitTimePitch?
  private var peakStretchIntensity: CGFloat = 0.0
  private var currentSwatterFrequency: Float = baseSwatterFrequency

  // MARK: - Musical Data

  // Chord progression state.
  private var progressionTimer: AsyncRepeatingTimer?
  private var currentChordIndex = 0
  private let chordProgressionInterval: TimeInterval = 8.0  // 8 seconds per chord.

  // Current active note sets (updated by progression).
  private var flyNotes: [Float] = []
  private var swatterHarmonics: [Float] = []

  // Not actually a progression right now (still playing around with this).
  private let chordProgression: [(name: String, flyNotes: [Float], swatterHarmonics: [Float])] = [
    // Am: C4/E4 (3, 7) and A3/B3/C4/D4/E4/F4 (1, 2, 3, 4, 5, 6).
    ("Am", [261.63, 329.63], [220.00, 246.94, 261.63, 293.66, 329.63, 349.23])
  ]

  // MARK: - Initialization

  init() {
    setupAudioEngine()
    initializeChordProgression()
    generateAllSounds()
    setupAudioRouteChangeNotification()
  }

  deinit {
    updateTimer?.invalidate()
    progressionTimer?.invalidate()
    if let token = audioConfigObserver {
      NotificationCenter.default.removeObserver(token)
      audioConfigObserver = nil
    }
  }

  func setup(flyManager: FlyManager, swatterManager: SwatterManager) {
    self.flyManager = flyManager
    self.swatterManager = swatterManager
    self.lastSwatReleaseTime = swatterManager.swatReleaseTime
    startUpdating()
    startChordProgression()
  }

  // MARK: - Audio Setup

  private func setupAudioEngine() {
    let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    guard
      AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: 2
      ) != nil
    else {
      return
    }

    engine.attach(environment)
    engine.connect(environment, to: engine.mainMixerNode, format: nil)

    environment.reverbParameters.enable = true
    environment.reverbParameters.level = 0.15

    engine.prepare()
    do {
      try engine.start()
    } catch let error as NSError {
      Self.logger.error(
        "Error starting audio engine: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func stopAudioEngine() {
    if engine.isRunning {
      engine.stop()
    }
  }

  // MARK: - Audio Route Change Handling

  private func setupAudioRouteChangeNotification() {
    audioConfigObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.restartAudioEngine()
      }
    }
  }

  private func restartAudioEngine() {
    // Stop current engine.
    stopAudioEngine()

    // Disconnect and remove all nodes except the main mixer and output.
    for node in engine.attachedNodes {
      if node !== engine.mainMixerNode && node !== engine.outputNode {
        engine.disconnectNodeOutput(node)
        engine.detach(node)
      }
    }

    // Reset swatter player and pitch unit references.
    swatterPlayer = nil
    swatterPitchUnit = nil

    // Clear fly audio players since they're now disconnected.
    flyAudioPlayers.removeAll()

    // Recreate and restart the engine.
    setupAudioEngine()
    Self.logger.info("Audio engine restarted due to route change")
  }

  // MARK: - Chord Progression Management

  private func initializeChordProgression() {
    let initialChord = chordProgression[0]
    flyNotes = initialChord.flyNotes
    swatterHarmonics = initialChord.swatterHarmonics
  }

  private func startChordProgression() {
    progressionTimer?.invalidate()
    let timer = AsyncRepeatingTimer(
      interval: .milliseconds(
        Int(chordProgressionInterval * 1000)
      )
    ) { [weak self] in
      await self?.advanceChordProgression()
    }
    progressionTimer = timer
    progressionTimer?.start()
  }

  private func advanceChordProgression() {
    currentChordIndex = (currentChordIndex + 1) % chordProgression.count
    let nextChord = chordProgression[currentChordIndex]
    flyNotes = nextChord.flyNotes
    swatterHarmonics = nextChord.swatterHarmonics
  }

  // MARK: - Sound Generation

  private func generateAllSounds() {
    let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    swatterPluckBuffer = generateMelodicPluck(sampleRate: sampleRate)

    // Pre-generate all chord progression notes.
    for chord in chordProgression {
      for note in chord.flyNotes {
        if flyToneBuffers[note] == nil {
          flyToneBuffers[note] = generateGentleFlyTone(
            frequency: note,
            sampleRate: sampleRate
          )
        }
      }

      for harmonic in chord.swatterHarmonics {
        if shimmerSplatBuffers[harmonic] == nil {
          shimmerSplatBuffers[harmonic] = generateShimmerySplat(
            frequency: harmonic,
            sampleRate: sampleRate
          )
        }
      }
    }
  }

  private func generateGentleFlyTone(frequency: Float, sampleRate: Double) -> AVAudioPCMBuffer? {
    let duration: TimeInterval = 2.8
    let frameCount = AVAudioFrameCount(duration * sampleRate)
    guard
      let format = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: 2
      ),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
      )
    else {
      return nil
    }

    buffer.frameLength = frameCount
    guard let leftChannel = buffer.floatChannelData?[0],
      let rightChannel = buffer.floatChannelData?[1]
    else {
      return nil
    }

    for frame in 0..<Int(frameCount) {
      let time = Float(frame) / Float(sampleRate)

      // Bassoon envelope: Gentle attack, sustained tone, and gradual decay.
      let attack = 1.0 - exp(-time * 8.0)
      let decay = exp(-time * 0.9)
      let envelope = attack * decay

      // Bassoon harmonic character: woody and warm with characteristic nasal quality.
      let fundamental = sin(2 * .pi * frequency * time)
      let h2 = sin(2 * .pi * frequency * 2.0 * time) * 0.3  // Softer 2nd for woodwind character.
      let h3 = sin(2 * .pi * frequency * 3.0 * time) * 0.45  // Strong 3rd (very bassoon-like).
      let h4 = sin(2 * .pi * frequency * 4.0 * time) * 0.2  // Subdued 4th.
      let h5 = sin(2 * .pi * frequency * 5.0 * time) * 0.25  // Present 5th for warmth.
      let h7 = sin(2 * .pi * frequency * 7.0 * time) * 0.15  // 7th for jazz character.

      // Bassoon "reed buzz" (characteristic nasal formant).
      let reedFreq = frequency * 4.5
      let reed = sin(2 * .pi * reedFreq * time) * exp(-time * 1.8) * 0.12

      let breath = 1.0 + sin(2 * .pi * 3.5 * time) * 0.02
      let pitchWaver = 1.0 + sin(2 * .pi * 1.2 * time) * 0.003

      let value = (fundamental * pitchWaver + h2 + h3 + h4 + h5 + h7 + reed) * breath / 2.2
      let finalValue = value * envelope * 0.22
      leftChannel[frame] = finalValue
      rightChannel[frame] = finalValue
    }

    return buffer
  }

  /// Used for swatter drag.
  private func generateMelodicPluck(sampleRate: Double) -> AVAudioPCMBuffer? {
    let duration: TimeInterval = 8.0  // Longer for seamless looping.
    let frameCount = AVAudioFrameCount(duration * sampleRate)
    guard
      let format = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: 2
      ),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
      )
    else {
      return nil
    }

    buffer.frameLength = frameCount
    guard let leftChannel = buffer.floatChannelData?[0],
      let rightChannel = buffer.floatChannelData?[1]
    else {
      return nil
    }

    let baseFrequency: Float = Self.baseSwatterFrequency
    for frame in 0..<Int(frameCount) {
      let time = Float(frame) / Float(sampleRate)
      let progress = time / Float(duration)

      // Sustained envelope with seamless loop fade.
      let envelope: Float
      if progress < 0.01 {
        envelope = progress / 0.01
      } else if progress > 0.99 {
        envelope = (1.0 - progress) / 0.01
      } else {
        envelope = 1.0
      }

      // Rich harmonic content with jazz nasal character.
      let fundamental = sin(2 * .pi * baseFrequency * time)
      let h2 = sin(2 * .pi * baseFrequency * 2.0 * time) * 0.5
      let h3 = sin(2 * .pi * baseFrequency * 3.0 * time) * 0.4  // Boosted for nasal quality.
      let h4 = sin(2 * .pi * baseFrequency * 4.0 * time) * 0.25
      let h5 = sin(2 * .pi * baseFrequency * 5.0 * time) * 0.18
      let h7 = sin(2 * .pi * baseFrequency * 7.0 * time) * 0.12  // Jazz bite.

      let nasalFreq = baseFrequency * 8.0
      let nasal = sin(2 * .pi * nasalFreq * time) * 0.08
      let growl = 1.0 + sin(2 * .pi * 3.0 * time) * 0.015

      let value = (fundamental + h2 + h3 + h4 + h5 + h7 + nasal) * growl / 2.5
      let finalValue = value * envelope * 0.6
      leftChannel[frame] = finalValue
      rightChannel[frame] = finalValue
    }

    return buffer
  }

  /// Used for swatter hit.
  private func generatePitchedBassPluck(frequency: Float, sampleRate: Double) -> AVAudioPCMBuffer? {
    let duration: TimeInterval = 2.0
    let frameCount = AVAudioFrameCount(duration * sampleRate)
    guard
      let format = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: 2
      ),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
      )
    else {
      return nil
    }

    buffer.frameLength = frameCount
    guard let leftChannel = buffer.floatChannelData?[0],
      let rightChannel = buffer.floatChannelData?[1]
    else {
      return nil
    }

    for frame in 0..<Int(frameCount) {
      let time = Float(frame) / Float(sampleRate)

      // Bass pluck envelope: punchy attack with snap and quicker decay.
      let attack = 1.0 - exp(-time * 180.0)
      let punch = exp(-time * 25.0)
      let sustain = exp(-time * 1.8)
      let envelope = attack * (punch * 0.6 + sustain * 0.4)

      // Lower fundamental for deeper bass tone (down an octave).
      let bassFreq = frequency * 0.5
      let pitchBend = bassFreq * (1.0 + exp(-time * 30.0) * 0.012)
      let fundamental = sin(2 * .pi * pitchBend * time)

      // Jazzy harmonics with boosted low-mids and warm character.
      let h2 = sin(2 * .pi * bassFreq * 2.0 * time) * 0.45
      let h3 = sin(2 * .pi * bassFreq * 3.0 * time) * 0.25
      let h4 = sin(2 * .pi * bassFreq * 4.0 * time) * 0.12
      let h5 = sin(2 * .pi * bassFreq * 5.0 * time) * 0.08

      // Enhanced pluck transient with more snap.
      let transientEnv = exp(-time * 60.0)
      let snap = sin(2 * .pi * bassFreq * 12.0 * time) * transientEnv * 0.2
      let fingerNoise = sin(2 * .pi * bassFreq * 6.0 * time) * transientEnv * 0.15

      // Deep body resonance for bass "thump" (quicker decay).
      let deepBodyFreq = bassFreq * 0.6
      let midBodyFreq = bassFreq * 1.4
      let bodyEnv = max(0, 1.0 - exp(-(time - 0.008) * 12.0)) * exp(-time * 2.2)
      let deepThump = sin(2 * .pi * deepBodyFreq * time) * bodyEnv * 0.12
      let midBody = sin(2 * .pi * midBodyFreq * time) * bodyEnv * 0.08

      // Bass "growl" (slight overdrive character with quicker decay).
      let growlEnv = exp(-time * 6.0)
      let growl = sin(2 * .pi * bassFreq * 1.5 * time) * growlEnv * 0.06

      // String tension modulation with vibrato.
      let vibrato = 1.0 + sin(2 * .pi * 5.2 * time) * exp(-time * 3.5) * 0.004

      // Sub-bass component for extra depth and punch.
      let subBass = sin(2 * .pi * bassFreq * 0.5 * time) * exp(-time * 8.0) * 0.15

      // Combine all components.
      let stringTone = (fundamental + h2 + h3 + h4 + h5) * vibrato
      let transients = snap + fingerNoise
      let bodyResonance = deepThump + midBody + growl + subBass

      let value = (stringTone + transients + bodyResonance) / 1.6
      let finalValue = value * envelope * 0.85
      leftChannel[frame] = finalValue
      rightChannel[frame] = finalValue
    }

    return buffer
  }

  /// Used for swatter kill.
  private func generateShimmerySplat(frequency: Float, sampleRate: Double) -> AVAudioPCMBuffer? {
    let duration: TimeInterval = 2.2
    let frameCount = AVAudioFrameCount(duration * sampleRate)
    guard
      let format = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: 2
      ),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
      )
    else {
      return nil
    }

    buffer.frameLength = frameCount
    guard let leftChannel = buffer.floatChannelData?[0],
      let rightChannel = buffer.floatChannelData?[1]
    else {
      return nil
    }

    for frame in 0..<Int(frameCount) {
      let time = Float(frame) / Float(sampleRate)

      let attack = 1.0 - exp(-time * 25.0)
      let decay = exp(-time * 1.5)
      let envelope = attack * decay

      // Create shimmer effect with detuned oscillators and octave up.
      var value: Float = 0.0
      let octaveFreq = frequency
      let detuneAmounts: [Float] = [0.0, 0.025, -0.02, 0.04, -0.035]

      for (i, detune) in detuneAmounts.enumerated() {
        let detunedFreq = octaveFreq * (1.0 + detune)
        let oscillator = sin(2 * .pi * detunedFreq * time)
        let weight = 1.0 / Float(i + 1)
        value += oscillator * weight
      }

      let nasalFreq = octaveFreq * 5.0
      let nasal = sin(2 * .pi * nasalFreq * time) * exp(-time * 3.0) * 0.2
      let sizzle = sin(2 * .pi * octaveFreq * 12.0 * time) * exp(-time * 5.0) * 0.15
      let growl = 1.0 + sin(2 * .pi * 8.0 * time) * 0.025

      // Moderate warble/detune layer that intensifies toward the end.
      let progress = time / Float(duration)
      let warbleIntensity = max(0, progress - 0.3) / 0.7
      let warble = sin(2 * .pi * 4.8 * time) * warbleIntensity * 0.012
      let detune = sin(2 * .pi * 2.0 * time) * warbleIntensity * 0.016
      let warbledValue = value * (1.0 + warble + detune)
      value = (warbledValue + nasal + sizzle) * growl / 3.2
      let finalValue = value * envelope * 0.8
      leftChannel[frame] = finalValue
      rightChannel[frame] = finalValue
    }

    return buffer
  }

  // MARK: - Update Loop

  // TODO: Make this event-driven instead of polling.
  // We started this way to limit coupling.
  private func startUpdating() {
    updateTimer?.invalidate()
    let timer = AsyncRepeatingTimer(interval: .milliseconds(33)) { [weak self] in
      await self?.update()
    }
    updateTimer = timer
    updateTimer?.start()
  }

  private func update() {
    guard let flyManager = flyManager, let swatterManager = swatterManager else {
      return
    }

    updateFlySounds(flies: flyManager.flies)
    updateSwatterSounds(swatterManager: swatterManager)
  }

  // MARK: - Fly Sound Logic

  private func updateFlySounds(flies: [Fly]) {
    let currentFlyIDs = Set(flies.map { $0.id })

    for fly in flies where fly.isAlive && !activeFlyIDs.contains(fly.id) {
      activeFlyIDs.insert(fly.id)
    }

    // Play sparkle on successful hits and clean up audio players.
    for fly in flies where !fly.isAlive && activeFlyIDs.contains(fly.id) {
      if !fly.suppressDeathSound {
        playShimmerSplat(at: fly.position)
      }
      stopFlyAudio(flyID: fly.id)
      activeFlyIDs.remove(fly.id)
    }

    // Manage flying sound for each fly.
    for fly in flies where fly.isAlive {
      let currentBehavior = fly.behaviorState
      let lastBehavior = flyBehaviorStates[fly.id]

      if currentBehavior == .flying {
        // Start playing if not already playing, and we've seen the first state transition from
        // some other state to flying.
        if flyAudioPlayers[fly.id] == nil, lastBehavior != .flying, lastBehavior != nil {
          let randomNote = flyNotes.randomElement() ?? 130.81
          startFlyAudio(flyID: fly.id, frequency: randomNote, position: fly.position)
        } else {
          // Update position and volume for existing player to be reactive.
          updateFlyAudioPosition(flyID: fly.id, position: fly.position)
          if let player = flyAudioPlayers[fly.id] {
            player.volume =
              0.25 * settings.audio.masterVolume * (settings.audio.flyEnabled ? 1.0 : 0.0)
          }
        }
      } else if currentBehavior != .flying && flyAudioPlayers[fly.id] != nil {
        // Stop playing when no longer flying.
        stopFlyAudio(flyID: fly.id)
      }

      // Don't save the last behavior state until the first update.
      if fly.ranFirstUpdate {
        flyBehaviorStates[fly.id] = currentBehavior
      }
    }

    // Clean up state for flies that no longer exist.
    activeFlyIDs = activeFlyIDs.intersection(currentFlyIDs)
    flyBehaviorStates = flyBehaviorStates.filter { currentFlyIDs.contains($0.key) }

    // Clean up orphaned audio players.
    let orphanedPlayers = Set(flyAudioPlayers.keys).subtracting(currentFlyIDs)
    for flyID in orphanedPlayers {
      stopFlyAudio(flyID: flyID)
    }
  }

  /// Helper function for panning width.
  private func getOverlayScreenWidth() -> CGFloat {
    if let window = NSApp.windows.first(where: {
      $0.identifier == BuzzkillApp.Constants.overlayWindowIdentifier
    }), let width = window.screen?.frame.width {
      return width
    }
    return NSScreen.main?.frame.width ?? 1920
  }

  private func startFlyAudio(flyID: UUID, frequency: Float, position: CGPoint) {
    guard let buffer = flyToneBuffers[frequency] else {
      return
    }

    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: buffer.format)

    let screenWidth = getOverlayScreenWidth()
    player.pan = Float((position.x / screenWidth) * 2 - 1) * maxPanWidth
    player.volume = 0.25 * settings.audio.masterVolume * (settings.audio.flyEnabled ? 1.0 : 0.0)

    // Schedule buffer to loop while flying.
    player.scheduleBuffer(buffer, at: nil, options: .loops)
    player.play()

    // Store the player for this fly.
    flyAudioPlayers[flyID] = player
  }

  private func updateFlyAudioPosition(flyID: UUID, position: CGPoint) {
    guard let player = flyAudioPlayers[flyID] else {
      return
    }

    let screenWidth = getOverlayScreenWidth()
    player.pan = Float((position.x / screenWidth) * 2 - 1) * maxPanWidth
  }

  private func stopFlyAudio(flyID: UUID) {
    guard let player = flyAudioPlayers[flyID] else {
      return
    }

    // Remove the reference for this fly's player.
    flyAudioPlayers.removeValue(forKey: flyID)

    // Fade out gracefully.
    startFadeOut(player: player, rate: 0.9)
  }

  // MARK: - Swatter Sound Logic

  private func updateSwatterSounds(swatterManager: SwatterManager) {
    let currentStretch = swatterManager.stretchIntensity
    let isActivelyDragging = swatterManager.isDragging && currentStretch > 0.08

    if isActivelyDragging {
      peakStretchIntensity = max(peakStretchIntensity, currentStretch)
    }

    // Start sustained tone when drag begins.
    if swatterManager.isDragging && swatterPlayer == nil {
      let player = AVAudioPlayerNode()
      let pitchUnit = AVAudioUnitTimePitch()
      let stereoFormat = AVAudioFormat(
        standardFormatWithSampleRate: engine.outputNode.outputFormat(forBus: 0).sampleRate,
        channels: 2
      )!

      engine.attach(player)
      engine.attach(pitchUnit)

      // Connect: Player -> Pitch Unit -> Mixer.
      engine.connect(player, to: pitchUnit, format: stereoFormat)
      engine.connect(pitchUnit, to: engine.mainMixerNode, format: stereoFormat)

      swatterPlayer = player
      swatterPitchUnit = pitchUnit

      if let buffer = swatterPluckBuffer {
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.volume =
          0.4 * settings.audio.masterVolume * (settings.audio.swatterDragEnabled ? 1.0 : 0.0)
        player.play()
      }
    }

    // Update sound while dragging through discrete musical intervals.
    if let player = swatterPlayer, let pitchUnit = swatterPitchUnit, swatterManager.isDragging {
      let stretchRange = min(max(Float(currentStretch), 0.0), 1.0)
      let harmonicIndex = Int(stretchRange * Float(swatterHarmonics.count - 1))
      currentSwatterFrequency = swatterHarmonics[harmonicIndex]

      let basePitch: Float = Self.baseSwatterFrequency
      let pitchRatio = currentSwatterFrequency / basePitch

      // Convert frequency ratio to cents (1200 cents = 1 octave).
      let pitchInCents = log2(pitchRatio) * 1200.0
      pitchUnit.pitch = pitchInCents
      player.volume =
        0.4 * settings.audio.masterVolume * (settings.audio.swatterDragEnabled ? 1.0 : 0.0)

      let screenWidth = getOverlayScreenWidth()
      player.pan = Float((swatterManager.swatCurrent.x / screenWidth) * 2 - 1) * maxPanWidth
    }

    // Fade out gracefully when drag ends.
    if (!swatterManager.isDragging || !settings.audio.swatterDragEnabled) && swatterPlayer != nil {
      guard let player = swatterPlayer, let pitchUnit = swatterPitchUnit else {
        return
      }

      swatterPlayer = nil
      swatterPitchUnit = nil
      startFadeOut(player: player, pitchUnit: pitchUnit, rate: 0.92)
    }

    // Play bass pluck on swat release (at the swat origin).
    if let swatTime = swatterManager.swatReleaseTime, swatTime != lastSwatReleaseTime {
      if settings.audio.deathEnabled {
        let bassPitch = currentSwatterFrequency / 2.0  // One octave down.
        playPitchedBassPluck(at: swatterManager.swatOrigin, frequency: bassPitch)
      }
      lastSwatReleaseTime = swatTime
      peakStretchIntensity = 0.0
    }
  }

  // MARK: - Sound Playback

  private func playOneShotSound(buffer: AVAudioPCMBuffer, position: CGPoint, volume: Float) {
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: buffer.format)

    let screenWidth = getOverlayScreenWidth()
    player.pan = Float((position.x / screenWidth) * 2 - 1) * maxPanWidth
    player.volume = volume
    player.scheduleBuffer(buffer, at: nil)
    player.play()

    // Schedule cleanup with fade-out.
    let fadeStartTime = buffer.duration * 0.85
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(fadeStartTime * 1_000_000_000))
      self?.startFadeOut(player: player, rate: 0.9)
    }
  }

  private func playGentleFlyTone(at position: CGPoint, frequency: Float) {
    guard let buffer = flyToneBuffers[frequency] else {
      return
    }
    guard settings.audio.flyEnabled else {
      return
    }
    playOneShotSound(buffer: buffer, position: position, volume: 0.25 * settings.audio.masterVolume)
  }

  private func playPitchedBassPluck(at position: CGPoint, frequency: Float) {
    let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    guard
      let buffer = generatePitchedBassPluck(
        frequency: frequency,
        sampleRate: sampleRate
      )
    else {
      return
    }
    playOneShotSound(buffer: buffer, position: position, volume: 0.8 * settings.audio.masterVolume)
  }

  private func playShimmerSplat(at position: CGPoint) {
    let randomHarmonic = swatterHarmonics.randomElement() ?? 220.0
    guard let buffer = shimmerSplatBuffers[randomHarmonic] else {
      return
    }
    guard settings.audio.splatEnabled else {
      return
    }
    playOneShotSound(buffer: buffer, position: position, volume: 0.5 * settings.audio.masterVolume)
  }

  // MARK: - Fade Helpers

  private func startFadeOut(
    player: AVAudioPlayerNode,
    rate: Float,
    interval: TimeInterval = 0.02
  ) {
    let key = ObjectIdentifier(player)
    fadeTimers[key]?.invalidate()
    let timer = AsyncRepeatingTimer(interval: .milliseconds(Int(interval * 1000))) {
      [weak self, weak player] in
      guard let self = self, let player = player else {
        return
      }
      await self.performPlayerFadeStep(player: player, rate: rate)
    }
    fadeTimers[key] = timer
    fadeTimers[key]?.start()
  }

  private func performPlayerFadeStep(player: AVAudioPlayerNode, rate: Float) {
    let key = ObjectIdentifier(player)
    player.volume *= rate
    if player.volume < 0.01 {
      fadeTimers[key]?.invalidate()
      fadeTimers.removeValue(forKey: key)
      player.stop()
      engine.disconnectNodeOutput(player)
      engine.detach(player)
    }
  }

  private func startFadeOut(
    player: AVAudioPlayerNode,
    pitchUnit: AVAudioUnitTimePitch,
    rate: Float,
    interval: TimeInterval = 0.02
  ) {
    let key = ObjectIdentifier(player)
    fadeTimers[key]?.invalidate()
    let timer = AsyncRepeatingTimer(interval: .milliseconds(Int(interval * 1000))) {
      [weak self, weak player, weak pitchUnit] in
      guard let self = self, let player = player, let pitch = pitchUnit else {
        return
      }
      await self.performSwatterFadeStep(player: player, pitch: pitch, rate: rate)
    }
    fadeTimers[key] = timer
    fadeTimers[key]?.start()
  }

  private func performSwatterFadeStep(
    player: AVAudioPlayerNode,
    pitch: AVAudioUnitTimePitch,
    rate: Float
  ) {
    let key = ObjectIdentifier(player)
    player.volume *= rate
    if player.volume < 0.01 {
      fadeTimers[key]?.invalidate()
      fadeTimers.removeValue(forKey: key)
      player.stop()
      engine.disconnectNodeOutput(player)
      engine.disconnectNodeOutput(pitch)
      engine.detach(player)
      engine.detach(pitch)
    }
  }
}

// MARK: - Extensions

extension AVAudioPCMBuffer {
  var duration: TimeInterval {
    guard format.sampleRate > 0 else {
      return 0
    }
    return TimeInterval(frameLength) / format.sampleRate
  }
}
