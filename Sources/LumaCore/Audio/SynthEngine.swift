import Foundation
import Synchronization

/// The mixer, running on the audio device's own thread.
///
/// Everything it touches is allocated once up front and reached through
/// unsafe pointers, and the control side speaks to it only through a
/// lock-free ring: no allocation, no reference counting and no locking
/// happens under the callback, which is what keeps a phrase from stuttering.
public enum SynthEngine {
    public static let channelCount = 8
    public static let sampleRate: Float = 48000

    static let voiceCount = 24
    static let patternCapacity = 256

    /// Three per channel, so staging can always find a buffer that is neither
    /// being performed nor waiting to be adopted. Two could not: a second
    /// commit landing inside one audio block would overwrite the pattern the
    /// mixer was midway through.
    static let bufferCount = 3

    /// Pitches one step may sound together.
    static let maxTones = 4
    static let commandCapacity = 256
    /// Two seconds at the rate the device runs at, which is as far back as
    /// the echo is allowed to reach.
    static let echoCapacity = 96000

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
        let performing = performingSlot(channel)
        let offered = storage.lastOffered[channel]
        storage.staging[channel] = (0..<bufferCount).first { $0 != performing && $0 != offered }!
        storage.stagedCount[channel] = 0
    }

    public static func addStep(frequency: Float, velocity: Float, steps: Int32, channel: Int) {
        let count = storage.stagedCount[channel]
        guard count < patternCapacity else { return }

        let buffer = storage.staging[channel]
        storage.steps[stepSlot(channel: channel, buffer: buffer, index: count)] = PatternStep(
            velocity: velocity,
            steps: max(steps, 1),
            toneCount: 1
        )
        storage.tones[toneSlot(channel: channel, buffer: buffer, index: count, tone: 0)] = frequency
        storage.stagedCount[channel] = count + 1
    }

    /// Sounds another pitch alongside the step just added, making it a chord.
    public static func addTone(frequency: Float, channel: Int) {
        let count = storage.stagedCount[channel]
        guard count > 0 else { return }

        let buffer = storage.staging[channel]
        let index = count - 1
        let slot = stepSlot(channel: channel, buffer: buffer, index: index)
        let tone = Int(storage.steps[slot].toneCount)
        guard tone < maxTones else { return }

        storage.tones[toneSlot(channel: channel, buffer: buffer, index: index, tone: tone)] = frequency
        storage.steps[slot].toneCount = Int32(tone + 1)
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

        storage.lastOffered[channel] = storage.staging[channel]
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

            var left: Float = 0
            var right: Float = 0
            for index in 0..<voiceCount where storage.voices[index].stage != .idle {
                let sample = render(&storage.voices[index])
                // Equal power, so a voice does not get louder as it crosses.
                let pan = storage.channels[storage.voices[index].channel].pan
                let angle = (min(max(pan, -1), 1) + 1) * (.pi / 4)
                left += sample * cos(angle)
                right += sample * sin(angle)
            }
            echoed(&left, &right)
            left = min(max(left * storage.level, -1), 1)
            right = min(max(right * storage.level, -1), 1)

            if channels == 1 {
                // Both sides into one, at the level a centred voice had.
                frames[frame] = min(max((left + right) * 0.70710677, -1), 1)
            } else {
                for channel in 0..<channels {
                    frames[frame * channels + channel] = channel % 2 == 0 ? left : right
                }
            }
        }
    }

    /// One tap of delay, crossing sides as it comes round: what went out
    /// left comes back right, which is what makes a tune sound wide rather
    /// than merely wet.
    private static func echoed(_ left: inout Float, _ right: inout Float) {
        guard storage.echoMix > 0, storage.echoFrames > 0 else { return }

        let read = (storage.echoWrite &+ echoCapacity &- storage.echoFrames) % echoCapacity
        let delayedLeft = storage.echo[read]
        let delayedRight = storage.echoRight[read]

        // What goes in enters one side only: fed to both, a centred voice
        // would come back centred and the tap would never bounce.
        storage.echo[storage.echoWrite] = (left + right) * 0.5 + delayedRight * storage.echoFeedback
        storage.echoRight[storage.echoWrite] = delayedLeft * storage.echoFeedback
        storage.echoWrite = (storage.echoWrite &+ 1) % echoCapacity

        left += delayedLeft * storage.echoMix
        right += delayedRight * storage.echoMix
    }

    /// Where a channel sits between the speakers, -1 to 1.
    public static func setPan(_ pan: Float, channel: Int) {
        var command = Command(kind: .pan, channel: Int32(channel))
        command.frequency = pan
        offer(command)
    }

    /// How far back the tap reaches, how much of it comes round again, and
    /// how much of it is heard.
    public static func setEcho(seconds: Float, feedback: Float, mix: Float) {
        var command = Command(kind: .echo, channel: 0)
        command.frequency = seconds
        command.velocity = feedback
        command.stepSeconds = min(max(mix, 0), 1)
        offer(command)
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
            case .echo:
                applyEcho(command)
            case .pan:
                storage.channels[channel].pan = min(max(command.frequency, -1), 1)
            case .patternStop:
                storage.channels[channel].performing = -1
                storage.channels[channel].offered = -1
                // Clear the step clock too, or the channel sits out the rest
                // of the note it was holding before it can take anything new.
                storage.channels[channel].stepIndex = 0
                storage.channels[channel].framesUntilStep = 0
                publishPerforming(channel, -1)
            }
            tail &+= 1
        }

        storage.commandTail.store(tail, ordering: .releasing)
    }

    /// Steps one channel a single frame on, sounding whatever the grid lands
    /// on. The clock is the device's, so a phrase keeps time whatever the host
    /// is doing.
    private static func applyEcho(_ command: Command) {
        storage.echoFrames = Int(min(max(command.frequency, 0), 2) * sampleRate)
        storage.echoFeedback = min(max(command.velocity, 0), 0.95)
        storage.echoMix = command.stepSeconds
        if storage.echoMix <= 0 {
            for index in 0..<echoCapacity {
                storage.echo[index] = 0
                storage.echoRight[index] = 0
            }
        }
    }

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
                publishPerforming(channel, -1)
                return
            }
            return
        }

        let index = storage.channels[channel].stepIndex
        storage.channels[channel].stepIndex = index + 1

        let step = storage.steps[stepSlot(channel: channel, buffer: performing, index: index)]
        for tone in 0..<Int(step.toneCount) {
            let frequency = storage.tones[toneSlot(channel: channel, buffer: performing, index: index, tone: tone)]
            guard frequency > 0 else { continue }

            let voice = Int(storage.channels[channel].sequencedVoice) % voiceCount
            storage.channels[channel].sequencedVoice &+= 1
            start(&storage.voices[voice], frequency, step.velocity, channel)
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
        publishPerforming(channel, offered)
    }

    /// Only the audio thread writes this; staging reads it to keep clear of
    /// whatever is sounding. A byte per channel, holding the slot plus one so
    /// that zero reads as nothing playing.
    private static func publishPerforming(_ channel: Int, _ slot: Int) {
        let shift = UInt32(channel * 8)
        var bits = storage.performingSlots.load(ordering: .relaxed)
        bits &= ~(0xFF << shift)
        bits |= UInt32(slot + 1) << shift
        storage.performingSlots.store(bits, ordering: .releasing)
    }

    private static func performingSlot(_ channel: Int) -> Int {
        let bits = storage.performingSlots.load(ordering: .acquiring)
        return Int((bits >> UInt32(channel * 8)) & 0xFF) - 1
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
        voice.lfoPhase = 0
        voice.cutoffEnvelope = 1
        voice.channel = channel
        voice.patch = storage.channels[channel].patch
    }

    private static func render(_ voice: inout Voice) -> Float {
        let patch = voice.patch

        let swing = lfo(&voice)
        let width = min(max(patch.pulseWidth + swing * patch.lfoToWidth, 0.03), 0.97)
        let bend = exp2(swing * patch.lfoToPitch / 12)

        var sample = oscillator(patch.waveform, voice.phase, width)
        let wrapped = voice.phase + voice.frequency * bend / sampleRate
        voice.phase = wrapped - Float(Int(wrapped))

        if patch.detuneSemitones != 0 || patch.ringMix > 0 {
            let detuned = voice.frequency * bend * exp2(patch.detuneSemitones / 12)
            let second = oscillator(patch.waveform, voice.detunedPhase, width)
            sample = patch.ringMix > 0
                ? sample * (1 - patch.ringMix) + sample * second * patch.ringMix * 2
                : (sample + second) * 0.5
            voice.detunedPhase += detuned / sampleRate
            voice.detunedPhase -= Float(Int(voice.detunedPhase))
            // Restarting the second on the first's edge is the sync sound.
            if patch.syncsDetuned && wrapped >= 1 {
                voice.detunedPhase = 0
            }
        }

        advanceEnvelope(&voice)
        advanceCutoffEnvelope(&voice)
        sample = filtered(&voice, sample, swing: swing)
        if patch.drive > 0 {
            sample = tanh(sample * (1 + patch.drive * 8)) * (1 / (1 + patch.drive))
        }
        return sample * voice.envelope * voice.velocity * patch.gain
    }

    private static func oscillator(_ waveform: Int32, _ phase: Float, _ width: Float) -> Float {
        switch waveform {
        case 1:
            return 4 * abs(phase - 0.5) - 1
        case 2:
            return 2 * phase - 1
        case 3:
            return phase < width ? 1 : -1
        case 4:
            storage.noiseSeed = storage.noiseSeed &* 1664525 &+ 1013904223
            return Float(storage.noiseSeed >> 8) / 8388608 - 1
        default:
            return sin(2 * .pi * phase)
        }
    }

    /// One cycle of the voice's own slow wave, -1 to 1.
    private static func lfo(_ voice: inout Voice) -> Float {
        let rate = voice.patch.lfoRate
        guard rate > 0 else { return 0 }

        voice.lfoPhase += rate / sampleRate
        voice.lfoPhase -= Float(Int(voice.lfoPhase))
        return sin(2 * .pi * voice.lfoPhase)
    }

    /// Falls from struck to closed on its own clock, so a note can open the
    /// filter and let it shut again while it holds.
    private static func advanceCutoffEnvelope(_ voice: inout Voice) {
        guard voice.patch.cutoffEnvelope != 0 else { return }
        voice.cutoffEnvelope -= 1 / max(voice.patch.cutoffDecay * sampleRate, 1)
        voice.cutoffEnvelope = max(voice.cutoffEnvelope, 0)
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
    private static func filtered(_ voice: inout Voice, _ sample: Float, swing: Float) -> Float {
        let patch = voice.patch
        guard patch.cutoff > 0 else { return sample }

        let opened = patch.cutoff
            * exp2(voice.cutoffEnvelope * patch.cutoffEnvelope)
            * exp2(swing * patch.lfoToCutoff)
        let f = 2 * sin(.pi * min(opened, sampleRate * 0.45) / sampleRate)
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
        ((channel * bufferCount) + buffer) * patternCapacity + index
    }

    private static func patternSlot(channel: Int, buffer: Int) -> Int {
        (channel * bufferCount) + buffer
    }

    private static func toneSlot(channel: Int, buffer: Int, index: Int, tone: Int) -> Int {
        stepSlot(channel: channel, buffer: buffer, index: index) * maxTones + tone
    }

    nonisolated(unsafe) private static let storage = Storage()

    private final class Storage {
        let voices: UnsafeMutableBufferPointer<Voice>
        let channels: UnsafeMutableBufferPointer<ChannelState>
        let steps: UnsafeMutableBufferPointer<PatternStep>
        let tones: UnsafeMutableBufferPointer<Float>
        let patterns: UnsafeMutableBufferPointer<Pattern>
        let commands: UnsafeMutableBufferPointer<Command>

        let commandHead = Atomic<UInt32>(0)
        let commandTail = Atomic<UInt32>(0)
        let nextVoice = Atomic<UInt32>(0)
        let performingSlots = Atomic<UInt32>(0)

        var level: Float = 0.6
        var echo = [Float](repeating: 0, count: SynthEngine.echoCapacity)
        var echoRight = [Float](repeating: 0, count: SynthEngine.echoCapacity)
        var echoWrite = 0
        var echoFrames = 0
        var echoFeedback: Float = 0
        var echoMix: Float = 0
        var noiseSeed: UInt32 = 22222
        var staging = [Int](repeating: 0, count: SynthEngine.channelCount)
        var stagedCount = [Int](repeating: 0, count: SynthEngine.channelCount)
        var lastOffered = [Int](repeating: -1, count: SynthEngine.channelCount)

        init() {
            voices = .allocate(capacity: SynthEngine.voiceCount)
            voices.initialize(repeating: Voice())
            channels = .allocate(capacity: SynthEngine.channelCount)
            channels.initialize(repeating: ChannelState())
            steps = .allocate(capacity: SynthEngine.channelCount * SynthEngine.bufferCount * SynthEngine.patternCapacity)
            steps.initialize(repeating: PatternStep())
            tones = .allocate(
                capacity: SynthEngine.channelCount * SynthEngine.bufferCount
                    * SynthEngine.patternCapacity * SynthEngine.maxTones)
            tones.initialize(repeating: 0)
            patterns = .allocate(capacity: SynthEngine.channelCount * SynthEngine.bufferCount)
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
        /// Where a pulse sits between its edges. Half is a square; away from
        /// half is what gives a chip lead its reedy voice.
        public var pulseWidth: Float = 0.5
        public var lfoRate: Float = 0
        public var lfoToPitch: Float = 0
        public var lfoToWidth: Float = 0
        public var lfoToCutoff: Float = 0
        /// The filter's own envelope: how far the cutoff opens, and how long
        /// it takes to fall back. This is what a pluck or an acid line is.
        public var cutoffEnvelope: Float = 0
        public var cutoffDecay: Float = 0.2
        /// The second oscillator restarted by the first, which is the sound
        /// of one pitch dragging another behind it.
        public var syncsDetuned: Bool = false
        /// The two multiplied rather than added: bells, and everything metal.
        public var ringMix: Float = 0
        /// Soft clipping, for when a voice should sound driven rather than
        /// loud.
        public var drive: Float = 0

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
        var lfoPhase: Float = 0
        var cutoffEnvelope: Float = 0
        var channel = 0
        var patch = PatchValues()
    }

    private struct ChannelState {
        var patch = PatchValues()
        /// -1 hard left, 1 hard right.
        var pan: Float = 0
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
        var velocity: Float = 0
        var steps: Int32 = 1
        var toneCount: Int32 = 0
    }

    private struct Pattern {
        var count: Int32 = 0
        var stepSeconds: Float = 0.125
        var loops = true
    }

    private enum CommandKind: Int32 {
        case patch, noteOn, noteOff, patternOffer, patternStop, echo, pan
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
