import CLumaAudio

/// What the image is allowed to do to the synthesiser. The mixer takes
/// commands through a lock-free queue, so the image calling these from its own
/// thread needs no hop to the host's.
///
/// A patch arrives field by field rather than as a struct, so the image has no
/// layout to marshal.
public enum PharoSynthBridge {
    /// No Swift caller reaches the exports below, and a static archive only
    /// yields the object files something references -- so without this touch
    /// the linker drops them all and the image's dlsym comes up empty.
    public static func ensureExported() {}
}

@_cdecl("luma_synth_start")
public func luma_synth_start() -> Int32 {
    SynthEngine.prepare()
    return luma_audio_start() ? 1 : 0
}

@_cdecl("luma_synth_stop")
public func luma_synth_stop() {
    luma_audio_stop()
}

@_cdecl("luma_synth_set_level")
public func luma_synth_set_level(_ level: Float) {
    SynthEngine.level = level
}

/// What each channel is set to, so the colour of a voice can be changed
/// without restating the rest of it.
private nonisolated(unsafe) var channelPatches = [SynthEngine.PatchValues](
    repeating: SynthEngine.PatchValues(), count: SynthEngine.channelCount)

/// The patches worth having a name for. A snippet asks for a sound rather
/// than for eleven numbers.
@_cdecl("luma_synth_use_preset")
public func luma_synth_use_preset(_ channel: Int32, _ name: UnsafePointer<CChar>) -> Int32 {
    let named: [String: SynthPatch] = [
        "pulse": .pulse, "bass": .bass, "blip": .blip, "noiseHit": .noiseHit,
        "pwmLead": .pwmLead, "acid": .acid, "syncLead": .syncLead,
        "bell": .bell, "pad": .pad,
    ]
    guard let patch = named[String(cString: name)] else { return 0 }

    channelPatches[Int(channel)] = patch.values
    SynthEngine.setPatch(patch.values, channel: Int(channel))
    return 1
}

/// What a voice does beyond its envelope and filter: the pulse it draws, the
/// slow wave moving it, what the filter does when struck, and how driven it
/// comes out.
@_cdecl("luma_synth_set_colour")
public func luma_synth_set_colour(
    _ channel: Int32,
    _ pulseWidth: Float,
    _ lfoRate: Float,
    _ lfoToPitch: Float,
    _ lfoToWidth: Float,
    _ lfoToCutoff: Float,
    _ cutoffEnvelope: Float,
    _ cutoffDecay: Float,
    _ syncsDetuned: Int32,
    _ ringMix: Float,
    _ drive: Float
) {
    var patch = channelPatches[Int(channel)]
    patch.pulseWidth = pulseWidth
    patch.lfoRate = lfoRate
    patch.lfoToPitch = lfoToPitch
    patch.lfoToWidth = lfoToWidth
    patch.lfoToCutoff = lfoToCutoff
    patch.cutoffEnvelope = cutoffEnvelope
    patch.cutoffDecay = cutoffDecay
    patch.syncsDetuned = syncsDetuned == 1
    patch.ringMix = ringMix
    patch.drive = drive
    channelPatches[Int(channel)] = patch
    SynthEngine.setPatch(patch, channel: Int(channel))
}

/// Stops every pattern and takes every voice with it.
@_cdecl("luma_synth_hush")
public func luma_synth_hush() {
    SynthEngine.hush()
}

/// Back to how it started. A channel below zero asks for all of them, and
/// the rest of the synth with them.
@_cdecl("luma_synth_reset")
public func luma_synth_reset(_ channel: Int32) {
    if channel < 0 {
        SynthEngine.reset(channel: nil)
        SynthEngine.level = 0.6
        for index in 0..<SynthEngine.channelCount {
            channelPatches[index] = SynthEngine.PatchValues()
        }
    } else {
        SynthEngine.reset(channel: Int(channel))
        // The colour it was given is remembered here, so it has to go too or
        // the next patch would take it back.
        channelPatches[Int(channel)] = SynthEngine.PatchValues()
    }
}

/// Where a channel sits between the speakers.
@_cdecl("luma_synth_set_pan")
public func luma_synth_set_pan(_ channel: Int32, _ pan: Float) {
    SynthEngine.setPan(pan, channel: Int(channel))
}

/// One tap of delay across everything.
@_cdecl("luma_synth_set_echo")
public func luma_synth_set_echo(_ seconds: Float, _ feedback: Float, _ mix: Float) {
    SynthEngine.setEcho(seconds: seconds, feedback: feedback, mix: mix)
}

@_cdecl("luma_synth_set_patch")
public func luma_synth_set_patch(
    _ channel: Int32,
    _ waveform: Int32,
    _ detuneSemitones: Float,
    _ attack: Float,
    _ decay: Float,
    _ sustain: Float,
    _ release: Float,
    _ cutoff: Float,
    _ resonance: Float,
    _ gain: Float
) {
    var patch = SynthEngine.PatchValues()
    patch.waveform = waveform
    patch.detuneSemitones = detuneSemitones
    patch.attack = attack
    patch.decay = decay
    patch.sustain = sustain
    patch.release = release
    patch.cutoff = cutoff
    patch.resonance = resonance
    patch.gain = gain
    // The colour it was last given stays put: only what was named changes.
    let held = channelPatches[Int(channel)]
    patch.pulseWidth = held.pulseWidth
    patch.lfoRate = held.lfoRate
    patch.lfoToPitch = held.lfoToPitch
    patch.lfoToWidth = held.lfoToWidth
    patch.lfoToCutoff = held.lfoToCutoff
    patch.cutoffEnvelope = held.cutoffEnvelope
    patch.cutoffDecay = held.cutoffDecay
    patch.syncsDetuned = held.syncsDetuned
    patch.ringMix = held.ringMix
    patch.drive = held.drive
    channelPatches[Int(channel)] = patch
    SynthEngine.setPatch(patch, channel: Int(channel))
}

@_cdecl("luma_synth_play")
public func luma_synth_play(_ channel: Int32, _ frequency: Float, _ velocity: Float) -> Int32 {
    SynthEngine.play(frequency: frequency, velocity: velocity, channel: Int(channel))
}

@_cdecl("luma_synth_release")
public func luma_synth_release(_ voice: Int32) {
    SynthEngine.release(voice: voice)
}

@_cdecl("luma_synth_pattern_begin")
public func luma_synth_pattern_begin(_ channel: Int32) {
    SynthEngine.beginPattern(channel: Int(channel))
}

@_cdecl("luma_synth_pattern_add")
public func luma_synth_pattern_add(_ channel: Int32, _ frequency: Float, _ velocity: Float, _ steps: Int32) {
    SynthEngine.addStep(frequency: frequency, velocity: velocity, steps: steps, channel: Int(channel))
}

@_cdecl("luma_synth_pattern_add_tone")
public func luma_synth_pattern_add_tone(_ channel: Int32, _ frequency: Float) {
    SynthEngine.addTone(frequency: frequency, channel: Int(channel))
}

@_cdecl("luma_synth_pattern_commit")
public func luma_synth_pattern_commit(_ channel: Int32, _ stepSeconds: Float, _ loops: Int32) {
    SynthEngine.commitPattern(stepSeconds: stepSeconds, loops: loops == 1, channel: Int(channel))
}

@_cdecl("luma_synth_pattern_stop")
public func luma_synth_pattern_stop(_ channel: Int32) {
    SynthEngine.stopPattern(channel: Int(channel))
}
