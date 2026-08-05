import CLumaAudio
import Foundation

/// The host-side synthesiser both frontends share. Voices are mixed on the
/// audio device's own thread by `SynthEngine`, reached only through a
/// lock-free command queue, so nothing here can stall it.
@MainActor
public final class Synth {
    public private(set) var isRunning = false

    /// Master level, 0..1.
    public var level: Float {
        didSet { SynthEngine.level = level }
    }

    public init(level: Float = 0.6) {
        self.level = level
        SynthEngine.prepare()
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
            SynthEngine.level = level
        }
        return isRunning
    }

    public func stop() {
        guard isRunning else { return }
        luma_audio_stop()
        isRunning = false
    }

    /// The recipe every voice subsequently played on this channel is built
    /// from. Each channel carries its own, so a bass and a lead can sound
    /// together.
    public func use(_ patch: SynthPatch, channel: Int = 0) {
        SynthEngine.setPatch(patch.values, channel: channel)
    }

    /// A patch that sustains needs the answered voice released; one that
    /// decays to silence does not.
    @discardableResult
    public func play(frequency: Float, velocity: Float = 1, channel: Int = 0) -> Int32 {
        SynthEngine.play(frequency: frequency, velocity: velocity, channel: channel)
    }

    public func release(voice: Int32) {
        SynthEngine.release(voice: voice)
    }

    /// Mixes without a device, for previews and for checking a patch makes
    /// the sound it claims to.
    public func renderOffline(frameCount: Int, channels: Int = 1) -> [Float] {
        var frames = [Float](repeating: 0, count: frameCount * channels)
        frames.withUnsafeMutableBufferPointer { buffer in
            SynthEngine.mix(into: buffer.baseAddress!, frameCount: frameCount, channels: channels)
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
        waveform: .triangle, attack: 0.004, decay: 0.18, sustain: 0, release: 0.05,
        cutoff: 2600, resonance: 0.35, detuneSemitones: 0.08, gain: 0.5)

    /// Unfiltered square, the way a PSG lead sounds.
    public static let pulse = SynthPatch(
        waveform: .square, attack: 0.001, decay: 0.09, sustain: 0, release: 0.01,
        cutoff: 0, resonance: 0, gain: 0.5)

    public static let bass = SynthPatch(
        waveform: .saw, attack: 0.002, decay: 0.22, sustain: 0, release: 0.03,
        cutoff: 900, resonance: 0.5, detuneSemitones: 0.06, gain: 0.7)

    public static let noiseHit = SynthPatch(
        waveform: .noise, attack: 0.001, decay: 0.07, sustain: 0, release: 0.01,
        cutoff: 4200, resonance: 0.2, gain: 0.4)

    var values: SynthEngine.PatchValues {
        var raw = SynthEngine.PatchValues()
        raw.waveform = waveform.rawValue
        raw.detuneSemitones = detuneSemitones
        raw.attack = attack
        raw.decay = decay
        raw.sustain = sustain
        raw.release = release
        raw.cutoff = cutoff
        raw.resonance = resonance
        raw.gain = gain
        return raw
    }
}
