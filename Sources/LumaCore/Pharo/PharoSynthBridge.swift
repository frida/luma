import CLumaAudio

/// What the image is allowed to do to the synthesiser. The mixer is reached
/// through a lock-free queue, so the image calling these from its own thread
/// needs no hop to the host's.
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
    luma_audio_start() ? 1 : 0
}

@_cdecl("luma_synth_stop")
public func luma_synth_stop() {
    luma_audio_stop()
}

@_cdecl("luma_synth_set_level")
public func luma_synth_set_level(_ level: Float) {
    luma_audio_set_level(level)
}

@_cdecl("luma_synth_set_patch")
public func luma_synth_set_patch(
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
    var patch = LumaSynthPatch(
        waveform: waveform,
        detune_semitones: detuneSemitones,
        attack_seconds: attack,
        decay_seconds: decay,
        sustain_level: sustain,
        release_seconds: release,
        cutoff_hz: cutoff,
        resonance: resonance,
        gain: gain
    )
    luma_audio_set_patch(&patch)
}

@_cdecl("luma_synth_play")
public func luma_synth_play(_ frequency: Float, _ velocity: Float) -> Int32 {
    luma_audio_note_on(frequency, velocity)
}

@_cdecl("luma_synth_release")
public func luma_synth_release(_ voice: Int32) {
    luma_audio_note_off(voice)
}
