import Foundation
import Synchronization

/// The mixer, running on the audio device's own thread.
///
/// Everything it touches is allocated once up front and reached through
/// unsafe pointers, and the control side speaks to it only through a
/// lock-free ring: no allocation, no reference counting and no locking
/// happens under the callback, which is what keeps a phrase from stuttering.
public enum SynthEngine {
    public static let channelCount = 4
    public static let sampleRate: Float = 48000

    static let voiceCount = 16
    static let patternCapacity = 256
    static let commandCapacity = 256

    public static func prepare() {
        _ = storage
    }

    public static func setPatch(_ patch: PatchValues, channel: Int) {
        var command = Command(kind: .patch, channel: Int32(channel))
        command.patch = patch
        offer(command)
    }

    @discardableResult
    public static func play(frequency: Float, velocity: Float, channel: Int) -> Int32 {
        let voice = Int32(storage.nextVoice.wrappingAdd(1, ordering: .relaxed).oldValue % UInt32(voiceCount))
        var command = Command(kind: .noteOn, channel: Int32(channel))
        command.index = voice
        command.frequency = frequency
        command.velocity = velocity
        offer(command)
        return voice
    }

    public static func release(voice: Int32) {
        var command = Command(kind: .noteOff, channel: 0)
        command.index = voice
        offer(command)
    }

    public static var level: Float {
        get { storage.level }
        set { storage.level = newValue }
    }

    // MARK: Patterns

    public static func beginPattern(channel: Int) {
        storage.stagedCount[channel] = 0
    }

    public static func addStep(frequency: Float, velocity: Float, steps: Int32, channel: Int) {
        let count = storage.stagedCount[channel]
        guard count < patternCapacity else { return }

        let buffer = storage.staging[channel]
        storage.steps[stepSlot(channel: channel, buffer: buffer, index: count)] = PatternStep(
            frequency: frequency,
            velocity: velocity,
            steps: max(steps, 1)
        )
        storage.stagedCount[channel] = count + 1
    }

    /// Offers the staged pattern. The mixer adopts it at the cycle boundary,
    /// so retuning a running loop lands musically rather than mid-bar.
    public static func commitPattern(stepSeconds: Float, loops: Bool, channel: Int) {
        var command = Command(kind: .patternOffer, channel: Int32(channel))
        command.index = Int32(storage.staging[channel])
        command.count = Int32(storage.stagedCount[channel])
        command.stepSeconds = stepSeconds
        command.loops = loops ? 1 : 0
        offer(command)

        storage.staging[channel] ^= 1
    }

    public static func stopPattern(channel: Int) {
        offer(Command(kind: .patternStop, channel: Int32(channel)))
    }

    // MARK: The audio thread

    static func mix(into frames: UnsafeMutablePointer<Float>, frameCount: Int, channels: Int) {
        drainCommands()

        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                advanceSequencer(channel)
            }

            var sample: Float = 0
            for index in 0..<voiceCount where storage.voices[index].stage != .idle {
                sample += render(&storage.voices[index])
            }
            sample = min(max(sample * storage.level, -1), 1)

            for channel in 0..<channels {
                frames[frame * channels + channel] = sample
            }
        }
    }

    private static func drainCommands() {
        let head = storage.commandHead.load(ordering: .acquiring)
        var tail = storage.commandTail.load(ordering: .relaxed)

        while tail != head {
            let command = storage.commands[Int(tail % UInt32(commandCapacity))]
            let channel = Int(command.channel)

            switch command.kind {
            case .patch:
                storage.channels[channel].patch = command.patch
            case .noteOn:
                start(&storage.voices[Int(command.index)], command.frequency, command.velocity, channel)
            case .noteOff:
                storage.voices[Int(command.index)].stage = .release
            case .patternOffer:
                storage.channels[channel].offered = Int(command.index)
                storage.channels[channel].offeredCount = Int(command.count)
                storage.channels[channel].offeredStepSeconds = command.stepSeconds
                storage.channels[channel].offeredLoops = command.loops == 1
            case .patternStop:
                storage.channels[channel].performing = -1
                storage.channels[channel].offered = -1
            }
            tail &+= 1
        }

        storage.commandTail.store(tail, ordering: .releasing)
    }

    /// Steps one channel a single frame on, sounding whatever the grid lands
    /// on. The clock is the device's, so a phrase keeps time whatever the host
    /// is doing.
    private static func advanceSequencer(_ channel: Int) {
        if storage.channels[channel].framesUntilStep > 0 {
            storage.channels[channel].framesUntilStep -= 1
            return
        }

        adoptOfferedPattern(channel)

        let performing = storage.channels[channel].performing
        guard performing >= 0 else { return }

        let pattern = storage.patterns[patternSlot(channel: channel, buffer: performing)]
        if storage.channels[channel].stepIndex >= Int(pattern.count) {
            storage.channels[channel].stepIndex = 0
            guard pattern.loops else {
                storage.channels[channel].performing = -1
                return
            }
            return
        }

        let index = storage.channels[channel].stepIndex
        storage.channels[channel].stepIndex = index + 1

        let step = storage.steps[stepSlot(channel: channel, buffer: performing, index: index)]
        if step.frequency > 0 {
            let voice = Int(storage.channels[channel].sequencedVoice) % voiceCount
            storage.channels[channel].sequencedVoice &+= 1
            start(&storage.voices[voice], step.frequency, step.velocity, channel)
        }
        storage.channels[channel].framesUntilStep = Int(step.steps * Int32(pattern.stepSeconds * sampleRate))
    }

    private static func adoptOfferedPattern(_ channel: Int) {
        let offered = storage.channels[channel].offered
        guard offered >= 0,
              storage.channels[channel].performing < 0 || storage.channels[channel].stepIndex == 0
        else { return }

        storage.patterns[patternSlot(channel: channel, buffer: offered)] = Pattern(
            count: Int32(storage.channels[channel].offeredCount),
            stepSeconds: storage.channels[channel].offeredStepSeconds,
            loops: storage.channels[channel].offeredLoops
        )
        storage.channels[channel].offered = -1
        storage.channels[channel].performing = offered
        storage.channels[channel].stepIndex = 0
    }

    private static func start(_ voice: inout Voice, _ frequency: Float, _ velocity: Float, _ channel: Int) {
        voice.stage = .attack
        voice.frequency = frequency
        voice.velocity = velocity
        voice.phase = 0
        voice.detunedPhase = 0
        voice.envelope = 0
        voice.lowpass = 0
        voice.bandpass = 0
        voice.patch = storage.channels[channel].patch
    }

    private static func render(_ voice: inout Voice) -> Float {
        let patch = voice.patch

        var sample = oscillator(patch.waveform, voice.phase)
        voice.phase += voice.frequency / sampleRate
        voice.phase -= Float(Int(voice.phase))

        if patch.detuneSemitones != 0 {
            let detuned = voice.frequency * exp2(patch.detuneSemitones / 12)
            sample = (sample + oscillator(patch.waveform, voice.detunedPhase)) * 0.5
            voice.detunedPhase += detuned / sampleRate
            voice.detunedPhase -= Float(Int(voice.detunedPhase))
        }

        advanceEnvelope(&voice)
        return filtered(&voice, sample) * voice.envelope * voice.velocity * patch.gain
    }

    private static func oscillator(_ waveform: Int32, _ phase: Float) -> Float {
        switch waveform {
        case 1:
            return 4 * abs(phase - 0.5) - 1
        case 2:
            return 2 * phase - 1
        case 3:
            return phase < 0.5 ? 1 : -1
        case 4:
            storage.noiseSeed = storage.noiseSeed &* 1664525 &+ 1013904223
            return Float(storage.noiseSeed >> 8) / 8388608 - 1
        default:
            return sin(2 * .pi * phase)
        }
    }

    private static func advanceEnvelope(_ voice: inout Voice) {
        let patch = voice.patch

        switch voice.stage {
        case .attack:
            voice.envelope += 1 / max(patch.attack * sampleRate, 1)
            if voice.envelope >= 1 {
                voice.envelope = 1
                voice.stage = .decay
            }
        case .decay:
            voice.envelope -= (1 - patch.sustain) / max(patch.decay * sampleRate, 1)
            if voice.envelope <= patch.sustain {
                voice.envelope = patch.sustain
                voice.stage = patch.sustain <= 0 ? .idle : .sustain
            }
        case .release:
            voice.envelope -= patch.sustain / max(patch.release * sampleRate, 1)
            if voice.envelope <= 0 {
                voice.envelope = 0
                voice.stage = .idle
            }
        case .idle, .sustain:
            break
        }
    }

    /// Chamberlin state variable, taking the lowpass tap.
    private static func filtered(_ voice: inout Voice, _ sample: Float) -> Float {
        let patch = voice.patch
        guard patch.cutoff > 0 else { return sample }

        let f = 2 * sin(.pi * min(patch.cutoff, sampleRate * 0.45) / sampleRate)
        let q = 1 - min(patch.resonance, 0.98)

        let highpass = sample - voice.lowpass - q * voice.bandpass
        voice.bandpass += f * highpass
        voice.lowpass += f * voice.bandpass
        return voice.lowpass
    }

    // MARK: Storage

    /// Drops the command when the ring is full rather than blocking the
    /// caller; a lost blip is cheaper than a stalled UI thread.
    private static func offer(_ command: Command) {
        let head = storage.commandHead.load(ordering: .relaxed)
        let tail = storage.commandTail.load(ordering: .acquiring)
        guard head &- tail < UInt32(commandCapacity) else { return }

        storage.commands[Int(head % UInt32(commandCapacity))] = command
        storage.commandHead.store(head &+ 1, ordering: .releasing)
    }

    private static func stepSlot(channel: Int, buffer: Int, index: Int) -> Int {
        ((channel * 2) + buffer) * patternCapacity + index
    }

    private static func patternSlot(channel: Int, buffer: Int) -> Int {
        (channel * 2) + buffer
    }

    nonisolated(unsafe) private static let storage = Storage()

    private final class Storage {
        let voices: UnsafeMutableBufferPointer<Voice>
        let channels: UnsafeMutableBufferPointer<ChannelState>
        let steps: UnsafeMutableBufferPointer<PatternStep>
        let patterns: UnsafeMutableBufferPointer<Pattern>
        let commands: UnsafeMutableBufferPointer<Command>

        let commandHead = Atomic<UInt32>(0)
        let commandTail = Atomic<UInt32>(0)
        let nextVoice = Atomic<UInt32>(0)

        var level: Float = 0.6
        var noiseSeed: UInt32 = 22222
        var staging = [Int](repeating: 0, count: SynthEngine.channelCount)
        var stagedCount = [Int](repeating: 0, count: SynthEngine.channelCount)

        init() {
            voices = .allocate(capacity: SynthEngine.voiceCount)
            voices.initialize(repeating: Voice())
            channels = .allocate(capacity: SynthEngine.channelCount)
            channels.initialize(repeating: ChannelState())
            steps = .allocate(capacity: SynthEngine.channelCount * 2 * SynthEngine.patternCapacity)
            steps.initialize(repeating: PatternStep())
            patterns = .allocate(capacity: SynthEngine.channelCount * 2)
            patterns.initialize(repeating: Pattern())
            commands = .allocate(capacity: SynthEngine.commandCapacity)
            commands.initialize(repeating: Command(kind: .patch, channel: 0))
        }
    }

    public struct PatchValues {
        public var waveform: Int32 = 0
        public var detuneSemitones: Float = 0
        public var attack: Float = 0.005
        public var decay: Float = 0.2
        public var sustain: Float = 0
        public var release: Float = 0.05
        public var cutoff: Float = 0
        public var resonance: Float = 0
        public var gain: Float = 0.5

        public init() {}
    }

    private enum Stage: Int32 {
        case idle, attack, decay, sustain, release
    }

    private struct Voice {
        var stage: Stage = .idle
        var frequency: Float = 0
        var velocity: Float = 0
        var phase: Float = 0
        var detunedPhase: Float = 0
        var envelope: Float = 0
        var lowpass: Float = 0
        var bandpass: Float = 0
        var patch = PatchValues()
    }

    private struct ChannelState {
        var patch = PatchValues()
        var performing = -1
        var offered = -1
        var offeredCount = 0
        var offeredStepSeconds: Float = 0.125
        var offeredLoops = true
        var stepIndex = 0
        var framesUntilStep = 0
        var sequencedVoice: UInt32 = 0
    }

    private struct PatternStep {
        var frequency: Float = 0
        var velocity: Float = 0
        var steps: Int32 = 1
    }

    private struct Pattern {
        var count: Int32 = 0
        var stepSeconds: Float = 0.125
        var loops = true
    }

    private enum CommandKind: Int32 {
        case patch, noteOn, noteOff, patternOffer, patternStop
    }

    private struct Command {
        var kind: CommandKind
        var channel: Int32
        var index: Int32 = 0
        var count: Int32 = 0
        var frequency: Float = 0
        var velocity: Float = 0
        var stepSeconds: Float = 0
        var loops: Int32 = 0
        var patch = PatchValues()
    }
}

/// Called by the device's audio callback, and directly when rendering with no
/// device at all.
@_cdecl("luma_synth_mix")
public func luma_synth_mix(_ frames: UnsafeMutablePointer<Float>, _ frameCount: Int32, _ channels: Int32) {
    SynthEngine.mix(into: frames, frameCount: Int(frameCount), channels: Int(channels))
}
