import CLumaAudio
import Foundation

/// The host-side synthesiser both frontends share. Voices are mixed on the
/// audio device's own thread in C, and reached only through a lock-free
/// command queue, so nothing here can stall or allocate under the callback.
@MainActor
public final class Synth {
    public private(set) var isRunning = false

    /// The recipe every subsequently played voice is built from.
    public var patch: SynthPatch {
        didSet {
            guard patch != oldValue else { return }
            var raw = patch.raw
            luma_audio_set_patch(&raw)
        }
    }

    /// Master level, 0..1.
    public var level: Float {
        didSet { luma_audio_set_level(level) }
    }

    public init(patch: SynthPatch = .blip, level: Float = 0.6) {
        self.patch = patch
        self.level = level
    }

    deinit {
        luma_audio_stop()
    }

    /// Answers false when the host has no usable output device, which is not
    /// fatal: playing stays callable and simply goes unheard.
    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }
        isRunning = luma_audio_start()
        if isRunning {
            luma_audio_set_level(level)
            var raw = patch.raw
            luma_audio_set_patch(&raw)
        }
        return isRunning
    }

    public func stop() {
        guard isRunning else { return }
        luma_audio_stop()
        isRunning = false
    }

    /// A patch that sustains needs the answered voice released; one that
    /// decays to silence does not.
    @discardableResult
    public func play(frequency: Float, velocity: Float = 1) -> Int32 {
        luma_audio_note_on(frequency, velocity)
    }

    public func release(voice: Int32) {
        luma_audio_note_off(voice)
    }

    /// Mixes without a device, for previews and for checking a patch makes
    /// the sound it claims to.
    public func renderOffline(frameCount: Int, channels: Int = 1) -> [Float] {
        var frames = [Float](repeating: 0, count: frameCount * channels)
        frames.withUnsafeMutableBufferPointer { buffer in
            luma_audio_render_offline(buffer.baseAddress!, Int32(frameCount), Int32(channels))
        }
        return frames
    }
}

public enum Waveform: Int32, Sendable, CaseIterable {
    case sine = 0
    case triangle = 1
    case saw = 2
    case square = 3
    case noise = 4
}

public struct SynthPatch: Sendable, Equatable {
    public var waveform: Waveform
    public var attack: Float
    public var decay: Float
    public var sustain: Float
    public var release: Float
    public var cutoff: Float
    public var resonance: Float
    public var detuneSemitones: Float
    public var gain: Float

    public init(
        waveform: Waveform,
        attack: Float,
        decay: Float,
        sustain: Float,
        release: Float,
        cutoff: Float,
        resonance: Float,
        detuneSemitones: Float = 0,
        gain: Float = 1
    ) {
        self.waveform = waveform
        self.attack = attack
        self.decay = decay
        self.sustain = sustain
        self.release = release
        self.cutoff = cutoff
        self.resonance = resonance
        self.detuneSemitones = detuneSemitones
        self.gain = gain
    }

    /// A short plucked blip: no sustain, so a voice frees itself.
    public static let blip = SynthPatch(
        waveform: .triangle,
        attack: 0.004,
        decay: 0.18,
        sustain: 0,
        release: 0.05,
        cutoff: 2600,
        resonance: 0.35,
        detuneSemitones: 0.08,
        gain: 0.5
    )

    var raw: LumaSynthPatch {
        LumaSynthPatch(
            waveform: waveform.rawValue,
            detune_semitones: detuneSemitones,
            attack_seconds: attack,
            decay_seconds: decay,
            sustain_level: sustain,
            release_seconds: release,
            cutoff_hz: cutoff,
            resonance: resonance,
            gain: gain
        )
    }
}
