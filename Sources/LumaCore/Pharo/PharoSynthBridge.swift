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

@_cdecl("luma_synth_pattern_commit")
public func luma_synth_pattern_commit(_ channel: Int32, _ stepSeconds: Float, _ loops: Int32) {
    SynthEngine.commitPattern(stepSeconds: stepSeconds, loops: loops == 1, channel: Int(channel))
}

@_cdecl("luma_synth_pattern_stop")
public func luma_synth_pattern_stop(_ channel: Int32) {
    SynthEngine.stopPattern(channel: Int(channel))
}
