#ifndef LUMA_CLUMAAUDIO_H
#define LUMA_CLUMAAUDIO_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    LUMA_WAVEFORM_SINE = 0,
    LUMA_WAVEFORM_TRIANGLE = 1,
    LUMA_WAVEFORM_SAW = 2,
    LUMA_WAVEFORM_SQUARE = 3,
    LUMA_WAVEFORM_NOISE = 4,
} LumaWaveform;

// A voice's whole recipe as data, so a patch is declared rather than coded:
// by a preset today, by an object in the image later.
typedef struct {
    int waveform;
    // Second oscillator's offset. Zero leaves it in unison, which just
    // thickens the tone.
    float detune_semitones;
    float attack_seconds;
    float decay_seconds;
    float sustain_level;
    float release_seconds;
    float cutoff_hz;
    // 0 is unresonant, approaching 1 self-oscillates.
    float resonance;
    float gain;
} LumaSynthPatch;

// Opens the default output device and starts the mixer. Answers false if
// the host has no usable device, which is not fatal: every other entry
// point stays callable and simply goes unheard.
bool luma_audio_start(void);
void luma_audio_stop(void);
bool luma_audio_is_running(void);

// Master level, 0..1, applied after the mix.
void luma_audio_set_level(float level);

// The patch every subsequently triggered voice is built from.
void luma_audio_set_patch(const LumaSynthPatch *patch);

// Triggers a voice, answering the index it landed on so it can be
// released. A patch whose sustain level is zero needs no release: the
// envelope runs to silence on its own.
int luma_audio_note_on(float frequency_hz, float velocity);
void luma_audio_note_off(int voice);

// Shapes the next pattern, then offers it. The performing pattern is only
// swapped at a cycle boundary, so an edit lands musically instead of jumping
// mid-bar. A frequency of zero is a rest; `steps` is the note's length on the
// grid. Committing while nothing plays starts at once.
void luma_audio_pattern_begin(void);
void luma_audio_pattern_add(float frequency_hz, float velocity, int steps);
void luma_audio_pattern_commit(float step_seconds, int loops);
void luma_audio_pattern_stop(void);

// Mixes without a device, for tests and for the previews a notebook keeps.
// Interleaves `channels` channels into `frames`.
void luma_audio_render_offline(float *frames, int frame_count, int channels);

#ifdef __cplusplus
}
#endif

#endif
