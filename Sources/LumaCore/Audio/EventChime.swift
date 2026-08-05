import Foundation

/// Sounds arriving events: the same activity that drives a shader effect
/// picks a degree of a pentatonic scale, so a busy target climbs. Off until
/// asked for -- instrumentation that makes noise unbidden is not a feature.
@MainActor
public final class EventChime {
    public var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                synth.start()
                synth.use(.blip, channel: chimeChannel)
            } else {
                synth.stop()
            }
        }
    }

    public let synth: Synth

    /// Semitone offsets of a minor pentatonic, spanning two octaves.
    private let degrees: [Float] = [0, 3, 5, 7, 10, 12, 15, 17, 19, 22]
    private let rootHz: Float = 196
    private let minimumSpacing: TimeInterval = 0.06

    private var lastSoundedAt: TimeInterval = 0

    /// Its own channel, so sounding events never restyles a tune's voices.
    private let chimeChannel = SynthEngine.channelCount - 1

    public init(synth: Synth = Synth()) {
        self.synth = synth
    }

    public func report(activity: Float, at now: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        guard isEnabled, now - lastSoundedAt >= minimumSpacing else { return }
        lastSoundedAt = now

        let degree = degrees[min(Int(activity * Float(degrees.count)), degrees.count - 1)]
        synth.play(
            frequency: rootHz * pow(2, degree / 12),
            velocity: 0.35 + activity * 0.5,
            channel: chimeChannel)
    }
}
