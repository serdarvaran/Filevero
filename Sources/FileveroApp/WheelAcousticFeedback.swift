import AVFAudio
import AppKit
import FileveroCore
import Foundation

/// Audio-haptic synthesizer for wheel interactions with voice caching and rate-limiting.
@MainActor
public final class WheelAcousticFeedback {
    public static let shared = WheelAcousticFeedback()

    public struct Attempt: Equatable {
        public enum Outcome: String { case disabled, throttled, requested }
        public let outcome: Outcome
        public let soundStarted: Bool
        public let hapticRequested: Bool

        public init(outcome: Outcome, soundStarted: Bool, hapticRequested: Bool) {
            self.outcome = outcome
            self.soundStarted = soundStarted
            self.hapticRequested = hapticRequested
        }
    }

    public struct Probe: Codable {
        public let enabled: Bool
        public let poolSize: Int
        public let preparedPlayers: Int
        public let tickDuration: TimeInterval
        public let minimumInterval: TimeInterval
        public let audioError: String?

        public init(enabled: Bool, poolSize: Int, preparedPlayers: Int, tickDuration: TimeInterval, minimumInterval: TimeInterval, audioError: String?) {
            self.enabled = enabled
            self.poolSize = poolSize
            self.preparedPlayers = preparedPlayers
            self.tickDuration = tickDuration
            self.minimumInterval = minimumInterval
            self.audioError = audioError
        }
    }

    private let defaults: UserDefaults
    private let clock: () -> TimeInterval
    private let injectedSound: (() -> Bool)?
    private let performHaptic: () -> Void
    private let players: [AVAudioPlayer]
    private var prepared: [Bool]
    private var playerIndex = 0
    private var lastRequest: TimeInterval?
    private var audioError: String?
    private let minimumInterval = WheelFeedbackTuning.minimumInterval

    public init(
        defaults: UserDefaults = .standard,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        playSound: (() -> Bool)? = nil,
        selectionSoundURL: URL? = nil,
        performHaptic: (() -> Void)? = nil
    ) {
        self.defaults = defaults
        self.clock = clock
        self.injectedSound = playSound
        self.performHaptic = performHaptic ?? {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }

        var pool: [AVAudioPlayer] = []
        var preparation: [Bool] = []
        var failure: String?

        if playSound == nil {
            if let url = selectionSoundURL ?? Self.soundURL {
                for _ in 0..<WheelFeedbackTuning.voices {
                    do {
                        let player = try AVAudioPlayer(contentsOf: url)
                        player.volume = Float(WheelFeedbackTuning.volume)
                        player.numberOfLoops = 0
                        pool.append(player)
                        preparation.append(player.prepareToPlay())
                    } catch {
                        failure = error.localizedDescription
                    }
                }
            } else {
                failure = "The wheel selection sound is missing."
            }
        }

        self.players = pool
        self.prepared = preparation
        self.audioError = failure ?? (!pool.isEmpty && !preparation.contains(true) ? "Audio output could not be prepared." : nil)
    }

    @discardableResult
    public func prepare() -> Probe {
        for index in players.indices where !prepared[index] {
            prepared[index] = players[index].prepareToPlay()
        }
        return probe()
    }

    @discardableResult
    public func selectionChanged() -> Attempt {
        guard isFeedbackEnabled else {
            for index in players.indices {
                players[index].stop()
                prepared[index] = false
            }
            lastRequest = nil
            return Attempt(outcome: .disabled, soundStarted: false, hapticRequested: false)
        }

        let now = clock()
        if let lastRequest, now >= lastRequest, now - lastRequest < minimumInterval {
            return Attempt(outcome: .throttled, soundStarted: false, hapticRequested: false)
        }
        lastRequest = now

        let started: Bool
        if let injectedSound {
            started = injectedSound()
        } else if !players.isEmpty {
            let index = playerIndex
            let player = players[index]
            playerIndex = (index + 1) % players.count
            if player.isPlaying {
                player.stop()
                prepared[index] = false
            }
            player.currentTime = 0
            if !prepared[index] { prepared[index] = player.prepareToPlay() }
            started = player.play()
            if started {
                audioError = nil
            } else {
                prepared[index] = false
                audioError = "Audio playback could not start."
            }
        } else {
            started = false
        }

        performHaptic()
        return Attempt(outcome: .requested, soundStarted: started, hapticRequested: true)
    }

    @discardableResult
    public func testPreview() -> Attempt {
        selectionChanged()
    }

    public func probe() -> Probe {
        Probe(
            enabled: isFeedbackEnabled,
            poolSize: players.count,
            preparedPlayers: prepared.filter { $0 }.count,
            tickDuration: players.first?.duration ?? 0,
            minimumInterval: minimumInterval,
            audioError: audioError
        )
    }

    private var isFeedbackEnabled: Bool {
        if let val = defaults.object(forKey: "soundsAndHapticsEnabled") as? Bool { return val }
        if defaults.object(forKey: "sound") != nil { return defaults.bool(forKey: "sound") }
        return true
    }

    private static var soundURL: URL? {
        if let url = Bundle.main.url(forResource: "WheelSelection", withExtension: "wav", subdirectory: "Sounds") {
            return url
        }
        #if DEBUG
        let development = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Sounds/WheelSelection.wav")
        if FileManager.default.fileExists(atPath: development.path) { return development }
        #endif
        return nil
    }
}

// Backward-compatibility alias
public typealias WheelFeedback = WheelAcousticFeedback

